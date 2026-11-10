#!/bin/zsh
# Jamf Pro extension attribute: macOSLAPS escrow (macOSLAPS 4.0+)
# Data type: String. Shows JSON (plaintext) or a CMS block (EscrowCertificates set).
LAPS=/usr/local/laps/macOSLAPS
[[ -x "$LAPS" ]] || { echo "<result>Not installed</result>"; exit 0; }
echo "<result>$("$LAPS" -escrow 2>/dev/null)</result>"
