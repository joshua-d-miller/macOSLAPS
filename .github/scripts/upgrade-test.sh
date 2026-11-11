#!/bin/bash
# Upgrade test: install the last published release, rotate with it, then install the
# new packages over it and prove nothing an existing deployment relies on breaks.
#   sudo bash .github/scripts/upgrade-test.sh <old full pkg> <dir with the new pkgs> <signed: true|false>
#
# Migration: the new build (signed com.joshua-d-miller.macoslaps) can't read the old
# "macOSLAPS" item; its helper (signed edu.psu.macOSLAPS) reads it and the password moves
# to the new item. That needs the Developer ID signature, so unsigned builds migrate
# from the -getPassword export instead (the fallback).
set -uo pipefail

OLD_PKG=$1; NEW_DIR=$2; SIGNED=${3:-false}
LAPS=/usr/local/laps/macOSLAPS
ACCT=lapsupgrade
FIRST='Initial-Pass-1234'
DOMAIN=/Library/Preferences/edu.psu.macoslaps
SYSKC=/Library/Keychains/System.keychain
SVC=com.joshua-d-miller.macoslaps
REPO=$(cd "$(dirname "$0")/../.." && pwd)
FAILURES=0

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 2; }
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
fatal() { echo "::error::FATAL: $*"; exit 1; }
stop_daemon() {
    # Let a run started by the installer's kickstart finish first (it may be migrating).
    for _ in $(seq 1 60); do
        launchctl print system/edu.psu.macoslaps-check 2>/dev/null | grep -q "state = running" || break
        sleep 1
    done
    launchctl bootout system/edu.psu.macoslaps-check 2>/dev/null || true
}
status_field() { "$LAPS" -status | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$1"; }
comment_of() { security find-generic-password -s "$1" "$SYSKC" 2>/dev/null | grep '"icmt"'; }
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
# Most checks expect -resetPassword to rotate immediately; staging has its own tests.
defaults write "$DOMAIN" StagedRotation -string off
"$LAPS" -resetPassword || fatal "previous release could not rotate"
OLD_PW=$(get_pw) || fatal "previous release could not export"
dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 && pass "previous release rotated and exported" || fatal "previous release's password does not authenticate"
OLD_CREATED=$(comment_of macOSLAPS)
OLD_EXPORT=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
echo "Previous release's item: $OLD_CREATED"
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

echo "::group::Migration from the previous release's keychain item"
"$LAPS" -status >/dev/null   # migrates now if the installer's run hasn't already
[ "$(status_field migration)" = "migrated" ] && pass "-status: migrated" || fail "-status after upgrade: $("$LAPS" -status)"
FROM=$(status_field migratedFrom)
if [ "$SIGNED" = "true" ]; then
    [ "$FROM" = "keychain" ] && pass "migrated through the legacy helper" || fail "migrated from '$FROM', expected keychain (helper)"
else
    [ "$FROM" = "getPassword export" ] && pass "unsigned build migrated from the -getPassword export" || fail "unsigned build migrated from '$FROM'"
fi
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "the legacy macOSLAPS item is still there" || pass "the legacy macOSLAPS item was removed"
security find-generic-password -s "$OLD_EXPORT" "$SYSKC" >/dev/null 2>&1 && fail "the previous release's -getPassword export is still there" || pass "the previous release's -getPassword export was removed"
[ "$(comment_of "$SVC")" = "$OLD_CREATED" ] && pass "creation date carried over (rotation stays on schedule)" || fail "creation date: '$(comment_of "$SVC")' vs '$OLD_CREATED'"
security find-generic-password -s "$SVC" "$SYSKC" 2>/dev/null | grep -qF "\"acct\"<blob>=\"$ACCT\"" && pass "new item's account is the admin's short name" || fail "new item's account attribute"
NEW_READ=$(get_pw) && [ "$NEW_READ" = "$OLD_PW" ] && pass "migrated password unchanged" || fail "migrated password differs or cannot be exported"
"$LAPS" -status | grep -q '"passwordVerifies":true' && pass "-status: stored password verifies" || fail "-status after upgrade: $("$LAPS" -status)"
"$LAPS" -resetPassword && pass "rotation after upgrade" || fail "rotation after upgrade failed"
NEW_PW=$(get_pw)
[ -n "$NEW_PW" ] && [ "$NEW_PW" != "$OLD_PW" ] && dscl . -authonly "$ACCT" "$NEW_PW" >/dev/null 2>&1 && pass "new password works" || fail "new password after upgrade"
dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 && fail "old password still works" || pass "old password invalidated"
[ "$(security find-generic-password -s "$SVC" "$SYSKC" 2>/dev/null | grep -c '"svce"')" = "1" ] && pass "exactly one $SVC keychain item" || fail "duplicate $SVC keychain items"
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "rotation re-created a legacy item" || pass "no legacy item after rotation"
echo "::endgroup::"

echo "::group::Migration required, and recovery with -firstPass -initialize"
# A legacy item nobody can use: it trusts only /usr/bin/security and holds a wrong password.
CUR=$NEW_PW
security delete-generic-password -s "$SVC" "$SYSKC" >/dev/null 2>&1
security add-generic-password -s macOSLAPS -a "LAPS Password" -w 'Not-The-Password-1' -j "Created: 2026-01-01 00:00:00" "$SYSKC"
rm -f /var/root/.GeneratedLAPSServiceName
if "$LAPS" -resetPassword >/dev/null 2>&1; then fail "rotation ran although migration is required"; else pass "rotation stops when migration is required"; fi
dscl . -authonly "$ACCT" "$CUR" >/dev/null 2>&1 && pass "account untouched when migration is required" || fail "account changed although migration is required"
if "$LAPS" -escrow >/dev/null 2>&1; then fail "-escrow succeeded although migration is required"; else pass "-escrow fails closed when migration is required"; fi
[ "$(status_field migration)" = "required" ] && pass "-status: migration required" || fail "-status migration: $("$LAPS" -status)"
"$LAPS" -status -v 2>/dev/null | grep -q "firstPass" && pass "-status -v explains the fix" || fail "-status -v output: $("$LAPS" -status -v 2>&1 | tail -20)"
"$LAPS" -firstPass "$CUR" -initialize >/dev/null 2>&1 && pass "-firstPass -initialize recovers" || fail "-firstPass -initialize failed while migration was required"
"$LAPS" -status >/dev/null
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "unusable legacy item left after recovery" || pass "unusable legacy item retired after recovery"
[ "$(status_field migration)" != "required" ] && pass "-status: no longer required" || fail "-status still says required"
echo "::endgroup::"

echo "::group::Fallback: 3.x plaintext file"
security delete-generic-password -s "$SVC" "$SYSKC" >/dev/null 2>&1
security add-generic-password -s macOSLAPS -a "LAPS Password" -w 'Not-The-Password-2' -j "Created: 2026-02-03 04:05:06" "$SYSKC"
mkdir -p "/var/root/Library/Application Support"
printf '%s\n' "$CUR" > "/var/root/Library/Application Support/macOSLAPS-password"
echo "2026-03-05 04:05:06" > "/var/root/Library/Application Support/macOSLAPS-expiration"
"$LAPS" -status >/dev/null
[ "$(status_field migratedFrom)" = "3.x plaintext file" ] && pass "migrated from the 3.x plaintext file" || fail "migratedFrom: $(status_field migratedFrom)"
[ ! -e "/var/root/Library/Application Support/macOSLAPS-password" ] && [ ! -e "/var/root/Library/Application Support/macOSLAPS-expiration" ] && pass "3.x plaintext files removed" || fail "3.x plaintext files left behind"
[ "$(comment_of "$SVC")" = '"icmt"<blob>="Created: 2026-02-03 04:05:06"' ] && pass "creation date taken from the legacy item's attributes" || fail "creation date: $(comment_of "$SVC")"
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "legacy item left after the plaintext migration" || pass "legacy item removed"
[ "$(get_pw)" = "$CUR" ] && pass "password from the plaintext file stored" || fail "stored password after the plaintext migration"
# The 2026-02-03 date is long past: a scheduled run now rotates.
"$LAPS" >/dev/null 2>&1 && pass "scheduled run after the plaintext migration" || fail "scheduled run failed: $(tail -5 /Library/Logs/macOSLAPS.log)"
NEW_PW=$(get_pw)
[ "$NEW_PW" != "$CUR" ] && dscl . -authonly "$ACCT" "$NEW_PW" >/dev/null 2>&1 && pass "overdue migrated password rotated on schedule" || fail "overdue migrated password was not rotated"
echo "::endgroup::"

echo "::group::Use a password with shell and JSON special characters for the script checks"
# Random passwords only sometimes contain these, so set one that always does.
TRICKY='Ab\c"d/e$f`g*h\b1'
dscl . -passwd "/Users/$ACCT" "$NEW_PW" "$TRICKY" && "$LAPS" -firstPass "$TRICKY" -initialize >/dev/null 2>&1 \
    && [ "$(get_pw)" = "$TRICKY" ] && pass "stored a password containing \\ \" / \$ \` * " || fail "could not set the special-character password"
NEW_PW=$TRICKY
echo "::endgroup::"

redact() { python3 -c 'import sys; print(sys.argv[1].replace(sys.argv[2], "<password>"))' "$1" "$NEW_PW"; }
echo "::group::Scripts admins already deploy keep working"
OUT=$(zsh "$REPO/MDM Scripts/macoslaps4-mdm-password-and-expiration.sh" 2>&1)
redact "$OUT"
echo "$OUT" | grep -qF "Successfully retrieved following password: $NEW_PW (expires 20" && pass "MDM password-and-expiration script" || fail "MDM password-and-expiration script output"
OUT=$(zsh "$REPO/MDM Scripts/macoslaps4-mdm-password-simple.sh" 2>&1)
echo "$OUT" | grep -qF "$NEW_PW (expires 20" && pass "MDM password-simple script" || fail "MDM password-simple script output: $(redact "$OUT")"
# The Jamf extension attributes read LocalAdminAccount from a managed profile.
mkdir -p "/Library/Managed Preferences"
cp "$DOMAIN.plist" "/Library/Managed Preferences/edu.psu.macoslaps.plist"
OUT=$(zsh "$REPO/jamf Extension Attributes/Password and Expiration Combined.zsh" 2>&1)
echo "$OUT" | grep -qE "^<result>\| Password: .+ \| Expiration: 20[0-9-]+ [0-9:]+ \|</result>$" && echo "$OUT" | grep -qF "Password: $NEW_PW |" \
    && pass "Jamf combined extension attribute" || fail "Jamf combined EA output: $(redact "$OUT")"
OUT=$(zsh "$REPO/jamf Extension Attributes/Password Only.zsh" 2>&1)
[ "$OUT" = "<result>| Password: $NEW_PW |</result>" ] && pass "Jamf password extension attribute" || fail "Jamf password EA output"
OUT=$(zsh "$REPO/jamf Extension Attributes/Expiration Only.zsh" 2>&1)
echo "$OUT" | grep -qE "^<result>\| Expiration: 20[0-9-]+ [0-9:]+ \|</result>$" && pass "Jamf expiration extension attribute" || fail "Jamf expiration EA output: $OUT"
OUT=$(zsh "$REPO/integrations/jamf/macOSLAPS-Escrow-EA.zsh" 2>&1)
# Compare the parsed JSON: the password may contain characters JSON escapes (" and \).
python3 -c 'import json,re,sys; m=re.search(r"<result>(.*)</result>", sys.argv[1], re.S); assert m and json.loads(m.group(1))["password"]==sys.argv[2]' "$OUT" "$NEW_PW" \
    && pass "integrations/jamf escrow attribute" || fail "integrations/jamf escrow EA output"
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

# Installer choices: same IDs as 845, and turning off installer_choice_2 skips the LaunchDaemon.
installer -showChoicesXML -pkg "$NEW_FULL" -target / > /tmp/laps-choices.xml 2>/dev/null
for c in installer_choice_1 installer_choice_2; do
    grep -q "<string>$c</string>" /tmp/laps-choices.xml && pass "full pkg has choice $c" || fail "full pkg is missing choice $c"
done
stop_daemon; rm -f /Library/LaunchDaemons/edu.psu.macoslaps-check.plist; pkgutil --forget edu.psu.macOSLAPS-check >/dev/null 2>&1
cat > /tmp/laps-skip-daemon.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>attributeSetting</key><integer>0</integer>
  <key>choiceAttribute</key><string>selected</string>
  <key>choiceIdentifier</key><string>installer_choice_2</string>
</dict></array></plist>
XML
installer -pkg "$NEW_FULL" -applyChoiceChangesXML /tmp/laps-skip-daemon.xml -target / >/dev/null \
    && pass "full pkg installs with installer_choice_2 turned off" || fail "install with choice changes failed"
[ ! -f /Library/LaunchDaemons/edu.psu.macoslaps-check.plist ] && ! pkgutil --pkgs | grep -qx edu.psu.macOSLAPS-check \
    && pass "LaunchDaemon skipped when installer_choice_2 is off" || fail "LaunchDaemon was installed despite installer_choice_2 off"
[ -x "$LAPS" ] && pass "binary installed with the daemon skipped" || fail "binary missing after choice install"
if [ "$SIGNED" = "true" ]; then
    for p in "$NEW_FULL" "$NEW_BIN" "$NEW_LD"; do
        spctl --assess --type install -vv "$p" 2>&1 | grep -q "accepted" && pass "Gatekeeper accepts $(basename "$p")" || fail "Gatekeeper rejects $(basename "$p"): $(spctl --assess --type install -vv "$p" 2>&1 | tr '\n' ' ')"
    done
fi
echo "::endgroup::"

echo "----"
if [ "$FAILURES" -gt 0 ]; then echo "::error::$FAILURES upgrade check(s) failed on $(sw_vers -productVersion)"; exit 1; fi
echo "All upgrade checks passed on $(sw_vers -productVersion)"
