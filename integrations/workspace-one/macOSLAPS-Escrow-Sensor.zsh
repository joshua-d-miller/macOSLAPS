#!/bin/zsh
: <<'HEADER'
===============================================================================
 macOSLAPS | Integrations | workspace-one/macOSLAPS-Escrow-Sensor.zsh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Updated:   2026-11-11

 Purpose:
     Workspace ONE sensor for macOS (run as root, String) with the local
     admin's password from macOSLAPS 4.0 -escrow: JSON with the current
     password (and a staged pending one), or a CMS block when
     EscrowCertificates is set. Keep every value Workspace ONE stores:
     during staged rotation the Mac switches to the pending password only
     after it has been collected. See integrations/README.md.
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
### Prints the -escrow output. Log messages go to stderr, so only the       ###
### result is captured.                                                     ###
if [[ ! -x "$LAPS" ]]
then
    /bin/echo "Not Installed"
    exit 0
fi
"$LAPS" -escrow 2>/dev/null
exit 0
