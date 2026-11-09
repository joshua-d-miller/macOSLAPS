#!/bin/zsh
#shellcheck shell=bash
# shellcheck disable=SC2317
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload is-at-least

# This script must run as root
if [[ ! $(id -u) = "0" ]]; then echo "Script must run be with root privileges."; exit 1; fi

#############################################################################################################################
# macOSLAPS password grab and pre-emptive rotate script for Intune (and other MDMs)
# By Henri Kovanen / Decens Oy / https://www.decens.fi
# Version 3 / 2025-01-10
#	* Tidying up and harmonizing things with the related scripts
# Version 2 / 2024-08-06
#	* Takes into account the new keychain method introduced in macOSLAPS 4.0.0
#   * First version with changelog
#

# NOTE: All exits (save the root check) are 0 since Intune doesn't show any output if script fails, and we really don't
# NEED the script to actually fail - we just need to see the last line echoed before exit.

#############################################################################################################################

# Define the treshold for rotating the password, i.e. if password expires in less than this many days, rotate the
# password. This is to prevent an edge case where the password is grabbed in MDM but rotated automatically soon after,
# causing grabbed password not to work until next grab. This is especially handy for Intune, which makes the devices to
# check-in only every 8 hours or so, so theoretically the password could be out of sync for hours.

rotateTresholdDays=7

#############################################################################################################################
# Start script, no need to modify anything below.
#############################################################################################################################

passwordFile="/var/root/Library/Application Support/macOSLAPS-password"
expirationFile="/var/root/Library/Application Support/macOSLAPS-expiration"
v4uuidFile="/var/root/.GeneratedLAPSServiceName"

selfCleanup () {
for file in "$passwordFile" "$expirationFile" "$v4uuidFile"; do
if [[ -e "$file" ]]; then rm "$file"; fi
done
}

# Auto-execute selfCleanup function on script exit
trap selfCleanup EXIT

# Define the function to get password and expiration
getCurrentLAPSPassword () {
	if ! /usr/local/laps/macOSLAPS -getPassword > /dev/null 2>&1; then echo "Error running macOSLAPS"; fi
    # Get the current admin password and expiration depending whether the method is file (3.0 and older) or keychain (4.x and newer)
    if is-at-least "4.0.0" "$currentVersion"; then
        # macOSLAPS 4.x or newer; follow the keychain procedure
        currentAdminPasswordUUID=$(cat "/var/root/.GeneratedLAPSServiceName")
        currentAdminPassword=$(security find-generic-password -w -s "$currentAdminPasswordUUID")
		currentAdminExpiration=$(security find-generic-password -s "$currentAdminPasswordUUID" | /usr/bin/grep -Eo "\d{4}-\d{2}-\d{2}.*\d")
    else
        # macOSLAPS 3.x or older, follow the file procedure
        currentAdminPassword=$(cat "/var/root/Library/Application Support/macOSLAPS-password")
        currentAdminExpiration=$(cat "/var/root/Library/Application Support/macOSLAPS-expiration")
    fi
	# Running macOSLAPS again to clear the entries
	/usr/local/laps/macOSLAPS >/dev/null 2>&1
}

# Clear existing files if they exist.
selfCleanup

if [[ ! -x /usr/local/laps/macOSLAPS ]]; then
	echo "macOSLAPS not installed."
	exit 0
else
	# Get current macOSLAPS version to determine the password retrieval method
	currentVersion=$(/usr/local/laps/macOSLAPS -version)
	# Determine managed vs. local settings (prefer managed over local)
	# (new io.github.joshua-d-miller.macoslaps domain first, then the legacy edu.psu.macoslaps domain)
	plistFile=""
	for candidate in "/Library/Managed Preferences/io.github.joshua-d-miller.macoslaps.plist" "/Library/Managed Preferences/edu.psu.macoslaps.plist" \
	                 "/Library/Preferences/io.github.joshua-d-miller.macoslaps.plist" "/Library/Preferences/edu.psu.macoslaps.plist"; do
		if [ -f "$candidate" ]; then plistFile="$candidate"; break; fi
	done
	if [ -z "$plistFile" ]; then
		echo "macOSLAPS installed but no preferences found."
		exit 0
	fi

	# Check if macOSLAPS is in AD mode
	if [[ $( /usr/libexec/PlistBuddy -c "Print :Method" "$plistFile" ) == "AD" ]]; then
		echo "macOSLAPS running in AD mode."
		exit 0
	fi

	# Get the password and expiration
	getCurrentLAPSPassword

	# Calculate current expiration vs. rotation treshold
	currentDate=$(date +%s)
	# shellcheck disable=SC2086
	expiryDate=$(date -j -f "%Y-%m-%d %H:%M:%S" "$currentAdminExpiration" +%s )
	timeDiffDays="$(( (expiryDate-currentDate)/86400 ))"
	if [[ "$timeDiffDays" -lt "$rotateTresholdDays" ]]; then
		echo "Password expiry ($timeDiffDays) below treshold ($rotateTresholdDays), rotating the password..."
		if ! /usr/local/laps/macOSLAPS -resetPassword > /dev/null 2>&1; then
			echo "Error rotating the password!"
			exit 0
		fi
		# Grab the password and expiration time after rotate
		if ! /usr/local/laps/macOSLAPS -getPassword > /dev/null 2>&1; then
			echo "Error running macOSLAPS"
			exit 0
		fi
		getCurrentLAPSPassword
	else
		echo "Password expiry ($timeDiffDays) over treshold ($rotateTresholdDays), will not rotate."
	fi

	# Following test no longer needed as macOSLAPS starting from version 3.x tests the password with -getPassword flag.
	# Uncomment following section if you're still using macOSLAPS 1.x/2.x.

	# localAdmin=$( /usr/libexec/PlistBuddy -c "Print :LocalAdminAccount" "$plistFile" )

	# if ! dscl . -authonly "$localAdmin" "$currentAdminPassword" >/dev/null 2>&1; then
	# 	echo "Password testing failed!"
	# 	selfCleanup
	# 	exit 0
	# fi

	echo "Successfully retrieved following password: $currentAdminPassword (expires $currentAdminExpiration)"
	exit 0
fi

exit 0