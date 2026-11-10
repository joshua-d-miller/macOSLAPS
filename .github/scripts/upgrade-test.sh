#!/bin/bash
# Upgrade test: install the last published release, rotate with it, then install the
# new packages over it and prove nothing an existing deployment relies on breaks.
#   sudo bash .github/scripts/upgrade-test.sh <old full pkg> <dir with the new pkgs> <signed: true|false>
#
# Keychain continuity (the new binary reading the item the old binary created) depends
# on the Developer ID signature, so that check only runs for signed builds.
set -uo pipefail

OLD_PKG=$1; NEW_DIR=$2; SIGNED=${3:-false}
LAPS=/usr/local/laps/macOSLAPS
ACCT=lapsupgrade
FIRST='Initial-Pass-1234'
DOMAIN=/Library/Preferences/edu.psu.macoslaps
SYSKC=/Library/Keychains/System.keychain
REPO=$(cd "$(dirname "$0")/../.." && pwd)
FAILURES=0

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 2; }
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
fatal() { echo "::error::FATAL: $*"; exit 1; }
stop_daemon() { launchctl bootout system/edu.psu.macoslaps-check 2>/dev/null || true; }
get_pw() {
    "$LAPS" -getPassword >&2 || return 1
    security find-generic-password -w -s "$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)" "$SYSKC"
}
NEW_FULL=$(ls "$NEW_DIR"/macOSLAPS-[0-9]*.pkg | head -1)
NEW_BIN=$(ls "$NEW_DIR"/macOSLAPS-Binary-*.pkg | head -1)
NEW_LD=$(ls "$NEW_DIR"/macOSLAPS-LD-*.pkg | head -1)
[ -f "$NEW_FULL" ] && [ -f "$NEW_BIN" ] && [ -f "$NEW_LD" ] || fatal "new packages not found in $NEW_DIR"

echo "::group::Install the previous release and rotate with it"
installer -pkg "$OLD_PKG" -target / || fatal "previous release did not install"
stop_daemon
OLD_VERSION=$("$LAPS" -version)
echo "Previous release: $OLD_VERSION"; codesign -dv "$LAPS" 2>&1 | grep -E "Identifier|TeamIdentifier"
pkgutil --pkgs | grep -i laps
sysadminctl -addUser "$ACCT" -fullName "LAPS Upgrade" -password "$FIRST" -admin 2>&1
defaults write "$DOMAIN" LocalAdminAccount -string "$ACCT"
defaults write "$DOMAIN" Method -string Local
defaults write "$DOMAIN" FirstPass -string "$FIRST"
defaults write "$DOMAIN" PasswordLength -int 16
defaults write "$DOMAIN" DaysTillExpiration -int 30
"$LAPS" -resetPassword || fatal "previous release could not rotate"
OLD_PW=$(get_pw) || fatal "previous release could not export"
dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 && pass "previous release rotated and exported" || fatal "previous release's password does not authenticate"
# Deliberately leave the export and /var/root/.GeneratedLAPSServiceName in place, as an
# MDM script would between its two calls.
echo "::endgroup::"

echo "::group::Upgrade in place"
installer -pkg "$NEW_FULL" -target / || fatal "new package did not install over the previous release"
launchctl print system/edu.psu.macoslaps-check >/dev/null 2>&1 && pass "LaunchDaemon loaded after upgrade" || fail "LaunchDaemon not loaded after upgrade"
stop_daemon
RECEIPTS=$(pkgutil --pkgs | grep -i laps | sort | tr '\n' ' ')
[ "$RECEIPTS" = "edu.psu.macOSLAPS edu.psu.macOSLAPS-check " ] && pass "same two receipts as before, no extras" || fail "receipts after upgrade: $RECEIPTS"
[ "$(cat /etc/paths.d/laps 2>/dev/null)" = "/usr/local/laps" ] && pass "/etc/paths.d/laps present" || fail "/etc/paths.d/laps missing"
NEW_VERSION=$("$LAPS" -version 2>/dev/null)
re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$NEW_VERSION" =~ $re ]] && pass "-version prints only the version with an export pending ($NEW_VERSION)" || fail "-version output: $(printf '%q' "$NEW_VERSION")"
echo "::endgroup::"

echo "::group::The new build reads the previous release's keychain item"
if [ "$SIGNED" = "true" ]; then
    NEW_READ=$(get_pw) && [ "$NEW_READ" = "$OLD_PW" ] && pass "stored password readable after upgrade, unchanged" || fail "new build cannot read the previous release's keychain item"
    "$LAPS" -status | grep -q '"passwordVerifies":true' && pass "-status: stored password verifies" || fail "-status after upgrade: $("$LAPS" -status)"
    "$LAPS" -resetPassword && pass "rotation after upgrade" || fail "rotation after upgrade failed"
    NEW_PW=$(get_pw)
    [ -n "$NEW_PW" ] && [ "$NEW_PW" != "$OLD_PW" ] && dscl . -authonly "$ACCT" "$NEW_PW" >/dev/null 2>&1 && pass "new password works" || fail "new password after upgrade"
    dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 && fail "old password still works" || pass "old password invalidated"
    [ "$(security find-generic-password -s macOSLAPS "$SYSKC" 2>/dev/null | grep -c '"svce"')" = "1" ] && pass "still exactly one macOSLAPS keychain item" || fail "duplicate macOSLAPS keychain items"
else
    echo "::notice::Unsigned build: keychain continuity needs the Developer ID signature and is not tested here."
    security delete-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1
    dscl . -passwd "/Users/$ACCT" "$FIRST"
    "$LAPS" -resetPassword || fail "rotation failed"
    NEW_PW=$(get_pw)
fi
echo "::endgroup::"

echo "::group::Scripts admins already deploy keep working"
OUT=$(zsh "$REPO/MDM Scripts/macoslaps4-mdm-password-and-expiration.sh" 2>&1)
echo "$OUT" | sed "s/$NEW_PW/<password>/"
echo "$OUT" | grep -qF "Successfully retrieved following password: $NEW_PW (expires 20" && pass "MDM password-and-expiration script" || fail "MDM password-and-expiration script output"
OUT=$(zsh "$REPO/MDM Scripts/macoslaps4-mdm-password-simple.sh" 2>&1)
echo "$OUT" | grep -qF "$NEW_PW (expires 20" && pass "MDM password-simple script" || fail "MDM password-simple script output: $(echo "$OUT" | sed "s/$NEW_PW/<password>/")"
# The Jamf extension attributes read LocalAdminAccount from a managed profile.
mkdir -p "/Library/Managed Preferences"
cp "$DOMAIN.plist" "/Library/Managed Preferences/edu.psu.macoslaps.plist"
OUT=$(zsh "$REPO/jamf Extension Attributes/Password:Expiration Combined.zsh" 2>&1)
echo "$OUT" | grep -qE "^<result>\| Password: .+ \| Expiration: 20[0-9-]+ [0-9:]+ \|</result>$" && echo "$OUT" | grep -qF "Password: $NEW_PW |" \
    && pass "Jamf combined extension attribute" || fail "Jamf combined EA output: $(echo "$OUT" | sed "s/$NEW_PW/<password>/")"
OUT=$(zsh "$REPO/jamf Extension Attributes/Password Only.zsh" 2>&1)
[ "$OUT" = "<result>| Password: $NEW_PW |</result>" ] && pass "Jamf password extension attribute" || fail "Jamf password EA output"
OUT=$(zsh "$REPO/jamf Extension Attributes/Expiration Only.zsh" 2>&1)
echo "$OUT" | grep -qE "^<result>\| Expiration: 20[0-9-]+ [0-9:]+ \|</result>$" && pass "Jamf expiration extension attribute" || fail "Jamf expiration EA output: $OUT"
OUT=$(zsh "$REPO/integrations/jamf/macOSLAPS-Escrow-EA.zsh" 2>&1)
echo "$OUT" | grep -qF "\"password\":\"$NEW_PW\"" && pass "integrations/jamf escrow attribute" || fail "integrations/jamf escrow EA output"
rm -f "/Library/Managed Preferences/edu.psu.macoslaps.plist"
dscl . -authonly "$ACCT" "$NEW_PW" >/dev/null 2>&1 && pass "none of the scripts rotated the password" || fail "a script rotated the password unexpectedly"
echo "::endgroup::"

echo "::group::Binary-only and LaunchDaemon-only packages"
installer -pkg "$NEW_BIN" -target / && pass "Binary package installs" || fail "Binary package failed"
installer -pkg "$NEW_LD" -target / && pass "LaunchDaemon package installs" || fail "LaunchDaemon package failed"
launchctl print system/edu.psu.macoslaps-check >/dev/null 2>&1 && pass "LaunchDaemon loaded by the LD package" || fail "LaunchDaemon not loaded by the LD package"
stop_daemon
RECEIPTS=$(pkgutil --pkgs | grep -i laps | sort | tr '\n' ' ')
[ "$RECEIPTS" = "edu.psu.macOSLAPS edu.psu.macOSLAPS-check " ] && pass "receipts unchanged" || fail "receipts: $RECEIPTS"
if [ "$SIGNED" = "true" ]; then
    for p in "$NEW_FULL" "$NEW_BIN" "$NEW_LD"; do
        spctl --assess --type install -vv "$p" 2>&1 | grep -q "accepted" && pass "Gatekeeper accepts $(basename "$p")" || fail "Gatekeeper rejects $(basename "$p"): $(spctl --assess --type install -vv "$p" 2>&1 | tr '\n' ' ')"
    done
fi
echo "::endgroup::"

echo "----"
if [ "$FAILURES" -gt 0 ]; then echo "::error::$FAILURES upgrade check(s) failed on $(sw_vers -productVersion)"; exit 1; fi
echo "All upgrade checks passed on $(sw_vers -productVersion)"
