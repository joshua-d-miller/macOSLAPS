#!/bin/zsh
: '
-------------------------
| macOSLAPS EA Combined |
-------------------------
| Captures the Password and Expiration from the files
| outputted to the filesystem and sends the results
| to jamf in the following format:
|     | Password: PasswordHere | Expiration: ExpirationHere |
------------------------------------------------------------
| Created: James Smith - https://github.com/smithjw
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
PW_FILE="/var/root/Library/Application Support/macOSLAPS-password"
## Path to Expiration File ##
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
    CURRENT_PASSWORD=$(read_exported password)
    EXPIRATION_DATE=$(read_exported expiration)
    ## Test $current_password to ensure there is a value
    if [ -z "$CURRENT_PASSWORD" ]; then
        ## Don't Write anything to jamf as it might overwrite an
        ## old password in place that might still be needed
        exit 0
    else
        /bin/echo "<result>| Password: $CURRENT_PASSWORD | Expiration: $EXPIRATION_DATE |</result>"
        ## Run macOSLAPS a second time to remove the password file
        ## and expiration date file from the system
        $LAPS > /dev/null 2>&1
    fi
## Otherwise ##
else
	echo "<result>Not Installed</result>"
fi

exit 0
