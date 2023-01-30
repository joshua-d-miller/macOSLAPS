#!/bin/zsh
: '
-------------------------
| macOSLAPS EA Password |
-------------------------
| Captures the Password from the file outputted
| to the filesystem and sends the result to jamf
| in the following format:
|     | Password: $CURRENT_PASSWORD |
------------------------------------------------------------
| Created: Richard Purves - https://github.com/franton
| Last Update By: Joshua D. Miller - josh.miller@outlook.com
| Last Update Date: January 29, 2023
------------------------------------------------------------
'
### -------------------- ###
### | Global Variables | ###
### -------------------- ###
## Path to macOSLAPS binary ##
LAPS=/usr/local/laps/macOSLAPS
## Path to Password File ##
PW_FILE="/var/root/Library/Application Support/macOSLAPS-password"
## Local Admin Account ##
LOCAL_ADMIN=$(/usr/bin/defaults read \
    "/Library/Managed Preferences/edu.psu.macoslaps.plist" LocalAdminAccount)
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
    CURRENT_PASSWORD=$(/bin/cat "$PW_FILE" 2&> /dev/null)
    ## Test $current_password to ensure there is a value
    if [ -z "$CURRENT_PASSWORD" ]
    then
        ## Don't Write anything to jamf as it might overwrite an
        ## old password in place that might still be needed
        exit 0
    else
        /bin/echo "<result>| Password: $CURRENT_PASSWORD |</result>"
        ## Run macOSLAPS a second time to remove the password file
        ## and expiration date file from the system
        $LAPS
    fi
## Otherwise ##
else
	echo "<result>$VERIFIED</result>"
fi

exit 0
