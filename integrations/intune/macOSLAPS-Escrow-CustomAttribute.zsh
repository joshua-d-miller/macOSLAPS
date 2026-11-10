#!/bin/zsh
# Intune custom attribute (macOS): macOSLAPS escrow (macOSLAPS 4.0+)
# Data type: String. Intune stores whatever this prints.
LAPS=/usr/local/laps/macOSLAPS
[[ -x "$LAPS" ]] || { echo "Not installed"; exit 0; }
"$LAPS" -escrow 2>/dev/null
