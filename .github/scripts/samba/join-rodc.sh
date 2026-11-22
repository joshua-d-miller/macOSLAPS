#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | AD | join-rodc.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-17
 Updated:   2026-11-22

 Purpose:
     Joins a throwaway Samba server to the CI domain as a read-only
     domain controller (RODC), so the Mac can be pointed at it: a
     write to an RODC is refused (a referral), which is what PreferredDC
     and the fallback to a writable DC are for.

 Usage:
     Environment: REALM (default LAPS.TEST), DOMAIN (LAPS), ADMINPASS,
     DC_IP and DC_HOSTNAME (the writable DC, reached over Tailscale),
     RODC_HOST_IP (this runner's Tailscale address) and RODC_HOSTNAME
     (e.g. rodc1). No DNS server and no DNS updates: the Mac pins the
     RODC's name in /etc/hosts, so nothing else ever finds it.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-22   joshua    Waits up to a minute for LDAP: it can
                        claude    start a few seconds after smbd answers.
 4.0.0     2026-11-17   joshua    New file.
                        claude
===============================================================================
HEADER

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
set -euo pipefail
REALM=${REALM:-LAPS.TEST}
DOMAIN=${DOMAIN:-LAPS}
: "${ADMINPASS:?}" "${DC_IP:?}" "${DC_HOSTNAME:?}" "${RODC_HOST_IP:?}" "${RODC_HOSTNAME:?}"
DNS_DOMAIN=$(echo "$REALM" | tr 'A-Z' 'a-z')

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq samba samba-ad-dc ldb-tools krb5-user winbind smbclient >/dev/null
systemctl stop smbd nmbd winbind samba-ad-dc 2>/dev/null || true
systemctl disable smbd nmbd winbind 2>/dev/null || true
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba/private/* /var/lib/samba/*.tdb /var/lib/samba/*.ldb 2>/dev/null || true

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------ ###
### | Names and DNS | ###
### ------------------ ###
### The domain's DNS is the writable DC's; both DCs' names are pinned.      ###
hostnamectl set-hostname "$RODC_HOSTNAME"
sed -i "/[[:space:]]$RODC_HOSTNAME\b/d; /[[:space:]]$DC_HOSTNAME\b/d" /etc/hosts
echo "$RODC_HOST_IP $RODC_HOSTNAME.$DNS_DOMAIN $RODC_HOSTNAME" >> /etc/hosts
echo "$DC_IP $DC_HOSTNAME.$DNS_DOMAIN $DC_HOSTNAME" >> /etc/hosts
systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
rm -f /etc/resolv.conf
printf 'search %s\nnameserver %s\nnameserver 1.1.1.1\n' "$DNS_DOMAIN" "$DC_IP" > /etc/resolv.conf
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_kdc = false
[realms]
    $REALM = {
        kdc = $DC_HOSTNAME.$DNS_DOMAIN
    }
EOF

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | Join as an RODC | ###
### ------------------- ###
samba-tool domain join "$DNS_DOMAIN" RODC -U Administrator --password="$ADMINPASS" \
  --server="$DC_HOSTNAME.$DNS_DOMAIN" --dns-backend=NONE \
  --option="bind interfaces only=no" --option="dns update command=/bin/true" \
  --option="server services=-dns" >/dev/null
samba -D

for i in $(seq 1 30); do
  smbclient -L localhost -N >/dev/null 2>&1 && break; sleep 2
done
# Samba's LDAP server can come up a few seconds after smbd answers.
for i in $(seq 1 30); do
  ss -ltn | grep -q ':389 ' && break; sleep 2
done
if ! ss -ltn | grep -q ':389 '; then
  echo "::error::the RODC isn't listening on LDAP after a minute"
  ss -ltn | awk 'NR > 1 {print "  listening: " $4}' | sort -u
  exit 1
fi
echo "Samba RODC $RODC_HOSTNAME.$DNS_DOMAIN up (writable DC: $DC_HOSTNAME.$DNS_DOMAIN)"
# The domain lists it as read-only.
ldbsearch -H /var/lib/samba/private/sam.ldb -b "CN=Sites,CN=Configuration,$(echo "$DNS_DOMAIN" | sed 's/^/DC=/; s/\./,DC=/g')" \
  "(&(objectClass=nTDSDSA)(msDS-isRODC=TRUE))" dn 2>/dev/null | sed -n 's/^dn: /  read-only: /p'
