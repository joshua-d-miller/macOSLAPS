#!/bin/zsh
: <<'HEADER'
===============================================================================
 macOSLAPS | MDM Scripts | macoslaps4-mdm-install-script.sh
===============================================================================
 Version:   4.0.0
 Author:    Henri Kovanen (Decens Oy), Joshua D. Miller, Claude
 Updated:   2026-11-12

 Purpose:
     Installs (or updates, or uninstalls) macOSLAPS from an MDM and makes
     sure the managed local admin exists, is an admin, works with
     macOSLAPS and has a rotated password. Waits for Setup Assistant and
     for the macOSLAPS settings profile first. Review the settings below
     before deploying, above all managedAdminAccountPassword,
     managedAdminAccountName, managedAdminAccountDeleteExisting,
     managedAdminAccountForceDeleteExisting and
     convertLoggedInUserToStandard.

 Usage:
     Run as root from your MDM. Any setting can be overridden as an argument:
     Uninstall macOSLAPS:
         ./macoslaps4-mdm-install-script.sh uninstall=true
     Uninstall macOSLAPS but leave the account:
         ./macoslaps4-mdm-install-script.sh uninstall=true \
             uninstallRemoveAdminAccount=false
     Install with custom download URL:
         ./macoslaps4-mdm-install-script.sh \
             downloadURL="https://yourserver.com/macOSLAPS.pkg"

 Returns:
     0  installed, updated, already current, or uninstalled
     1  stopped; the log says why
        (/private/var/log/macOSLAPS-install-script.log)

 Credits:
     Written by Henri Kovanen, Decens Oy (https://www.decens.fi). Many
     kudos to Armin Briegel (@scriptingosx), Joshua Miller (@jmiller) and
     many others at the MacAdmins Slack, CoPilot, StackOverflow and many
     others. Versions v9 and v10 are Henri's own script versions;
     scriptVersion is 11 from 4.0.0.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 v9        2024-08-06   henri     Takes into account the new keychain method
                                  introduced in macOSLAPS 4.0.0. First version
                                  with an actual changelog.

 v10       2025-01-13   henri     Tidying up, extra documentation and
                                  harmonizing things with the related scripts.
                                  Checks that the log folder exists before
                                  writing there. Optionally promotes the
                                  logged-in user to admin when uninstalling.
                                  Option to prevent admin account creation
                                  (managedAdminAccountMustExist).

 4.0.0     2026-11-12   joshua    macOSLAPS 4.0: finds the app in /Applications
                        claude    (falling back to /usr/local/laps) and the
                                  LaunchDaemon
                                  com.joshua-d-miller.macoslaps-check (falling
                                  back to edu.psu.macoslaps-check). Checks the
                                  stored password with -status instead of
                                  exporting it. Uninstall runs macOSLAPS's own
                                  uninstaller (with --purge when the account is
                                  removed) and forgets the new and old
                                  receipts. Failsafe settings go to the new
                                  com.joshua-d-miller.macoslaps domain.

                                  Fixes: downloads the full package (not the
                                  app-only or LaunchDaemon-only one); reads the
                                  version from the release tag; reloads the
                                  LaunchDaemon so a new StartInterval takes
                                  effect (kickstart did not); the PID marker is
                                  no longer world-writable; the log is appended
                                  to, not overwritten. The admin password is
                                  piped to -firstPass -, never put on the
                                  command line.

                                  New header and section style (scriptVersion
                                  11).
===============================================================================
HEADER
#shellcheck shell=bash
# shellcheck disable=SC2317
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

scriptVersion=11

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------------------------- ###
### | Settings: admin account and password | ###
### ---------------------------------------- ###
### Define these per environment. Every setting can also be given as a      ###
### script argument, for example uninstall=true or                          ###
### downloadURL="https://yourserver.com/macOSLAPS.pkg".                     ###
# ABOUT ADMIN ACCOUNT:
# If macOSLAPS is already installed, the script reads the account name from its settings and checks that macOSLAPS has a
# working password for it. If so, the account is kept intact UNLESS managedAdminAccountForceDeleteExisting is set to 'true'
# (default 'false'). If macOSLAPS is not installed or the account is allowed to be deleted, then the following password will
# be set for the new account.
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
#
# ABOUT SECURE TOKENS:
# If your existing admin account is Secure Token enabled and you wish to keep it that way, then you MUST enter a working
# password as managedAdminAccountPassword option 1 so that the account should not get deleted. Accounts created via this
# script DO NOT HAVE Secure Token and thus CANNOT unlock FileVault. If your MDM supports Bootstrap Token, you can login with
# the admin account once via GUI to enable a Secure Token but this would be a manual step.
#
# You should always escrow your FileVault Personal Recovery Keys to MDM or other service make sure you have a method for
# resetting forgotten user passwords. The macOSLAPS account without a Secure Token can only be used for elevation, not
# resetting ST-enabled users' passwords or unlocking FileVault.

    # Option 1: Set a fixed password for newly created accounts or existing admin account without macOSLAPS:
# managedAdminAccountPassword="Sup3r_S3cur3_P4sSw0rd"

    # Option 2: ...OR set computer serial number as initial password:
# managedAdminAccountPassword=$(system_profiler SPHardwareDataType | grep "Serial Number" | awk '{print $NF}')

    # Option 3: ...OR set a random generated string as password (example: 'D60656cD-944c-4110-9118-6c03Dc88Fbb2'):
managedAdminAccountPassword=$(uuidgen | tr 'A-C' 'a-c')

    # Define initial admin password here using one of the three options. If you are converting existing managed admin
    # account to macOSLAPS, use the existing password to ensure the account does not get deleted and re-created (IF
    # managedAdminAccountDeleteExisting is set to 'true'). This is also used as newly created admin password and macOSLAPS
    # firstPass parameter when doing the initial rotation.
    #
    # If you have custom password policies in place, make sure the password satisfies those. If you have set password MINIMUM
    # lifetime, you need to either create the user separately beforehand enough to allow a password reset, or set
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
    # The script checks the password stored by an existing macOSLAPS installation and the password set above as
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------------------- ###
### | Settings: download and install | ###
### ---------------------------------- ###
### Where the installer comes from and which version is required.           ###
    # Latest release on GitHub (the full package, not the app-only or LaunchDaemon-only ones):
downloadURL=$(curl -s https://api.github.com/repos/joshua-d-miller/macOSLAPS/releases/latest | grep browser_download_url | grep -oE 'https://[^"]*/macOSLAPS-[0-9][^"/]*\.pkg' | head -n 1)
    # Alternatively you can set a fixed URL for curl download, either GitHub or self-hosted:
#downloadURL="https://github.com/joshua-d-miller/macOSLAPS/releases/download/4.0.0.868/macOSLAPS-4.0.0.868.pkg"

    # Version of the latest release, from its tag (4.0.0.868, or 4.0.0(845) for older releases, read as 4.0.0.845):
latestVersion=$(curl -s https://api.github.com/repos/joshua-d-miller/macOSLAPS/releases/latest | grep '"tag_name":' | head -n 1 | sed -E 's/.*"tag_name": *"([^"]*)".*/\1/; s/\(/./; s/\)//')
    # Alternatively you can set a fixed version number to lock your deployment to specific version:
# latestVersion="4.0.0.868"
    # NOTE! Make sure that running 'macOSLAPS -version' with your desired version returns this version (or a later one).
    # Use this preferably with a fixed download URL to avoid new installs with a later version than desired.

pkgName=$(basename "$downloadURL")
pkgPath="/var/tmp/$pkgName"
    # Variables for macOSLAPS install. You can change pkgPath if you really, REALLY want/need to.

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------ ###
### | Settings: local settings and log | ###
### ------------------------------------ ###
### Failsafe settings, the LaunchDaemon interval and the log file.          ###
createFailsafeSettings=false
    # Create local "failsafe" default settings if no existing settings found? (Default: false)
    # Recommended to keep 'false' when deploying settings via MDM to avoid conflicts.

launchDaemonInterval=90
    # Launch daemon interval in minutes, i.e. how often macOSLAPS checks if the password should be rotated. (Default: 90)

logFile="/private/var/log/macOSLAPS-install-script.log"
    # Define location for installation log file. (Default: "/private/var/log/macOSLAPS-install-script.log")

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------- ###
### | Settings: uninstall | ###
### ----------------------- ###
### What uninstall=true removes besides macOSLAPS itself.                   ###
uninstall=false
    # Uninstall mode (Default: false)
    # Can also be defined via script argument: ./macOSLAPS-install.sh uninstall=true

uninstallRemoveAdminAccount=true
    # If uninstalling, remove the managed admin account as well? (Default: true)
    # When the account is kept, macOSLAPS keeps its stored password too, so a reinstall picks up where it left off.

uninstallForceRemoveAdminAccount=true
    # ...Even if said account was currently logged in, still kick out and remove? (Default: true)

uninstallPromoteLoggedUserAdmin=true
    # Promote logged in user as admin when uninstalling and removing managed admin account? (Default: true)
    # WARNING!
    # By default the currently logged in user will be promoted to admin when the managed admin is removed, UNLESS
    # uninstallPromoteLoggedUserAdmin is set to 'false'. In such case, MAKE SURE you don't end up with no admin users
    # left on the machine. If you don't have a management tool in place to create one, you may need to WIPE the device.

uninstallRemoveLocalConfig=true
    # Remove local config files (/Library/Preferences/com.joshua-d-miller.macoslaps.plist and the legacy
    # edu.psu.macoslaps.plist) during uninstall? (Default: true)

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | End of settings | ###
### ------------------- ###
### Nothing below this point needs changing.                                ###

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------- ###
### | Only one run at a time | ###
### -------------------------- ###
### Must run as root. A marker file keeps a second copy from running, and   ###
### caffeinate keeps the Mac awake until the script exits.                  ###
if [[ ! $(id -u) = "0" ]]; then echo "Script must be run with root privileges."; exit 1; fi

if [[ -e /var/tmp/.lapsInstallRunning ]]; then
    echo "Another instance of the script already running, waiting 10 seconds, then exiting..."
    sleep 10
    exit 1
fi

processPID=$$
echo "$processPID" > /var/tmp/.lapsInstallRunning
chmod 644 /var/tmp/.lapsInstallRunning

caffeinate -dimsu -w $processPID &
caffPID=$!

# Internal variable
install=true

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Where macOSLAPS is | ###
### ---------------------- ###
### 4.0 installs the app in /Applications; 3.x and 4.0.0 (845) used         ###
### /usr/local/laps, which 4.x keeps as a legacy link. findLAPS sets LAPS   ###
### to whichever exists, and the LaunchDaemon label and plist the same way. ###
LAPS_APP=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
LAPS_LEGACY=/usr/local/laps/macOSLAPS
findLAPS () {
    if [ -x "$LAPS_APP" ]; then LAPS="$LAPS_APP"
    elif [ -x "$LAPS_LEGACY" ]; then LAPS="$LAPS_LEGACY"
    else LAPS=""
    fi
    if [ -f /Library/LaunchDaemons/com.joshua-d-miller.macoslaps-check.plist ]; then
        daemonLabel=com.joshua-d-miller.macoslaps-check
    else
        daemonLabel=edu.psu.macoslaps-check
    fi
    daemonPlist="/Library/LaunchDaemons/$daemonLabel.plist"
}
findLAPS

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------- ###
### | Logging and cleanup | ###
### ----------------------- ###
### echoOut writes to the screen and the log. selfCleanup runs on every     ###
### exit: it removes the downloaded package and anything an older macOSLAPS ###
### left behind.                                                            ###
echoOut () {
    echo "$(date +"%Y-%m-%d %H:%M:%S"): macOSLAPS install script: $*" | tee -a "$logFile"
}

rmrf () {
    if [ -e "$1" ] || [ -L "$1" ]; then rm -rfv "$1" >> "$logFile"; fi
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------ ###
### | Admin accounts | ###
### ------------------ ###
### Checking, granting and removing admin rights, and whether the managed   ###
### admin exists.                                                           ###
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

promoteLoggedInUser () {
    ## Make the logged-in user an admin before the managed admin goes away ##
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
}

deleteManagedAdmin () {
    sysadminctl -deleteUser "$managedAdminAccount" | tee -a "$logFile"
    sleep 1
    if checkAdminExists; then
        echoOut "Error! Deleting existing account failed."
        exit 1
    else
        echoOut "Account successfully deleted."
    fi
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------- ###
### | Version check | ###
### ----------------- ###
### Compares the installed macOSLAPS with latestVersion. Returns 0 when no  ###
### update is needed.                                                       ###
checkVersion () {
    if [ -n "$LAPS" ]; then
        currentVersion=$("$LAPS" -version 2>/dev/null)
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | macOSLAPS settings | ###
### ---------------------- ###
### Waits for the settings profile (or creates failsafe local settings when ###
### allowed) and reads the managed admin's name. The 4.0 domain             ###
### com.joshua-d-miller.macoslaps comes first, then the legacy              ###
### edu.psu.macoslaps one.                                                  ###
settingsFiles=(
    "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist"
    "/Library/Managed Preferences/edu.psu.macoslaps.plist"
    "/Library/Preferences/com.joshua-d-miller.macoslaps.plist"
    "/Library/Preferences/edu.psu.macoslaps.plist"
)

createFailsafeSettings () {
    if [ $createFailsafeSettings = true ]; then
        managedAdminAccount="$managedAdminAccountName"
        preferenceFile="/Library/Preferences/com.joshua-d-miller.macoslaps.plist"
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

anySettings () {
    local file
    for file in "${settingsFiles[@]}"; do
        [ -f "$file" ] && return 0
    done
    return 1
}

readCurrentSettings () {
    if [ $uninstall = true ]; then
        # Uninstall mode - assume settings should be present and if not, wait for up to 1 minute
        runCountMax=12
        echoOut "readCurrentSettings: Uninstall mode - Looking for macOSLAPS settings (up to 1 minute) before continuing..."
    else
        # Install mode - wait for up to 10 minutes until (possibly) falling back to failsafe settings
        runCountMax=120
        echoOut "readCurrentSettings: Install mode - Looking for macOSLAPS settings (up to 10 minutes) before continuing..."
    fi
    runCount=1
    echoOut "readCurrentSettings: Checking macOSLAPS settings (round # $runCount) in /Library/Managed Preferences and /Library/Preferences..."
    until anySettings; do
        sleep 5
        runCount=$((runCount+1))
        if [ $runCount -gt $runCountMax ]; then
            break
        fi
        echoOut "Checking macOSLAPS settings (round # $runCount) in /Library/Managed Preferences and /Library/Preferences..."
    done

    # The first settings file that names the account wins (managed before local, new domain before legacy)
    local file
    for file in "${settingsFiles[@]}"; do
        [ -f "$file" ] || continue
        managedAdminAccount=$(defaults read "$file" LocalAdminAccount 2>/dev/null)
        if [[ -n "$managedAdminAccount" ]]; then
            preferenceFile="$file"
            echoOut "Reading macOSLAPS settings from $file..."
            break
        fi
    done
    if [[ -z "$managedAdminAccount" ]]; then
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------------- ###
### | Does macOSLAPS have a working password? | ###
### ------------------------------------------- ###
### macOSLAPS 4.0 checks its stored password against the account with       ###
### -status (passwordVerifies), so the password never leaves macOSLAPS. 3.1 ###
### - 4.0.0 (845) check it with -getPassword, which also leaves a temporary ###
### keychain copy that is removed again right away.                         ###
lapsPasswordWorks () {
    [ -n "$LAPS" ] || return 1
    if "$LAPS" -help 2>/dev/null | grep -q -- "-status"; then
        "$LAPS" -status 2>>"$logFile" | grep -q '"passwordVerifies":true'
        return
    fi
    "$LAPS" -getPassword >> "$logFile" 2>&1 || return 1
    local service
    service=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName 2>/dev/null)
    [ -n "$service" ] && security delete-generic-password -s "$service" /Library/Keychains/System.keychain >/dev/null 2>&1
    rm -f /var/root/.GeneratedLAPSServiceName
    return 0
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Start | ###
### --------- ###
### Log folder, script arguments (name=value pairs override the settings    ###
### above), and wait until Setup Assistant is done and a user is logged in. ###
logFolder=$(dirname "$logFile")
if [ ! -d "$logFolder" ]; then
    if ! mkdir -p "$logFolder"; then
        echo "ERROR! Could not create log folder: ${logFolder}"
        exit 1
    fi
fi

echoOut " "
echoOut "############# SCRIPT START (version $scriptVersion, PID $processPID ) #############"

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

echoOut "Setup Assistant has finished and a user is logged in, continuing..."

readCurrentSettings

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------ ###
### | Download | ###
### ------------ ###
### Unless uninstalling or the required version is already installed.       ###
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------- ###
### | Uninstall | ###
### ------------- ###
### Removes the managed admin when requested, then macOSLAPS itself:        ###
### macOSLAPS -uninstall for 4.0 (with -purge when the account is gone, so  ###
### no stored password is left), and the files, LaunchDaemon and receipts   ###
### of older releases.                                                      ###
if [ $uninstall = true ]; then
    echoOut "Uninstall mode requested. Performing uninstall..."

    # Stop the LaunchDaemon (4.0 and older labels)
    for label in com.joshua-d-miller.macoslaps-check edu.psu.macoslaps-check; do
        launchctl bootout "system/$label" 2>/dev/null && echoOut "Stopped $label"
    done

    # Delete managed admin account if requested
    if [ $uninstallRemoveAdminAccount = true ]; then
        if checkAdminExists; then
            echoOut "Removal of admin account requested in config, trying to remove..."
            loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
            if [[ ! "$loggedInUser" == "$managedAdminAccount" ]]; then
                if [ $uninstallPromoteLoggedUserAdmin = true ]; then
                    promoteLoggedInUser
                else
                    echoOut "Not allowed to promote logged in user as admin, leaving as-is..."
                fi
                deleteManagedAdmin
            else
                if [ $uninstallForceRemoveAdminAccount = true ]; then
                    echoOut "$managedAdminAccount currently logged in, kicking out..."
                    # shellcheck disable=SC2086
                    lwPID=$(pgrep -u "$(id -u $managedAdminAccount)" loginwindow | head -n1)
                    kill -9 "$lwPID"
                    sleep 5
                    if [ $uninstallPromoteLoggedUserAdmin = true ]; then
                        promoteLoggedInUser
                    else
                        echoOut "Not allowed to promote logged in user as admin, leaving as-is..."
                    fi
                    deleteManagedAdmin
                else
                    echoOut "Error! $managedAdminAccount currently logged in, cannot delete!"
                    exit 1
                fi
            fi
        fi
    else
        echoOut "Leaving managed admin account as is (removal not requested)."
    fi

    # macOSLAPS 4.0: its own uninstaller. The stored password goes too when the account is gone.
    if [ -x /Applications/macOSLAPS.app/Contents/Resources/uninstall.sh ]; then
        if [ $uninstallRemoveAdminAccount = true ]; then
            /bin/bash /Applications/macOSLAPS.app/Contents/Resources/uninstall.sh --purge >> "$logFile" 2>&1
        else
            /bin/bash /Applications/macOSLAPS.app/Contents/Resources/uninstall.sh >> "$logFile" 2>&1
        fi
        echoOut "macOSLAPS 4.0 uninstaller finished (exit $?)."
    fi

    # Older releases, and anything left over
    for i in "/usr/local/laps/macOSLAPS" "/usr/local/laps/macOSLAPS-repair" "/private/etc/paths.d/laps" "/var/root/Library/Application Support/macOSLAPS-password" "/var/root/Library/Application Support/macOSLAPS-expiration" "/Library/LaunchDaemons/edu.psu.macoslaps-check.plist" "/Library/LaunchDaemons/com.joshua-d-miller.macoslaps-check.plist" "/var/root/.GeneratedLAPSServiceName"; do
        rmrf "$i"
    done
    rmdir /usr/local/laps 2>/dev/null

    # Forget packages
    for receipt in $(pkgutil --pkgs | grep -E '^(edu\.psu\.macOSLAPS|com\.joshua-d-miller\.macoslaps)'); do
        pkgutil --forget "$receipt"
    done

    if [ $uninstallRemoveLocalConfig = true ]; then
        echoOut "Removal of local config requested, removing..."
        for file in /Library/Preferences/com.joshua-d-miller.macoslaps.plist /Library/Preferences/edu.psu.macoslaps.plist; do
            if [ -e "$file" ]; then rm "$file"; echoOut "Removed $file"; fi
        done
    fi

    echoOut "Uninstall finished."
    exit 0
fi

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------- ###
### | Verify the existing admin account | ###
### ------------------------------------- ###
### Decides three things: does the existing account need to be deleted,     ###
### does a new account need to be created, and does the password need to be ###
### rotated.                                                                ###
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
        if [ -n "$LAPS" ]; then
            # macOSLAPS found, we will test the password so we won't be updating blind
            echoOut "macOSLAPS found, checking its password for $managedAdminAccount..."
            if lapsPasswordWorks; then
                echoOut "macOSLAPS has a working password for $managedAdminAccount - will keep existing account as is."
                deleteExistingAdmin=false
                createAdminAccount=false
                rotatePassword=false
            else
                echoOut "Error! macOSLAPS has no working password (wrong password or application error)."
                echoOut "Trying to reset the password..."
                set -o pipefail
                if "$LAPS" -resetPassword 2>&1 | tee -a "$logFile" && lapsPasswordWorks; then
                    echoOut "Password rotated and tested successfully."
                else
                    echoOut "Rotation or test failed."
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
                set +o pipefail
            fi
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------------------------- ###
### | Delete the existing account if needed | ###
### ----------------------------------------- ###
### The logged-in user is made an admin first, so the Mac is never left     ###
### without one.                                                            ###
if [ $deleteExistingAdmin = true ]; then
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

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------- ###
### | Create the account if needed | ###
### -------------------------------- ###
### Then make sure it has a home folder, admin rights and the requested     ###
### visibility.                                                             ###
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

if [ $managedAdminAccountHidden = true ]; then
    echoOut "Hidden account requested in config, hiding..."
    dscl . create "/Users/$managedAdminAccount" IsHidden 1
    chflags hidden "/Users/$managedAdminAccount"
else
    echoOut "Visible account requested in config, making sure it's visible..."
    dscl . create "/Users/$managedAdminAccount" IsHidden 0
    chflags nohidden "/Users/$managedAdminAccount"
fi

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------- ###
### | Install macOSLAPS | ###
### --------------------- ###
### Then look up where it was installed (the app in 4.0) and which          ###
### LaunchDaemon it uses.                                                   ###
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
findLAPS
if [ -z "$LAPS" ]; then
    echoOut "Error! macOSLAPS is not installed. Cleaning up and exiting."
    exit 1
fi

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------- ###
### | Rotate the password | ###
### ----------------------- ###
### macOSLAPS takes over the account with -firstPass, then the new password ###
### is checked against the account.                                         ###
if [ $rotatePassword = true ]; then
    echoOut "Rotating the password..."
    set -o pipefail
    # Piped in (-firstPass -) so the password never shows in the process list.
    if printf '%s\n' "$managedAdminAccountPassword" | "$LAPS" -firstPass - 2>&1 | tee -a "$logFile"; then
        echoOut "Password rotated successfully."
    else
        echoOut "Error! Password was not rotated successfully, check logs for troubleshooting. Cleaning up and exiting."
        exit 1
    fi
    set +o pipefail
    echoOut "Testing the rotated password against the local directory..."
    if ! lapsPasswordWorks; then
        echoOut "Password was rotated, yet admin authentication failed. Cleaning up and exiting."
        exit 1
    fi
fi

echoOut "macOSLAPS installed and tested successfully."

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------- ###
### | LaunchDaemon interval | ###
### ------------------------- ###
### Sets StartInterval and reloads the LaunchDaemon so the new interval     ###
### takes effect.                                                           ###
intervalInSeconds=$((launchDaemonInterval * 60))
if [ ! -f "$daemonPlist" ]; then
    echoOut "Error! Could not find macOSLAPS launch daemon!"
    exit 1
fi
if [[ $(defaults read "$daemonPlist" StartInterval 2>/dev/null) -ne "$intervalInSeconds" ]]; then
    echoOut "Adjusting launch daemon run interval to $launchDaemonInterval minutes ($intervalInSeconds seconds)..."
    plutil -replace StartInterval -integer "$intervalInSeconds" "$daemonPlist"
    chown root:wheel "$daemonPlist"
    chmod 644 "$daemonPlist"
    echoOut "Interval adjusted, reloading $daemonLabel..."
    launchctl bootout "system/$daemonLabel" 2>/dev/null
    launchctl bootstrap system "$daemonPlist" 2>&1 | tee -a "$logFile"
else
    echoOut "Launch daemon interval already set at requested interval, not changing."
fi

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------------ ###
### | Convert the logged-in user to standard | ###
### ------------------------------------------ ###
### Only when convertLoggedInUserToStandard is true.                        ###
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
