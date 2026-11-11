#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | AD | verify-dc.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-09
 Updated:   2026-11-11

 Purpose:
     Checks the DC the way a joined Mac uses it: a computer account
     authenticates as itself and writes its own LAPS attributes, and a
     domain admin can read them back. Also checks that an ordinary user
     can NOT read them (they are confidential).
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
                                  New header and section style.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
set -uo pipefail
REALM=${REALM:-LAPS.TEST}
: "${ADMINPASS:?}"
BASEDN=$(echo "$REALM" | tr 'A-Z' 'a-z' | sed 's/^/DC=/; s/\./,DC=/g')
FAIL=0
ok()  { echo "PASS: $*"; }
bad() { echo "::error::FAIL: $*"; FAIL=$((FAIL+1)); }

PC=MACTEST01; PCPASS='Pc-Pass-4417-xyz'
samba-tool computer create "$PC" >/dev/null && ok "computer $PC created" || bad "computer create"
samba-tool user setpassword "$PC\$" --newpassword="$PCPASS" >/dev/null 2>&1 || \
  { samba-tool user setpassword "CN=$PC,CN=Computers,$BASEDN" --newpassword="$PCPASS" >/dev/null 2>&1; }
PCDN="CN=$PC,CN=Computers,$BASEDN"

# FILETIME 30 days from now, and the update time in hex for msLAPS-Password.
now=$(date +%s); ft() { echo $(( ($1 + 11644473600) * 10000000 )); }
EXP=$(ft $((now + 30*86400))); UPD=$(printf '%x' "$(ft "$now")")
PW='Rotated-Pw-8812!'
cat > /tmp/self-write.ldif <<LDIF
dn: $PCDN
changetype: modify
replace: ms-Mcs-AdmPwd
ms-Mcs-AdmPwd: $PW
-
replace: ms-Mcs-AdmPwdExpirationTime
ms-Mcs-AdmPwdExpirationTime: $EXP
-
replace: msLAPS-Password
msLAPS-Password: {"n":"lapsadmin","t":"$UPD","p":"$PW"}
-
replace: msLAPS-PasswordExpirationTime
msLAPS-PasswordExpirationTime: $EXP
LDIF
if ldbmodify -H ldap://localhost -U "$PC\$%$PCPASS" /tmp/self-write.ldif >/dev/null 2>/tmp/self.err; then
  ok "computer wrote its own legacy + Windows LAPS attributes"
else
  bad "computer could not write its own attributes: $(cat /tmp/self.err)"
fi

# ldbsearch prints LDIF, which folds long values onto continuation lines starting
# with a space; unfold before extracting.
read_attr() { ldbsearch -H ldap://localhost -U "$1" -b "$PCDN" -s base "(objectClass=computer)" "$2" 2>/dev/null \
  | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n //g' | sed -n "s/^$2: //p"; }
[ "$(read_attr "Administrator%$ADMINPASS" ms-Mcs-AdmPwd)" = "$PW" ] && ok "admin reads ms-Mcs-AdmPwd" || bad "ms-Mcs-AdmPwd readback"
[ "$(read_attr "Administrator%$ADMINPASS" msLAPS-PasswordExpirationTime)" = "$EXP" ] && ok "admin reads msLAPS-PasswordExpirationTime" || bad "msLAPS-PasswordExpirationTime readback"
J=$(read_attr "Administrator%$ADMINPASS" msLAPS-Password)
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['n']=='lapsadmin' and d['p']==sys.argv[2] and int(d['t'],16)>0" "$J" "$PW" \
  && ok "msLAPS-Password is valid JSON {n,t,p}" || bad "msLAPS-Password JSON: $J"

samba-tool user create plainuser 'Plain-User-5521!' >/dev/null
[ -z "$(read_attr 'plainuser%Plain-User-5521!' ms-Mcs-AdmPwd)" ] && ok "ordinary user cannot read ms-Mcs-AdmPwd" || bad "ms-Mcs-AdmPwd readable by ordinary user"
[ -z "$(read_attr 'plainuser%Plain-User-5521!' msLAPS-Password)" ] && ok "ordinary user cannot read msLAPS-Password" || bad "msLAPS-Password readable by ordinary user"

# Another computer must not be able to write this computer's password.
samba-tool computer create OTHERPC >/dev/null; samba-tool user setpassword 'OTHERPC$' --newpassword="$PCPASS" >/dev/null 2>&1
if ldbmodify -H ldap://localhost -U "OTHERPC\$%$PCPASS" /tmp/self-write.ldif >/dev/null 2>&1; then
  bad "a different computer could overwrite $PC's password"
else
  ok "a different computer cannot write $PC's attributes"
fi

echo "----"; [ "$FAIL" -eq 0 ] && echo "All DC checks passed" || { echo "::error::$FAIL DC check(s) failed"; exit 1; }
