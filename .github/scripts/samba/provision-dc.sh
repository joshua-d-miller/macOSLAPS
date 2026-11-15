#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | AD | provision-dc.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-09
 Updated:   2026-11-14

 Purpose:
     Provisions a throwaway Samba AD domain controller for CI with both
     LAPS schemas: legacy (ms-Mcs-AdmPwd, ms-Mcs-AdmPwdExpirationTime) and
     Windows LAPS (msLAPS-Password, msLAPS-PasswordExpirationTime).
     Attribute definitions follow Microsoft's published schema ([MS-ADA2]
     2.64/2.65) and the legacy LAPS schema. Computers get SELF write on
     all four attributes, the equivalent of
     Set-AdmPwdComputerSelfPermission / Set-LapsADComputerSelfPermission.

 Usage:
     Environment: REALM (default LAPS.TEST), DOMAIN (LAPS),
     ADMINPASS (required). Stage 2 (a Mac joins over Tailscale) also
     sets DC_HOSTNAME (e.g. dc1) and DC_HOST_IP (the Tailscale address),
     so the domain's DNS records point at the address the Mac can reach.
     Samba won't bind the /32 IPv4 address of a point-to-point interface
     like tailscale0, so with DC_HOST_IP it listens on all addresses,
     after systemd-resolved gives up port 53.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
                                  New header and section style.
                        joshua    DC_HOSTNAME, DC_HOST_IP and DC_INTERFACES
                        claude    for stage 2 over Tailscale; listen on all
                                  addresses then.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
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
INTERFACES=${DC_INTERFACES:-lo $IFACE}
BINDONLY=yes
HOSTIP=()
if [ -n "${DC_HOST_IP:-}" ]; then
  # Free port 53 for Samba's DNS and resolve through a public server instead.
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  BINDONLY=no
fi
if [ -n "${DC_HOSTNAME:-}" ]; then
  # The DC's name must resolve to the address clients use, before provisioning.
  hostnamectl set-hostname "$DC_HOSTNAME"
  sed -i "/[[:space:]]$DC_HOSTNAME\b/d" /etc/hosts
  echo "${DC_HOST_IP:-127.0.1.1} $DC_HOSTNAME.$(echo "$REALM" | tr 'A-Z' 'a-z') $DC_HOSTNAME" >> /etc/hosts
fi
[ -n "${DC_HOST_IP:-}" ] && HOSTIP=(--host-ip="$DC_HOST_IP")
samba-tool domain provision --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL \
  --realm="$REALM" --domain="$DOMAIN" --adminpass="$ADMINPASS" "${HOSTIP[@]}" \
  --option="interfaces=$INTERFACES" --option="bind interfaces only=$BINDONLY" \
  --option="dns forwarder=1.1.1.1" >/dev/null
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------- ###
### | Schema | ###
### ---------- ###
### Adds the LAPS attributes to the computer class.                         ###
apply() { ldbmodify -H "$SAM" --option="dsdb:schema update allowed"=true "$1" >/dev/null; }

# 1. Attribute schema
sed "s/@SCHEMA@/$SCHEMA/g" "$HERE/laps-attributes.ldif" > /tmp/laps-attributes.ldif
ldbadd -H "$SAM" --option="dsdb:schema update allowed"=true /tmp/laps-attributes.ldif >/dev/null
# 2. Allow them on computer objects
sed "s/@SCHEMA@/$SCHEMA/g" "$HERE/laps-computer-class.ldif" > /tmp/laps-computer-class.ldif
apply /tmp/laps-computer-class.ldif

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------- ###
### | SELF write | ###
### -------------- ###
### Computers may write their own LAPS attributes.                          ###
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | Wait for the DC | ###
### ------------------- ###
for i in $(seq 1 30); do
  smbclient -L localhost -N >/dev/null 2>&1 && break; sleep 2
done
echo "Samba AD DC up: realm $REALM, base $BASEDN"
