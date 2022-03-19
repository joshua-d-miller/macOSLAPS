#!/bin/sh
: '
-------------------------
| macOSLAPS EA Password |
-------------------------
| Captures the Password from the file outputted
| to the filesystem and sends the result to jamf
| in the following format:
|     | Password: PasswordHere |
------------------------------------------------------------
| Created: Richard Purves - https://github.com/franton
| Last Update By: Joshua D. Miller - josh.miller@outlook.com
| Last Update Date: March 19, 2022
------------------------------------------------------------
'
# Path to macOSLAPS binary
LAPS=/usr/local/laps/macOSLAPS
# Path to Password File
EXP_FILE="/var/root/Library/Application Support/macOSLAPS-expiration"

if [ -e $LAPS ] ; then
    # Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    $LAPS -getPassword
    CURRENT_EXPIRATION=$(/bin/cat "$EXP_FILE")
    # Test $current_password to ensure there is a value
    if [ -z "$CURRENT_EXPIRATION" ]; then
        # Write no expiration date is present and send to
        # jamf Pro
        /bin/echo "<result>No Expiration Date Present</result>"
        exit 0
    else
        /bin/echo "<result>| Password: $CURRENT_EXPIRATION |</result>"
        # Run macOSLAPS a second time to remove the password file
        # and expiration date file from the system
        $LAPS
    fi

else
	echo "<result>Not Installed</result>"
fi

exit 0
