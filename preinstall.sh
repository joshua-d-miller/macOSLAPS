#!/bin/zsh

# macOSLAPS preinstall script

# Path to the LaunchDaemon
ld="/Library/LaunchDaemons/edu.psu.macoslaps-check.plist"

# If the LD exists
if [ -f "$ld" ];
then
  # Stop the LaunchDaemon running
	/bin/launchctl unload -w "$ld"

  # Remove the existing file.
  /bin/rm -f "$ld"
  
  # Let LaunchD sort itself out.
	sleep 1
fi

exit
