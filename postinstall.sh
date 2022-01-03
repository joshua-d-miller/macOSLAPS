#!/bin/zsh

# macOSLAPS postinstall script

# Path to the LaunchDaemon
ld="/Library/LaunchDaemons/edu.psu.macoslaps-check.plist"

# Tell launchd to load the file. We can assume the file is present because the package attempts to place one.
/bin/launchctl load -w "$ld"

exit
