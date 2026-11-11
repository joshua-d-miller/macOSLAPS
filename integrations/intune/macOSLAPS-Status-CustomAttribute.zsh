#!/bin/zsh
: <<'HEADER'
===============================================================================
 macOSLAPS | Integrations | intune/macOSLAPS-Status-CustomAttribute.zsh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Updated:   2026-11-11

 Purpose:
     Intune custom attribute for macOS (String) with one line of macOSLAPS
     4.0 -status JSON: the account, secureToken, FileVault, whether the
     stored password works, escrow, staging and migration. Build smart or
     dynamic groups on fields such as "passwordVerifies":false or
     "migration":"required".
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file for macOSLAPS 4.0.
                        claude
                                  Finds the app in /Applications, falling back
                                  to /usr/local/laps; new header and section
                                  style.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Where macOSLAPS is | ###
### ---------------------- ###
### The app in /Applications, or the legacy /usr/local/laps path (removed   ###
### in macOSLAPS 5.0).                                                      ###
LAPS=/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS
[[ -x "$LAPS" ]] || LAPS=/usr/local/laps/macOSLAPS

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------- ###
### | Main | ###
### -------- ###
### Prints the -status output. Log messages go to stderr, so only the       ###
### result is captured.                                                     ###
if [[ ! -x "$LAPS" ]]
then
    /bin/echo "Not Installed"
    exit 0
fi
"$LAPS" -status 2>/dev/null
exit 0
