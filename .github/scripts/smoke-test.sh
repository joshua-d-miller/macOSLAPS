#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | smoke-test.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-08
 Updated:   2026-11-12

 Purpose:
     macOSLAPS smoke test for GitHub-hosted macOS runners. Exercises the
     installed package end to end on a throwaway admin account: layout,
     rotation, exports, secureToken handling, preferences, -status,
     -escrow (plain and CMS), -initialize, staged rotation, the inventory
     hook, password styles and uninstall. The real secureToken path only
     runs if the runner gives the test account a token; otherwise it needs
     community testing.

 Usage:
     sudo bash .github/scripts/smoke-test.sh
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    Tests for every 4.0 feature: app layout, new
                        claude    label and receipts, Login Items attribution,
                                  migration status, staging, -firstPass never
                                  staging, uninstall.

                                  New header and section style.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
### Paths, the test account and helpers.                                    ###
set -uo pipefail

LAPS=/usr/local/laps/macOSLAPS
APP=/Applications/macOSLAPS.app
# Keychain service of the stored password (4.0 identity; 3.x/845 used "macOSLAPS").
KCSVC=com.joshua-d-miller.macoslaps
LABEL=com.joshua-d-miller.macoslaps-check
PLIST=/Library/LaunchDaemons/$LABEL.plist
ACCT=lapstest
FIRST='Initial-Pass-1234'
LEN=16
EXCLUDED='{}[]|_'
ROUNDS=25
DOMAIN=/Library/Preferences/edu.psu.macoslaps
SYSKC=/Library/Keychains/System.keychain
FAILURES=0

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 2; }

pass() { echo "PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAILURES=$((FAILURES + 1)); }
fatal() { echo "::error::FATAL: $*"; exit 1; }

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------- ###
### | Environment | ###
### --------------- ###
echo "::group::Environment"
sw_vers
uname -m
"$LAPS" -version || fatal "binary does not run"
codesign -dv --verbose=2 "$LAPS" 2>&1 | grep -E "Identifier|Authority|Signature|flags" || true
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------------------------- ###
### | Installed layout matches earlier releases | ###
### --------------------------------------------- ###
echo "::group::Installed layout matches earlier releases"
launchctl print system/$LABEL >/dev/null 2>&1 && pass "LaunchDaemon $LABEL loaded by the installer" || fail "LaunchDaemon not loaded after install"
RECEIPTS=$(pkgutil --pkgs | grep -iE 'laps' | sort | tr '\n' ' ')
[ "$RECEIPTS" = "com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps-check " ] && pass "receipts com.joshua-d-miller.macoslaps and -check" || fail "receipts: $RECEIPTS"
/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST" | grep -qx "$APP/Contents/MacOS/macOSLAPS" && pass "LaunchDaemon runs the app directly" || fail "LaunchDaemon program: $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST")"
[ "$(cat /etc/paths.d/laps 2>/dev/null)" = "$APP/Contents/MacOS" ] && pass "/etc/paths.d/laps points into the app" || fail "/etc/paths.d/laps: $(cat /etc/paths.d/laps 2>/dev/null)"
[ "$(env -i /bin/bash -c 'eval "$(/usr/libexec/path_helper -s)"; command -v macOSLAPS')" = "$APP/Contents/MacOS/macOSLAPS" ] && pass "macOSLAPS on PATH is the app" || fail "macOSLAPS on PATH: $(env -i /bin/bash -c 'eval "$(/usr/libexec/path_helper -s)"; command -v macOSLAPS')"
[ "$(stat -f '%Su:%Sg %Lp' "$PLIST")" = "root:wheel 644" ] && pass "LaunchDaemon owner and mode" || fail "LaunchDaemon owner/mode: $(stat -f '%Su:%Sg %Lp' "$PLIST")"
launchctl print system/com.joshua-d-miller.macoslaps-service >/dev/null 2>&1 && pass "service LaunchDaemon loaded" || fail "service LaunchDaemon not loaded"
REQ="/Library/Application Support/macOSLAPS/Requests"
[ "$(stat -f '%Su:%Sg %Mp%Lp' "$REQ")" = "root:wheel 1733" ] && pass "request folder root:wheel 1733" || fail "request folder: $(stat -f '%Su:%Sg %Mp%Lp' "$REQ" 2>&1)"
[ "$(stat -L -f '%Su:%Sg %Lp' "$LAPS")" = "root:wheel 755" ] && pass "binary owner and mode" || fail "binary owner/mode: $(stat -L -f '%Su:%Sg %Lp' "$LAPS")"
[ -x "$APP/Contents/MacOS/macOSLAPS" ] && [ -x "$APP/Contents/Helpers/macOSLAPS-legacy" ] && pass "app installed in /Applications with its helper" || fail "macOSLAPS.app or its helper missing"
[ "$(readlink "$LAPS")" = "$APP/Contents/MacOS/macOSLAPS" ] && pass "$LAPS is a symlink into the app" || fail "$LAPS -> $(readlink "$LAPS")"
codesign --verify --strict --deep "$APP" && pass "installed app's signature is valid" || fail "installed app's signature is broken"
[ "$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')" = "com.joshua-d-miller.macoslaps" ] && pass "app signed com.joshua-d-miller.macoslaps" || fail "app identifier: $(codesign -dv "$APP" 2>&1 | grep ^Identifier)"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------------------------- ###
### | Background item (Login Items) attribution | ###
### --------------------------------------------- ###
echo "::group::Background item (Login Items) attribution"
# macOS names a background item after the app it belongs to; without one it falls back to
# the signer ("Joshua Miller", issue #75). Show what Background Task Management recorded.
BTM=$(sfltool dumpbtm 2>/dev/null)
ENTRIES=$(awk '/^ +#[0-9]+:$/ { if (block ~ /macoslaps/) print block; block = "" } { block = block "\n" $0 } END { if (block ~ /macoslaps/) print block }' <<< "$BTM")
if [ -z "$BTM" ]; then
    echo "::notice::sfltool dumpbtm printed nothing on this runner"
else
    echo "$ENTRIES"
    # The daemon must be filed under the app (Parent Identifier), so Login Items and the
    # "added items that can run in the background" notice show macOSLAPS, not the signer.
    echo "$ENTRIES" | grep -qE "^ +Parent Identifier: [0-9]+\.com\.joshua-d-miller\.macoslaps$" \
        && pass "LaunchDaemon is attributed to macOSLAPS.app" || fail "LaunchDaemon has no parent app in Background Task Management"
fi
echo "::endgroup::"

# Stop the daemon the pkg loaded so it can't race the test.
launchctl bootout system/$LABEL 2>/dev/null || true

# `macOSLAPS -version` is parsed by MDM scripts: exactly one line, the version, nothing else,
# in every state (as a user, as root, with a legacy-domain config and an export pending).
version_is_clean() {
    local label="$1" out
    out=$("$LAPS" -version 2>/dev/null)
    local re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    [[ "$out" =~ $re ]] && pass "-version prints only the version ($label)" || fail "-version output is not just a version ($label): $(printf '%q' "$out")"
}
version_is_clean "no configuration"
sudo -u nobody "$LAPS" -version >/dev/null 2>&1 && pass "-version works without root" || fail "-version fails without root"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------- ###
### | Create test admin and config | ###
### -------------------------------- ###
echo "::group::Create test admin and config"
sysadminctl -addUser "$ACCT" -fullName "LAPS Test" -password "$FIRST" -admin 2>&1
TOKEN=$(sysadminctl -secureTokenStatus "$ACCT" 2>&1)
echo "$TOKEN"
if echo "$TOKEN" | grep -q ENABLED; then HAS_TOKEN=1; else HAS_TOKEN=0; fi
defaults write "$DOMAIN" LocalAdminAccount -string "$ACCT"
# The runner's own admins (e.g. runner) stay admin: AdminGroupPolicy auto removes the rest.
read -r -a RUNNER_ADMINS <<< "$(dscl . -read /Groups/admin GroupMembership | cut -d: -f2)"
defaults write "$DOMAIN" ApprovedAdmins -array "${RUNNER_ADMINS[@]}"
echo "Approved for CI: ${RUNNER_ADMINS[*]}"
defaults write "$DOMAIN" Method -string Local
defaults write "$DOMAIN" FirstPass -string "$FIRST"
defaults write "$DOMAIN" PasswordLength -int "$LEN"
defaults write "$DOMAIN" DaysTillExpiration -int 30
# Most checks expect -resetPassword to rotate immediately; staging has its own tests.
defaults write "$DOMAIN" StagedRotation -string off
defaults write "$DOMAIN" RemovePassChars -string "$EXCLUDED"
defaults read "$DOMAIN"
echo "::endgroup::"

get_pw() {
    "$LAPS" -getPassword >&2 || return 1
    local export_name
    export_name=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
    security find-generic-password -w -s "$export_name" "$SYSKC"
}

check_pw() {
    local pw="$1" label="$2"
    if dscl . -authonly "$ACCT" "$pw" >/dev/null 2>&1; then
        pass "$label: exported password authenticates"
    else
        fail "$label: exported password does NOT authenticate $ACCT"
    fi
    [ "${#pw}" -eq "$LEN" ] && pass "$label: length ${#pw}" || fail "$label: length ${#pw}, expected $LEN"
    printf '%s' "$pw" | grep -q '[][{}|_]' && fail "$label: contains an excluded character" || pass "$label: no excluded characters"
    LC_ALL=C; local re='^[!-~]+$'
    [[ "$pw" =~ $re ]] && pass "$label: printable ASCII only" || fail "$label: non-printable or non-ASCII character"
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------------------------------- ###
### | First rotation (FirstPass from preferences) | ###
### ----------------------------------------------- ###
echo "::group::First rotation (FirstPass from preferences)"
"$LAPS" -resetPassword && pass "first rotation exited 0" || fail "first rotation failed"
PW1=$(get_pw) || fail "-getPassword failed after first rotation"
check_pw "${PW1:-}" "rotation 1"
dscl . -authonly "$ACCT" "$FIRST" >/dev/null 2>&1 && fail "FirstPass still works after rotation" || pass "FirstPass no longer works"
echo "::endgroup::"

version_is_clean "legacy domain, export pending"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------------- ###
### | Export item is removed on next run | ###
### -------------------------------------- ###
echo "::group::Export item is removed on next run"
SVC=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
"$LAPS"
security find-generic-password -s "$SVC" "$SYSKC" >/dev/null 2>&1 \
    && fail "exported keychain item $SVC still present" || pass "exported keychain item removed"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------------------------- ###
### | Forced rotation invalidates previous password | ###
### ------------------------------------------------- ###
echo "::group::Forced rotation invalidates previous password"
"$LAPS" -resetPassword && pass "forced rotation exited 0" || fail "forced rotation failed"
PW2=$(get_pw) || fail "-getPassword failed after forced rotation"
check_pw "${PW2:-}" "rotation 2"
[ "${PW1:-x}" != "${PW2:-x}" ] && pass "password changed" || fail "password did not change"
dscl . -authonly "$ACCT" "${PW1:-}" >/dev/null 2>&1 && fail "previous password still works" || pass "previous password invalidated"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------- ###
### | Generator: $ROUNDS rotations | ###
### -------------------------------- ###
echo "::group::Generator: $ROUNDS rotations"
for i in $(seq 1 "$ROUNDS"); do
    "$LAPS" -resetPassword >/dev/null 2>&1 || { fail "rotation $i failed"; continue; }
    PW=$(get_pw 2>/dev/null) || { fail "export $i failed"; continue; }
    check_pw "$PW" "round $i" > /tmp/laps-round.log
    grep -v '^PASS' /tmp/laps-round.log || true
done
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------------------------------------- ###
### | Simulated secureToken: old password must be known | ###
### ----------------------------------------------------- ###
echo "::group::Simulated secureToken: old password must be known"
export MACOSLAPS_TEST_ASSUME_SECURETOKEN=1
KNOWN='Known-Pass-5678'
dscl . -passwd "/Users/$ACCT" "$KNOWN" || fail "could not reset account to a known password"
STORED_BEFORE=$(get_pw 2>/dev/null)
# Wrong FirstPass: must fail and change nothing.
if "$LAPS" -firstPass 'Wrong-Pass-0000' -resetPassword >/dev/null 2>&1; then
    fail "rotation with a wrong FirstPass succeeded (old password is not being enforced)"
else
    pass "rotation with a wrong FirstPass failed"
fi
dscl . -authonly "$ACCT" "$KNOWN" >/dev/null 2>&1 && pass "account unchanged after failed rotation" || fail "account changed after failed rotation"
[ "$(get_pw 2>/dev/null)" = "$STORED_BEFORE" ] && pass "keychain unchanged after failed rotation" || fail "keychain changed after failed rotation"
# Correct FirstPass, flag after -resetPassword (#92 argument order).
"$LAPS" -resetPassword -firstPass "$KNOWN" && pass "-resetPassword -firstPass <pw> succeeded" || fail "-resetPassword -firstPass <pw> failed"
PWA=$(get_pw) && check_pw "$PWA" "token sim, CLI firstPass (after)"
# Correct FirstPass, flag first.
dscl . -passwd "/Users/$ACCT" "$KNOWN"
"$LAPS" -firstPass "$KNOWN" -resetPassword && pass "-firstPass <pw> -resetPassword succeeded" || fail "-firstPass <pw> -resetPassword failed"
PWB=$(get_pw) && check_pw "$PWB" "token sim, CLI firstPass (before)"
# Stored-password path.
"$LAPS" -resetPassword && pass "rotation with the stored password succeeded" || fail "rotation with the stored password failed"
PWC=$(get_pw) && check_pw "$PWC" "token sim, stored password"
dscl . -authonly "$ACCT" "$PWB" >/dev/null 2>&1 && fail "previous password still works" || pass "previous password invalidated"
unset MACOSLAPS_TEST_ASSUME_SECURETOKEN
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------------------------------- ###
### | A stop signal between changing and storing | ###
### ---------------------------------------------- ###
### The password is ignored.                                                ###
echo "::group::A stop signal between changing and storing the password is ignored"
MACOSLAPS_TEST_PAUSE_AFTER_CHANGE=5 "$LAPS" -resetPassword >/dev/null 2>&1 &
RUN_PID=$!
sleep 2
kill -TERM "$RUN_PID" 2>/dev/null; kill -HUP "$RUN_PID" 2>/dev/null; kill -INT "$RUN_PID" 2>/dev/null
wait "$RUN_PID"; RC=$?
[ "$RC" -eq 0 ] && pass "rotation finished despite SIGTERM/SIGHUP/SIGINT (exit 0)" || fail "rotation was stopped mid-way (exit $RC)"
SIG_PW=$(get_pw 2>/dev/null)
dscl . -authonly "$ACCT" "$SIG_PW" >/dev/null 2>&1 && pass "account and keychain agree after the signals" || fail "account and keychain disagree after a stop signal"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------------- ###
### | secureToken detection fails closed | ###
### -------------------------------------- ###
echo "::group::secureToken detection fails closed"
SAVED_FIRSTPASS=$(defaults read "$DOMAIN" FirstPass 2>/dev/null || true)
defaults delete "$DOMAIN" FirstPass 2>/dev/null || true
KNOWN2='Known-Pass-9753'
CURRENT=$(get_pw 2>/dev/null)
dscl . -passwd "/Users/$ACCT" "$CURRENT" "$KNOWN2" 2>/dev/null || dscl . -passwd "/Users/$ACCT" "$KNOWN2"
# 1. Token status unknown and no stored password: refuse, change nothing.
security delete-generic-password -s "$KCSVC" "$SYSKC" >/dev/null 2>&1
if MACOSLAPS_TEST_SECURETOKEN=unknown "$LAPS" -resetPassword >/dev/null 2>&1; then
    fail "unknown token status with no known password still rotated"
else
    pass "unknown token status with no known password refuses to reset"
fi
dscl . -authonly "$ACCT" "$KNOWN2" >/dev/null 2>&1 && pass "account untouched when token status is unknown" || fail "account changed with unknown token status"
# 2. Stored password out of date and token status unknown: refuse, change nothing.
"$LAPS" -firstPass "$KNOWN2" -initialize >/dev/null 2>&1 || fail "-initialize for the out-of-date test"
dscl . -passwd "/Users/$ACCT" "$KNOWN2" "$FIRST"          # keychain now holds an out-of-date password
if MACOSLAPS_TEST_SECURETOKEN=unknown "$LAPS" -resetPassword >/dev/null 2>&1; then
    fail "unknown token status reset over an out-of-date stored password"
else
    pass "unknown token status with an out-of-date stored password refuses"
fi
dscl . -authonly "$ACCT" "$FIRST" >/dev/null 2>&1 && pass "account untouched (unknown token, out-of-date keychain)" || fail "account changed (unknown token, out-of-date keychain)"
# 3. Confirmed no token (real sysadminctl on the runner) and an out-of-date stored password: recover with a reset.
if "$LAPS" -resetPassword >/dev/null 2>&1; then
    RESET_PW=$(get_pw)
    dscl . -authonly "$ACCT" "$RESET_PW" >/dev/null 2>&1 && pass "no token + out-of-date keychain recovers with a reset" || fail "reset password does not work"
else
    fail "no token + out-of-date keychain did not recover"
fi
security find-generic-password -s "$KCSVC" "$SYSKC" 2>/dev/null | grep -q '"icmt"<blob>="Created: 20' \
    && pass "a newly created keychain item has its creation date" || fail "new keychain item is missing its Created: comment"
[ -n "$SAVED_FIRSTPASS" ] && defaults write "$DOMAIN" FirstPass -string "$SAVED_FIRSTPASS"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["secureToken"] is False, d' \
    && pass "-status reports secureToken false on the runner" || fail "-status secureToken value"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Preference domains | ###
### ---------------------- ###
### New domain wins per key, legacy fills the rest.                         ###
echo "::group::Preference domains: new domain wins per key, legacy fills the rest"
NEWDOM=/Library/Preferences/com.joshua-d-miller.macoslaps
defaults write "$NEWDOM" PasswordLength -int 20
CFG=$("$LAPS" -showConfig 2>/dev/null)
echo "$CFG" | grep -E "PasswordLength|LocalAdminAccount|Method"
echo "$CFG" | grep -q "PasswordLength = 20  \[/Library/Preferences, new domain\]" && pass "PasswordLength comes from the new domain" || fail "PasswordLength not taken from the new domain"
echo "$CFG" | grep -q "LocalAdminAccount = $ACCT  \[/Library/Preferences, legacy domain\]" && pass "LocalAdminAccount still comes from the legacy domain" || fail "LocalAdminAccount not filled in from the legacy domain"
echo "$CFG" | grep -q "Method = Local  \[/Library/Preferences, legacy domain\]" && pass "Method still comes from the legacy domain" || fail "Method not filled in from the legacy domain"
"$LAPS" -resetPassword >/dev/null 2>&1 && P20=$(get_pw) && [ "${#P20}" -eq 20 ] && dscl . -authonly "$ACCT" "$P20" >/dev/null 2>&1 \
    && pass "rotation with split settings uses the right account and the new length" || fail "rotation with split settings (length ${#P20})"
# A managed profile in the new domain beats both local files.
mkdir -p "/Library/Managed Preferences"
defaults write "/Library/Managed Preferences/com.joshua-d-miller.macoslaps" PasswordLength -int 24
killall cfprefsd 2>/dev/null; sleep 1
if "$LAPS" -showConfig 2>/dev/null | grep -q "PasswordLength = 24  \[profile, new domain\]"; then
    pass "a managed new-domain value beats local settings"
else
    echo "::notice::Managed preferences written by hand weren't treated as managed on this runner: $("$LAPS" -showConfig 2>/dev/null | grep PasswordLength)"
fi
rm -f "/Library/Managed Preferences/com.joshua-d-miller.macoslaps.plist"
defaults delete "$NEWDOM" >/dev/null 2>&1; rm -f "$NEWDOM.plist"
killall cfprefsd 2>/dev/null; sleep 1
"$LAPS" -showConfig 2>/dev/null | grep -q "PasswordLength = $LEN  \[/Library/Preferences, legacy domain\]" && pass "back to legacy-only settings" || fail "settings not restored to legacy only"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------- ###
### | -status records the last run | ###
### -------------------------------- ###
### Failed password checks are not repeated.                                ###
echo "::group::-status records the last run; failed password checks are not repeated"
"$LAPS" -resetPassword >/dev/null 2>&1
"$LAPS" -status | python3 -c 'import json,sys,re; d=json.load(sys.stdin); iso=re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$"); assert d["lastResult"]=="rotated" and all(iso.match(d[k]) for k in ("lastRun","lastSuccess","lastRotation","expires")), d' \
    && pass "-status reports the last rotation" || fail "-status last run after rotation: $("$LAPS" -status)"
"$LAPS" >/dev/null 2>&1
"$LAPS" -status | grep -q '"lastResult":"not-due"' && pass "-status reports a not-due run" || fail "-status after a not-due run"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["migration"]=="none" and "migratedAt" not in d, d' \
    && pass "-status: nothing to migrate on a fresh install" || fail "-status migration on a fresh install: $("$LAPS" -status)"
security find-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1 && fail "a fresh install created a legacy macOSLAPS item" || pass "no legacy keychain item on a fresh install"
OUT=$("$LAPS" 2>&1); echo "$OUT" | grep -q "is deprecated" && pass "running from /usr/local/laps logs a deprecation notice" || fail "no deprecation notice for /usr/local/laps: $OUT"
OUT=$("$APP/Contents/MacOS/macOSLAPS" 2>&1); echo "$OUT" | grep -q "is deprecated" && fail "deprecation notice when run from the app" || pass "no deprecation notice when run from the app"
OUT=$("$LAPS" -status 2>&1); echo "$OUT" | grep -q "is deprecated" && fail "-status output carries the deprecation notice" || pass "-status output has no deprecation notice"
# Keychain and account disagree: the first check fails, later ones reuse that result
# instead of adding a failed login each time.
GOOD=$(get_pw)
dscl . -passwd "/Users/$ACCT" "$GOOD" 'Changed-Behind-Its-Back-1'
"$LAPS" -status | grep -q '"passwordVerifies":false' && pass "-status detects keychain/account mismatch" || fail "-status missed the mismatch"
# verifiedAt changes only when the password is actually checked against the account
# (-escrow also writes lastEscrow, so the file's modification time is not a signal).
checked_at() { plutil -extract verifiedAt raw /var/db/macoslaps/state.plist 2>/dev/null; }
BEFORE=$(checked_at)
sleep 1
for i in 1 2 3; do "$LAPS" -status >/dev/null; "$LAPS" -escrow >/dev/null 2>&1; done
AFTER=$(checked_at)
[ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ] && pass "failed check reused (no new authentication attempts)" || fail "failed check was repeated ($BEFORE -> $AFTER)"
dscl . -passwd "/Users/$ACCT" 'Changed-Behind-Its-Back-1' "$GOOD"
"$LAPS" -resetPassword >/dev/null 2>&1   # a rotation verifies and clears the cached failure
"$LAPS" -status | grep -q '"passwordVerifies":true' && pass "a rotation clears the cached failure" || fail "-status after recovery: $("$LAPS" -status)"
[ "$(stat -f '%Lp %Su' /var/db/macoslaps/state.plist)" = "600 root" ] && pass "state file is root-only" || fail "state file permissions: $(stat -f '%Lp %Su' /var/db/macoslaps/state.plist)"
grep -qF -- "$(get_pw)" /var/db/macoslaps/state.plist && fail "state file contains the password" || pass "state file holds no password"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------- ###
### | -status | ###
### ----------- ###
echo "::group::-status"
ST=$("$LAPS" -status)
echo "$ST"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accountExists"] and d["accountIsAdmin"] and d["passwordStored"] and d["passwordVerifies"], d' "$ST" \
  && pass "-status JSON reports a working stored password" || fail "-status JSON unexpected: $ST"
"$LAPS" -status -v | tee /tmp/laps-status.txt
grep -q "The stored password works" /tmp/laps-status.txt && pass "-status -v checklist" || fail "-status -v missing checks"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------------- ###
### | Two runs at once do not interleave | ###
### -------------------------------------- ###
echo "::group::Two runs at once do not interleave"
"$LAPS" -resetPassword >/tmp/laps-a.log 2>&1 & A=$!
"$LAPS" -resetPassword >/tmp/laps-b.log 2>&1 & B=$!
wait $A; RA=$?; wait $B; RB=$?
[ "$RA" -eq 0 ] && [ "$RB" -eq 0 ] && pass "both concurrent runs exited 0" || { fail "concurrent runs exited $RA / $RB"; cat /tmp/laps-a.log /tmp/laps-b.log; }
PWL=$(get_pw) && dscl . -authonly "$ACCT" "$PWL" >/dev/null 2>&1 && pass "stored password authenticates after concurrent runs" || fail "keychain and account disagree after concurrent runs"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------- ###
### | -escrow (plaintext) | ###
### ----------------------- ###
echo "::group::-escrow (plaintext)"
CUR=$(get_pw)
ESC=$("$LAPS" -escrow)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2] and d["verified"] and d["account"]==sys.argv[3], d' "$ESC" "$CUR" "$ACCT" \
  && pass "-escrow plaintext JSON has the current, verified password" || fail "-escrow plaintext unexpected"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------- ###
### | -escrow (CMS) | ###
### ----------------- ###
echo "::group::-escrow (CMS)"
OPENSSL=$(ls /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl 2>/dev/null | head -1)
if [ -z "$OPENSSL" ]; then
    echo "::notice::OpenSSL 3 not found on this runner; CMS round-trip skipped."
else
    T=$(mktemp -d)
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 2 -subj "/CN=macoslaps-ci" \
        -addext "keyUsage=keyEncipherment,dataEncipherment" -addext "extendedKeyUsage=1.3.6.1.4.1.311.80.1" 2>/dev/null
    defaults write "$DOMAIN" EscrowCertificates -array "$(cat "$T/c.pem")"
    "$LAPS" -escrow > "$T/escrow.pem"
    head -1 "$T/escrow.pem" | grep -q "BEGIN CMS" && pass "-escrow prints a CMS block" || fail "-escrow did not print CMS"
    "$OPENSSL" cms -cmsout -print -inform PEM -in "$T/escrow.pem" > "$T/print.txt"
    grep -A1 -i "contentEncryptionAlgorithm" "$T/print.txt" | grep -q "aes-256-cbc" && pass "CMS content encrypted with AES-256-CBC" || { fail "CMS is not AES-256-CBC"; grep -A1 -i contentEncryptionAlgorithm "$T/print.txt"; }
    DEC=$("$OPENSSL" cms -decrypt -inform PEM -in "$T/escrow.pem" -recip "$T/c.pem" -inkey "$T/k.pem" 2>&1)
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2], d' "$DEC" "$CUR" \
      && pass "CMS escrow decrypts with the admin key to the current password" || fail "CMS decrypt failed: $DEC"
    "$LAPS" -status | grep -q '"escrow":"cms"' && pass "-status reports CMS escrow" || fail "-status escrow mode"
    "$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["escrowCertificatesExpire"].startswith("20"), d' \
      && pass "-status reports the escrow certificate expiry" || fail "-status escrowCertificatesExpire missing"
    "$LAPS" -status -v | grep -q "escrow certificate expires in" && pass "-status -v warns about a certificate expiring soon" || fail "-status -v expiry warning missing"
    # macOS's own tool, as documented in integrations/README.md.
    "$OPENSSL" pkcs12 -export -legacy -out "$T/id.p12" -inkey "$T/k.pem" -in "$T/c.pem" -passout pass:ci 2>/dev/null
    security create-keychain -p ci "$T/cms.keychain" && security unlock-keychain -p ci "$T/cms.keychain"
    security import "$T/id.p12" -k "$T/cms.keychain" -P ci -A -f pkcs12 || fail "could not import the test identity"
    security find-identity -v "$T/cms.keychain" | head -3
    # security cms looks up the recipient identity in the keychain search list.
    OLD_LIST=$(security list-keychains -d user | tr -d '"')
    security list-keychains -d user -s "$T/cms.keychain" $OLD_LIST
    sed '1d;$d' "$T/escrow.pem" | base64 -D > "$T/escrow.der"
    SDEC=$(security cms -D -k "$T/cms.keychain" -i "$T/escrow.der" 2>&1)
    security list-keychains -d user -s $OLD_LIST
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2], d' "$SDEC" "$CUR" 2>/dev/null; then
        pass "CMS escrow decrypts with /usr/bin/security cms"
    else
        fail "security cms -D did not decrypt the escrow: ${SDEC:0:200}"
    fi
    security delete-keychain "$T/cms.keychain" 2>/dev/null
    # Hand the blob and a Windows-importable identity to the Windows job (Unprotect-CmsMessage).
    if [ -n "${CMS_ARTIFACT_DIR:-}" ]; then
        mkdir -p "$CMS_ARTIFACT_DIR"
        cp "$T/escrow.pem" "$CMS_ARTIFACT_DIR/escrow.txt"
        "$OPENSSL" pkcs12 -export -out "$CMS_ARTIFACT_DIR/identity.pfx" -inkey "$T/k.pem" -in "$T/c.pem" -passout pass:ci \
            -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
        printf '%s' "$CUR" > "$CMS_ARTIFACT_DIR/expected.txt"
        chmod -R a+rX "$CMS_ARTIFACT_DIR"
    fi
    defaults delete "$DOMAIN" EscrowCertificates

    # Fail closed: encryption configured but unusable must never print the password.
    escrow_withheld() {   # escrow_withheld <label>
        local out rc
        out=$("$LAPS" -escrow 2>/dev/null); rc=$?
        if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qF -- "$CUR" \
           && python3 -c 'import json,sys; assert json.loads(sys.argv[1])["status"]=="error"' "$out" 2>/dev/null; then
            pass "-escrow withholds the password: $1"
        else
            fail "-escrow with $1 (exit $rc) did not fail closed"
        fi
    }
    defaults write "$DOMAIN" EscrowCertificates -array "not a certificate"
    escrow_withheld "an invalid certificate"
    "$LAPS" -status | grep -q '"escrow":"error"' && pass "-status reports escrow error" || fail "-status escrow error"
    "$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/ec.key" -out "$T/ec.pem" -days 2 -subj "/CN=ec" 2>/dev/null
    defaults write "$DOMAIN" EscrowCertificates -array "$(cat "$T/ec.pem")"
    escrow_withheld "only a non-RSA certificate"
    # A valid certificate next to a bad one: encrypt to the valid one.
    defaults write "$DOMAIN" EscrowCertificates -array "not a certificate" "$(cat "$T/c.pem")"
    "$LAPS" -escrow 2>/dev/null | head -1 | grep -q "BEGIN CMS" && pass "-escrow encrypts to the usable certificate and skips the bad one" || fail "-escrow with one bad and one good certificate"
    # An empty array (as in the example profile) means plaintext escrow.
    defaults write "$DOMAIN" EscrowCertificates -array
    "$LAPS" -escrow 2>/dev/null | python3 -c 'import json,sys; assert json.load(sys.stdin)["password"]' && pass "empty EscrowCertificates means plaintext escrow" || fail "empty EscrowCertificates"
    defaults delete "$DOMAIN" EscrowCertificates
    rm -rf "$T"
fi
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------------------------------------------- ###
### | -initialize (#88): adopt current password without rotating | ###
### -------------------------------------------------------------- ###
echo "::group::-initialize (#88): adopt current password without rotating"
INIT='Init-Pass-2468'
dscl . -passwd "/Users/$ACCT" "$INIT"
if "$LAPS" -firstPass 'Not-The-Password' -initialize >/dev/null 2>&1; then fail "-initialize accepted a wrong password"; else pass "-initialize rejects a wrong password"; fi
"$LAPS" -firstPass "$INIT" -initialize && pass "-initialize succeeded" || fail "-initialize failed"
[ "$(get_pw)" = "$INIT" ] && pass "stored password is the initialized one" || fail "stored password not the initialized one"
dscl . -authonly "$ACCT" "$INIT" >/dev/null 2>&1 && pass "account not rotated by -initialize" || fail "account was rotated"
"$LAPS" >/dev/null 2>&1
[ "$(get_pw)" = "$INIT" ] && pass "scheduled run does not rotate before expiry" || fail "scheduled run rotated early"
# Running -initialize again (an MDM doing it every check-in) must not move the date.
CREATED1=$(security find-generic-password -s "$KCSVC" "$SYSKC" | grep '"icmt"')
sleep 2
"$LAPS" -firstPass "$INIT" -initialize >/dev/null 2>&1 && pass "repeated -initialize succeeds" || fail "repeated -initialize failed"
[ "$(security find-generic-password -s "$KCSVC" "$SYSKC" | grep '"icmt"')" = "$CREATED1" ] && pass "repeated -initialize keeps the creation date" || fail "repeated -initialize reset the creation date"
# FirstPass in the configuration is readable by local users; -status must flag it while it is live.
defaults write "$DOMAIN" FirstPass -string "$INIT"
"$LAPS" -status | grep -q '"passwordIsFirstPass":true' && pass "-status flags a live FirstPass" || fail "-status does not flag a live FirstPass"
"$LAPS" -resetPassword >/dev/null 2>&1
"$LAPS" -status | grep -q '"passwordIsFirstPass":false' && pass "-status clears the flag after rotation" || fail "-status FirstPass flag after rotation"
# After that rotation, an outdated FirstPass is not tried against the account.
ROT=$(get_pw)
"$LAPS" -firstPass "$INIT" -initialize >/dev/null 2>&1 && pass "-initialize on a managed Mac exits cleanly" || fail "-initialize on a managed Mac failed"
[ "$(get_pw)" = "$ROT" ] && pass "-initialize leaves a rotated password alone" || fail "-initialize replaced the rotated password"
defaults write "$DOMAIN" FirstPass -string "$FIRST"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------- ###
### | Staged rotation | ###
### ------------------- ###
### The MDM gets the next password before the account uses it.              ###
echo "::group::Staged rotation: the MDM gets the next password before the account uses it"
defaults write "$DOMAIN" StagedRotation -string on
defaults write "$DOMAIN" EscrowConfirmations -int 2
defaults write "$DOMAIN" InventoryHook -string ""
BEFORE=$(get_pw)
"$LAPS" -resetPassword >/dev/null 2>&1 && pass "-resetPassword with staging exits cleanly" || fail "-resetPassword with staging failed"
[ "$(get_pw)" = "$BEFORE" ] && dscl . -authonly "$ACCT" "$BEFORE" >/dev/null 2>&1 && pass "staging leaves the current password in use" || fail "staging changed the account"
ST=$("$LAPS" -status)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["pending"] and d["pendingExports"]==0 and d["pendingExportsNeeded"]==2 and d["lastResult"]=="staged", d' "$ST" \
    && pass "-status shows the staged password (0 of 2)" || fail "-status staging fields: $ST"
E1=$("$LAPS" -escrow 2>/dev/null)
PENDING=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2]; print(d["pending"])' "$E1" "$BEFORE") \
    && [ -n "$PENDING" ] && [ "$PENDING" != "$BEFORE" ] && pass "-escrow reports current and pending passwords" || fail "-escrow pending output"
"$LAPS" >/dev/null 2>&1
dscl . -authonly "$ACCT" "$BEFORE" >/dev/null 2>&1 && pass "not applied after 1 of 2 exports" || fail "applied too early"
"$LAPS" -escrow >/dev/null 2>&1
"$LAPS" >/dev/null 2>&1
dscl . -authonly "$ACCT" "$PENDING" >/dev/null 2>&1 && [ "$(get_pw)" = "$PENDING" ] && pass "applied after 2 exports: account and keychain use the escrowed pending password" || fail "pending password not applied after 2 exports"
dscl . -authonly "$ACCT" "$BEFORE" >/dev/null 2>&1 && fail "previous password still works after apply" || pass "previous password invalidated"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["pending"] and d["lastResult"]=="rotated", d' && pass "no pending password after apply" || fail "pending left after apply"
"$LAPS" -escrow 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "pending" not in d, d' && pass "-escrow has no pending field when nothing is staged" || fail "-escrow still shows pending"

# A hook that collects inventory confirms immediately (applied in the same run).
rm -f /tmp/laps-collected.json
cat > /tmp/laps-collect.sh <<HOOK
#!/bin/sh
out=\$("$LAPS" -escrow 2>/dev/null)
case "\$out" in *'"pending"'*) printf '%s' "\$out" > /tmp/laps-collected.json ;; esac
HOOK
chmod +x /tmp/laps-collect.sh
defaults write "$DOMAIN" InventoryHook -string custom
defaults write "$DOMAIN" InventoryHookCommand -array /tmp/laps-collect.sh
defaults write "$DOMAIN" InventoryHookConfirms -bool true
BEFORE=$(get_pw)
"$LAPS" -resetPassword >/dev/null 2>&1
AFTER=$(get_pw)
COLLECTED=$(python3 -c 'import json; print(json.load(open("/tmp/laps-collected.json"))["pending"])' 2>/dev/null)
[ "$AFTER" != "$BEFORE" ] && [ "$AFTER" = "$COLLECTED" ] && dscl . -authonly "$ACCT" "$AFTER" >/dev/null 2>&1 \
    && pass "hook collected the pending password; applied in the same run" || fail "hook confirmation (before/after/collected differ unexpectedly)"
defaults write "$DOMAIN" InventoryHook -string ""
defaults delete "$DOMAIN" InventoryHookConfirms

# Power loss / SIGKILL after the account changed: the next run finishes the job.
"$LAPS" -resetPassword >/dev/null 2>&1                     # stage
"$LAPS" -escrow >/dev/null 2>&1; "$LAPS" -escrow >/dev/null 2>&1
P2=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pending"])' "$("$LAPS" -escrow 2>/dev/null)")
MACOSLAPS_TEST_PAUSE_AFTER_CHANGE=10 "$LAPS" >/dev/null 2>&1 &
KPID=$!
sleep 4
kill -9 "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
dscl . -authonly "$ACCT" "$P2" >/dev/null 2>&1 && [ "$(get_pw)" != "$P2" ] && pass "simulated crash: account changed, keychain not yet updated" || echo "::notice::crash simulation timing missed the window"
"$LAPS" >/dev/null 2>&1
[ "$(get_pw)" = "$P2" ] && dscl . -authonly "$ACCT" "$P2" >/dev/null 2>&1 && pass "next run finished the interrupted rotation" || fail "interrupted rotation not recovered"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["pending"] and d["passwordVerifies"], d' && pass "clean state after recovery" || fail "state after recovery"

# auto mode: active only when -escrow has run recently.
defaults write "$DOMAIN" StagedRotation -string auto
"$LAPS" -status | grep -q '"stagedRotation":"auto (active)"' && pass "auto mode is active after -escrow ran" || fail "auto mode not active after -escrow"
# Taking over an account with -firstPass never stages, even with staging active:
# a FirstPass given on the command line would be gone when the staged one is applied.
TAKEOVER='Takeover-Pass-2468'
dscl . -passwd "/Users/$ACCT" "$(get_pw)" "$TAKEOVER" >/dev/null 2>&1
security delete-generic-password -s "$KCSVC" "$SYSKC" >/dev/null 2>&1
"$LAPS" -firstPass "$TAKEOVER" >/dev/null 2>&1
TP=$(get_pw 2>/dev/null)
[ -n "$TP" ] && [ "$TP" != "$TAKEOVER" ] && dscl . -authonly "$ACCT" "$TP" >/dev/null 2>&1 \
    && "$LAPS" -status | grep -q '"pending":false' && pass "-firstPass rotates right away with staging active" || fail "-firstPass with staging active: $("$LAPS" -status)"
defaults write "$DOMAIN" StagedRotation -string off
"$LAPS" -status | grep -q '"stagedRotation":"off (inactive)"' && pass "staging off" || fail "staging off status"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------ ###
### | InventoryHook custom | ###
### ------------------------ ###
echo "::group::InventoryHook custom"
rm -f /tmp/laps-hook-ran
defaults write "$DOMAIN" InventoryHook -string custom
defaults write "$DOMAIN" InventoryHookCommand -array /usr/bin/touch /tmp/laps-hook-ran
"$LAPS" -resetPassword >/dev/null 2>&1 && [ -f /tmp/laps-hook-ran ] && pass "custom hook ran after rotation" || fail "custom hook did not run"
# A slow hook must not hold the run lock: a second run starts while the hook sleeps.
defaults write "$DOMAIN" InventoryHookCommand -array /bin/sleep 30
"$LAPS" -resetPassword >/dev/null 2>&1 &
SLOW_PID=$!
sleep 6
T0=$(date +%s)
defaults write "$DOMAIN" InventoryHook -string ""          # the second run itself skips the hook
"$LAPS" -resetPassword >/dev/null 2>&1; RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 0 ] && [ "$ELAPSED" -lt 15 ] && pass "a second run isn't blocked by a slow hook (${ELAPSED}s)" || fail "second run waited ${ELAPSED}s (exit $RC) for the first run's hook"
kill "$SLOW_PID" 2>/dev/null; pkill -f "/bin/sleep 30" 2>/dev/null; wait "$SLOW_PID" 2>/dev/null
defaults write "$DOMAIN" InventoryHook -string custom
defaults write "$DOMAIN" InventoryHookCommand -array /usr/bin/touch /tmp/laps-hook-ran
dscl . -authonly "$ACCT" "$(get_pw)" >/dev/null 2>&1 && pass "account and keychain agree after overlapping runs" || fail "account and keychain disagree after overlapping runs"
# A hook that calls macOSLAPS -resetPassword again (as a recon-triggered script might) must not loop.
cat > /tmp/laps-hook.sh <<HOOK
#!/bin/sh
echo run >> /tmp/laps-hook-count
"$LAPS" -resetPassword >> /tmp/laps-hook-nested.log 2>&1
"$LAPS" -escrow > /tmp/laps-hook-escrow.json 2>/dev/null
HOOK
chmod 755 /tmp/laps-hook.sh; rm -f /tmp/laps-hook-count /tmp/laps-hook-escrow.json
defaults write "$DOMAIN" InventoryHookCommand -array /tmp/laps-hook.sh
"$LAPS" -resetPassword >/dev/null 2>&1
[ "$(wc -l < /tmp/laps-hook-count | tr -d ' ')" = "1" ] && pass "hook ran once; nested run did not rotate or re-run it" || fail "hook ran $(wc -l < /tmp/laps-hook-count) times"
HP=$(get_pw)
python3 -c 'import json,sys; d=json.load(open("/tmp/laps-hook-escrow.json")); assert d["password"]==sys.argv[1]' "$HP" \
  && pass "-escrow inside the hook returns the new password" || fail "-escrow inside the hook"
defaults delete "$DOMAIN" InventoryHook; defaults delete "$DOMAIN" InventoryHookCommand
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------- ###
### | PasswordStyle readable | ###
### -------------------------- ###
echo "::group::PasswordStyle readable"
defaults write "$DOMAIN" PasswordStyle -string readable
"$LAPS" -resetPassword >/dev/null 2>&1 || fail "readable rotation failed"
RP=$(get_pw)
echo "sample: ${RP:0:4}-****"
re='^[A-HJ-NP-Za-km-np-z2-9]{4}(-[A-HJ-NP-Za-km-np-z2-9]{4}){3}$'
[[ "$RP" =~ $re ]] && pass "readable password is 4x4 groups without look-alikes or symbols" || fail "readable password format: length ${#RP}"
dscl . -authonly "$ACCT" "$RP" >/dev/null 2>&1 && pass "readable password authenticates" || fail "readable password does not authenticate"
defaults delete "$DOMAIN" PasswordStyle
echo "::endgroup::"

if [ "$HAS_TOKEN" -eq 1 ]; then
    echo "::group::secureToken: -firstPass on the command line (after -resetPassword)"
    KNOWN='Known-Pass-5678'
    CUR=$(get_pw)
    dscl . -passwd "/Users/$ACCT" "$CUR" "$KNOWN" || fail "could not set known password"
    security delete-generic-password -s "$KCSVC" "$SYSKC" >/dev/null 2>&1
    defaults delete "$DOMAIN" FirstPass
    "$LAPS" -resetPassword -firstPass "$KNOWN" && pass "CLI -firstPass rotation exited 0" || fail "CLI -firstPass rotation failed"
    PW3=$(get_pw) && check_pw "$PW3" "cli firstPass"
    echo "::endgroup::"
else
    echo "::notice::Test account has no secureToken on this runner; secureToken path needs community testing."
fi

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------------------ ###
### | Device mode (reveal codes) | ###
### ------------------------------ ###
### The MDM gets a one-time code, never the password. -reveal shows the     ###
### password, replaces the code and starts the grace period; a passed       ###
### deadline rotates; five wrong codes lock reveals until the next          ###
### rotation.                                                               ###
echo "::group::Device mode (reveal codes)"
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
code_now() { jget "$("$LAPS" -escrow 2>/dev/null)" revealCode; }
reveal_pw() { "$LAPS" -reveal "$1" 2>/dev/null | sed -n 's/^Password: //p'; }
BEFORE=$(get_pw)
defaults write "$DOMAIN" RetrievalMode -string device
"$LAPS" >/dev/null 2>&1
E=$("$LAPS" -escrow 2>/dev/null)
CODE=$(jget "$E" revealCode)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["mode"]=="device" and "password" not in d and "pending" not in d, d' "$E" \
    && [[ "$CODE" =~ ^[A-HJKMNP-Z2-9]{4}(-[A-HJKMNP-Z2-9]{4}){3}$ ]] && pass "-escrow prints a reveal code, no password" || fail "device-mode -escrow: $E"
"$LAPS" -getPassword >/dev/null 2>&1 && fail "-getPassword works in device mode" || pass "-getPassword refused in device mode"
"$LAPS" -reveal AAAA-BBBB-CCCC-DDDD >/dev/null 2>&1 && fail "a wrong code revealed the password" || pass "wrong code refused"
[ "$(jget "$("$LAPS" -status)" revealFailures)" = "1" ] && pass "-status counts the wrong code" || fail "revealFailures: $("$LAPS" -status)"
LOWER=$(tr -d '-' <<< "$CODE" | tr 'A-Z' 'a-z')
OUT=$("$LAPS" -reveal "$LOWER" 2>/dev/null)
grep -qxF "Password: $BEFORE" <<< "$OUT" && grep -q "^Works until: " <<< "$OUT" && pass "right code (any case, no dashes) shows the password and the deadline" || fail "-reveal output: $(sed 's/Password: .*/Password: <redacted>/' <<< "$OUT")"
ST=$("$LAPS" -status)
python3 -c 'import json,sys,datetime as D; d=json.loads(sys.argv[1]); r=D.datetime.fromisoformat(d["rotatesAt"]); n=D.datetime.now(r.tzinfo); assert d["revealedAt"] and d["rotateReason"]=="reveal" and d["revealFailures"]==0 and 3.9*3600 < (r-n).total_seconds() <= 4*3600, d' "$ST" \
    && pass "-status: revealed, rotates in 4 h, failures reset" || fail "-status after reveal: $ST"
[ "$(code_now)" = "$CODE" ] && pass "the code stays the same until the rotation" || fail "the code changed after a reveal"
R1=$(jget "$("$LAPS" -status)" rotatesAt); sleep 2
[ "$(reveal_pw "$CODE")" = "$BEFORE" ] && [ "$(jget "$("$LAPS" -status)" rotatesAt)" = "$R1" ] \
    && pass "the same code reveals again (to elevate again) without extending the deadline" || fail "second reveal with the same code"
"$LAPS" -expireIn 0 >/dev/null 2>&1
"$LAPS" >/dev/null 2>&1
CODE3=$(code_now); AFTER=$(reveal_pw "$CODE3")
[ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ] && dscl . -authonly "$ACCT" "$AFTER" >/dev/null 2>&1 && pass "passed deadline: the next run rotated" || fail "no rotation after the deadline"
[ "$CODE3" != "$CODE" ] && ! "$LAPS" -reveal "$CODE" >/dev/null 2>&1 && pass "the rotation issued a new code; the old one no longer works" || fail "old code after the rotation"
dscl . -authonly "$ACCT" "$BEFORE" >/dev/null 2>&1 && fail "the revealed password still works after the deadline" || pass "the revealed password stopped working"
"$LAPS" -expireIn 0 >/dev/null 2>&1; "$LAPS" >/dev/null 2>&1   # clear the deadline the last reveal set
for i in 1 2 3 4 5; do "$LAPS" -reveal ZZZZ-ZZZZ-ZZZZ-ZZZZ >/dev/null 2>&1; done
GOOD=$(code_now)
"$LAPS" -reveal "$GOOD" >/dev/null 2>&1 && fail "reveal worked while locked" || pass "five wrong codes lock reveals, even for the right one"
[ "$(jget "$("$LAPS" -status)" revealLocked)" = "True" ] && pass "-status: revealLocked" || fail "revealLocked: $("$LAPS" -status)"
"$LAPS" -resetPassword >/dev/null 2>&1
[ "$(jget "$("$LAPS" -status)" revealLocked)" = "False" ] && [ "$(code_now)" != "$GOOD" ] && pass "a rotation unlocks reveals with a new code" || fail "still locked after -resetPassword"
LAST=$(reveal_pw "$(code_now)")
"$LAPS" -expireIn 0 >/dev/null 2>&1; "$LAPS" >/dev/null 2>&1
defaults write "$DOMAIN" RetrievalMode -string escrow
CUR=$(get_pw)
[ -n "$CUR" ] && dscl . -authonly "$ACCT" "$CUR" >/dev/null 2>&1 && pass "back in escrow mode with a working password" || fail "escrow mode after device mode"
"$LAPS" -expireIn 2h30m >/dev/null 2>&1
python3 -c 'import json,sys,datetime as D; d=json.loads(sys.argv[1]); r=D.datetime.fromisoformat(d["rotatesAt"]); n=D.datetime.now(r.tzinfo); assert d["rotateReason"]=="expireIn" and 2.4*3600 < (r-n).total_seconds() <= 2.5*3600, d' "$("$LAPS" -status)" \
    && pass "-expireIn 2h30m sets the deadline in escrow mode" || fail "-expireIn: $("$LAPS" -status)"
"$LAPS" -expireIn 0 >/dev/null 2>&1; "$LAPS" >/dev/null 2>&1
[ -z "$(jget "$("$LAPS" -status)" rotatesAt)" ] && pass "rotation clears the deadline" || fail "deadline left after rotation"
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | Privileged service | ###
### ---------------------- ###
### A standard user reaches the root service over XPC (status, reveal,      ###
### rotate now); a copy of macOSLAPS without its signature is turned away;  ###
### a request file only ends an active grace period; the check run waits    ###
### for a near deadline and rotates on time.                                ###
echo "::group::Privileged service"
STD=lapsstd
sysadminctl -addUser "$STD" -fullName "LAPS Standard" -password 'Std-Pass-2468' >/dev/null 2>&1
asuser() { sudo -u "$STD" "$@"; }
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
OUT=$(asuser "$LAPS" -status 2>&1)
[ "$(jget "$OUT" account 2>/dev/null)" = "$ACCT" ] && pass "standard user gets -status through the service" || fail "-status as a standard user: $OUT"
defaults write "$DOMAIN" RetrievalMode -string device
"$LAPS" >/dev/null 2>&1
CODE=$(jget "$("$LAPS" -escrow 2>/dev/null)" revealCode)
EXPECT=$("$LAPS" -reveal "$CODE" 2>/dev/null | sed -n 's/^Password: //p')
"$LAPS" -expireIn 0 >/dev/null 2>&1; "$LAPS" >/dev/null 2>&1      # rotate: clean deadline, new code
CODE=$(jget "$("$LAPS" -escrow 2>/dev/null)" revealCode)
asuser "$LAPS" -reveal WRONG-WRONG-WRONG-WRNG >/dev/null 2>&1 && fail "wrong code accepted through the service" || pass "wrong code refused through the service"
OUT=$(asuser "$LAPS" -reveal "$CODE" -reason "TICKET-42" 2>/dev/null)
PW=$(sed -n 's/^Password: //p' <<< "$OUT")
[ -n "$PW" ] && dscl . -authonly "$ACCT" "$PW" >/dev/null 2>&1 && grep -q "^Works until: " <<< "$OUT" && pass "standard user reveals through the service" || fail "reveal as a standard user"
python3 -c 'import plistlib,sys; h=plistlib.load(open("/var/db/macoslaps/state.plist","rb")).get("revealHistory",[]); assert any("lapsstd" in x and "TICKET-42" in x for x in h), h' \
    && pass "the reveal is recorded with the user and the reason" || fail "revealHistory: $(plutil -extract revealHistory json -o - /var/db/macoslaps/state.plist 2>&1)"
cp "$APP/Contents/MacOS/macOSLAPS" /tmp/laps-unsigned && codesign --force --sign - /tmp/laps-unsigned >/dev/null 2>&1 && chmod 755 /tmp/laps-unsigned
asuser /tmp/laps-unsigned -reveal "$CODE" >/dev/null 2>&1 && fail "the service answered an unsigned copy" || pass "the service refuses a copy without the macOSLAPS signature"
rm -f /tmp/laps-unsigned
asuser "$LAPS" -rotateNow >/dev/null 2>&1 && [ -n "$(jget "$("$LAPS" -status)" rotatesAt)" ] \
    && python3 -c 'import json,sys,datetime as D; d=json.loads(sys.argv[1]); r=D.datetime.fromisoformat(d["rotatesAt"]); assert (r-D.datetime.now(r.tzinfo)).total_seconds() <= 1, d' "$("$LAPS" -status)" \
    && pass "-rotateNow as a standard user ends the grace period" || fail "-rotateNow through the service"
"$LAPS" >/dev/null 2>&1
dscl . -authonly "$ACCT" "$PW" >/dev/null 2>&1 && fail "the revealed password still works after rotate now" || pass "rotate now: the next run rotated"
defaults write "$DOMAIN" RetrievalMode -string escrow
# A request file with no deadline does nothing; with one it ends the grace period.
asuser touch "$REQ/rotate-now"; sleep 6
[ -z "$(ls -A "$REQ")" ] && [ -z "$(jget "$("$LAPS" -status)" rotatesAt)" ] && pass "request file without a deadline: removed, nothing changed" || fail "request file without a deadline: $(ls -A "$REQ") / $("$LAPS" -status)"
"$LAPS" -expireIn 2h >/dev/null 2>&1
asuser touch "$REQ/rotate-now"; sleep 6
BEFORE=$(get_pw)
"$LAPS" >/dev/null 2>&1
AFTER=$(get_pw)
[ "$AFTER" != "$BEFORE" ] && [ -z "$(jget "$("$LAPS" -status)" rotatesAt)" ] && pass "request file during a grace period: rotated" || fail "request file with a deadline"
# The check run waits for a deadline that comes before its next scheduled run.
"$LAPS" -expireIn 15s >/dev/null 2>&1
BEFORE=$(get_pw); START=$(date +%s)
"$LAPS" >/dev/null 2>&1
TOOK=$(( $(date +%s) - START )); AFTER=$(get_pw)
[ "$TOOK" -ge 13 ] && [ "$TOOK" -le 90 ] && [ "$AFTER" != "$BEFORE" ] && dscl . -authonly "$ACCT" "$AFTER" >/dev/null 2>&1 \
    && pass "the check run waited ${TOOK}s for the deadline and rotated" || fail "deadline timer (took ${TOOK}s)"
sysadminctl -deleteUser "$STD" >/dev/null 2>&1
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------------------- ###
### | Admin group protection | ###
### -------------------------- ###
### Only the managed admin, root and ApprovedAdmins may stay admin. auto    ###
### removes the rest unless an elevation tool is installed; nothing is      ###
### removed without a verified password for the managed admin.              ###
echo "::group::Admin group protection"
EXTRA=lapsextra
sysadminctl -addUser "$EXTRA" -fullName "LAPS Extra" -password 'Extra-Pass-1357' -admin >/dev/null 2>&1
is_admin() { dseditgroup -o checkmember -m "$1" admin >/dev/null 2>&1; }
is_admin "$EXTRA" || fail "could not create the extra admin"
# report: listed, not removed
defaults write "$DOMAIN" AdminGroupPolicy -string report
"$LAPS" >/dev/null 2>&1
is_admin "$EXTRA" && pass "report: unapproved admin kept" || fail "report removed an admin"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["unapprovedAdmins"]==["lapsextra"] and d["adminGroupPolicy"]=="report", d' \
    && pass "-status lists the unapproved admin" || fail "-status unapprovedAdmins: $("$LAPS" -status)"
# auto with a fake elevation tool: report only
mkdir -p /Applications/Privileges.app
defaults write "$DOMAIN" AdminGroupPolicy -string auto
"$LAPS" >/dev/null 2>&1
is_admin "$EXTRA" && "$LAPS" -status | grep -q '"elevationTool":"SAP Privileges"' && pass "auto + elevation tool: kept and reported" || fail "auto with an elevation tool"
rm -rf /Applications/Privileges.app
# no verified password for the managed admin: nothing is removed
CUR=$(get_pw 2>/dev/null)
dscl . -passwd "/Users/$ACCT" "$CUR" 'Not-Stored-Pass-1' >/dev/null 2>&1
"$LAPS" >/dev/null 2>&1
is_admin "$EXTRA" && pass "no verified managed-admin password: nothing removed" || fail "removed an admin without a working managed-admin password"
dscl . -passwd "/Users/$ACCT" 'Not-Stored-Pass-1' "$CUR" >/dev/null 2>&1
# auto: removed
"$LAPS" >/dev/null 2>&1
! is_admin "$EXTRA" && pass "auto: unapproved admin removed" || fail "auto did not remove the unapproved admin"
is_admin "$ACCT" && pass "managed admin still admin" || fail "managed admin lost admin"
"$LAPS" -status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["unapprovedAdmins"]==[] and any(x.startswith("lapsextra ") for x in d["demotedAdmins"]), d' \
    && pass "-status records the removal" || fail "-status demotedAdmins: $("$LAPS" -status)"
for u in "${RUNNER_ADMINS[@]}"; do [ "$u" = root ] && continue; is_admin "$u" && pass "approved admin $u kept" || fail "approved admin $u removed"; done
# approved by group
dseditgroup -o edit -a "$EXTRA" -t user admin
dseditgroup -o create lapsapproved >/dev/null 2>&1
dseditgroup -o edit -a "$EXTRA" -t user lapsapproved
defaults write "$DOMAIN" ApprovedAdmins -array "${RUNNER_ADMINS[@]}" group:lapsapproved
"$LAPS" >/dev/null 2>&1
is_admin "$EXTRA" && pass "approved through group:lapsapproved: kept" || fail "group approval did not keep the admin"
defaults write "$DOMAIN" ApprovedAdmins -array "${RUNNER_ADMINS[@]}"
dseditgroup -o delete lapsapproved >/dev/null 2>&1
sysadminctl -deleteUser "$EXTRA" >/dev/null 2>&1
echo "::endgroup::"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------------------------------------- ###
### | -uninstall keeps the password, uninstall.sh | ###
### ----------------------------------------------- ###
### --purge removes it.                                                     ###
echo "::group::-uninstall keeps the password, uninstall.sh --purge removes it"
KEPT=$(get_pw 2>/dev/null)
cp "$APP/Contents/Resources/uninstall.sh" /tmp/laps-uninstall.sh
"$LAPS" -uninstall && pass "-uninstall exited 0" || fail "-uninstall failed"
[ ! -e "$APP" ] && [ ! -e "$LAPS" ] && [ ! -L "$LAPS" ] && [ ! -e /etc/paths.d/laps ] && [ ! -e "$PLIST" ] \
    && pass "app, symlink, paths.d and LaunchDaemon removed" || fail "files left after -uninstall: $(ls -d "$APP" "$LAPS" /etc/paths.d/laps "$PLIST" 2>/dev/null | tr '\n' ' ')"
launchctl print system/$LABEL >/dev/null 2>&1 && fail "LaunchDaemon still loaded after -uninstall" || pass "LaunchDaemon unloaded"
launchctl print system/com.joshua-d-miller.macoslaps-service >/dev/null 2>&1 && fail "service still loaded after -uninstall" || pass "service unloaded"
[ ! -e /Library/LaunchDaemons/com.joshua-d-miller.macoslaps-service.plist ] && [ ! -e "$REQ" ] && pass "service plist and request folder removed" || fail "service files left after -uninstall"
[ -z "$(pkgutil --pkgs | grep -i laps)" ] && pass "receipts forgotten" || fail "receipts left: $(pkgutil --pkgs | grep -i laps | tr '\n' ' ')"
security find-generic-password -s "$KCSVC" "$SYSKC" >/dev/null 2>&1 && pass "stored password kept without -purge" || fail "-uninstall deleted the stored password"
dscl . -authonly "$ACCT" "$KEPT" >/dev/null 2>&1 && pass "account untouched by -uninstall" || fail "account changed by -uninstall"
bash /tmp/laps-uninstall.sh --purge && pass "uninstall.sh --purge exited 0" || fail "uninstall.sh --purge failed"
security find-generic-password -s "$KCSVC" "$SYSKC" >/dev/null 2>&1 && fail "stored password left after --purge" || pass "stored password deleted by --purge"
[ ! -e /var/db/macoslaps ] && pass "state removed by --purge" || fail "/var/db/macoslaps left after --purge"
echo "::endgroup::"

echo "----"
if [ "$FAILURES" -gt 0 ]; then
    echo "::error::$FAILURES check(s) failed on $(sw_vers -productVersion)"
    exit 1
fi
echo "All checks passed on $(sw_vers -productVersion)"
