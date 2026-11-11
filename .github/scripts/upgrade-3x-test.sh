#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | upgrade-3x-test.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-11
 Updated:   2026-11-11

 Purpose:
     Upgrade from macOSLAPS 3.0.4 (781), the last 3.x release: install it,
     rotate with it, let -getPassword write its plaintext files, then
     install the new packages over it. The new build must migrate the
     password from 3.0.4's keychain item through the legacy helper (signed
     builds; unsigned builds can only use the plaintext file), keep its
     creation date, remove the old item and the plaintext files, and keep
     rotating.

 Usage:
     sudo bash .github/scripts/upgrade-3x-test.sh <3.0.4 pkg> \
         <dir with the new pkgs> <signed: true|false>
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
### Paths, the test account and helpers.                                    ###
set -uo pipefail

OLD_PKG=$1; NEW_DIR=$2; SIGNED=${3:-false}
LAPS=/usr/local/laps/macOSLAPS
ACCT=laps3x
FIRST='Initial-Pass-3x-1234'
DOMAIN=/Library/Preferences/edu.psu.macoslaps
SYSKC=/Library/Keychains/System.keychain
SVC=com.joshua-d-miller.macoslaps
PLAIN_PW="/var/root/Library/Application Support/macOSLAPS-password"
PLAIN_EXP="/var/root/Library/Application Support/macOSLAPS-expiration"
FAILURES=0

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 2; }
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
fatal() { echo "::error::FATAL: $*"; exit 1; }
stop_daemons() {
    for label in com.joshua-d-miller.macoslaps-check edu.psu.macoslaps-check; do
        for _ in $(seq 1 60); do
            launchctl print "system/$label" 2>/dev/null | grep -q "state = running" || break
            sleep 1
        done
        launchctl bootout "system/$label" 2>/dev/null || true
    done
}
status_field() { "$LAPS" -status | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }
escrow_pw() { "$LAPS" -escrow 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])'; }
comment_of() { security find-generic-password -s "$1" "$SYSKC" 2>/dev/null | grep '"icmt"'; }
NEW_FULL=$(ls "$NEW_DIR"/macOSLAPS-[0-9]*.pkg | head -1)
[ -f "$NEW_FULL" ] || fatal "new full package not found in $NEW_DIR"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------ ###
### | Install 3.0.4 and rotate with it | ###
### ------------------------------------ ###
### 3.x rotates with the FirstPass setting and -getPassword writes the      ###
### password to plaintext files.                                            ###
echo "::group::Install 3.0.4 and rotate with it"
installer -pkg "$OLD_PKG" -target / || fatal "3.0.4 did not install"
stop_daemons
echo "3.0.4 reports: $("$LAPS" -version 2>&1)"
codesign -dv "$LAPS" 2>&1 | grep -E "^Identifier|^TeamIdentifier|^Authority=Developer"
sysadminctl -addUser "$ACCT" -fullName "LAPS 3x" -password "$FIRST" -admin 2>&1
defaults write "$DOMAIN" LocalAdminAccount -string "$ACCT"
defaults write "$DOMAIN" Method -string Local
defaults write "$DOMAIN" FirstPass -string "$FIRST"
defaults write "$DOMAIN" PasswordLength -int 16
defaults write "$DOMAIN" DaysTillExpiration -int 30
# -resetPassword must rotate right away; staging has its own tests.
defaults write "$DOMAIN" StagedRotation -string off
"$LAPS" -firstPass || "$LAPS" -resetPassword || fatal "3.0.4 could not rotate"
"$LAPS" -getPassword || fatal "3.0.4 -getPassword failed"
OLD_PW=$(cat "$PLAIN_PW" 2>/dev/null)
[ -n "$OLD_PW" ] && [ "$OLD_PW" != "$FIRST" ] && dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 \
    && pass "3.0.4 rotated and wrote its plaintext file" || fatal "3.0.4's password does not authenticate"
OLD_CREATED=$(comment_of macOSLAPS)
[ -n "$OLD_CREATED" ] && pass "3.0.4's keychain item: $OLD_CREATED" || fatal "3.0.4 left no macOSLAPS keychain item"
# The files stay in place, as they would on a Mac whose MDM script ran -getPassword.
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------ ###
### | Upgrade to 4.0 | ###
### ------------------ ###
### Migration through the helper when the build is signed.                  ###
echo "::group::Upgrade to 4.0"
installer -pkg "$NEW_FULL" -target / || fatal "the new package did not install over 3.0.4"
stop_daemons
"$LAPS" -status >/dev/null   # migrates now if the installer's run hasn't already
if [ "$SIGNED" = "true" ]; then
    [ "$(status_field migration)" = "migrated" ] && pass "-status: migrated" || fail "-status after upgrade: $("$LAPS" -status)"
    FROM=$(status_field migratedFrom)
    [ "$FROM" = "keychain" ] && pass "the helper read 3.0.4's keychain item" || fail "migrated from '$FROM', expected keychain (helper)"
    [ "$(comment_of "$SVC")" = "$OLD_CREATED" ] && pass "creation date carried over" || fail "creation date: '$(comment_of "$SVC")' vs '$OLD_CREATED'"
else
    # Unsigned: the helper can't read the item and the plaintext file is never used.
    [ "$(status_field migration)" = "required" ] && pass "unsigned build: migration required (plaintext file not used)" || fail "-status after upgrade: $("$LAPS" -status)"
    "$LAPS" -firstPass "$OLD_PW" -initialize >/dev/null 2>&1 && "$LAPS" -status >/dev/null && pass "recovered with -firstPass -initialize" || fail "recovery failed"
fi
[ "$(escrow_pw)" = "$OLD_PW" ] && pass "stored password is 3.0.4's" || fail "stored password differs"
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "3.0.4's keychain item is still there" || pass "3.0.4's keychain item removed"
[ ! -e "$PLAIN_PW" ] && [ ! -e "$PLAIN_EXP" ] && pass "3.0.4's plaintext files removed" || fail "plaintext files left behind"
[ ! -e /Library/LaunchDaemons/edu.psu.macoslaps-check.plist ] && pass "3.0.4's LaunchDaemon removed" || fail "3.0.4's LaunchDaemon left behind"
RECEIPTS=$(pkgutil --pkgs | grep -i laps | sort | tr '\n' ' ')
[ "$RECEIPTS" = "com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps-check " ] && pass "receipts switched" || fail "receipts: $RECEIPTS"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------- ###
### | Rotation after upgrade | ###
### -------------------------- ###
echo "::group::Rotation after upgrade"
"$LAPS" -resetPassword >/dev/null 2>&1 && pass "rotation after upgrade" || fail "rotation after upgrade failed"
NEW_PW=$(escrow_pw)
[ -n "$NEW_PW" ] && [ "$NEW_PW" != "$OLD_PW" ] && dscl . -authonly "$ACCT" "$NEW_PW" >/dev/null 2>&1 && pass "new password works" || fail "new password after upgrade"
dscl . -authonly "$ACCT" "$OLD_PW" >/dev/null 2>&1 && fail "3.0.4's password still works" || pass "3.0.4's password invalidated"
echo "::endgroup::"

echo "----"
if [ "$FAILURES" -gt 0 ]; then echo "::error::$FAILURES check(s) failed on $(sw_vers -productVersion)"; exit 1; fi
echo "All 3.0.4 upgrade checks passed on $(sw_vers -productVersion)"
