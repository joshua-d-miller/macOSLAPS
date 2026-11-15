#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | ad-mac-test.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-14
 Updated:   2026-11-14

 Purpose:
     AD stage 2: binds a macOS runner to the throwaway Samba domain from
     .github/scripts/samba/ (reached over Tailscale) and runs macOSLAPS
     with Method AD against it. For each ADSchema (legacy, windowsLAPS,
     both) it rotates the password, reads the LAPS attributes back as the
     domain admin, and checks the password in AD is the one that works
     on the Mac and that the old one stopped working. Then device mode
     with ADRevealCode: AD must hold the reveal code, never the password.
     Passwords read from AD are masked in the log.

 Usage:
     sudo -E bash .github/scripts/ad-mac-test.sh <full pkg>
     Environment: DC_IP (the domain controller's Tailscale address),
     ADMINPASS, COMPUTER (computer name, at most 15 characters),
     REALM (default LAPS.TEST), DC_HOSTNAME (default dc1)
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
### Install, test helpers and the names of things.                          ###
set -uo pipefail
PKG="$1"
: "${DC_IP:?}" "${ADMINPASS:?}" "${COMPUTER:?}"
REALM=${REALM:-LAPS.TEST}
DC_HOSTNAME=${DC_HOSTNAME:-dc1}
DOMAIN_DNS=$(echo "$REALM" | tr 'A-Z' 'a-z')
BASEDN=$(echo "$DOMAIN_DNS" | sed 's/^/DC=/; s/\./,DC=/g')
DC_FQDN="$DC_HOSTNAME.$DOMAIN_DNS"
echo "::add-mask::$ADMINPASS"

LAPS=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
DOM=/Library/Preferences/com.joshua-d-miller.macoslaps
ACCT=ladmin
FIRST='Initial-Pass-1234'

FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
works() { dscl . -authonly "$ACCT" "$1" >/dev/null 2>&1; }
# The stored password, as an MDM would collect it (escrow mode).
stored() { jget "$("$LAPS" -escrow 2>/dev/null)" password; }

# Mark this computer done (or failed) in AD, so the DC job can stop.
finish() {
  local mark=macoslaps-ci-done; [ "$FAILURES" -eq 0 ] || mark=macoslaps-ci-failed
  klist -s 2>/dev/null || printf '%s' "$ADMINPASS" | kinit --password-file=STDIN "Administrator@$REALM" >/dev/null 2>&1
  printf 'dn: CN=%s,CN=Computers,%s\nchangetype: modify\nreplace: description\ndescription: %s\n' \
    "$COMPUTER" "$BASEDN" "$mark" > /tmp/mark.ldif
  ldapmodify -Q -Y GSSAPI -H "ldap://$DC_FQDN" -f /tmp/mark.ldif >/dev/null 2>&1 \
    || echo "::warning::could not mark the computer object $mark"
  dsconfigad -remove -force -username Administrator -password "$ADMINPASS" >/dev/null 2>&1 || true
  kdestroy -A >/dev/null 2>&1 || true
}

trap finish EXIT
installer -pkg "$PKG" -target / >/dev/null || { echo "::error::install failed"; exit 1; }
pass "installed $(basename "$PKG")"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------- ###
### | DNS for the test domain | ###
### ------------------------- ###
### Only the test domain resolves through the DC; everything else is left   ###
### alone. The DC's own name is pinned in /etc/hosts for Kerberos.          ###
mkdir -p /etc/resolver
printf 'nameserver %s\n' "$DC_IP" > "/etc/resolver/$DOMAIN_DNS"
sed -i '' "/[[:space:]]$DC_FQDN/d" /etc/hosts
echo "$DC_IP $DC_FQDN $DC_HOSTNAME" >> /etc/hosts
dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true

for i in $(seq 1 30); do
  srv=$(dig +short @"$DC_IP" "_ldap._tcp.$DOMAIN_DNS" SRV 2>/dev/null)
  [ -n "$srv" ] && break; sleep 5
done
[ -n "${srv:-}" ] && pass "the DC answers DNS for $DOMAIN_DNS ($srv)" || { fail "no SRV record for _ldap._tcp.$DOMAIN_DNS from $DC_IP"; exit 1; }
nc -z -G 5 "$DC_IP" 389 && pass "LDAP reachable on $DC_IP" || fail "LDAP (389) not reachable on $DC_IP"
nc -z -G 5 "$DC_IP" 88 && pass "Kerberos reachable on $DC_IP" || fail "Kerberos (88) not reachable on $DC_IP"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------- ###
### | Join the domain | ###
### ----------------- ###
out=$(dsconfigad -add "$DOMAIN_DNS" -computer "$COMPUTER" -username Administrator \
  -password "$ADMINPASS" -force 2>&1) && pass "bound to $DOMAIN_DNS as $COMPUTER" \
  || { fail "dsconfigad -add: $out"; exit 1; }
dsconfigad -show | sed 's/^/  /'

NODE="/Active Directory/$(echo "$REALM" | cut -d. -f1)/All Domains"
for i in $(seq 1 30); do
  dscl "$NODE" -read "/Computers/$COMPUTER\$" RecordName >/dev/null 2>&1 && break; sleep 4
done
dscl "$NODE" -read "/Computers/$COMPUTER\$" RecordName >/dev/null 2>&1 \
  && pass "the computer record is visible through Open Directory" \
  || fail "Open Directory can't see /Computers/$COMPUTER\$ in $NODE"

# The domain admin's ticket, to read the LAPS attributes back (they are confidential).
printf '%s' "$ADMINPASS" | kinit --password-file=STDIN "Administrator@$REALM" >/dev/null 2>&1 \
  && pass "Kerberos ticket for Administrator" || fail "kinit Administrator@$REALM"

# One attribute of this computer, unfolded (LDIF folds long values).
ad_attr() {
  ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$DC_FQDN" -b "CN=$COMPUTER,CN=Computers,$BASEDN" -s base \
    "(objectClass=computer)" "$1" 2>/dev/null \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n //g' | sed -n "s/^$1:: //p; s/^$1: //p" | head -1
}
# Values sent base64 (":: ") when they contain unusual characters.
ad_value() {
  local raw; raw=$(ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$DC_FQDN" -b "CN=$COMPUTER,CN=Computers,$BASEDN" -s base \
    "(objectClass=computer)" "$1" 2>/dev/null | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n //g')
  if grep -q "^$1:: " <<< "$raw"; then sed -n "s/^$1:: //p" <<< "$raw" | base64 -D
  else sed -n "s/^$1: //p" <<< "$raw"; fi
}
future_filetime() { python3 -c 'import sys,time; t=int(sys.argv[1] or 0)/1e7-11644473600; sys.exit(0 if t>time.time() else 1)' "$1"; }

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------- ###
### | The managed admin | ###
### --------------------- ###
### Admin group protection keeps the runner's own admins.                   ###
sysadminctl -addUser "$ACCT" -fullName "Local Admin" -password "$FIRST" -admin >/dev/null 2>&1
id "$ACCT" >/dev/null 2>&1 && pass "created $ACCT" || { fail "could not create $ACCT"; exit 1; }
defaults write "$DOM" LocalAdminAccount -string "$ACCT"
defaults write "$DOM" Method -string AD
defaults write "$DOM" DaysTillExpiration -int 30
defaults write "$DOM" PasswordLength -int 16
APPROVED=()
for u in $(dscl . -read /Groups/admin GroupMembership 2>/dev/null | cut -d: -f2); do
  [ "$u" = "$ACCT" ] || APPROVED+=("$u")
done
defaults write "$DOM" ApprovedAdmins -array "${APPROVED[@]}"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------- ###
### | Rotate with each schema | ###
### --------------------------- ###
### legacy: ms-Mcs-AdmPwd. windowsLAPS: msLAPS-Password (JSON n/t/p).       ###
### both: the two must agree. The first rotation uses -firstPass.           ###
previous="$FIRST"
for schema in legacy windowsLAPS both; do
  echo "---- ADSchema $schema"
  defaults write "$DOM" ADSchema -string "$schema"
  if [ "$schema" = legacy ]; then
    out=$(printf '%s\n' "$FIRST" | "$LAPS" -firstPass - -resetPassword 2>&1)
  else
    out=$("$LAPS" -resetPassword 2>&1)
  fi
  rc=$?
  # What macOSLAPS said about this run (it never logs passwords).
  echo "  macOSLAPS log:"; tail -n 14 /Library/Logs/macOSLAPS.log | sed 's/^/    /'
  echo "  LAPS attributes on $COMPUTER: $(ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$DC_FQDN" \
    -b "CN=$COMPUTER,CN=Computers,$BASEDN" -s base "(objectClass=computer)" \
    ms-Mcs-AdmPwd ms-Mcs-AdmPwdExpirationTime msLAPS-Password msLAPS-PasswordExpirationTime 2>/dev/null \
    | sed -n 's/^\([A-Za-z-]*\)::\{0,1\} .*/\1/p' | grep -v '^dn$' | tr '\n' ' ')"
  [ $rc -eq 0 ] && pass "$schema: rotation finished" || { fail "$schema: rotation exited $rc"; echo "$out" | tail -15; continue; }

  legacy_pw=$(ad_value ms-Mcs-AdmPwd); [ -n "$legacy_pw" ] && echo "::add-mask::$legacy_pw"
  win_json=$(ad_value msLAPS-Password)
  win_pw=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["p"])' "$win_json" 2>/dev/null)
  [ -n "$win_pw" ] && echo "::add-mask::$win_pw"
  win_n=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["n"] if int(d["t"],16)>0 else "")' "$win_json" 2>/dev/null)

  case $schema in
    legacy)      current="$legacy_pw" ;;
    windowsLAPS) current="$win_pw" ;;
    both)        current="$legacy_pw"
                 [ -n "$legacy_pw" ] && [ "$legacy_pw" = "$win_pw" ] \
                   && pass "both: ms-Mcs-AdmPwd and msLAPS-Password agree" \
                   || fail "both: the two password attributes differ or are missing" ;;
  esac

  [ -n "$current" ] && pass "$schema: the password is in AD" || { fail "$schema: no password in AD"; continue; }
  works "$current" && pass "$schema: the password in AD works for $ACCT" || fail "$schema: the password in AD does not work for $ACCT"
  works "$previous" && fail "$schema: the previous password still works" || pass "$schema: the previous password stopped working"
  [ "$current" = "$(stored)" ] \
    && pass "$schema: AD and the stored password (-escrow) agree" \
    || fail "$schema: AD and the stored password differ"

  if [ "$schema" != legacy ]; then
    [ "$win_n" = "$ACCT" ] && pass "$schema: msLAPS-Password names $ACCT with a valid time" \
      || fail "$schema: msLAPS-Password account/time wrong (n=$win_n)"
    future_filetime "$(ad_attr msLAPS-PasswordExpirationTime)" \
      && pass "$schema: msLAPS-PasswordExpirationTime is in the future" || fail "$schema: msLAPS-PasswordExpirationTime"
  fi
  if [ "$schema" != windowsLAPS ]; then
    future_filetime "$(ad_attr ms-Mcs-AdmPwdExpirationTime)" \
      && pass "$schema: ms-Mcs-AdmPwdExpirationTime is in the future" || fail "$schema: ms-Mcs-AdmPwdExpirationTime"
  fi
  previous="$current"
done

# A normal run before the expiration must not rotate.
before=$(stored)
"$LAPS" >/dev/null 2>&1
[ "$before" = "$(stored)" ] \
  && pass "a scheduled run before the expiration leaves the password alone" \
  || fail "a scheduled run rotated before the expiration"

ST=$("$LAPS" -status 2>/dev/null)
[ "$(jget "$ST" method)" = AD ] && [ "$(jget "$ST" passwordVerifies)" = True ] \
  && pass "-status: method AD, stored password verifies" \
  || fail "-status: $ST"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------- ###
### | Device mode with ADRevealCode | ###
### ------------------------------- ###
### AD gets the reveal code, never the password.                            ###
echo "---- Device mode, ADSchema both, ADRevealCode"
defaults write "$DOM" RetrievalMode -string device
defaults write "$DOM" ADRevealCode -bool true
"$LAPS" -resetPassword >/dev/null 2>&1 && pass "device mode: rotation finished" || fail "device mode: rotation failed"
CODE=$(jget "$("$LAPS" -escrow 2>/dev/null)" revealCode)
legacy_pw=$(ad_value ms-Mcs-AdmPwd)
win_pw=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["p"])' "$(ad_value msLAPS-Password)" 2>/dev/null)
[ -n "$CODE" ] && [ "$legacy_pw" = "$CODE" ] && [ "$win_pw" = "$CODE" ] \
  && pass "device mode: both AD attributes hold the reveal code" \
  || fail "device mode: AD doesn't hold the reveal code"
! works "$legacy_pw" && ! works "$win_pw" \
  && pass "device mode: what AD holds is not the password" \
  || fail "device mode: the password was written to AD"

defaults write "$DOM" ADRevealCode -bool false
"$LAPS" -resetPassword >/dev/null 2>&1
left=$(ad_value ms-Mcs-AdmPwd)
{ [ -z "$left" ] || ! works "$left"; } \
  && pass "device mode without ADRevealCode: AD doesn't get the password" \
  || fail "device mode without ADRevealCode: the password is in AD"
future_filetime "$(ad_attr ms-Mcs-AdmPwdExpirationTime)" \
  && pass "device mode without ADRevealCode: the expiration is still written" \
  || fail "device mode without ADRevealCode: no expiration in AD"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------- ###
### | Result | ###
### ---------- ###
echo "----"
[ "$FAILURES" -eq 0 ] && echo "All AD checks passed" || { echo "::error::$FAILURES AD check(s) failed"; exit 1; }
