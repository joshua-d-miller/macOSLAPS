macOS LAPS (Local Administrator Password Solution)
==================================================
Swift binary that utilizes Open Directory to determine if the
local administrator password has expired as specified by the Active Directory
attribute dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime. If this is the case
then a new randomly generated password will be set for the local admin account
and a new expiration date will be set. The LAPS password is stored in the
Active Directory attribute dsAttrTypeNative:ms-Mcs-AdmPwd. This attribute can
only be read by those designated to view the attribute. The computer record
can write to this attribute but it cannot read.

Requirements
------------

The following parameters must be set or the application will use the defaults:

**LocalAdminAccount** - Local Administrator Account. Default is 'admin'. (In String format)  
**DaysTillExpiration** - Expiration date of random password. Default is 60 Days. (In Integer format)  
**PasswordLength** - Length of randomly generated password. Default is 12. (In Integer format) . 
**RemoveKeyChain** - Remove the local admin keychains after password change. (In Boolean format, recommended)  
**RemovePassChars** - Exclude any characters you'd like from the randomly generated password (In String format)  
**ExclusionSets** - Exclude any character set you'd like by specificying a string in an array (Example: "symbols")  

These parameters are set in the location /Libary/Preferences/edu.psu.macoslaps.plist
or you can use your MDM's Custom Settings to set these values.

**NOTE**: The Swift binary will most likely only work on macOS 10.10+. If you need to run LAPS on older versions of macOS please use the legacy version of macOSLAPS written in Python [here](https://github.com/joshua-d-miller/macOSLAPS-Legacy)

Exclusions
----------------
As pointed out by one of my fellow colleagues, the **'** key on macOS cannot be used on Windows without opening
the character map to enter it. Since this is very detriment to using a LAPS password from a Windows client I have made this key excluded by default.

Installation Instructions
-------------------------
At this time you can clone the repo or download a zip of the repo or you can
use the package created using Packages to install. This script will run
3 times a day between 8 A.M. and 5 P.M. at 9 A.M., 1 P.M. and 4 P.M.

Logging
-------
The script will also perform logging so that you know when the password is changed
and its new expiration date or when the current unchanged password will expire. This
file is stored in /Library/Logs/ as macOSLAPS.log

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
* Joel Rennich - For taking my questions about Swift and advising me on better ways to utilize Swift
