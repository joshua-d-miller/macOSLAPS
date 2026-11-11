#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | CI | check-style.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Updated:   2026-11-11

 Purpose:
     Every code file opens with the project's header (what it's for, who
     wrote it, and its changelog), and its header, divider and box lines
     fit in 79 columns. Files not converted yet are listed in
     .github/style-pending.txt; that list only shrinks.

 Usage:
     bash .github/scripts/check-style.sh
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------- ###
### | Which files | ###
### --------------- ###
### Swift, shell and zsh files tracked by git, minus the pending list.      ###
cd "$(dirname "$0")/../.." || exit 2
PENDING=.github/style-pending.txt
FAILURES=0
mapfile -t FILES < <(git ls-files '*.swift' '*.sh' '*.zsh' 'packaging/*-scripts/*' | grep -vxFf <(grep -v '^#' "$PENDING" | sed '/^$/d'))

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------- ###
### | Header | ###
### ---------- ###
### The title line, Version, Author, Updated and CHANGELOG must be in the   ###
### first 200 lines.                                                        ###
for f in "${FILES[@]}"; do
    top=$(head -200 "$f")
    for pattern in '^ macOSLAPS \| ' '^ Version: {3}[0-9]+\.[0-9]+\.[0-9]+$' '^ Author: {4}[^ ]' \
                   '^ Updated: {3}[0-9]{4}-[0-9]{2}-[0-9]{2}$' '^ CHANGELOG$'; do
        grep -Eq "$pattern" <<< "$top" || { echo "::error file=$f::header is missing /$pattern/"; FAILURES=$((FAILURES + 1)); }
    done
done

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### -------------- ###
### | 79 columns | ###
### -------------- ###
### Header lines, ### / // boxes and :::: dividers.                         ###
for f in "${FILES[@]}"; do
    awk -v f="$f" '
        /^===/ || /^ [A-Za-z]/ && NR < 200 && in_header { if (length($0) > 79) bad = 1 }
        /^: <<.HEADER.$/ || /^\/\*$/ { in_header = 1 }
        /^HEADER$/ || /^\*\/$/ { in_header = 0 }
        /(###|\/\/)$/ || /^[[:space:]]*(#|\/\/) :::::::::/ { if (length($0) > 79) bad = 1 }
        bad { printf "::error file=%s,line=%d::longer than 79 columns\n", f, NR; bad = 0; errors++ }
        END { exit errors > 0 }' "$f" || FAILURES=$((FAILURES + 1))
done

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------- ###
### | Pending list | ###
### ---------------- ###
### Every listed file must still exist, so the list can't hide renamed      ###
### files.                                                                  ###
while read -r f; do
    [[ -z "$f" || "$f" == \#* ]] && continue
    [ -e "$f" ] || { echo "::error::$PENDING lists $f, which doesn't exist"; FAILURES=$((FAILURES + 1)); }
done < "$PENDING"

echo "Checked ${#FILES[@]} files; $(grep -cv '^#\|^$' "$PENDING") still pending."
[ "$FAILURES" -eq 0 ]
