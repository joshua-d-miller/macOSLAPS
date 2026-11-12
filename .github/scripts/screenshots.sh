#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | screenshots.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     Screenshots of device mode the way a technician uses it, taken on a
     GitHub runner that has a signed-in screen (macOS 26 and 27). It
     installs the pkg, creates the admin ladmin in device mode, gets the
     reveal code the way an MDM would (-escrow), opens macOSLAPS.app as
     the signed-in user, types the code and a ticket number with simulated
     keystrokes and presses Return, then captures each state. It is also a
     UI test: it fails unless macOSLAPS recorded the reveal by that user
     with that ticket.

 Usage:
     sudo bash .github/scripts/screenshots.sh <full pkg> <output folder>
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file.
                        claude
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
### Install, the signed-in user, and helpers.                               ###
set -uo pipefail
PKG="$1"; OUT="$2"
mkdir -p "$OUT"
chmod 777 "$OUT"   # screencapture runs as the signed-in user
installer -pkg "$PKG" -target / >/dev/null || { echo "::error::install failed"; exit 1; }
APP=/Applications/macOSLAPS.app
LAPS="$APP/Contents/MacOS/macOSLAPS"
GUI_USER=$(stat -f %Su /dev/console)
GUI_UID=$(id -u "$GUI_USER")
echo "Signed-in user: $GUI_USER ($GUI_UID); macOS $(sw_vers -productVersion)"
FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
as_gui() { launchctl asuser "$GUI_UID" sudo -u "$GUI_USER" "$@"; }
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

# Window ids and owners (no Screen Recording permission needed for these fields).
cat > /tmp/wininfo.swift <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print("\(id)\t\(layer)\t\(pid)\t\(Int(b["X"] ?? 0))\t\(Int(b["Y"] ?? 0))\t\(Int(b["Width"] ?? 0))\t\(Int(b["Height"] ?? 0))\t\(owner)")
}
SWIFT
swiftc -O /tmp/wininfo.swift -o /tmp/wininfo 2>&1 | tail -3
chmod 755 /tmp/wininfo
# shot <name> [window id]: a window, or the whole screen.
shot() {
    local file="$OUT/$1.png"
    if [ -n "${2:-}" ]; then as_gui screencapture -x -o -l"$2" "$file"; else as_gui screencapture -x "$file"; fi
    [ -s "$file" ] && echo "captured $1" || echo "::warning::no image for $1"
}
# window_of <pid> <layer>: the first on-screen window of that process at that layer.
window_of() { as_gui /tmp/wininfo | awk -F'\t' -v p="$1" -v l="$2" '$3==p && $2==l && $6>20 {print $1; exit}'; }
# AppleScript as the signed-in user; errors go to the log (e.g. no Accessibility access).
ui() { as_gui osascript -e "$1" 2>&1 | sed 's/^/  osascript: /'; }
keys() { ui "tell application \"System Events\" to keystroke \"$1\""; }
key_code() { ui "tell application \"System Events\" to key code $1"; }
# SwiftUI nests controls in groups, so search the whole window by role.
ax_find() {  # $1 pid, $2 role, $3 index or name, $4 action (focus/press)
    ui "tell application \"System Events\" to tell (first process whose unix id is $1)
        set hits to {}
        set everything to (get entire contents of window 1)
        repeat with e in everything
            if role of e is \"$2\" then set end of hits to e
        end repeat
        if \"$3\" is in \"0123456789\" then
            set t to item ($3 as integer) of hits
        else
            set t to missing value
            repeat with e in hits
                set label to \"\"
                try
                    set label to (value of attribute \"AXTitle\" of e as text)
                end try
                try
                    set label to label & \" \" & (value of attribute \"AXDescription\" of e as text)
                end try
                try
                    set label to label & \" \" & (value of attribute \"AXIdentifier\" of e as text)
                end try
                if label contains \"$3\" then set t to e
            end repeat
        end if
        if \"$4\" is \"focus\" then
            set focused of t to true
        else
            perform action \"AXPress\" of t
        end if
    end tell"
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------- ###
### | A device-mode Mac | ###
### --------------------- ###
### The admin ladmin, a readable password, device mode, and the runner's    ###
### admins approved.                                                        ###
ACCT=ladmin
FIRST='Initial-Pass-1234'
sysadminctl -addUser "$ACCT" -fullName "Local Admin" -password "$FIRST" -admin >/dev/null 2>&1
DOM=/Library/Preferences/com.joshua-d-miller.macoslaps
defaults write "$DOM" LocalAdminAccount -string "$ACCT"
defaults write "$DOM" Method -string Local
defaults write "$DOM" FirstPass -string "$FIRST"
defaults write "$DOM" DaysTillExpiration -int 30
defaults write "$DOM" PasswordStyle -string readable
defaults write "$DOM" PasswordLength -int 16
defaults write "$DOM" RetrievalMode -string device
defaults write "$DOM" RevealGracePeriod -int 4
APPROVED=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | cut -d: -f2-)
defaults write "$DOM" ApprovedAdmins -array $APPROVED
"$LAPS" -firstPass "$FIRST" -resetPassword >/dev/null 2>&1 || fail "first rotation"
CODE=$(jget "$("$LAPS" -escrow 2>/dev/null)" revealCode)
[[ "$CODE" =~ ^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$ ]] && pass "reveal code from -escrow" || { fail "no reveal code"; exit 1; }

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------- ###
### | The app: enter the code | ###
### --------------------------- ###
### Opened as the signed-in user, the code typed with keystrokes.           ###
as_gui open "$APP"
sleep 6
APP_PID=$(pgrep -u "$GUI_UID" -f "^$APP/Contents/MacOS/macOSLAPS$" | head -1)
[ -n "$APP_PID" ] && pass "the app opened as $GUI_USER" || fail "the app did not open"
WIN=$(window_of "$APP_PID" 0)
[ -n "$WIN" ] && pass "the app window is on screen" || fail "no app window"
shot 01-window-empty "$WIN"
PROC="(first process whose unix id is $APP_PID)"
ui "tell application \"System Events\" to set frontmost of $PROC to true"
echo "Frontmost: $(as_gui osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)"
echo "Window elements: $(as_gui osascript -e "tell application \"System Events\" to get {role, description} of every UI element of window 1 of $PROC" 2>&1)"
echo "Window controls: $(as_gui osascript -e "tell application \"System Events\" to tell $PROC
    set out to {}
    repeat with e in (get entire contents of window 1)
        set label to \"\"
        try
            set label to (value of attribute \"AXTitle\" of e as text)
        end try
        set end of out to (role of e as text) & \":\" & label
    end repeat
    return out
end tell" 2>&1)"
ax_find "$APP_PID" AXTextField 1 focus; sleep 0.5
keys "$CODE"; sleep 0.5
ax_find "$APP_PID" AXTextField 2 focus; sleep 0.5
keys "TICKET-4021"; sleep 1
shot 02-window-code-entered "$WIN"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | The app: reveal | ###
### ------------------- ###
### Return presses Reveal Password; macOSLAPS must record the reveal.       ###
ax_find "$APP_PID" AXButton 1 press; sleep 6   # Reveal Password
shot 03-window-revealed "$WIN"
python3 -c 'import plistlib,sys; h=plistlib.load(open("/var/db/macoslaps/state.plist","rb")).get("revealHistory",[]); assert any(sys.argv[1] in x and "TICKET-4021" in x for x in h), h' "$GUI_USER" \
    && pass "revealed through the window by $GUI_USER with the ticket" || fail "the window did not reveal the password (revealHistory: $(plutil -extract revealHistory json -o - /var/db/macoslaps/state.plist 2>&1))"
WIN_TEXT=$(as_gui osascript -e "tell application \"System Events\" to tell $PROC
    set out to \"\"
    repeat with e in (get entire contents of window 1)
        try
            set out to out & (value of e as text) & linefeed
        end try
    end repeat
    return out
end tell" 2>&1)
echo "$WIN_TEXT" | grep -q "logged out" \
    && fail "the window warns of a logout though ladmin isn't logged in" \
    || pass "the window doesn't warn of a logout (ladmin isn't logged in)"
echo "$WIN_TEXT" | grep -q "works until" \
    && pass "the window shows when the password stops working" \
    || fail "the window text: $WIN_TEXT"
ST=$("$LAPS" -status)
[ -n "$(jget "$ST" rotatesAt)" ] && pass "the grace period started" || fail "no deadline after the reveal"
ax_find "$APP_PID" AXButton 2 press   # Copy, Show Phonetic, Done
sleep 2
shot 04-window-phonetic "$WIN"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------ ###
### | Menu bar and notifications | ###
### ------------------------------ ###
### The agent's countdown, its menu, and whatever notification shows.       ###
sleep 4
AGENT_PID=$(pgrep -u "$GUI_UID" -f "macOSLAPS -agent" | head -1)
[ -n "$AGENT_PID" ] && pass "the menu bar agent is running" || fail "the menu bar agent is not running"
ITEM=$(as_gui /tmp/wininfo | awk -F'\t' -v p="$AGENT_PID" '$3==p && $2>0 {print $1; exit}')
[ -n "$ITEM" ] && shot 05-menubar-item "$ITEM" || echo "::warning::no menu bar item window"
[ -n "$AGENT_PID" ] && ui "tell application \"System Events\" to click menu bar item 1 of menu bar 2 of (first process whose unix id is $AGENT_PID)"
sleep 2
MENU=$(as_gui /tmp/wininfo | awk -F'\t' -v p="$AGENT_PID" '$3==p && $2>=101 {print $1; exit}')
[ -n "$MENU" ] && shot 06-menubar-menu "$MENU" || echo "::warning::no menu window"
shot 07-screen-with-menu
key_code 53; sleep 1        # Escape closes the menu
shot 08-screen

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------------- ###
### | The icon and escrow mode | ###
### ---------------------------- ###
### The app in Finder, then the window in escrow mode.                      ###
as_gui osascript -e 'tell application "Finder" to quit' >/dev/null 2>&1; sleep 2
as_gui open -R "$APP"; sleep 4
FINDER_PID=$(pgrep -u "$GUI_UID" -x Finder | head -1)
FWIN=$(window_of "$FINDER_PID" 0)
[ -n "$FWIN" ] && shot 09-finder-icon "$FWIN"
kill "$APP_PID" 2>/dev/null; sleep 2
"$LAPS" -expireIn 0 >/dev/null 2>&1; "$LAPS" >/dev/null 2>&1
defaults write "$DOM" RetrievalMode -string escrow
as_gui open "$APP"; sleep 6
APP_PID=$(pgrep -u "$GUI_UID" -f "^$APP/Contents/MacOS/macOSLAPS$" | head -1)
WIN=$(window_of "$APP_PID" 0)
[ -n "$WIN" ] && shot 10-window-escrow-mode "$WIN"
kill "$APP_PID" 2>/dev/null

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------ ###
### | Terminal | ###
### ------------ ###
### -reveal from a pipe, as text.                                           ###
defaults write "$DOM" RetrievalMode -string device
"$LAPS" >/dev/null 2>&1
CODE=$(jget "$("$LAPS" -escrow 2>/dev/null)" revealCode)
{ echo "$ printf '%s\n' \"\$code\" | macOSLAPS -reveal -reason TICKET-4022"
  printf '%s\n' "$CODE" | as_gui "$LAPS" -reveal -reason TICKET-4022 2>&1; } > "$OUT/11-terminal-reveal.txt"
grep -q "^Password: " "$OUT/11-terminal-reveal.txt" && pass "-reveal from a pipe as $GUI_USER" || fail "-reveal from a pipe: $(cat "$OUT/11-terminal-reveal.txt")"
grep -q "logged out" "$OUT/11-terminal-reveal.txt" \
    && fail "-reveal warns of a logout though ladmin isn't logged in" \
    || pass "-reveal doesn't warn of a logout (ladmin isn't logged in)"
as_gui /tmp/wininfo > "$OUT/windows.txt"
ls -l "$OUT"
# The images, also in the log (base64, between markers), for readers that can't
# download artifacts.
for f in "$OUT"/*.png; do
    [ -s "$f" ] || continue
    small="/tmp/$(basename "$f")"
    sips -Z 1400 "$f" --out "$small" >/dev/null 2>&1 || cp "$f" "$small"
    echo "::group::image $(basename "$f")"
    echo "BEGIN-IMAGE $(basename "$f")"; base64 -i "$small" | fold -w 4000; echo "END-IMAGE $(basename "$f")"
    echo "::endgroup::"
done
echo "----"
[ "$FAILURES" -eq 0 ] || { echo "::error::$FAILURES check(s) failed"; exit 1; }
echo "All screenshot checks passed."
