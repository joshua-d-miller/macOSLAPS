#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | securetoken-test.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-14
 Updated:   2026-11-14

 Purpose:
     A real secureToken and FileVault, not the simulated token of the
     smoke test (issues #96 and #120). GitHub's runner account holds a
     secureToken and logs in automatically, so its password decodes
     from /etc/kcpassword. With it, this grants a token to the managed
     admin, turns FileVault on for both, and runs macOSLAPS:
       - a wrong FirstPass fails closed (token and FileVault untouched)
       - the first rotation with the right FirstPass, then a forced one
       - an outside password change stops rotation without a reset
       - -firstPass <current> takes the account back
     After every rotation the account must keep its token and stay a
     FileVault user, the stored password (-escrow) must unlock the data
     volume (diskutil apfs unlockVolume -verify, no reboot) and the
     previous password must not. Every password is masked in the log.
     Skips with a notice if the runner image no longer allows this.

 Usage:
     sudo bash .github/scripts/securetoken-test.sh <full pkg>
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-14   joshua    New file.
                        claude
===============================================================================
HEADER

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
### Test helpers and names.                                                 ###
set -uo pipefail
PKG="$1"
LAPS=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
DOM=/Library/Preferences/com.joshua-d-miller.macoslaps
ACCT=ladmin
FIRST='Token-First-Pass-1234'
OUTSIDE='Changed-Outside-5678'
echo "::add-mask::$FIRST"; echo "::add-mask::$OUTSIDE"

FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
skip() { echo "::notice::secureToken test skipped: $*"; exit 0; }
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

works()    { dscl . -authonly "$ACCT" "$1" >/dev/null 2>&1; }
token()    { sysadminctl -secureTokenStatus "$ACCT" 2>&1 | grep -q "ENABLED"; }
fv_user()  { fdesetup list 2>/dev/null | cut -d, -f1 | grep -qx "$ACCT"; }
stored()   { jget "$("$LAPS" -escrow 2>/dev/null)" password; }
DATA=$(diskutil info /System/Volumes/Data | awk -F: '/Device Node/{gsub(/ /,"",$2); print $2}')
unlocks()  { diskutil apfs unlockVolume "$DATA" -user "$UUID" -passphrase "$1" -verify 2>&1 | grep -q "Passphrase valid"; }

# The full check after a rotation: $1 label, $2 current password, $3 previous.
check_rotation() {
  local label=$1 current=$2 previous=$3
  [ -n "$current" ] || { fail "$label: no stored password"; return; }
  works "$current"    && pass "$label: the stored password logs in"           || fail "$label: the stored password doesn't log in"
  token               && pass "$label: $ACCT still has its secureToken"      || fail "$label: $ACCT lost its secureToken"
  fv_user             && pass "$label: $ACCT is still a FileVault user"      || fail "$label: $ACCT is no longer a FileVault user"
  unlocks "$current"  && pass "$label: the stored password unlocks FileVault" || fail "$label: the stored password does NOT unlock FileVault"
  if unlocks "$previous"; then fail "$label: the previous password still unlocks FileVault"
  else pass "$label: the previous password no longer unlocks FileVault"; fi
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------- ###
### | The runner's password | ###
### ------------------------- ###
### Decoded from the auto-login file; it must hold a secureToken.           ###
[ -f /etc/kcpassword ] || skip "no /etc/kcpassword on this runner image"
RP=$(python3 -c '
import sys
k=[0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F]
d=open("/etc/kcpassword","rb").read()
print(bytes(b ^ k[i % len(k)] for i,b in enumerate(d)).split(b"\x00")[0].decode("utf-8","replace"))')
echo "::add-mask::$RP"
dscl . -authonly runner "$RP" >/dev/null 2>&1 || skip "the auto-login password doesn't authenticate runner"
sysadminctl -secureTokenStatus runner 2>&1 | grep -q ENABLED || skip "runner has no secureToken on this image"
pass "runner holds a secureToken and its password is known"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------------ ###
### | A token holder with FileVault, for real | ###
### ------------------------------------------ ###
installer -pkg "$PKG" -target / >/dev/null || { echo "::error::install failed"; exit 1; }
pass "installed $(basename "$PKG")"
# The scheduled check must not rotate in the middle of the test.
launchctl bootout system/com.joshua-d-miller.macoslaps-check 2>/dev/null || true
sysadminctl -addUser "$ACCT" -fullName "Local Admin" -password "$FIRST" -admin >/dev/null 2>&1
UUID=$(dscl . -read "/Users/$ACCT" GeneratedUID | awk '{print $2}')
sysadminctl -secureTokenOn "$ACCT" -password "$FIRST" -adminUser runner -adminPassword "$RP" >/dev/null 2>&1
token && pass "$ACCT has a real secureToken" || { fail "could not grant $ACCT a secureToken"; exit 1; }

fv_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Username</key><string>runner</string>
  <key>Password</key><string>$RP</string>
  <key>AdditionalUsers</key><array><dict>
    <key>Username</key><string>$ACCT</string>
    <key>Password</key><string>$FIRST</string>
  </dict></array>
</dict></plist>
PLIST
}
# The output plist holds a recovery key: it goes to /dev/null, never the log.
for attempt in 1 2; do
  fv_plist | fdesetup enable -inputplist -outputplist >/dev/null 2>/tmp/fverr && break
  echo "fdesetup enable attempt $attempt failed: $(tail -1 /tmp/fverr)"; sleep 10
done
rm -f /tmp/fverr
fdesetup status | grep -q "FileVault is On" && pass "FileVault is on" || { fail "FileVault could not be turned on"; exit 1; }
fv_user && pass "$ACCT is a FileVault user" || fail "$ACCT is not a FileVault user"
unlocks "$FIRST" && pass "the starting password unlocks FileVault" || fail "the starting password does not unlock FileVault"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------ ###
### | Settings | ###
### ------------ ###
### Escrow mode; staging off (the test reads -escrow); the runner's admins  ###
### stay approved.                                                          ###
defaults write "$DOM" LocalAdminAccount -string "$ACCT"
defaults write "$DOM" Method -string Local
defaults write "$DOM" PasswordLength -int 16
defaults write "$DOM" StagedRotation -string off
APPROVED=()
for u in $(dscl . -read /Groups/admin GroupMembership 2>/dev/null | cut -d: -f2); do
  [ "$u" = "$ACCT" ] || APPROVED+=("$u")
done
defaults write "$DOM" ApprovedAdmins -array "${APPROVED[@]}"
unset MACOSLAPS_TEST_ASSUME_SECURETOKEN MACOSLAPS_TEST_SECURETOKEN

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------- ###
### | A wrong FirstPass fails closed | ###
### ------------------------------- ###
echo "---- Wrong FirstPass"
if printf '%s\n' 'Not-The-Password-0000' | "$LAPS" -firstPass - -resetPassword >/dev/null 2>&1; then
  fail "a wrong FirstPass rotated a secureToken account"
else
  pass "a wrong FirstPass is refused"
fi
works "$FIRST"   && pass "the account still has its starting password" || fail "the account's password changed"
token            && pass "the token is untouched"                       || fail "the token was lost"
unlocks "$FIRST" && pass "FileVault still unlocks with the starting password" || fail "FileVault no longer unlocks with the starting password"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------- ###
### | Rotations | ###
### ------------- ###
echo "---- First rotation (FirstPass)"
if printf '%s\n' "$FIRST" | "$LAPS" -firstPass - -resetPassword >/dev/null 2>&1; then
  pass "first rotation finished"
else
  fail "first rotation failed"; tail -n 15 /Library/Logs/macOSLAPS.log | sed 's/^/    /'
fi
P1=$(stored); [ -n "$P1" ] && echo "::add-mask::$P1"
check_rotation "first rotation" "$P1" "$FIRST"

ST=$("$LAPS" -status 2>/dev/null)
[ "$(jget "$ST" secureToken)" = True ] && [ "$(jget "$ST" fileVault)" = True ] \
  && pass "-status: secureToken and FileVault reported" || fail "-status: secureToken=$(jget "$ST" secureToken) fileVault=$(jget "$ST" fileVault)"

echo "---- Second rotation (stored password)"
"$LAPS" -resetPassword >/dev/null 2>&1 && pass "second rotation finished" || fail "second rotation failed"
P2=$(stored); [ -n "$P2" ] && echo "::add-mask::$P2"
check_rotation "second rotation" "$P2" "$P1"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------- ###
### | Something else changes it | ###
### --------------------------- ###
### Changed with the old password (as another tool would): macOSLAPS must   ###
### stop, not reset, so the token and FileVault keep the outside password.  ###
echo "---- Outside change"
dscl . -passwd "/Users/$ACCT" "$P2" "$OUTSIDE" && pass "password changed outside macOSLAPS"
if "$LAPS" -resetPassword >/dev/null 2>&1; then
  fail "macOSLAPS reset an account something else had changed"
else
  pass "rotation refused after the outside change"
fi
[ -n "$(jget "$("$LAPS" -status 2>/dev/null)" externalChange)" ] && pass "-status reports externalChange" || fail "-status has no externalChange"
works "$OUTSIDE"   && pass "the outside password still logs in"         || fail "the outside password was replaced"
token              && pass "the token survived"                         || fail "the token was lost"
unlocks "$OUTSIDE" && pass "FileVault unlocks with the outside password" || fail "FileVault doesn't unlock with the outside password"

echo "---- Taking the account back"
if printf '%s\n' "$OUTSIDE" | "$LAPS" -firstPass - -resetPassword >/dev/null 2>&1; then
  pass "-firstPass <current> -resetPassword finished"
else
  fail "-firstPass <current> -resetPassword failed"
fi
P3=$(stored); [ -n "$P3" ] && echo "::add-mask::$P3"
check_rotation "after taking it back" "$P3" "$OUTSIDE"
[ -z "$(jget "$("$LAPS" -status 2>/dev/null)" externalChange)" ] && pass "externalChange cleared" || fail "externalChange still set"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------- ###
### | Result | ###
### ---------- ###
echo "----"
[ "$FAILURES" -eq 0 ] && echo "All secureToken and FileVault checks passed" || { echo "::error::$FAILURES check(s) failed"; exit 1; }
