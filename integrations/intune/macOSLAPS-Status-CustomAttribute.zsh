#!/bin/zsh
# Intune custom attribute (macOS): macOSLAPS health JSON (macOSLAPS 4.0+)
LAPS=/usr/local/laps/macOSLAPS
[[ -x "$LAPS" ]] || { echo "Not installed"; exit 0; }
"$LAPS" -status 2>/dev/null
