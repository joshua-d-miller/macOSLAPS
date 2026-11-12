#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | Packaging | uninstall.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-11
 Updated:   2026-11-12

 Purpose:
     Removes macOSLAPS: the app, the /usr/local/laps symlink, the
     LaunchDaemon (current and 3.x / 845 labels), /etc/paths.d/laps, and
     the installer receipts. By default the stored password is KEPT in the
     System keychain, so reinstalling macOSLAPS picks up where it left
     off. --purge also deletes the stored passwords (current, pending,
     legacy items and exports), the state in /var/db/macoslaps and the
     log; after that nobody can look up the admin's password from this
     Mac, so make sure your MDM has it (or change it) first. Settings
     profiles are your MDM's and are not touched.

 Usage:
     sudo /Applications/macOSLAPS.app/Contents/Resources/\
         uninstall.sh [--purge]
     sudo macOSLAPS -uninstall [-purge]
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file. Also removes the service daemon,
                        claude    its request folder, the deadline file and
                                  the menu bar LaunchAgent; --purge also
                                  removes the logs.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------- ###
### | Options | ###
### ----------- ###
set -u

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh must be run as root." >&2; exit 77; }
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge|-purge) PURGE=1 ;;
        *) echo "Unknown option: $arg (use --purge to also delete the stored password)" >&2; exit 64 ;;
    esac
done

SYSKC=/Library/Keychains/System.keychain
say() { echo "macOSLAPS uninstall: $*"; }

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------- ###
### | LaunchDaemon, app and files | ###
### ------------------------------- ###
for label in com.joshua-d-miller.macoslaps-check com.joshua-d-miller.macoslaps-service edu.psu.macoslaps-check; do
    /bin/launchctl bootout "system/$label" 2>/dev/null && say "stopped $label"
    plist="/Library/LaunchDaemons/$label.plist"
    [ -e "$plist" ] && /bin/rm -f "$plist" && say "removed $plist"
done

console_uid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null)
if [ -n "$console_uid" ] && [ "$console_uid" != 0 ]; then
    /bin/launchctl bootout "gui/$console_uid/com.joshua-d-miller.macoslaps.agent" 2>/dev/null && say "stopped the menu bar agent"
fi
[ -e /Library/LaunchAgents/com.joshua-d-miller.macoslaps.agent.plist ] && /bin/rm -f /Library/LaunchAgents/com.joshua-d-miller.macoslaps.agent.plist && say "removed the menu bar LaunchAgent"

# The symlink (4.0) or binary (3.x / 845) at the old path, and the directory if empty.
if [ -L /usr/local/laps/macOSLAPS ] || [ -e /usr/local/laps/macOSLAPS ]; then
    /bin/rm -f /usr/local/laps/macOSLAPS && say "removed /usr/local/laps/macOSLAPS"
fi
/bin/rmdir /usr/local/laps 2>/dev/null
[ -e /etc/paths.d/laps ] && /bin/rm -f /etc/paths.d/laps && say "removed /etc/paths.d/laps"
if [ -d /Applications/macOSLAPS.app ]; then
    /bin/rm -rf /Applications/macOSLAPS.app && say "removed /Applications/macOSLAPS.app"
fi
/bin/rm -f /var/run/macOSLAPS.lock
[ -d "/Library/Application Support/macOSLAPS/Requests" ] && /bin/rm -rf "/Library/Application Support/macOSLAPS/Requests" && say "removed the request folder"
/bin/rm -f "/Library/Application Support/macOSLAPS/deadline.plist"
/bin/rmdir "/Library/Application Support/macOSLAPS" 2>/dev/null

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------ ###
### | Receipts | ###
### ------------ ###
for receipt in com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps-check edu.psu.macOSLAPS edu.psu.macOSLAPS-check; do
    /usr/sbin/pkgutil --pkg-info "$receipt" >/dev/null 2>&1 && /usr/sbin/pkgutil --forget "$receipt" >/dev/null && say "forgot receipt $receipt"
done

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------ ###
### | Stored passwords (--purge) | ###
### ------------------------------ ###
if [ "$PURGE" -eq 1 ]; then
    if [ -f /var/root/.GeneratedLAPSServiceName ]; then
        export_name=$(/usr/bin/tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
        [ -n "$export_name" ] && /usr/bin/security delete-generic-password -s "$export_name" "$SYSKC" >/dev/null 2>&1
        /bin/rm -f /var/root/.GeneratedLAPSServiceName
    fi
    for service in com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps.pending com.joshua-d-miller.macoslaps.reveal macOSLAPS macOSLAPS-pending; do
        while /usr/bin/security delete-generic-password -s "$service" "$SYSKC" >/dev/null 2>&1; do
            say "deleted keychain item $service"
        done
    done
    /bin/rm -f "/var/root/Library/Application Support/macOSLAPS-password" "/var/root/Library/Application Support/macOSLAPS-expiration"
    /bin/rm -rf /var/db/macoslaps && say "removed /var/db/macoslaps"
    /bin/rm -f /Library/Logs/macOSLAPS.log
    /bin/rm -rf "/Library/Application Support/macOSLAPS/Logs" && say "removed the logs"
    /bin/rmdir "/Library/Application Support/macOSLAPS" 2>/dev/null
    say "stored passwords deleted (--purge)."
else
    say "the stored password was kept in the System keychain (use --purge to delete it)."
fi
say "done."
exit 0
