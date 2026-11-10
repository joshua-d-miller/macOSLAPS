#!/bin/zsh
#shellcheck shell=bash
# shellcheck disable=SC2317
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload is-at-least

#############################################################################################################################
# macOSLAPS simple password grab (with expiration, if available)
# By Henri Kovanen / Decens Oy / https://www.decens.fi
# Version 3 / 2025-01-10
#	* Tidying up and harmonizing things with the related scripts
# Version 2 / 2024-08-06
#	* Takes into account the new keychain method introduced in macOSLAPS 4.0.0
#   * First version with changelog
#
#############################################################################################################################

gotError=false

# Define the function to get password and expiration
getCurrentLAPSPassword () {
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

passwordFile="/var/root/Library/Application Support/macOSLAPS-password"
expirationFile="/var/root/Library/Application Support/macOSLAPS-expiration"
v4uuidFile="/var/root/.GeneratedLAPSServiceName"

selfCleanup () {
for file in "$passwordFile" "$expirationFile" "$v4uuidFile"; do
if [[ -e "$file" ]]; then rm "$file"; fi
done
}

trap selfCleanup EXIT

# Grab the managed admin account from macOSLAPS preferences
# (new com.joshua-d-miller.macoslaps domain first, then the legacy edu.psu.macoslaps domain)
if [ -e "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist" ]; then
	preferenceFile="/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist"
elif [ -e "/Library/Managed Preferences/edu.psu.macoslaps.plist" ]; then
	preferenceFile="/Library/Managed Preferences/edu.psu.macoslaps.plist"
elif [ -e "/Library/Preferences/com.joshua-d-miller.macoslaps.plist" ]; then
	preferenceFile="/Library/Preferences/com.joshua-d-miller.macoslaps.plist"
elif [ -e "/Library/Preferences/edu.psu.macoslaps.plist" ]; then
	preferenceFile="/Library/Preferences/edu.psu.macoslaps.plist"
else
	outMsg="Error! Could not read macOSLAPS settings."
	gotError=true
fi

if [ $gotError = false ]; then
	if [ ! -x /usr/local/laps/macOSLAPS ]; then
		outMsg="Error! macOSLAPS not installed."
		gotError=true
	else
		currentVersion=$(/usr/local/laps/macOSLAPS -version)
	fi
fi
if [ $gotError = false ]; then
	if [[ $( /usr/libexec/PlistBuddy -c "Print :Method" "$preferenceFile" ) = "AD" ]]; then
		outMsg="Error! macOSLAPS in AD mode, can't read password locally."
		gotError=true
	fi
fi
if [ $gotError = false ]; then
	if ! /usr/local/laps/macOSLAPS -getPassword > /dev/null; then
		outMsg="Error! Running macOSLAPS returned an error."
		gotError=true
	else
		getCurrentLAPSPassword
		outMsg="${currentAdminPassword} (expires ${currentAdminExpiration})"
	fi
fi
if [ $gotError = false ]; then
	print -r -- "$outMsg"
	exit 0
else
	print -r -- "$outMsg"
	exit 1
fi