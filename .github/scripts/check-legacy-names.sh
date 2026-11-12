#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | check-legacy-names.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     The project moved from Penn State's edu.psu identifiers to
     com.joshua-d-miller.macoslaps in 4.0. The old names may only appear
     where they are still needed: migration, the legacy preference domain,
     the helper's signing identity, cleanup of old installs, tests of
     those, and the credit to Penn State. Each allowed file is listed in
     .github/legacy-names-allowlist.txt with the reason; anything else
     fails.

 Usage:
     bash .github/scripts/check-legacy-names.sh
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
### ---------- ###
### | Search | ###
### ---------- ###
### Tracked files that mention edu.psu, psu.edu or Penn State, minus the    ###
### allowlist.                                                              ###

cd "$(dirname "$0")/../.." || exit 2
ALLOW=.github/legacy-names-allowlist.txt
FAILURES=0
while IFS= read -r f; do
    grep -qxF "$f" <(sed -e 's/[[:space:]]*#.*$//' -e '/^$/d' "$ALLOW") && continue
    while IFS= read -r hit; do
        echo "::error file=$f::legacy name: $hit"
        FAILURES=$((FAILURES + 1))
    done < <(grep -niE 'edu\.psu|psu\.edu|penn ?state' "$f" | cut -c1-120)
done < <(git grep -liE 'edu\.psu|psu\.edu|penn ?state' -- . ":!$ALLOW")

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------- ###
### | Stale allowlist entries | ###
### --------------------------- ###
### An allowed file that no longer mentions a legacy name is removed from   ###
### the list.                                                               ###

while IFS= read -r f; do
    [ -f "$f" ] && grep -qiE 'edu\.psu|psu\.edu|penn ?state' "$f" && continue
    echo "::error file=$ALLOW::$f no longer needs to be allowed; remove it"
    FAILURES=$((FAILURES + 1))
done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^$/d' "$ALLOW")
echo "Legacy names: $FAILURES problem(s)."
[ "$FAILURES" -eq 0 ]
