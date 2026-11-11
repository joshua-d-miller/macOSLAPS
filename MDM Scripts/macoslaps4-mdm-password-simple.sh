#!/bin/zsh
: <<'HEADER'
===============================================================================
 macOSLAPS | MDM Scripts | macoslaps4-mdm-password-simple.sh
===============================================================================
 Version:   4.0.0
 Author:    Henri Kovanen (Decens Oy), Joshua D. Miller, Claude
 Updated:   2026-11-11

 Purpose:
     Prints the macOSLAPS password of the managed local admin and when it
     expires, as one line for an MDM script result:
     <password> (expires yyyy-MM-dd HH:mm:ss)
     While a new password is staged, " (pending: <password>)" is added:
     the Mac switches to it once the MDM has collected it. With
     EscrowCertificates set, the encrypted CMS block is printed instead.

 Usage:
     Run as root by the MDM.

 Credits:
     Written by Henri Kovanen, Decens Oy (https://www.decens.fi). Versions
     v2 and v3 are Henri's own script versions.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 v2        2024-08-06   henri     Takes into account the new keychain method
                                  introduced in macOSLAPS 4.0.0. First version
                                  with a changelog.

 v3        2025-01-10   henri     Tidying up and harmonizing things with the
                                  related scripts.

 4.0.0     2026-11-11   joshua    macOSLAPS 4.0: reads -escrow and -status (no
                        claude    temporary keychain copy), finds the app in
                                  /Applications with /usr/local/laps as the
                                  fallback, and reports a staged pending
                                  password too. Older releases keep using
                                  -getPassword; the 3.0 plaintext files are no
                                  longer read (macOSLAPS 4.0 deletes them).

                                  New header and section style.
===============================================================================
HEADER
#shellcheck shell=bash
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Where macOSLAPS is | ###
### ---------------------- ###
### The app in /Applications (4.0), or the old path for 3.x and 4.0.0       ###
### (845). /usr/local/laps is legacy and removed in macOSLAPS 5.0.          ###
LAPS=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
[[ -x "$LAPS" ]] || LAPS=/usr/local/laps/macOSLAPS
SYSTEM_KEYCHAIN=/Library/Keychains/System.keychain
EXPORT_NAME_FILE=/var/root/.GeneratedLAPSServiceName

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------- ###
### | Reading macOSLAPS | ###
### --------------------- ###
### macOSLAPS 4.0 prints JSON with -escrow and -status. Older releases only ###
### have -getPassword, which copies the password to a temporary keychain    ###
### item that a second, plain run removes again. read_password sets         ###
### currentAdminPassword, currentAdminExpiration (yyyy-MM-dd HH:mm:ss),     ###
### pendingAdminPassword and escrowCMS.                                     ###
json_value () {
    ## plutil prints "Could not extract value" on stdout on some macOS versions ##
    local value
    value=$(plutil -extract "$1" raw -o - - <<< "$2" 2>/dev/null) || return 0
    printf '%s' "$value"
}
iso_to_local () {
    [[ -n "$1" ]] && printf '%s' "${${1[1,19]}/T/ }"
}
has_flag () {
    "$LAPS" -help 2>/dev/null | grep -q -- "$1"
}
laps_method () {
    ## Local or AD. 4.0: from -status, which merges both settings domains per key ##
    if has_flag -status; then
        json_value method "$("$LAPS" -status 2>/dev/null)"
        return
    fi
    local plist
    for plist in "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist" \
                 "/Library/Managed Preferences/edu.psu.macoslaps.plist" \
                 "/Library/Preferences/com.joshua-d-miller.macoslaps.plist" \
                 "/Library/Preferences/edu.psu.macoslaps.plist"; do
        if [ -f "$plist" ]; then
            /usr/libexec/PlistBuddy -c "Print :Method" "$plist" 2>/dev/null
            return
        fi
    done
}
read_password () {
    currentAdminPassword="" currentAdminExpiration="" pendingAdminPassword="" escrowCMS=""
    if has_flag -escrow; then
        local out
        out=$("$LAPS" -escrow 2>/dev/null) || return 1
        if [[ "$out" == -----BEGIN* ]]; then
            escrowCMS="$out"
            return 0
        fi
        currentAdminPassword=$(json_value password "$out")
        currentAdminExpiration=$(iso_to_local "$(json_value expires "$out")")
        pendingAdminPassword=$(json_value pending "$out")
        [[ -n "$currentAdminPassword" ]]
        return
    fi
    ## macOSLAPS 3.1 - 4.0.0 (845) ##
    "$LAPS" -getPassword > /dev/null 2>&1 || return 1
    local service
    service=$(tr -d '\n' < "$EXPORT_NAME_FILE" 2>/dev/null)
    currentAdminPassword=$(security find-generic-password -w -s "$service" "$SYSTEM_KEYCHAIN" 2>/dev/null)
    currentAdminExpiration=$(security find-generic-password -s "$service" "$SYSTEM_KEYCHAIN" 2>/dev/null | \
        grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1)
    ## A plain run removes the temporary copy ##
    "$LAPS" > /dev/null 2>&1
    rm -f "$EXPORT_NAME_FILE"
    [[ -n "$currentAdminPassword" ]]
}
## The password, its expiry and a staged one, as one line ##
password_line () {
    local line="${currentAdminPassword} (expires ${currentAdminExpiration})"
    [[ -n "$pendingAdminPassword" ]] && line="$line (pending: ${pendingAdminPassword})"
    print -r -- "$line"
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------- ###
### | Main | ###
### -------- ###
### Prints the password and its expiry, or a line starting with Error!.     ###
### Exits 1 on an error.                                                    ###
fail () {
    print -r -- "Error! $1"
    exit 1
}
[[ -x "$LAPS" ]] || fail "macOSLAPS not installed."
[[ "$(laps_method)" != "AD" ]] || fail "macOSLAPS in AD mode, can't read password locally."
read_password || fail "Running macOSLAPS returned an error."
if [[ -n "$escrowCMS" ]]; then
    print -r -- "$escrowCMS"
    exit 0
fi
password_line
exit 0
