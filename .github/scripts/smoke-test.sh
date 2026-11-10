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

echo "::group::-stageMigration hands the current password to the next version"
CURRENT=$(get_pw)
"$LAPS" -stageMigration && pass "-stageMigration exited 0" || fail "-stageMigration failed"
if [ -f /var/root/.macOSLAPS-migration ]; then
    STAGE=$(tr -d '\n' < /var/root/.macOSLAPS-migration)
    STAGED=$(security find-generic-password -w -s "$STAGE" "$SYSKC" 2>/dev/null)
    [ "$STAGED" = "$CURRENT" ] && pass "staged password readable via /usr/bin/security and current" \
        || fail "staged password missing or does not match current password"
    security delete-generic-password -s "$STAGE" "$SYSKC" >/dev/null 2>&1
    rm -f /var/root/.macOSLAPS-migration
else
    fail "-stageMigration did not write /var/root/.macOSLAPS-migration"
fi
echo "::endgroup::"

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

echo "::group::-status"
ST=$("$LAPS" -status)
echo "$ST"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accountExists"] and d["accountIsAdmin"] and d["passwordStored"] and d["passwordVerifies"], d' "$ST" \
  && pass "-status JSON reports a working stored password" || fail "-status JSON unexpected: $ST"
"$LAPS" -status -v | tee /tmp/laps-status.txt
grep -q "The stored password works" /tmp/laps-status.txt && pass "-status -v checklist" || fail "-status -v missing checks"
echo "::endgroup::"

echo "::group::-escrow (plaintext)"
CUR=$(get_pw)
ESC=$("$LAPS" -escrow)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2] and d["verified"] and d["account"]==sys.argv[3], d' "$ESC" "$CUR" "$ACCT" \
  && pass "-escrow plaintext JSON has the current, verified password" || fail "-escrow plaintext unexpected"
echo "::endgroup::"

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
    "$OPENSSL" cms -cmsout -print -inform PEM -in "$T/escrow.pem" | grep -A2 -i "contentEncryptionAlgorithm" | sed -n '1,3p'
    DEC=$("$OPENSSL" cms -decrypt -inform PEM -in "$T/escrow.pem" -recip "$T/c.pem" -inkey "$T/k.pem" 2>&1)
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["password"]==sys.argv[2], d' "$DEC" "$CUR" \
      && pass "CMS escrow decrypts with the admin key to the current password" || fail "CMS decrypt failed: $DEC"
    "$LAPS" -status | grep -q '"escrow":"cms"' && pass "-status reports CMS escrow" || fail "-status escrow mode"
    defaults delete "$DOMAIN" EscrowCertificates
    rm -rf "$T"
fi
echo "::endgroup::"

echo "::group::-initialize (#88): adopt current password without rotating"
INIT='Init-Pass-2468'
dscl . -passwd "/Users/$ACCT" "$INIT"
if "$LAPS" -firstPass 'Not-The-Password' -initialize >/dev/null 2>&1; then fail "-initialize accepted a wrong password"; else pass "-initialize rejects a wrong password"; fi
"$LAPS" -firstPass "$INIT" -initialize && pass "-initialize succeeded" || fail "-initialize failed"
[ "$(get_pw)" = "$INIT" ] && pass "stored password is the initialized one" || fail "stored password not the initialized one"
dscl . -authonly "$ACCT" "$INIT" >/dev/null 2>&1 && pass "account not rotated by -initialize" || fail "account was rotated"
"$LAPS" >/dev/null 2>&1
[ "$(get_pw)" = "$INIT" ] && pass "scheduled run does not rotate before expiry" || fail "scheduled run rotated early"
echo "::endgroup::"

echo "::group::InventoryHook custom"
rm -f /tmp/laps-hook-ran
defaults write "$DOMAIN" InventoryHook -string custom
defaults write "$DOMAIN" InventoryHookCommand -array /usr/bin/touch /tmp/laps-hook-ran
"$LAPS" -resetPassword >/dev/null 2>&1 && [ -f /tmp/laps-hook-ran ] && pass "custom hook ran after rotation" || fail "custom hook did not run"
defaults delete "$DOMAIN" InventoryHook; defaults delete "$DOMAIN" InventoryHookCommand
echo "::endgroup::"

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
