#!/bin/zsh
# Workspace ONE sensor (macOS, run as root, response type String): macOSLAPS health JSON (macOSLAPS 4.0+)
LAPS=/usr/local/laps/macOSLAPS
[[ -x "$LAPS" ]] || { echo "Not installed"; exit 0; }
"$LAPS" -status 2>/dev/null
