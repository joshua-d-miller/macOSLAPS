#!/bin/bash
# Provision a throwaway Samba AD DC for CI with both LAPS schemas:
#   legacy:      ms-Mcs-AdmPwd, ms-Mcs-AdmPwdExpirationTime
#   Windows LAPS: msLAPS-Password, msLAPS-PasswordExpirationTime
# Attribute definitions follow Microsoft's published schema ([MS-ADA2] 2.64/2.65)
# and the legacy LAPS schema. Computers get SELF write on all four attributes,
# the equivalent of Set-AdmPwdComputerSelfPermission / Set-LapsADComputerSelfPermission.
#
# Env: REALM (default LAPS.TEST), DOMAIN (LAPS), ADMINPASS (required)
set -euo pipefail
REALM=${REALM:-LAPS.TEST}
DOMAIN=${DOMAIN:-LAPS}
: "${ADMINPASS:?ADMINPASS must be set}"
BASEDN=$(echo "$REALM" | tr 'A-Z' 'a-z' | sed 's/^/DC=/; s/\./,DC=/g')
SAM=/var/lib/samba/private/sam.ldb
SCHEMA="CN=Schema,CN=Configuration,$BASEDN"
HERE=$(cd "$(dirname "$0")" && pwd)

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq samba samba-ad-dc samba-ad-provision ldb-tools krb5-user winbind smbclient >/dev/null
systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
systemctl disable smbd nmbd winbind 2>/dev/null || true
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/* /var/lib/samba/*.tdb /var/lib/samba/*.ldb 2>/dev/null || true

IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
samba-tool domain provision --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL \
  --realm="$REALM" --domain="$DOMAIN" --adminpass="$ADMINPASS" \
  --option="interfaces=lo $IFACE" --option="bind interfaces only=yes" \
  --option="dns forwarder=1.1.1.1" >/dev/null
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

apply() { ldbmodify -H "$SAM" --option="dsdb:schema update allowed"=true "$1" >/dev/null; }

# 1. Attribute schema
sed "s/@SCHEMA@/$SCHEMA/g" "$HERE/laps-attributes.ldif" > /tmp/laps-attributes.ldif
ldbadd -H "$SAM" --option="dsdb:schema update allowed"=true /tmp/laps-attributes.ldif >/dev/null
# 2. Allow them on computer objects
sed "s/@SCHEMA@/$SCHEMA/g" "$HERE/laps-computer-class.ldif" > /tmp/laps-computer-class.ldif
apply /tmp/laps-computer-class.ldif

# 3. SELF write for computers, inherited from the domain root
guid() { ldbsearch -H "$SAM" -b "$SCHEMA" "(lDAPDisplayName=$1)" schemaIDGUID | awk '/^schemaIDGUID:/{print $2}'; }
COMPUTER_CLASS=bf967a86-0de6-11d0-a285-00aa003049e2
SDDL=""
for attr in ms-Mcs-AdmPwd ms-Mcs-AdmPwdExpirationTime msLAPS-Password msLAPS-PasswordExpirationTime; do
  g=$(guid "$attr"); [ -n "$g" ] || { echo "schema attribute $attr missing"; exit 1; }
  echo "$attr schemaIDGUID=$g"
  SDDL="$SDDL(OA;CI;WP;$g;$COMPUTER_CLASS;PS)"
done
samba-tool dsacl set -H "$SAM" --objectdn="$BASEDN" --sddl="$SDDL" >/dev/null

samba -D
for i in $(seq 1 30); do
  smbclient -L localhost -N >/dev/null 2>&1 && break; sleep 2
done
echo "Samba AD DC up: realm $REALM, base $BASEDN"
