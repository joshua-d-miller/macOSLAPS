#!/bin/bash
# Which code-signing identities can read a System keychain item created by another?
# Answers the questions the app-bundle migration depends on:
#   1. Does an item created by edu.psu.macOSLAPS stay readable by the same identity at
#      another path (the ACL matches the designated requirement, not the path)?
#   2. Is a binary signed com.joshua-d-miller.macoslaps (same team) denied?
#   3. Can a helper signed edu.psu.macOSLAPS inside an app signed with the new identity
#      read it and delete it?
#   4. The same against a real item created by the signed 4.0.0 (845) release.
#   sudo bash keychain-identity-probe.sh <dir with signed probes> <845 pkg>
set -uo pipefail
P=$1; OLD_PKG=$2
A=$P/a/kcprobe; A2=$P/elsewhere/kcprobe; B=$P/b/kcprobe
APP=$P/Probe.app; MAIN=$APP/Contents/MacOS/Probe; HELPER=$APP/Contents/Helpers/kcprobe-legacy
FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
expect_read() {  # expect_read <ok|denied> <binary> <service> <label> [expected password]
    out=$("$2" read "$3" 2>&1); rc=$?
    if [ "$1" = ok ]; then
        [ $rc -eq 0 ] && { [ -z "${5:-}" ] || [ "$out" = "$5" ]; } && pass "$4 can read" || fail "$4 could not read: $out"
    else
        [ $rc -ne 0 ] && pass "$4 is denied ($out)" || fail "$4 was NOT denied"
    fi
}
for b in "$A" "$A2" "$B" "$MAIN" "$HELPER"; do codesign -dv "$b" 2>&1 | grep -E "^Identifier|^TeamIdentifier|^Authority=Developer" | tr '\n' ' '; echo " <- $b"; done

echo "::group::Item created by a probe signed edu.psu.macOSLAPS"
SVC=macOSLAPS-probe-$$
"$A" add "$SVC" 'Probe-Pass-1' || { echo "::error::could not create the probe item"; exit 1; }
security dump-keychain -a /Library/Keychains/System.keychain 2>/dev/null | grep -A40 "\"$SVC\"" | grep -iE "applications|requirement|identifier" | head -8
expect_read ok     "$A2"     "$SVC" "same identity at another path" 'Probe-Pass-1'
expect_read denied "$B"      "$SVC" "com.joshua-d-miller.macoslaps (same team)"
expect_read denied "$MAIN"   "$SVC" "app main executable (new identity)"
expect_read ok     "$HELPER" "$SVC" "legacy helper inside the app bundle" 'Probe-Pass-1'
# Deleting needs the item's owner entry, which trusts no app (so it would prompt).
# Record what works for retiring the legacy item after migration.
"$HELPER" delete "$SVC" 2>&1 && echo "RESULT: legacy helper CAN delete" || echo "RESULT: legacy helper cannot delete (expected)"
"$HELPER" update "$SVC" 'MIGRATED' && [ "$("$HELPER" read "$SVC")" = MIGRATED ] && pass "legacy helper can overwrite the item with a tombstone" || fail "legacy helper could not overwrite the item"
security delete-generic-password -s "$SVC" /Library/Keychains/System.keychain >/dev/null 2>&1 \
    && echo "RESULT: root 'security delete-generic-password' CAN delete" || echo "RESULT: root 'security delete-generic-password' cannot delete"
security find-generic-password -s "$SVC" /Library/Keychains/System.keychain >/dev/null 2>&1 && echo "RESULT: item still present" || echo "RESULT: item gone"
echo "::endgroup::"

echo "::group::Item created by the signed 4.0.0 (845) release"
installer -pkg "$OLD_PKG" -target / >/dev/null || { echo "::error::845 did not install"; exit 1; }
launchctl bootout system/edu.psu.macoslaps-check 2>/dev/null || true
LAPS=/usr/local/laps/macOSLAPS; DOMAIN=/Library/Preferences/edu.psu.macoslaps
codesign -dv "$LAPS" 2>&1 | grep -E "^Identifier|^TeamIdentifier|^Authority=Developer" | tr '\n' ' '; echo " <- 845"
sysadminctl -addUser lapsprobe -fullName "LAPS Probe" -password 'Initial-Pass-1234' -admin 2>/dev/null
defaults write "$DOMAIN" LocalAdminAccount -string lapsprobe
defaults write "$DOMAIN" Method -string Local
defaults write "$DOMAIN" FirstPass -string 'Initial-Pass-1234'
"$LAPS" -resetPassword >/dev/null 2>&1 || { echo "::error::845 could not rotate"; exit 1; }
REAL=$("$HELPER" read macOSLAPS 2>&1)
dscl . -authonly lapsprobe "$REAL" >/dev/null 2>&1 && pass "legacy helper reads 845's item and the password works" || fail "legacy helper could not read 845's item: $REAL"
expect_read denied "$MAIN" macOSLAPS "app main executable on 845's item"
expect_read denied "$B"    macOSLAPS "com.joshua-d-miller.macoslaps on 845's item"
security delete-generic-password -s macOSLAPS /Library/Keychains/System.keychain >/dev/null 2>&1 \
    && echo "RESULT: root 'security delete-generic-password' CAN delete 845's item" || echo "RESULT: root 'security delete-generic-password' cannot delete 845's item"
echo "::endgroup::"

echo "$FAILURES unexpected result(s)"
[ "$FAILURES" -eq 0 ]
