#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | AD | wait-for-mac.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-14
 Updated:   2026-11-14

 Purpose:
     Keeps the stage-2 domain controller up until the Mac job finishes.
     The Mac marks its own computer object's description
     "macoslaps-ci-done" (or "macoslaps-ci-failed") when it is done; this
     script polls for that, then lists which LAPS attributes each joined
     computer holds (names only, never the values). If MAC_HOST is set
     and that Tailscale device leaves without a mark (the Mac job failed
     early), it stops too, instead of waiting out the timeout.

 Usage:
     Environment: REALM (default LAPS.TEST), WAIT_MINUTES (default 45),
     MAC_HOST (the Mac's Tailscale host name, optional)
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
set -uo pipefail
REALM=${REALM:-LAPS.TEST}
BASEDN=$(echo "$REALM" | tr 'A-Z' 'a-z' | sed 's/^/DC=/; s/\./,DC=/g')
SAM=/var/lib/samba/private/sam.ldb
DEADLINE=$(( $(date +%s) + ${WAIT_MINUTES:-45} * 60 ))

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------ ###
### | Wait for a mark | ###
### ------------------ ###
### Prints the computers that joined, once, and their marks as they come.   ###
seen=""
mac_seen=0; mac_gone=0
# Present in the netmap (ephemeral devices disappear when their job logs out).
# "Online" is not used: it can read false while a device is idle.
mac_online() {
  tailscale status --json 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); h=sys.argv[1]
sys.exit(0 if any(p.get("HostName")==h for p in (d.get("Peer") or {}).values()) else 1)' "$1"
}
while :; do
  joined=$(ldbsearch -H "$SAM" -b "CN=Computers,$BASEDN" "(objectClass=computer)" sAMAccountName 2>/dev/null \
    | sed -n 's/^sAMAccountName: //p' | sort | tr '\n' ' ')
  [ "$joined" != "$seen" ] && { echo "Joined computers: ${joined:-none}"; seen=$joined; }
  marks=$(ldbsearch -H "$SAM" -b "CN=Computers,$BASEDN" "(description=macoslaps-ci-*)" description 2>/dev/null \
    | sed -n 's/^description: //p')
  if grep -q "macoslaps-ci-" <<< "$marks"; then
    echo "The Mac reported: $marks"
    break
  fi
  if [ -n "${MAC_HOST:-}" ]; then
    if mac_online "$MAC_HOST"; then
      [ "$mac_seen" -eq 0 ] && echo "The Mac ($MAC_HOST) is on the tailnet"
      mac_seen=1; mac_gone=0
    elif [ "$mac_seen" -eq 1 ]; then
      mac_gone=$((mac_gone + 1))
      if [ "$mac_gone" -ge 18 ]; then
        echo "::error::The Mac left the tailnet without reporting a result (see the ad-mac job)"
        exit 1
      fi
    fi
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::The Mac did not finish within ${WAIT_MINUTES:-45} minutes"
    exit 1
  fi
  sleep 10
done

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | What AD now holds | ###
### ---------------------- ###
### Attribute names only: the values are passwords.                         ###
ldbsearch -H "$SAM" -b "CN=Computers,$BASEDN" "(objectClass=computer)" \
  sAMAccountName ms-Mcs-AdmPwd ms-Mcs-AdmPwdExpirationTime msLAPS-Password msLAPS-PasswordExpirationTime 2>/dev/null \
  | sed -n 's/^\(sAMAccountName: .*\)$/\1/p; s/^\(ms-Mcs-AdmPwd\|msLAPS-Password\): .*/  \1: (set)/p; s/^\(ms[A-Za-z-]*ExpirationTime: .*\)$/  \1/p'
grep -q "macoslaps-ci-done" <<< "$marks"
