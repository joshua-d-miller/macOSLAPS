macOS LAPS (Local Administrator Password Solution)
==================================================
Swift binary that utilizes Open Directory to determine if the
local administrator password has expired as specified by the Active Directory
attribute `dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime`. If this is the case
then a new randomly generated password will be set for the local admin account
and a new expiration date will be set. The LAPS password is stored in the
Active Directory attribute `dsAttrTypeNative:ms-Mcs-AdmPwd`. This attribute can
only be read by those designated to view the attribute. The computer record
can write to this attribute but it cannot read.

Requirements
------------

The following preference keys must be set or the application will use the defaults:

`LocalAdminAccount` - Local Administrator Account. Default is 'admin'. (In String format)  
`DaysTillExpiration` - Expiration date of random password. Default is 60 Days. (In Integer format)  
`PasswordLength` - Length of randomly generated password. Default is 12. (In Integer format)  
`RemoveKeyChain` - Remove the local admin keychains after password change. (In Boolean format, recommended)  
`RemovePassChars` - Exclude any characters you'd like from the randomly generated password (In String format)  
`ExclusionSets` - Exclude any character set you'd like by specificying a string in an array (Example: "symbols")
`PreferredDC` - Set your preferred Domain Controller to connect to [Useful when you have RODCs] (In String format)
`FirstPass` - Use this key if you are LAPS Admin is a FileVault user. The script will read this key in if there isn't a keyhcain entry in **System** keychain for macOSLAPS. Once this has been completed, the keychain entry will then be used.

**NOTE about *FirstPass*:** macOSLAPS must know at least one password via config profile before we can start the keychain process. Settings this key before running it for the first time when it is your temporary admin password is the best method.

These parameters are set in the location `/Library/Preferences/edu.psu.macoslaps.plist`
or you can use your MDM's Custom Settings to set these values.

**NOTE**: The Swift binary will most likely only work on macOS 10.10+. If you need to run LAPS on older versions of macOS please use the legacy version of macOSLAPS written in Python [here](https://github.com/joshua-d-miller/macOSLAPS-Legacy)

Exclusions
----------------
As pointed out by one of my fellow colleagues, the **'** key on macOS cannot be used on Windows without opening
the character map to enter it. Since this is very detriment to using a LAPS password from a Windows client I have made this key excluded by default.

Installation Instructions
-------------------------
At this time you can clone the repo or download a zip of the repo or you can use the package created using Packages to install. The package includes a Launch Daemon to run macOSLAPS every 90 minutes.

Usage
-------
macOSLAPS is designed to run in an automated fashion (e.g. triggered by a Launch Daemon or your management tool of choice). It can be invoked manually at the command line by running `/usr/local/laps/macOSLAPS` as root.

#### Optional Flags

`-resetPassword` - generates a new password and writes it to the Active Directory computer record.  
`-version` - prints out the current verison of macOSLAPS.

Logging
-------
The script will also perform logging so that you know when the password is changed
and its new expiration date or when the current unchanged password will expire. This
file is stored in `/Library/Logs/macOSLAPS.log`

Feedback
--------
Since this is a binary, it can be signed which means that the code itself will not display when viewing the executable. Please test this new version and report back results.

Local Admin Keychain
--------
By default, the local admin you choose has its keychain deleted since we wouldn't know the randomized password.

Credits
--------------
* Rusty Myers - For helping to determine that Windows has its own time method vs
Epoch time
* Matt Hansen - For critiquing and assisting with generating the random password
* Allen Clouser and Jody Harptster - For showing me that the **'** key cannot be used from a Windows client without character map
* John Pater - For advising me on the idea of generating 10 random passwords and picking one randomly to further randomize the password
* Joel Rennich - For taking my questions about Swift and advising me on better ways to utilize Swift. Another special thanks to Joel for advising me on saving the password in the **System** keychain to deal with secureToken.
* Peter Szul - For working with me to determine the initial date set by a newly bound computer is invalid and we need to test writing to the Domain Controller with another value for the first run.
