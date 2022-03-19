#!/bin/sh
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
| Last Update Date: March 19, 2022
------------------------------------------------------------
'
# Path to macOSLAPS binary
LAPS=/usr/local/laps/macOSLAPS
# Path to Password File
PW_FILE="/var/root/Library/Application Support/macOSLAPS-password"
EXP_FILE="/var/root/Library/Application Support/macOSLAPS-expiration"

if [ -e $LAPS ] ; then
    # Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    $LAPS -getPassword
    CURRENT_PASSWORD=$(/bin/cat "$PW_FILE")
    EXPIRATION_DATE=$(/bin/cat "$EXP_FILE" )
    # Test $current_password to ensure there is a value
    if [ -z "$CURRENT_PASSWORD" ]; then
        # Don't Write anything to jamf as it might overwrite an
        # old password in place that might still be needed
        exit 0
    else
        /bin/echo "<result>| Password: $CURRENT_PASSWORD | Expiration: $EXPIRATION_DATE |</result>"
        # Run macOSLAPS a second time to remove the password file
        # and expiration date file from the system
        $LAPS
    fi

else
	echo "<result>Not Installed</result>"
fi

exit 0
