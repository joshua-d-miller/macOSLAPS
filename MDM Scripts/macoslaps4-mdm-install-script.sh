#!/bin/zsh
#shellcheck shell=bash
# shellcheck disable=SC2317
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload is-at-least

#############################################################################################################################
# macOSLAPS Install And Managed Admin User Creation Script
# By Henri Kovanen / Decens Oy / https://www.decens.fi
#
# Version 10 / 2025-01-13
#	* Tidying up, extra documentation and harmonizing things with the related scripts
#   * Added check for log folder existing before trying to write there
#   * Added optional promoting logged in user as admin when uninstalling
#   * Added option to prevent admin account creation (see managedAdminAccountMustExist)
# Version 9 / 2024-08-06
#	* Takes into account the new keychain method introduced in macOSLAPS 4.0.0
#   * First version with actual changelog
#
# Many kudos to Armin Briegel (@scriptingosx), Joshua Miller (@jmiller) and many others at MacAdmins Slack,
# CoPilot, StackOverflow and many others.
#
# The default variables work for new installations via MDM and if you already have macOSLAPS in your environment in 'Local'
# mode. If you have existing local admin account you wish to convert to LAPS-managed, please review the settings carefully.
# The most important settings to set per-environment are managedAdminAccountPassword, managedAdminAccountName,
# managedAdminAccountDeleteExisting, managedAdminAccountForceDeleteExisting and convertLoggedInUserToStandard.
#############################################################################################################################

scriptVersion=10

# This script must run as root
if [[ ! $(id -u) = "0" ]]; then echo "Script must run be with root privileges."; exit 1; fi

if [[ -e /var/tmp/.lapsInstallRunning ]]; then
    echo "Another instance of the script already running, waiting 10 seconds, then exiting..."
    sleep 10
    exit 1
fi

# Grab script PID and create a temp file to keep the script from launcing multiple instances
processPID=$$
echo "$processPID" > /var/tmp/.lapsInstallRunning
chmod 777 /var/tmp/.lapsInstallRunning

# Prevent computer sleep while script is active and grab the PID
caffeinate -dimsu -w $processPID &
caffPID=$!

#############################################################################################################################
# DEFINE VARIABLES HERE
#############################################################################################################################

# NOTE! You can override all of these temporarily by defining them as script arguments. Few examples:
# Uninstall macOSLAPS:                          ./macOSLAPS-install.sh uninstall=true
# Uninstall macOSLAPS but leave the account:    ./macOSLAPS-install.sh uninstall=true uninstallRemoveAdminAccount=false
# Install with custom download URL:             ./macOSLAPS-install.sh downloadURL="https://yourserver.com/macOSLAPS.pkg"

# ABOUT ADMIN ACCOUNT:
# If macOSLAPS is already installed, the script retrieves the account name from config and tries to get the password via
# macOSLAPS and test it. If the password works, the account will be kept intact UNLESS managedAdminAccountForceDeleteExisting
# is set to 'true' (default 'false'). If macOSLAPS is not installed or the account is allowed to be deleted,
# then the following password will be set for the new account.
#
# If the user creation options are not enough, you could use other tools such as https://github.com/freegeek-pdx/mkuser to
# create the account first, then install macOSLAPS to take control of that account. Set managedAdminAccountMustExist to
# 'true' to make sure the account is never created via this script. You should also set managedAdminAccountDeleteExisting
# and managedAdminAccountForceDeleteExisting both to 'false' in such case.
#
# ABOUT PASSWORD:
# Should everything work, this password is valid only for a few seconds until macOSLAPS rotates it to a random password.
# If you don't want to expose your existing fixed password as plaintext in the script, you should probably use the default
# password (which would fail on purpose) and set managedAdminAccountDeleteExisting to 'true' so the existing account gets
# deleted and re-created.

# ABOUT SECURE TOKENS:
# If your existing admin account is Secure Token enabled and you wish to keep it that way, then you MUST enter a working
# password as managedAdminAccountPassword option 1 so that the account should not get deleted. Accounts created via this'
# script DO NOT HAVE Secure Token and thus CANNOT unlock FileVault. If your MDM supports Bootstrap Token, you can login with
# the admin account once via GUI to enable a Secure Token but this would be a manual step.
#
# You should always escrow your FileVault Personal Recovery Keys to MDM or other service make sure you have a method for
# resetting forgotten user passwords. The macOSLAPS account without a Secure Token can only be used for elevation, not
# resetting ST-enabled users' passwords or unlocking FileVault.

#######################################################
##### Admin account and password variables
#######################################################

    # Option 1: Set a fixed password for newly created accounts or existing admin account without macOSLAPS:
# managedAdminAccountPassword="Sup3r_S3cur3_P4sSw0rd"

    # Option 2: ...OR set computer serial number as initial password:
# managedAdminAccountPassword=$(system_profiler SPHardwareDataType | grep "Serial Number" | awk '{print $NF}')

    # Option 3: ...OR set a random generated string as password (example: 'D60656cD-944c-4110-9118-6c03Dc88Fbb2'):
managedAdminAccountPassword=$(uuidgen | tr 'A-C' 'a-c')

    # Define initial admin password here using one using one of the three options. If you are converting existing managed admin
    # account to macOSLAPS, use the existing password to ensure the account does not get deleted and re-created (IF
    # managedAdminAccountDeleteExisting is set to 'true'). This is also used as newly created admin password and macOSLAPS
    # firstPass parameter when doing the initial rotation.
    #
    # If you have custom password policies in place, make sure the password satisfies those. If you have set password MINIMUM
    # lifetime, you need to either create the user separately beforhand enough to allow a password reset, or set
    # managedAdminAccountDeleteExisting and managedAdminAccountForceDeleteExisting both to 'false', in which case the admin gets
    # created during first run but the password rotation will fail until the minimum lifetime has passed.

managedAdminAccountName="lapsadmin"
    # Define custom name for newly created managed admin. (Default: 'lapsadmin')
    # This applies when there is no existing configured macOSLAPS installation (i.e. during first time install), OR
    # managedAdminAccountForceDeleteExisting is set to 'true'.

managedAdminUID="486"
    # Define custom UID for new managed admin account if necessary. (Default: 486)
    # Affects newly created accounts (and thus when managedAdminAccountForceDeleteExisting is set to 'true').

managedAdminAccountMustExist=false
    # Managed admin must exist to proceed with macOSLAPS installation. (Default: false)
    # Set this to 'true' if you are creating your admin account some other way and do NOT want this script to create it under
    # any circumstance. In that case this script will fail when there is no existing account so you may wish to run the script
    # on a schedule to ensure macOSLAPS gets installed eventually.

managedAdminAccountDeleteExisting=true
    # Delete existing admin if managedAdminAccountPassword (via script or grabbed from existing macOSLAPS) does not work? (Default: true)
    # The script tries to use the password from existing macOSLAPS installation and the password set above as
    # $managedAdminAccountPassword. If this is set to 'true', the managed admin account will be deleted and re-created IF
    # existing passwords fail. If set to 'false', the script will fail and exit without modifying the existing account.

    # NOTE! Deleting the account during install will ALWAYS automatically promote currently logged in user as admin if user is standard.
    # This is a failsafe preventive measure to ensure there is at least one local admin present on the machine, should something
    # fail. If you wish to keep the user as standard, set the variable convertLoggedInUserToStandard to true so the user
    # gets demoted as last step of install process, if creating the new account works.

managedAdminAccountForceDeleteExisting=false
    # Delete existing admin always, no matter what? (Default: false)
    # Set to 'true' if existing admin account should be deleted in any case, no matter if the existing passwords work or not.
    # This might be useful in some instances where the name/UID needs to be changed for one reason or another. Note that if
    # the script runs periodically, the account is removed and re-created every time the script runs. This works best when run
    # just once to whole fleet, then schedule the periodic runs with this preference set to 'false'.

managedAdminAccountHidden=true
    # Hide the managed admin account? (Default: true)
    # Set to 'true' if you want the account to be hidden from Login Window and home folder hidden. NOTE! Hides both existing
    # AND newly created accounts. Set to 'false' to create visible account OR unhide hidden existing account.

convertLoggedInUserToStandard=false
    # Convert currently logged in user to standard after installing macOSLAPS if user is currently admin? (Default: false)
    # ATTENTION! If you want to ensure there's MDM management or such, deploy your macOSLAPS settings separately beforehand and
    # set createFailsafeSettings to 'false' so the script won't proceed unless managed settings are successfully applied.
    # You don't want to end up in a situation where the machine has only one admin with a random password and no way to read it.

#######################################################
##### Download and install variables
#######################################################

    # Dynamic URL for latest version released in GitHub:
downloadURL=$(curl -s https://api.github.com/repos/joshua-d-miller/macOSLAPS/releases/latest | grep browser_download_url | grep -o 'https://.*\.pkg' | head -n 1)
    # Alternatively you can set a fixed URL for curl download, either GitHub or self-hosted:
#downloadURL="https://github.com/joshua-d-miller/macOSLAPS/releases/download/3.0.1(771)/macOSLAPS-3.0.1.771.pkg"

    # Dynamic URL to check the latest released version:
latestVersion=$(curl -s https://api.github.com/repos/joshua-d-miller/macOSLAPS/releases/latest | grep '"name":' | head -n 1 | awk '{print $3}')
    # Alternatively you can set a fixed version number to lock your deployment to specific version:
# latestVersion="3.0.4"
    # NOTE! Make sure that running '/usr/local/laps/macOSLAPS -version' with your desired version returns this exact version.
    # Use this preferrably with a fixed download URL to avoid new installs with a later version than desired.

pkgName=$(basename "$downloadURL")
pkgPath="/var/tmp/$pkgName"
    # Variables for macOSLAPS install. You can change pkgPath if you really, REALLY want/need to.

#######################################################
##### Local setting variables
#######################################################

createFailsafeSettings=false
    # Create local "failsafe" default settings if no existing settings found? (Default: false)
    # Recommended to keep 'false' when deploying settings via MDM to avoid conflicts.

launchDaemonInterval=90
    # Launch daemon interval in minutes, i.e. how often macOSLAPS checks if the password should be rotated. (Default: 90)

logFile="/private/var/log/macOSLAPS-install-script.log"
    # Define location for installation log file. (Default: "/private/var/log/macOSLAPS-install-script.log")

#######################################################
##### Uninstall variables
#######################################################

uninstall=false
    # Uninstall mode (Default: false)
    # Can also be defined via script argument: ./macOSLAPS-install.sh uninstall=true

uninstallRemoveAdminAccount=true
    # If uninstalling, remove the managed admin account as well? (Default: true)

uninstallForceRemoveAdminAccount=true
    # ...Even if said account was currently logged in, still kick out and remove? (Default: true)

uninstallPromoteLoggedUserAdmin=true
    # Promote logged in user as admin when uninstalling and removing managed admin account? (Default: true)
    # WARNING!
    # By default the currently logged in user will be promoted to admin when the managed admin is removed, UNLESS
    # uninstallPromoteLoggedUserAdmin is set to 'false'. In such case, MAKE SURE you don't end up with no admin users
    # left on the machine. If you don't have a management tool in place to create one, you may need to WIPE the device.

uninstallRemoveLocalConfig=true
    # Remove local config file ('/Library/Preferences/edu.psu.macoslaps.plist') during uninstall? (Default: true)

#############################################################################################################################
# END VARIABLE DEFINITION - DO NOT MODIFY BELOW
#############################################################################################################################

# Internal variable
install=true

########### Define functions ###########
echoOut () {
echo "$(date +"%Y-%m-%d %H:%M:%S"): macOSLAPS install script: $*" | tee -a "$logFile"
}

rmrf () {
    if [ -e "$1" ]; then rm -rfv "$1" > "$logFile"; fi
}

selfCleanup () {
    for i in "/var/root/Library/Application Support/macOSLAPS-password" "/var/root/Library/Application Support/macOSLAPS-expiration" "/var/root/.GeneratedLAPSServiceName" "$pkgPath"; do
        rmrf "$i"
    done
    exitProcessPID=$(cat /var/tmp/.lapsInstallRunning)
    if [[ $exitProcessPID = "$processPID" ]]; then
        echoOut "Removing temporary PID indicator..."
        rm /var/tmp/.lapsInstallRunning >/dev/null 2>&1
    else
        echoOut "Temporary PID indicator mismatch, keeping it..."
    fi
    kill "$caffPID"
    echoOut "############# SCRIPT END #############"
}

# Auto-execute selfCleanUp function on script exit
trap selfCleanup EXIT

checkAdmin () {
echoOut "checkAdmin: Checking $1"
dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1
}

enableAdmin () {
    echoOut "enableAdmin: Enabling admins for $1"
    dseditgroup -o edit -a "$1" -t user admin >/dev/null 2>&1
    if checkAdmin "$1"; then
        echoOut "enableAdmin: $1 is now admin"
        return 0
    else
        echoOut "enableAdmin: Error! $1 is still not admin"
        return 1
    fi
}

disableAdmin () {
    echoOut "disableAdmin: Disabling admins for $1"
    dseditgroup -o edit -d "$1" -t user admin >/dev/null 2>&1
    if checkAdmin "$1"; then
        echoOut "disableAdmin: Error! $1 is still admin"
        return 1
    else
        echoOut "disableAdmin: $1 is no longer admin"
        return 0
    fi
}

checkAdminExists () {
    # shellcheck disable=SC2086
    if [[ $(dscl . -list /Users | grep -Ec ^${managedAdminAccount}$) -ne 0 ]]; then
        echoOut "checkAdminExists: $managedAdminAccount exists"
        return 0
    else
        echoOut "checkAdminExists: $managedAdminAccount does NOT exist"
        return 1
    fi
}

checkVersion () {
    if [ -x /usr/local/laps/macOSLAPS ]; then
        currentVersion=$(/usr/local/laps/macOSLAPS -version)
        # Validate version numbers: check if strings start with 1-3 numbers, dot and then another 1-3 numbers
        # This pattern should work for version numbers from 0.0 to 999.999
        if [[ ! "$latestVersion" =~ ^[0-9]{1,3}[.][0-9]{1,3} ]] || [[ ! "$currentVersion" =~ ^[0-9]{1,3}[.][0-9]{1,3} ]]; then
            echoOut "Error parsing version numbers, defaulting to not to install..."
            echoOut "Versions: latest: $latestVersion // current: $currentVersion"
            return 0
        elif [ "$(printf '%s\n' "$latestVersion" "$currentVersion" | sort -V | head -n1)" = "$latestVersion" ]; then 
            # Version greater or equal than required
            echoOut "Current version $currentVersion (require $latestVersion) - update not needed."
            return 0
        else
            # Version less than required
            echoOut "Current version $currentVersion (require $latestVersion) - update needed"
            return 1
        fi
    else
        echoOut "macOSLAPS not currently installed"
        return 1
    fi
}

createFailsafeSettings () {
    ########### Create failsafe config ###########
    if [ $createFailsafeSettings = true ]; then
        managedAdminAccount="$managedAdminAccountName"
        preferenceFile="/Library/Preferences/edu.psu.macoslaps.plist"
        defaults write "$preferenceFile" LocalAdminAccount "$managedAdminAccountName"
        defaults write "$preferenceFile" Method "Local"
        defaults write "$preferenceFile" RemovePassChars "01iIlLoO"
        defaults write "$preferenceFile" PasswordLength -int 16
        defaults write "$preferenceFile" PasswordGrouping -int 4
        defaults write "$preferenceFile" PasswordSeparator "-"
        defaults write "$preferenceFile" ExclusionSets -array-add symbols
        killall cfprefsd
        return 0
    else
        if [ $uninstall = true ]; then
            return 0
        else
            return 1
        fi
    fi
}

readCurrentSettings () {
    if [ $uninstall = true ]; then
        # Uninstall mode - assume settings should be present and if not, wait for up to 1 minute
        runCountMax=12
        echoOut "readCurrentSettings: Uninstall mode - Looking for macOSLAPS settings (up to 1 minute) before continuing..."
    else
        # Install mode - wait for up to 5 minutes until (possibly) falling back to failsafe settings
        runCountMax=120
        echoOut "readCurrentSettings: Install mode - Looking for macOSLAPS settings (up to 10 minutes) before continuing..."
    fi
    runCount=1
    echoOut "readCurrentSettings: Checking edu.psu.macoslaps.plist (round # $runCount) from /Library/Preferences and /Library/Managed Preferences..."
    until [ -f "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist" ] || [ -f "/Library/Managed Preferences/edu.psu.macoslaps.plist" ] || [ -f "/Library/Preferences/com.joshua-d-miller.macoslaps.plist" ] || [ -f "/Library/Preferences/edu.psu.macoslaps.plist" ]; do
    sleep 5
    runCount=$((runCount+1))
    if [ $runCount -gt $runCountMax ]; then
        break
    fi
    echoOut "Checking edu.psu.macoslaps.plist (round # $runCount) from /Library/Preferences and /Library/Managed Preferences..."
    done

    # Grab the managed admin account from macOSLAPS preferences
    # (new com.joshua-d-miller.macoslaps domain first, then the legacy edu.psu.macoslaps domain)
    if [ -f "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist" ]; then
        echoOut "Reading macOSLAPS managed settings..."
        preferenceFile="/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist"
        managedAdminAccount=$(defaults read "$preferenceFile" LocalAdminAccount)
    elif [ -f "/Library/Managed Preferences/edu.psu.macoslaps.plist" ]; then
        echoOut "Reading macOSLAPS managed settings..."
        preferenceFile="/Library/Managed Preferences/edu.psu.macoslaps.plist"
        managedAdminAccount=$(defaults read "$preferenceFile" LocalAdminAccount)
    fi
    if [[ -z "$managedAdminAccount" ]] || [[ "$managedAdminAccount" = "" ]]; then
        if [ -e "/Library/Preferences/com.joshua-d-miller.macoslaps.plist" ]; then
            echoOut "Reading macOSLAPS local settings..."
            preferenceFile="/Library/Preferences/com.joshua-d-miller.macoslaps.plist"
            managedAdminAccount=$(defaults read "$preferenceFile" LocalAdminAccount)
        elif [ -e "/Library/Preferences/edu.psu.macoslaps.plist" ]; then
            echoOut "Reading macOSLAPS local settings..."
            preferenceFile="/Library/Preferences/edu.psu.macoslaps.plist"
            managedAdminAccount=$(defaults read "$preferenceFile" LocalAdminAccount)
        fi
    fi
    if [[ -z "$managedAdminAccount" ]] || [[ "$managedAdminAccount" = "" ]]; then
        echoOut "Did not get managed account from existing settings, trying failsafe settings..."
        if createFailsafeSettings; then
            echoOut "Failsafe (local) settings created."
        else
            echoOut "Error reading settings and could not create failsafe settings - Cannot continue (need more information)."
            exit 1
        fi
    fi

    echoOut "Managed account: $managedAdminAccount (via $preferenceFile)"
}

getCurrentLAPSPassword () {
    # Output the current admin password depending whether the method is file (3.0 and older) or keychain (4.x and newer)
    if is-at-least "4.0.0" "$currentVersion"; then
        # macOSLAPS 4.x or newer; follow the keychain procedure
        unset currentAdminPasswordUUID
        currentAdminPasswordUUID=$(cat "/var/root/.GeneratedLAPSServiceName")
        sleep 0.5
        currentAdminPassword=$(security find-generic-password -w -s "$currentAdminPasswordUUID")
        security delete-generic-password -s "$currentAdminPasswordUUID" >/dev/null 2>&1
        rm "/var/root/.GeneratedLAPSServiceName" >/dev/null 2>&1
        echo "$currentAdminPassword"
    else
        # macOSLAPS 3.x or older, follow the file procedure
        currentAdminPassword=$(cat "/var/root/Library/Application Support/macOSLAPS-password")
        rm "/var/root/Library/Application Support/macOSLAPS-password" >/dev/null 2>&1
        echo "$currentAdminPassword"
    fi
}


#################################################################################################################################################################################
# START OF SCRIPT
#################################################################################################################################################################################

# Verify log folder exists, create if missing
logFolder=$(dirname "$logFile")
if [ ! -d "$logFolder" ]; then
    if ! mkdir -p "$logFolder"; then
        echo "ERROR! Could not create log folder: ${logFolder}"
        exit 1
    fi
fi

echoOut " "
echoOut "############# SCRIPT START (version $scriptVersion, PID $processPID ) #############"


########### Evaluate variables ###########
if [ -z "$1" ]; then
    echoOut "No variables declared, proceeding with script defaults..."
else
    while [[ -n $1 ]]; do
        # shellcheck disable=SC2076
        if [[ $1 =~ ".*\=.*" ]]; then
            echoOut "Evaluating variable $1"
            eval "$1"
        fi
        shift 1
    done
fi

########### Do not run while Setup Assistant is running ###########
runCount=0
echoOut "Waiting for Setup Assistant to finish if it's running and a user to log in (check every 5 seconds for up to 30 minutes)..."
until ! pgrep -lqx 'Setup Assistant' && pgrep -lqx 'Finder' && pgrep -lqx 'Dock' && [ -f /var/db/.AppleSetupDone ]; do
	runCount=$((runCount+1))
	echoOut "Run # $runCount (waiting for Setup Assistant to quit and user to log in)"
	if [ $runCount -gt 360 ]; then
        echoOut "Timeout reached, exiting..."
		exit 1
	fi
	sleep 5
done

echoOut "Setup Assistant has finnished and a user is logged in, continuing..."

########### Verify that settings are present before continuing, either reading from file or creating failsafe ones ###########
readCurrentSettings



########### Download (if not uninstalling or latest version already installed) ###########
if [ ! $uninstall = true ]; then
    if checkVersion; then
        install=false
    fi
    if [ $install = true ]; then
        echoOut "Downloading installer..."
        set -o pipefail
        if curl --no-progress-meter -o "$pkgPath" -LJO "$downloadURL" | tee -a "$logFile"; then
            echoOut "Downloaded $pkgName from $downloadURL"
        else
            echoOut "Error! Curl command failed for $downloadURL"
            exit 1
        fi
        set +o pipefail
        if pkgutil --payload-files "$pkgPath" >/dev/null 2>&1; then
            echoOut "Downloaded package seems OK; contains payload files according to pkgutil."
        else
            echoOut "Error reading the file downloaded from $downloadURL"
            exit 1
        fi
    fi
fi



########### Uninstall if requested ###########
if [ $uninstall = true ]; then
    echoOut "Uninstall mode requested. Performing uninstall..."

    # Unload launch daemon
    if [[ $(launchctl list | grep -v grep | grep -c 'edu.psu.macoslaps-check' ) -ne 0 ]]; then
        launchctl bootout system/edu.psu.macoslaps-check | tee -a "$logFile"
    fi

    # Delete managed admin account if requested
    if [ $uninstallRemoveAdminAccount = true ]; then
        if checkAdminExists; then
            echoOut "Removal of admin account requested in config, trying to remove..."
            loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
            if [[ ! "$loggedInUser" == "$managedAdminAccount" ]]; then
                if [ $uninstallPromoteLoggedUserAdmin = true ]; then
                    if checkAdmin "$loggedInUser"; then
                        echoOut "$loggedInUser is admin, continuing..."
                    else
                        echoOut "$loggedInUser is not admin, promoting to admin..."
                        if enableAdmin "$loggedInUser"; then
                            echoOut "Added admin privileges for $loggedInUser"
                        else
                            echoOut "Error adding admin privileges for $loggedInUser"
                            exit 1
                        fi
                    fi
                else
                    echoOut "Not allowed to promote logged in user as admin, leaving as-is..."
                fi
                sysadminctl -deleteUser "$managedAdminAccount"  | tee -a "$logFile"
                sleep 1
                if checkAdminExists; then
                    echoOut "Error! Deleting existing account failed."
                    exit 1
                else
                    echoOut "Account successfully deleted."
                fi
            else
                if [ $uninstallForceRemoveAdminAccount = true ]; then
                    echoOut "$managedAdminAccount currently logged in, kicking out..."
                    # lwPID=$(ps aux | grep -v grep | grep loginwindow | grep "$managedAdminAccount" -m 1 | awk '{print $2}')
                    # shellcheck disable=SC2086
                    lwPID=$(pgrep -u "$(id -u $managedAdminAccount)" loginwindow | head -n1)
                    kill -9 "$lwPID"
                    sleep 5
                    if [ $uninstallPromoteLoggedUserAdmin = true ]; then
                        if checkAdmin "$loggedInUser"; then
                            echoOut "$loggedInUser is admin, continuing..."
                        else
                            echoOut "$loggedInUser is not admin, promoting to admin..."
                            if enableAdmin "$loggedInUser"; then
                                echoOut "Added admin privileges for $loggedInUser"
                            else
                                echoOut "Error adding admin privileges for $loggedInUser"
                                exit 1
                            fi
                        fi
                    else
                        echoOut "Not allowed to promote logged in user as admin, leaving as-is..."
                    fi
                    sysadminctl -deleteUser "$managedAdminAccount"  | tee -a "$logFile"
                    sleep 1
                    if checkAdminExists; then
                        echoOut "Error! Deleting existing account failed."
                        exit 1
                    else
                        echoOut "Account successfully deleted."
                    fi
                else
                    echoOut "Error! $managedAdminAccount currently logged in, cannot delete!"
                    exit 1
                fi
            fi
        fi
    else
        echoOut "Leaving managed admin account as is (removal not requested)."
    fi

    # Delete files
    for i in "/usr/local/laps/macosLAPS" "/usr/local/laps/macOSLAPS-repair" "/private/etc/paths.d/laps" "/var/root/Library/Application Support/macOSLAPS-password" "/var/root/Library/Application Support/macOSLAPS-expiration" "/Library/LaunchDaemons/edu.psu.macoslaps-check.plist" "/var/root/.GeneratedLAPSServiceName"; do
        rmrf "$i"
    done

    # Forget packages
    for receipt in $(pkgutil --pkgs | grep edu.psu.macOSLAPS); do
        pkgutil --forget "$receipt"
    done

    if [ $uninstallRemoveLocalConfig = true ]; then
        echoOut "Removal of local config requested, removing..."
        if [ -e "/Library/Preferences/edu.psu.macoslaps.plist" ]; then rm "/Library/Preferences/edu.psu.macoslaps.plist"; else echoOut "No local settings present."; fi
    fi

    echoOut "Uninstall finished."
    exit 0
fi


########### Verify existing admin account ###########
# Will run series of tests and determine the following:
# 1. Does the existing account need to be deleted?
# 2. Does a new account need to be created?
# 3. Does the password need to be rotated?
echoOut "Verifying existing admin account..."

# Set defaults to failsafe mode
deleteExistingAdmin=false
createAdminAccount=false
rotatePassword=false


if ! checkAdminExists; then
    if [ $managedAdminAccountMustExist = true ]; then
        echoOut "Managed admin does not exist but required in script config (managedAdminAccountMustExist set to 'true'). Exiting without further action."
        exit 1
    fi
	echoOut "Account $managedAdminAccount not found, creating it and continuing with installation."
    deleteExistingAdmin=false
    createAdminAccount=true
    rotatePassword=true
else
    if [ $managedAdminAccountForceDeleteExisting = true ]; then
        echoOut "ATTENTION! managedAdminAccountForceDeleteExisting set to TRUE - will delete existing account."
        deleteExistingAdmin=true
        createAdminAccount=true
        rotatePassword=true
    else
        # Verify existing macOSLAPS, i.e. are we just doing a version update
        if [ -x /usr/local/laps/macOSLAPS ]; then
            # macOSLAPS found, we will test the password so we won't be updating blind
            echoOut "macOSLAPS found, trying to get the current password for $managedAdminAccount..."
            set -o pipefail
            if /usr/local/laps/macOSLAPS -getPassword > "$logFile"; then
                echoOut "Got a working password for $managedAdminAccount - will keep existing account as is."
                adminPassword=$(getCurrentLAPSPassword)
                # Change the default password to one grabbed by macOSLAPS
                managedAdminAccountPassword="$adminPassword"
                deleteExistingAdmin=false
                createAdminAccount=false
                rotatePassword=false
            else
                echoOut "Error! Running macOSLAPS to get the existing password failed (wrong password or application error)."
                echoOut "Trying to reset the password..."
                if /usr/local/laps/macOSLAPS -resetPassword | tee -a "$logFile"; then
                    echoOut "Password rotated successfully, testing once more...."
                    if /usr/local/laps/macOSLAPS -getPassword | tee -a "$logFile"; then
                        echoOut "Password tested successfully."
                    else
                        echoOut "Password test failed."
                        if [ $managedAdminAccountDeleteExisting = true ] || [ $managedAdminAccountForceDeleteExisting = true ]; then
                            echoOut "Allowed to remediate - will delete existing account and create a new one."
                            deleteExistingAdmin=true
                            createAdminAccount=true
                            rotatePassword=true
                        else
                            echoOut "Not allowed to remediate so abort install. Exiting."
                            exit 1
                        fi
                    fi
                else
                    echoOut "Rotation failed."
                    if [ $managedAdminAccountDeleteExisting = true ] || [ $managedAdminAccountForceDeleteExisting = true ]; then
                        echoOut "Allowed to remediate - will delete existing account and create a new one."
                        deleteExistingAdmin=true
                        createAdminAccount=true
                        rotatePassword=true
                    else
                        echoOut "Not allowed to remediate so abort install. Cleaning up and exiting."
                        exit 1
                    fi
                fi
            fi
            set +o pipefail
        else
            echoOut "macOSLAPS not found - trying default password for $managedAdminAccount from script..."
            if dscl . authonly "$managedAdminAccount" "$managedAdminAccountPassword"; then
                echoOut "Default password worked for $managedAdminAccount - will keep existing account but rotate the password..."
                deleteExistingAdmin=false
                createAdminAccount=false
                rotatePassword=true
            else
                echoOut "Error! Default password failed."
                if [ $managedAdminAccountDeleteExisting = true ] || [ $managedAdminAccountForceDeleteExisting = true ]; then
                    echoOut "Allowed to remediate - will delete existing account and create a new one."
                    deleteExistingAdmin=true
                    createAdminAccount=true
                    rotatePassword=true
                else
                    echoOut "Not allowed to remediate, abort install and exit."
                    exit 1
                fi
            fi
        fi
    fi
fi


########### Delete existing account if needed ###########
if [ $deleteExistingAdmin = true ]; then
    # Promote current user to admin as failsafe security measure
    loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
    if [[ ! "$loggedInUser" == "$managedAdminAccount" ]] && [[ ! "$loggedInUser" == "root" ]] && [[ ! "$loggedInUser" == "_mbsetupuser" ]] && [[ ! "$loggedInUser" == "loginwindow" ]]; then
        if ! checkAdmin "$loggedInUser"; then
            if enableAdmin "$loggedInUser"; then
                echoOut "Added admin privileges for $loggedInUser"
            else
                echoOut "Error adding admin privileges for $loggedInUser"
                exit 1
            fi
        else
            echoOut "User $loggedInUser is admin"
        fi
    fi
    if [[ ! "$loggedInUser" == "$managedAdminAccount" ]]; then
        sysadminctl -deleteUser "$managedAdminAccount" | tee -a "$logFile"
        sleep 5
        if checkAdminExists; then
            echoOut "Error! Deleting existing account failed. Cleaning up and exiting."
            exit 1
        else
            echoOut "Existing account deleted successfully."
        fi
    else
        echoOut "Error! Managed admin currently logged in, cannot delete!"
        exit 1
    fi
fi


########### Create new account if needed ###########
if [ $createAdminAccount = true ]; then
    sysadminctl -addUser "$managedAdminAccount" -fullName "$managedAdminAccount" -UID "$managedAdminUID" -password "$managedAdminAccountPassword" -admin 2>&1 | tee -a "$logFile"
    sleep 5
    if ! checkAdminExists; then
        echoOut "Error! Creating new account failed. Cleaning up and exiting."
        exit 1
    else
        echoOut "New account created successfully."
    fi
fi


########### Verify the account has home directory to ease up logins ###########
echoOut "Verifying managed account home directory..."
if [ ! -d "/Users/$managedAdminAccount" ]; then
    echoOut "Admin account has no home directory, attempting to create one..."
    createhomedir -c -u "$managedAdminAccount" | tee -a "$logFile"
    if [ ! -d "/Users/$managedAdminAccount" ]; then
        echoOut "Error! Failed to create home directory for admin account. Cleaning up and exiting."
        exit 1
    else
        echoOut "Home directory created successfully."
    fi
else
    echoOut "Home directory found."
fi


########### Verify the admin account is actually admin, try to grant privileges if not ###########
echoOut "Verifying managed account privileges..."
if checkAdmin "$managedAdminAccount"; then
    echoOut "Account has admin privileges."
else
    if enableAdmin "$managedAdminAccount"; then
        echoOut "Admin account didn't have admin privileges but successfully granted them."
    else
        echoOut "Account exists but does not have admin privileges AND granting them failed - verify manually what's going on. Cleaning up and exiting."
        exit 1
    fi
fi


########### Hide the account if defined ###########
if [ $managedAdminAccountHidden = true ]; then
    echoOut "Hidden account requested in config, hiding..."
    dscl . create "/Users/$managedAdminAccount" IsHidden 1
    chflags hidden "/Users/$managedAdminAccount"
else
    echoOut "Visible account requested in config, making sure it's visible..."
    dscl . create "/Users/$managedAdminAccount" IsHidden 0
    chflags nohidden "/Users/$managedAdminAccount"
fi


########### Install macOSLAPS ###########
if [ $install = true ]; then
    echoOut "Installing macOSLAPS..."
    set -o pipefail
    if ! installer -pkg "$pkgPath" -target / | tee -a "$logFile"; then
        echoOut "Error! Install failed for $pkgName. Cleaning up and exiting."
        exit 1
    fi
    set +o pipefail
    echoOut "Install successful."
fi


########### Rotate the password after installing macOSLAPS ###########
if [ $rotatePassword = true ]; then
    echoOut "Rotating the password..."
    set -o pipefail
	if /usr/local/laps/macOSLAPS -firstPass "$managedAdminAccountPassword" | tee -a "$logFile"; then
        echoOut "Password rotated successfully."
    else
        echoOut "Error! Password was not rotated successfully, check logs for troubleshooting. Cleaning up and exiting."
        exit 1
    fi
    set +o pipefail
    ########### Grab the new password and test it against open directory authorization ###########
    echoOut "Getting the rotated password and testing against local directory..."
    set -o pipefail
    if ! /usr/local/laps/macOSLAPS -getPassword | tee -a "$logFile"; then
        echoOut "Error! Getting the rotated password failed. Cleaning up and exiting."
        exit 1
    fi
    set +o pipefail
    newAdminPassword=$(getCurrentLAPSPassword)
    if ! dscl . authonly "$managedAdminAccount" "$newAdminPassword"; then
        echoOut "Password was rotated and fetched, yet admin authentication failed. Cleaning up and exiting."
        exit 1
    fi
fi

echoOut "macOSLAPS installed and tested successfully."

########### Adjust launch daemon interval and restart the daemon ###########
intervalInSeconds=$((launchDaemonInterval * 60))
if [[ $(defaults read /Library/LaunchDaemons/edu.psu.macoslaps-check StartInterval) -ne "$intervalInSeconds" ]]; then
    echoOut "Adjusting launch daemon run interval to $launchDaemonInterval minutes ($intervalInSeconds seconds)..."
    defaults write /Library/LaunchDaemons/edu.psu.macoslaps-check StartInterval "$intervalInSeconds"
    echoOut "Interval adjusted, restarting the macoslaps-check daemon..."
    if [[ $(launchctl list | grep -v grep | grep -c 'edu.psu.macoslaps-check' ) -ne 0 ]]; then
        launchctl kickstart -k system/edu.psu.macoslaps-check | tee -a "$logFile"
    else
        if [ -e "/Library/LaunchDaemons/edu.psu.macoslaps-check.plist" ]; then
            launchctl start /Library/LaunchDaemons/edu.psu.macoslaps-check.plist | tee -a "$logFile"
        else
            echoOut "Error! Could not find macOSLAPS launch daemon!"
            exit 1
        fi
    fi
else
    echoOut "Launch daemon interval already se at requested interval, not changing."
fi

########### Convert logged in user to standard ###########
if [ $convertLoggedInUserToStandard = true ]; then
    echoOut "Requested to convert logged in user to standard..."
    loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
    echoOut "User logged in: $loggedInUser"
    if [[ ! "$loggedInUser" == "$managedAdminAccount" ]] && [[ ! "$loggedInUser" == "root" ]] && [[ ! "$loggedInUser" == "_mbsetupuser" ]] && [[ ! "$loggedInUser" == "loginwindow" ]]; then
        if checkAdmin "$loggedInUser"; then
            echoOut "$loggedInUser is admin, removing privileges..."
            if disableAdmin "$loggedInUser"; then
                echoOut "Removed admin privileges from $loggedInUser"
            else
                echoOut "Error removing admin privileges from $loggedInUser"
                exit 1
            fi
        else
            echoOut "$loggedInUser is not admin, no need to remove privileges."
        fi
    fi
fi

echoOut "macOSLAPS install has finished successfully."

exit 0