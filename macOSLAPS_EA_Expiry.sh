#!/bin/zsh

# Path to macOSLAPS binary
laps="/usr/local/laps/macOSLAPS"

if [ -f "$laps" ];
then
    # Ask macOSLAPS to write out the current password and echo it for the Jamf EA
    "$laps" -getPassword
    expiration_date=$( cat "/var/root/Library/Application Support/macOSLAPS-expiration" )

	# Test $current_password to ensure there is a value
    if [ -z "$expiration_date" ];
    then 
        # The $current_password variable is empty, not writing anything
        echo "<result>1970-01-01 12:00:00</result>"
        exit 0
    else
        # We know that $current_password has a value so writing it to Jamf
        echo "<result>$expiration_date</result>"

		# Run macOSLAPS a second time to remove the password file from the system
        "$laps" >/dev/null
    fi 
     
else
	echo "<result>1970-01-31 13:00:00</result>"
fi

exit 0
