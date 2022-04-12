#!/bin/sh
: '
-------------------------
| macOSLAPS EA Password |
-------------------------
| Captures the Password from the file outputted
| to the filesystem and sends the result to jamf
| in the following format:
|     | Expiration: ExpirationHere |
------------------------------------------------------------
| Created: Richard Purves - https://github.com/franton
| Last Update By: Joshua D. Miller - josh.miller@outlook.com
| Last Update Date: March 19, 2022
------------------------------------------------------------
'
# Path to macOSLAPS binary
LAPS=/usr/local/laps/macOSLAPS
# Path to Password File
PW_FILE="/var/root/Library/Application Support/macOSLAPS-password"

if [ -e $LAPS ] ; then
    # Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    $LAPS -getPassword
    CURRENT_PASSWORD=$(/bin/cat "$PW_FILE")
    # Test $current_password to ensure there is a value
    if [ -z "$CURRENT_PASSWORD" ]; then
        # Don't Write anything to jamf as it might overwrite an
        # old password in place that might still be needed
        exit 0
    else
        /bin/echo "<result>| Password: $CURRENT_PASSWORD |</result>"
        # Run macOSLAPS a second time to remove the password file
        # and expiration date file from the system
        $LAPS
    fi

else
	echo "<result>Not Installed</result>"
fi

exit 0
