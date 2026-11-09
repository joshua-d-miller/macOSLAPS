#!/bin/bash
# macOSLAPS smoke test for GitHub-hosted macOS runners. Run as root:
#   sudo bash .github/scripts/smoke-test.sh
#
# Exercises Local mode end to end on a throwaway admin account:
# first rotation, -getPassword export via `security`, export cleanup,
# forced rotation, old password invalidated, and repeated generator checks.
# The secureToken path is only exercised if the runner happens to grant
# the test account a token; otherwise it needs community testing.
set -uo pipefail

LAPS=/usr/local/laps/macOSLAPS
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

echo "::group::Environment"
sw_vers
uname -m
"$LAPS" -version || fatal "binary does not run"
codesign -dv --verbose=2 "$LAPS" 2>&1 | grep -E "Identifier|Authority|Signature|flags" || true
echo "::endgroup::"

# Stop the daemon the pkg loaded so it can't race the test.
launchctl bootout system/edu.psu.macoslaps-check 2>/dev/null || true

echo "::group::Create test admin and config"
sysadminctl -addUser "$ACCT" -fullName "LAPS Test" -password "$FIRST" -admin 2>&1
TOKEN=$(sysadminctl -secureTokenStatus "$ACCT" 2>&1)
echo "$TOKEN"
if echo "$TOKEN" | grep -q ENABLED; then HAS_TOKEN=1; else HAS_TOKEN=0; fi
defaults write "$DOMAIN" LocalAdminAccount -string "$ACCT"
defaults write "$DOMAIN" Method -string Local
defaults write "$DOMAIN" FirstPass -string "$FIRST"
defaults write "$DOMAIN" PasswordLength -int "$LEN"
defaults write "$DOMAIN" DaysTillExpiration -int 30
defaults write "$DOMAIN" RemovePassChars -string "$EXCLUDED"
defaults read "$DOMAIN"
echo "::endgroup::"

get_pw() {
    "$LAPS" -getPassword >&2 || return 1
    SVC=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
    security find-generic-password -w -s "$SVC" "$SYSKC"
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

echo "::group::First rotation (FirstPass from preferences)"
"$LAPS" -resetPassword && pass "first rotation exited 0" || fail "first rotation failed"
PW1=$(get_pw) || fail "-getPassword failed after first rotation"
check_pw "${PW1:-}" "rotation 1"
dscl . -authonly "$ACCT" "$FIRST" >/dev/null 2>&1 && fail "FirstPass still works after rotation" || pass "FirstPass no longer works"
echo "::endgroup::"

echo "::group::Export item is removed on next run"
SVC=$(tr -d '\n' < /var/root/.GeneratedLAPSServiceName)
"$LAPS"
security find-generic-password -s "$SVC" "$SYSKC" >/dev/null 2>&1 \
    && fail "exported keychain item $SVC still present" || pass "exported keychain item removed"
echo "::endgroup::"

echo "::group::Forced rotation invalidates previous password"
"$LAPS" -resetPassword && pass "forced rotation exited 0" || fail "forced rotation failed"
PW2=$(get_pw) || fail "-getPassword failed after forced rotation"
check_pw "${PW2:-}" "rotation 2"
[ "${PW1:-x}" != "${PW2:-x}" ] && pass "password changed" || fail "password did not change"
dscl . -authonly "$ACCT" "${PW1:-}" >/dev/null 2>&1 && fail "previous password still works" || pass "previous password invalidated"
echo "::endgroup::"

echo "::group::Generator: $ROUNDS rotations"
for i in $(seq 1 "$ROUNDS"); do
    "$LAPS" -resetPassword >/dev/null 2>&1 || { fail "rotation $i failed"; continue; }
    PW=$(get_pw 2>/dev/null) || { fail "export $i failed"; continue; }
    check_pw "$PW" "round $i" > /tmp/laps-round.log
    grep -v '^PASS' /tmp/laps-round.log || true
done
echo "::endgroup::"

if [ "$HAS_TOKEN" -eq 1 ]; then
    echo "::group::secureToken: -firstPass on the command line (after -resetPassword)"
    KNOWN='Known-Pass-5678'
    CUR=$(get_pw)
    dscl . -passwd "/Users/$ACCT" "$CUR" "$KNOWN" || fail "could not set known password"
    security delete-generic-password -s macOSLAPS "$SYSKC" >/dev/null 2>&1
    defaults delete "$DOMAIN" FirstPass
    "$LAPS" -resetPassword -firstPass "$KNOWN" && pass "CLI -firstPass rotation exited 0" || fail "CLI -firstPass rotation failed"
    PW3=$(get_pw) && check_pw "$PW3" "cli firstPass"
    echo "::endgroup::"
else
    echo "::notice::Test account has no secureToken on this runner; secureToken path needs community testing."
fi

echo "----"
if [ "$FAILURES" -gt 0 ]; then
    echo "::error::$FAILURES check(s) failed on $(sw_vers -productVersion)"
    exit 1
fi
echo "All checks passed on $(sw_vers -productVersion)"
