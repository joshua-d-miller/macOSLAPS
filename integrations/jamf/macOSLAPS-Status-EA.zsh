#!/bin/zsh
# Jamf Pro extension attribute: macOSLAPS health (macOSLAPS 4.0+)
# Data type: String. One line of JSON; build smart groups on e.g. "passwordVerifies":false
LAPS=/usr/local/laps/macOSLAPS
[[ -x "$LAPS" ]] || { echo "<result>Not installed</result>"; exit 0; }
echo "<result>$("$LAPS" -status 2>/dev/null)</result>"
