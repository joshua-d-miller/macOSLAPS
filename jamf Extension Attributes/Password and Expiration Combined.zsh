#!/bin/zsh
: <<'HEADER'
===============================================================================
 macOSLAPS | Jamf Extension Attributes | Password and Expiration Combined.zsh
===============================================================================
 Version:   4.0.0
 Author:    James Smith, Joshua D. Miller, Claude
 Updated:   2026-11-11

 Purpose:
     Jamf Pro extension attribute (String) with the local admin's current
     password and when it expires:
     | Password: <password> | Expiration: <yyyy-MM-dd HH:mm:ss> |
     While a new password is staged (StagedRotation), it is added as
     "Pending: <password> |": the Mac switches to it once Jamf has it.
     With EscrowCertificates set, the result is the encrypted CMS block.

 Credits:
     Originally written by James Smith (github.com/smithjw); maintained by
     Joshua D. Miller.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    Reads macOSLAPS 4.0 with -escrow (or -status
                        claude    for the date) and shows a staged pending
                                  password too, so Jamf always has the password
                                  the Mac will use. Finds the app in
                                  /Applications, falling back to
                                  /usr/local/laps. Older releases (3.1 - 4.0.0
                                  845) still work through the -getPassword
                                  export; the 3.0 plaintext files are no longer
                                  read (macOSLAPS 4.0 deletes them).

                                  New header and section style.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Where macOSLAPS is | ###
### ---------------------- ###
### The app in /Applications (4.0), or the old path for 3.x and 4.0.0       ###
### (845). /usr/local/laps is legacy and removed in macOSLAPS 5.0.          ###
LAPS=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
[[ -x "$LAPS" ]] || LAPS=/usr/local/laps/macOSLAPS
SYSTEM_KEYCHAIN=/Library/Keychains/System.keychain

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------ ###
### | Reading the password | ###
### ------------------------ ###
### macOSLAPS 4.0 prints JSON with -escrow (or a CMS block when             ###
### EscrowCertificates is set). Older releases only have -getPassword,      ###
### which copies the password to a temporary keychain item; a second, plain ###
### run removes that copy again. Sets PASSWORD, PENDING, EXPIRATION and     ###
### CMS.                                                                    ###
json_value () {
    /usr/bin/plutil -extract "$1" raw -o - - <<< "$2" 2>/dev/null
}
iso_to_local () {
    ## 2026-12-11T14:00:00-05:00 -> 2026-12-11 14:00:00 (the format earlier EAs used) ##
    [[ -n "$1" ]] && /bin/echo "${${1[1,19]}/T/ }"
}
has_flag () {
    "$LAPS" -help 2>/dev/null | /usr/bin/grep -q -- "$1"
}
read_escrow () {
    PASSWORD="" PENDING="" EXPIRATION="" CMS=""
    if has_flag -escrow
    then
        local out
        out=$("$LAPS" -escrow 2>/dev/null)
        if [[ "$out" == -----BEGIN* ]]
        then
            CMS="$out"
            return
        fi
        PASSWORD=$(json_value password "$out")
        PENDING=$(json_value pending "$out")
        EXPIRATION=$(iso_to_local "$(json_value expires "$out")")
        return
    fi
    ## macOSLAPS 3.1 - 4.0.0 (845) ##
    "$LAPS" -getPassword > /dev/null 2>&1 || return
    local service
    service=$(/usr/bin/tr -d '\n' < /var/root/.GeneratedLAPSServiceName 2>/dev/null)
    [[ -n "$service" ]] || return
    PASSWORD=$(/usr/bin/security find-generic-password -w -s "$service" "$SYSTEM_KEYCHAIN" 2>/dev/null)
    EXPIRATION=$(/usr/bin/security find-generic-password -s "$service" "$SYSTEM_KEYCHAIN" 2>/dev/null | \
        /usr/bin/grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" | /usr/bin/head -1)
    ## A plain run removes the temporary copy ##
    "$LAPS" > /dev/null 2>&1
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------- ###
### | Main | ###
### -------- ###
### Nothing installed: say so. No password: print nothing, so Jamf keeps    ###
### the last value it has rather than storing an empty one.                 ###
if [[ ! -x "$LAPS" ]]
then
    /bin/echo "<result>Not Installed</result>"
    exit 0
fi
read_escrow
if [[ -n "$CMS" ]]
then
    /usr/bin/printf '%s\n' "<result>$CMS</result>"
elif [[ -n "$PASSWORD" ]]
then
    RESULT="| Password: $PASSWORD |"
    [[ -n "$EXPIRATION" ]] && RESULT="$RESULT Expiration: $EXPIRATION |"
    [[ -n "$PENDING" ]] && RESULT="$RESULT Pending: $PENDING |"
    /usr/bin/printf '%s\n' "<result>$RESULT</result>"
fi
exit 0
