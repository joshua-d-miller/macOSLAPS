#!/bin/zsh
: '
---------------------------
| macOSLAPS EA Expiration |
---------------------------
| Captures the Expiration from the file outputted
| to the filesystem and sends the result to jamf
| in the following format:
|     | Expiration: Expiration Date |
------------------------------------------------------------
| Created: Richard Purves - https://github.com/franton
| Last Update By: Joshua D. Miller - josh.miller@outlook.com
| Last Update Date: November 10, 2026
------------------------------------------------------------
'
### -------------------- ###
### | Global Variables | ###
### -------------------- ###
## Path to macOSLAPS binary ##
LAPS=/usr/local/laps/macOSLAPS
## Path to Password File ##
EXP_FILE="/var/root/Library/Application Support/macOSLAPS-expiration"
## Local Admin Account ##
LOCAL_ADMIN=$(/usr/bin/defaults read \
    "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist" LocalAdminAccount 2>/dev/null || \
    /usr/bin/defaults read \
    "/Library/Managed Preferences/edu.psu.macoslaps.plist" LocalAdminAccount)
## Service name file written by macOSLAPS 4.x (-getPassword exports to the System keychain) ##
SERVICE_FILE="/var/root/.GeneratedLAPSServiceName"
## Read the password / expiration exported by -getPassword ##
## macOSLAPS 4.x: temporary System keychain item. macOSLAPS 3.x: files. ##
read_exported () {
    if [ -f "$SERVICE_FILE" ]
    then
        local service=$(/bin/cat "$SERVICE_FILE")
        if [ "$1" = "password" ]
        then
            /usr/bin/security find-generic-password -w -s "$service" /Library/Keychains/System.keychain 2>/dev/null
        else
            /usr/bin/security find-generic-password -s "$service" /Library/Keychains/System.keychain 2>/dev/null | \
                /usr/bin/grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" | /usr/bin/head -1
        fi
    elif [ "$1" = "password" ]
    then
        /bin/cat "/var/root/Library/Application Support/macOSLAPS-password" 2>/dev/null
    else
        /bin/cat "/var/root/Library/Application Support/macOSLAPS-expiration" 2>/dev/null
    fi
}
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------- ###
### | Verify Requirements | ###
### ----------------------- ###
verify_requirements () {
    ## Does the binary exist ##
    if [ ! -e $LAPS ]
    then
        /bin/echo "macOSLAPS Not Installed"
        return
    fi
    ## Verify Local Admin Specified Exists ##
    if id "$1" &> /dev/null
    then
        /bin/echo "Yes"
    else
        /bin/echo "Account Not Found"
    fi
    return
}
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------- ###
### | Main Function | ###
### ----------------- ###
## Determine if macOSLAPS itself exits and the local admin account is present ##
VERIFIED=$(verify_requirements "$LOCAL_ADMIN")
## If we have verified LAPS and the Account ##
if [[ "$VERIFIED" == "Yes" ]]
then
    ## Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    $LAPS -getPassword > /dev/null
    CURRENT_EXPIRATION=$(read_exported expiration)
    ## Test $CURRENT_EXPIRATION to ensure there is a value
    if [ -z "$CURRENT_EXPIRATION" ]
    then
        ## Write no expiration date is present and send to
        ## jamf Pro
        /bin/echo "<result>No Expiration Date Present</result>"
    else
        /bin/echo "<result>| Expiration: $CURRENT_EXPIRATION |</result>"
        ## Run macOSLAPS a second time to remove the Expiration file
        ## and expiration date file from the system
        $LAPS
    fi
## Otherwise ##
else
	echo "<result>$VERIFIED</result>"
fi

exit 0
