#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | screenshots.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-22

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
 4.0.0     2026-11-22   joshua    Waits for each step instead of fixed
                        claude    sleeps: the app, its window, the reveal,
                                  the agent and its menu. Typed fields are
                                  read back (and retyped) before Reveal is
                                  pressed, and Reveal is pressed again once
                                  if nothing was recorded.
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
# wait_for <seconds> <command...>: polls every half second until it succeeds.
wait_for() {
    local limit=$(( $1 * 2 )) i=0; shift
    until "$@" >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -ge "$limit" ] && return 1
        sleep 0.5
    done
}
app_pid() { pgrep -u "$GUI_UID" -f "^$APP/Contents/MacOS/macOSLAPS$" | head -1; }
has_app() { [ -n "$(app_pid)" ]; }
has_window() { [ -n "$(window_of "$(app_pid)" 0)" ]; }
# The text of the nth text field in the app's window.
field_value() {
    as_gui osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
        set hits to {}
        repeat with e in (get entire contents of window 1)
            if role of e is \"AXTextField\" then set end of hits to e
        end repeat
        return value of item $2 of hits
    end tell" 2>/dev/null
}
# enter <pid> <field index> <text>: focus, replace the contents, read back;
# up to three tries, so a keystroke lost to focus never reaches Reveal.
enter() {
    local try
    for try in 1 2 3; do
        ax_find "$1" AXTextField "$2" focus; sleep 0.3
        ui "tell application \"System Events\" to keystroke \"a\" using command down"; sleep 0.2
        keys "$3"; sleep 0.3
        [ "$(field_value "$1" "$2")" = "$3" ] && return 0
        echo "  field $2 holds '$(field_value "$1" "$2")' (try $try); typing it again"
    done
    return 1
}
revealed_by() {   # the state file records a reveal by $1 with reason $2
    python3 -c 'import plistlib,sys; h=plistlib.load(open("/var/db/macoslaps/state.plist","rb")).get("revealHistory",[]); sys.exit(0 if any(sys.argv[1] in x and sys.argv[2] in x for x in h) else 1)' "$1" "$2"
}
window_text() {
    as_gui osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
        set out to \"\"
        repeat with e in (get entire contents of window 1)
            try
                set out to out & (value of e as text) & linefeed
            end try
        end repeat
        return out
    end tell" 2>&1
}
shows_deadline() { window_text "$1" | grep -q "works until"; }
has_deadline() { [ -n "$(jget "$("$LAPS" -status)" rotatesAt)" ]; }
agent_pid() { pgrep -u "$GUI_UID" -f "macOSLAPS -agent" | head -1; }
has_agent() { [ -n "$(agent_pid)" ]; }
agent_window() { as_gui /tmp/wininfo | awk -F'\t' -v p="$1" -v l="$2" '$3==p && $2>=l {print $1; exit}'; }
has_agent_window() { [ -n "$(agent_window "$1" "$2")" ]; }

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
wait_for 30 has_app; APP_PID=$(app_pid)
[ -n "$APP_PID" ] && pass "the app opened as $GUI_USER" || fail "the app did not open"
wait_for 30 has_window; WIN=$(window_of "$APP_PID" 0)
[ -n "$WIN" ] && pass "the app window is on screen" || fail "no app window"
sleep 1   # let the first frame settle before the screenshot
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
enter "$APP_PID" 1 "$CODE" && pass "the code is in the code field" || fail "the code field holds '$(field_value "$APP_PID" 1)'"
enter "$APP_PID" 2 "TICKET-4021" && pass "the ticket is in the reason field" || fail "the reason field holds '$(field_value "$APP_PID" 2)'"
sleep 0.5
shot 02-window-code-entered "$WIN"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | The app: reveal | ###
### ------------------- ###
### Return presses Reveal Password; macOSLAPS must record the reveal.       ###
# Reveal Password. A press lost to focus is pressed once more, after checking
# the fields still hold the right code (a wrong code would count against us).
ax_find "$APP_PID" AXButton 1 press
if ! wait_for 20 revealed_by "$GUI_USER" "TICKET-4021"; then
    echo "  no reveal recorded after 20 s; pressing Reveal Password again"
    [ "$(field_value "$APP_PID" 1)" = "$CODE" ] && ax_find "$APP_PID" AXButton 1 press
    wait_for 20 revealed_by "$GUI_USER" "TICKET-4021"
fi
revealed_by "$GUI_USER" "TICKET-4021" \
    && pass "revealed through the window by $GUI_USER with the ticket" || fail "the window did not reveal the password (revealHistory: $(plutil -extract revealHistory json -o - /var/db/macoslaps/state.plist 2>&1))"
wait_for 15 shows_deadline "$APP_PID"
shot 03-window-revealed "$WIN"
WIN_TEXT=$(window_text "$APP_PID")
echo "$WIN_TEXT" | grep -q "logged out" \
    && fail "the window warns of a logout though ladmin isn't logged in" \
    || pass "the window doesn't warn of a logout (ladmin isn't logged in)"
echo "$WIN_TEXT" | grep -q "works until" \
    && pass "the window shows when the password stops working" \
    || fail "the window text: $WIN_TEXT"
wait_for 15 has_deadline && pass "the grace period started" || fail "no deadline after the reveal"
ax_find "$APP_PID" AXButton 2 press   # Copy, Show Phonetic, Done
sleep 2
shot 04-window-phonetic "$WIN"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------ ###
### | Menu bar and notifications | ###
### ------------------------------ ###
### The agent's countdown, its menu, and whatever notification shows.       ###
# The agent starts through the root service after the reveal: wait for it.
wait_for 45 has_agent; AGENT_PID=$(agent_pid)
[ -n "$AGENT_PID" ] && pass "the menu bar agent is running" || fail "the menu bar agent is not running"
[ -n "$AGENT_PID" ] && wait_for 15 has_agent_window "$AGENT_PID" 1
ITEM=$([ -n "$AGENT_PID" ] && agent_window "$AGENT_PID" 1)
[ -n "$ITEM" ] && shot 05-menubar-item "$ITEM" || echo "::warning::no menu bar item window"
MENU=""
for try in 1 2 3; do
    [ -n "$AGENT_PID" ] || break
    ui "tell application \"System Events\" to click menu bar item 1 of menu bar 2 of (first process whose unix id is $AGENT_PID)"
    wait_for 5 has_agent_window "$AGENT_PID" 101 && { MENU=$(agent_window "$AGENT_PID" 101); break; }
done
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
as_gui open "$APP"
wait_for 30 has_app; wait_for 30 has_window; sleep 1
APP_PID=$(app_pid)
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
