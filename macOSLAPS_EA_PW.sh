#!/bin/zsh

# EA to show current macOSLAPS password

# Path to macOSLAPS binary
laps="/usr/local/laps/macOSLAPS"

if [ -f "$laps" ];
then
    # Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    "$laps" -getPassword
    current_password=$( cat "/var/root/Library/Application Support/macOSLAPS-password" )

	# Test $current_password to ensure there is a value
    if [ -z "$current_password" ];
    then 
        # The $current_password variable is empty, not writing anything
        echo "<result>No Password Set</result>"
        exit 0
    else
        # We know that $current_password has a value so writing it to Jamf
        echo "<result>$current_password</result>"

	# Run macOSLAPS a second time to remove the password file from the system
        "$laps" >/dev/null
    fi 
     
else
	echo "<result>Not Installed</result>"
fi

exit 0
