#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | ad-mac-test.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-14
 Updated:   2026-11-22

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
 4.0.0     2026-11-22   joshua    The LDAP fallback, end to end: pf blocks
                        claude    IPv4 LDAP to dc1, Open Directory can't
                                  reach AD, rodc1 (from DNS) refuses, and
                                  the write must reach dcw (dc1's second
                                  name, IPv6 only, from DNS) over LDAP.
 4.0.0     2026-11-21   joshua    The DNS check counts only an SRV answer
                        claude    (not dig's timeout message), keeps
                                  retrying, and says whether TCP works.
 4.0.0     2026-11-17   joshua    PreferredDC over LDAP as the computer
                        claude    account; an unreachable PreferredDC; a
                                  read-only DC (PreferredDC on it, the
                                  binding on it, and both).
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
  # No dsconfigad -remove: it deletes the computer object, mark included, and the
  # runner is discarded after the job anyway.
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

# dig +short prints ";; connection timed out" on stdout, so only an SRV
# answer (priority weight port target.) counts.
srv_of() {
  dig +short +time=3 +tries=1 "$@" @"$DC_IP" "_ldap._tcp.$DOMAIN_DNS" SRV \
    2>/dev/null | grep -E '^[0-9]+ [0-9]+ [0-9]+ [^ ]+\.$'
}
srv=""
for i in $(seq 1 30); do
  srv=$(srv_of) && break
  [ "$i" -eq 1 ] && echo "  no DNS answer from $DC_IP yet; retrying (4 min)"
  srv=""; sleep 5
done
if [ -n "$srv" ]; then
  pass "the DC answers DNS for $DOMAIN_DNS ($srv)"
else
  fail "no SRV record for _ldap._tcp.$DOMAIN_DNS from $DC_IP over UDP"
  if tcp=$(srv_of +tcp); then
    echo "  over TCP it answers ($tcp): UDP to the DC is lost on the tailnet"
  else
    echo "  no answer over TCP either: the DC's DNS service isn't answering"
  fi
  tailscale ping -c 1 --timeout 5s "$DC_IP" 2>&1 | sed 's/^/  /' || true
  exit 1
fi
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
# The test reads the stored password with -escrow, which would turn on staged
# rotation (auto); rotations must reach AD straight away here.
defaults write "$DOM" StagedRotation -string off
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
### --------------- ###
### | PreferredDC | ###
### --------------- ###
### Reads and writes go over LDAP to the chosen DC, as the computer         ###
### account (its own Kerberos ticket, not the admin's).                     ###
echo "---- PreferredDC $DC_FQDN, ADSchema both"
defaults write "$DOM" PreferredDC -string "$DC_FQDN"
defaults write "$DOM" ADSchema -string both
lines_before=$(wc -l < /Library/Logs/macOSLAPS.log)
"$LAPS" -rotate >/dev/null 2>&1; rc=$?
new_log=$(tail -n +"$((lines_before + 1))" /Library/Logs/macOSLAPS.log)
echo "  macOSLAPS log:"; sed 's/^/    /' <<< "$new_log"
grep -qiF "Using PreferredDC $DC_FQDN (LDAP as $COMPUTER\$)" <<< "$new_log" \
  && pass "PreferredDC: macOSLAPS connects to $DC_FQDN over LDAP as $COMPUTER\$" || fail "PreferredDC: not used"
legacy_pw=$(ad_value ms-Mcs-AdmPwd); [ -n "$legacy_pw" ] && echo "::add-mask::$legacy_pw"
win_pw=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["p"])' "$(ad_value msLAPS-Password)" 2>/dev/null)
[ $rc -eq 0 ] && [ -n "$legacy_pw" ] && [ "$legacy_pw" = "$win_pw" ] && [ "$legacy_pw" != "$previous" ] \
  && works "$legacy_pw" && [ "$legacy_pw" = "$(stored)" ] \
  && pass "PreferredDC: the rotation wrote both schemas over LDAP, and the password works" \
  || fail "PreferredDC: rotation over LDAP (rc $rc)"
future_filetime "$(ad_attr ms-Mcs-AdmPwdExpirationTime)" && future_filetime "$(ad_attr msLAPS-PasswordExpirationTime)" \
  && pass "PreferredDC: both expiration times are in the future" || fail "PreferredDC: expiration times"
before=$(stored)
"$LAPS" >/dev/null 2>&1
[ "$before" = "$(stored)" ] && pass "PreferredDC: a scheduled run reads the expiration over LDAP and leaves the password alone" \
  || fail "PreferredDC: a scheduled run rotated before the expiration"
ls /var/run/macoslaps/krb5cc_* >/dev/null 2>&1 && fail "PreferredDC: a Kerberos ticket cache was left behind" \
  || pass "PreferredDC: the computer's ticket cache is removed after the run"
# A PreferredDC that can't be reached stops the run before anything changes.
defaults write "$DOM" PreferredDC -string "nodc.$DOMAIN_DNS"
"$LAPS" -rotate >/dev/null 2>&1 && fail "an unreachable PreferredDC was accepted" \
  || { [ "$before" = "$(stored)" ] && works "$before" && pass "an unreachable PreferredDC stops the run; nothing changed" || fail "the password changed with an unreachable PreferredDC"; }
defaults delete "$DOM" PreferredDC
previous="$before"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------- ###
### | A read-only DC (RODC) | ###
### ------------------------- ###
### rodc1 is a Samba RODC in the same domain. A write to it is refused, so  ###
### PreferredDC pointing at it must stop the run; with the binding on it,   ###
### the password must still reach the writable DC.                          ###
echo "---- Read-only domain controller"
if [ -z "${RODC_IP:-}" ]; then
  fail "no read-only DC to test against (see the ad-rodc job)"
else
  RODC_FQDN="rodc1.$DOMAIN_DNS"
  sed -i '' "/[[:space:]]$RODC_FQDN/d" /etc/hosts
  echo "$RODC_IP $RODC_FQDN rodc1" >> /etc/hosts
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
  nc -z -G 5 "$RODC_IP" 389 && pass "the RODC answers LDAP at $RODC_FQDN" || fail "the RODC isn't reachable on LDAP"
  rodc_says=$(ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$RODC_FQDN" -b "" -s base "(objectClass=*)" dsServiceName 2>&1 | head -3)
  echo "  RODC rootDSE: $rodc_says"
  run_log() {   # runs macOSLAPS with the given arguments; sets rc and new_log
    local before_lines; before_lines=$(wc -l < /Library/Logs/macOSLAPS.log)
    "$LAPS" "$@" >/dev/null 2>&1; rc=$?
    new_log=$(tail -n +"$((before_lines + 1))" /Library/Logs/macOSLAPS.log)
    echo "  macOSLAPS $* (exit $rc):"; sed 's/^/    /' <<< "$new_log"
  }
  ad_now() { ad_value ms-Mcs-AdmPwd; }   # read on the writable DC, as the domain admin
  # The RODC pulls from the writable DC every 30 s; wait until it has this computer.
  for i in $(seq 1 30); do
    ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$RODC_FQDN" -b "$BASEDN" "(sAMAccountName=$COMPUTER\$)" dn 2>/dev/null | grep -q "^dn:" && break
    sleep 5
  done
  ldapsearch -LLL -Q -Y GSSAPI -H "ldap://$RODC_FQDN" -b "$BASEDN" "(sAMAccountName=$COMPUTER\$)" dn 2>/dev/null | grep -q "^dn:" \
    && pass "the RODC has replicated $COMPUTER" || fail "the RODC never received $COMPUTER"

  # 1. PreferredDC = the RODC: refused, nothing changes anywhere.
  defaults write "$DOM" PreferredDC -string "$RODC_FQDN"
  before=$(stored); before_ad=$(ad_now)
  run_log -rotate
  [ $rc -ne 0 ] && [ "$before" = "$(stored)" ] && works "$before" && [ "$before_ad" = "$(ad_now)" ] \
    && grep -q "Unable to write the LAPS expiration attribute(s) .* through LDAP to $RODC_FQDN" <<< "$new_log" \
    && pass "PreferredDC on the RODC: the RODC refuses the write and nothing changed" \
    || fail "PreferredDC on the RODC (exit $rc): not refused by the RODC itself"

  # 2. The binding prefers the RODC; PreferredDC unset: the password still reaches the writable DC.
  defaults delete "$DOM" PreferredDC
  out=$(dsconfigad -preferred "$RODC_FQDN" 2>&1) && pass "the binding now prefers $RODC_FQDN" || fail "dsconfigad -preferred: $out"
  dsconfigad -show | grep -i "preferred" | sed 's/^/  /'
  sleep 5
  run_log -rotate
  now_ad=$(ad_now); [ -n "$now_ad" ] && echo "::add-mask::$now_ad"
  if [ $rc -eq 0 ] && [ -n "$now_ad" ] && [ "$now_ad" != "$before_ad" ] && works "$now_ad" && [ "$now_ad" = "$(stored)" ]; then
    if grep -q "Writing to .* instead (LDAP as" <<< "$new_log"; then
      pass "binding on the RODC: the write was refused and macOSLAPS fell back to a writable DC over LDAP"
    else
      pass "binding on the RODC: the rotation reached the writable DC"
      echo "::notice::macOS wrote through the RODC itself (it followed the referral), so the LDAP fallback wasn't needed"
    fi
  else
    fail "binding on the RODC: the new password didn't reach the writable DC (exit $rc)"
  fi
  before_ad="$now_ad"

  # 2b. As 2, but pf blocks IPv4 LDAP to dc1 (open connections too), so
  # Open Directory can't reach AD. macOSLAPS goes to DNS: dc1 (blocked),
  # rodc1 (priority 5: answers, but refuses the write), then dcw, dc1's
  # second name on its IPv6 address only (priority 10, its own SPN), which
  # must take the write over LDAP.
  dcw="dcw.$DOMAIN_DNS"
  dc6=$(dig +short +time=3 @"$DC_IP" "$dcw" AAAA | grep ':' | head -1)
  if [ -z "$dc6" ]; then
    fail "$dcw has no IPv6 address in the domain's DNS (see the ad-dc job)"
  elif ! nc -6 -z -G 5 "$dc6" 389 2>/dev/null; then
    fail "dc1 doesn't answer LDAP on its IPv6 address $dc6"
  else
    rc=1; new_log=""
    # Pinned like dc1 and rodc1: macOS may not ask DNS for AAAA records.
    sed -i '' "/[[:space:]]$dcw/d" /etc/hosts
    echo "$dc6 $dcw dcw" >> /etc/hosts
    dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
    pf_rules=$(mktemp)
    echo "block return out quick proto tcp from any to $DC_IP port 389" > "$pf_rules"
    pfctl -a com.apple/macoslaps-ci -f "$pf_rules" 2>/dev/null
    pf_token=$(pfctl -E 2>&1 | sed -n 's/^Token : //p')
    pfctl -k 0.0.0.0/0 -k "$DC_IP" >/dev/null 2>&1 || true
    if nc -z -G 3 "$DC_IP" 389 2>/dev/null; then
      fail "pf didn't block IPv4 LDAP to dc1; 2b can't run"
    else
      run_log -rotate
    fi
    pfctl -a com.apple/macoslaps-ci -F all >/dev/null 2>&1 || true
    [ -n "$pf_token" ] && pfctl -X "$pf_token" >/dev/null 2>&1 || true
    nc -z -G 5 "$DC_IP" 389 2>/dev/null || fail "IPv4 LDAP to dc1 didn't come back after 2b"
    now_ad=$(ad_now); [ -n "$now_ad" ] && echo "::add-mask::$now_ad"
    if [ "$rc" -eq 0 ] && [ -n "$now_ad" ] && [ "$now_ad" != "$before_ad" ] && works "$now_ad" \
       && [ "$now_ad" = "$(stored)" ] && grep -q "Writing to $dcw instead (LDAP as" <<< "$new_log"; then
      pass "binding on the RODC, dc1 unreachable over IPv4: macOSLAPS fell back to $dcw over LDAP"
      grep -q "Open Directory can't reach Active Directory" <<< "$new_log" \
        && pass "Open Directory's failure led macOSLAPS to the DCs in DNS" \
        || echo "::notice::Open Directory still reached AD; the fallback came from the RODC's refusal alone"
      grep -q "$RODC_FQDN didn't take the write\|binding uses didn't take the write" <<< "$new_log" \
        && pass "the RODC's refusal is logged before the fallback" \
        || fail "the fallback happened without the RODC refusing first"
    elif [ "$rc" -eq 0 ] && [ "$now_ad" != "$before_ad" ]; then
      fail "binding on the RODC, dc1 unreachable over IPv4: the write landed without the LDAP fallback"
    else
      fail "binding on the RODC, dc1 unreachable over IPv4: no fallback to $dcw (exit $rc)"
    fi
    [ -n "$now_ad" ] && before_ad="$now_ad"
  fi

  # 3. The binding prefers the RODC; PreferredDC = the writable DC: works.
  defaults write "$DOM" PreferredDC -string "$DC_FQDN"
  run_log -rotate
  now_ad=$(ad_now); [ -n "$now_ad" ] && echo "::add-mask::$now_ad"
  [ $rc -eq 0 ] && [ "$now_ad" != "$before_ad" ] && works "$now_ad" && [ "$now_ad" = "$(stored)" ] \
    && pass "binding on the RODC with PreferredDC on the writable DC: rotation works" \
    || fail "PreferredDC on the writable DC with the binding on the RODC (exit $rc)"

  defaults delete "$DOM" PreferredDC
  dsconfigad -nopreferred >/dev/null 2>&1 || true
  previous="$now_ad"
fi

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
