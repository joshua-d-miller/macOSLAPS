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
| Last Update Date: January 29, 2023
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
    CURRENT_EXPIRATION=$(/bin/cat "$EXP_FILE" 2&> /dev/null)
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
