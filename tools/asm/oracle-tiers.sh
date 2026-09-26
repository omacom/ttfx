#!/usr/bin/env bash
# oracle-tiers.sh - run tools/asm/oracle.sh for every effect at every CPU tier
# (TTFX_ASM_TIER=1..4), at most JOBS (default 4) oracles at a time.
#
# Usage: tools/asm/oracle-tiers.sh [quick|full] [tier ...]
#
# A tier the binary does not have (left out by build.rs, or above this CPU)
# is reported and skipped. Build with TTFX_ASM_UNCHECKED_TIERS=1 to check the
# lower tiers' output before every file is tier-clean.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
MODE="${1:-quick}"
shift || true
TIERS="${*:-1 2 3 4}"
JOBS="${JOBS:-4}"
LOGS="$ROOT/target/oracle-tiers"
mkdir -p "$LOGS"
EFFECTS=$(cd "$ROOT/asm/effects" && ls *.asm | sed 's/\.asm$//' | grep -vx registry)

status=0
for tier in $TIERS; do
    rm -f "$LOGS/$tier-"*.log
    for effect in $EFFECTS; do echo "$tier $effect"; done
done | xargs -P "$JOBS" -L 1 sh -c '
    TTFX_ASM_TIER=$3 "$1/tools/asm/oracle.sh" "$4" "$0" > "$2/$3-$4.log" 2>&1
    tail -1 "$2/$3-$4.log"
' "$MODE" "$ROOT" "$LOGS"

for tier in $TIERS; do
    passed=0; failed=0; missing=0
    for effect in $EFFECTS; do
        log="$LOGS/$tier-$effect.log"
        if grep -q "is not available" "$log" 2>/dev/null; then
            missing=1; continue
        fi
        if tail -1 "$log" | grep -q ", 0 failed$"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1)); status=1
            echo "tier $tier $effect: $(tail -1 "$log")"
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "tier $tier: not available in this binary ($(grep -h "is not available" "$LOGS/$tier-"*.log | head -1 | sed 's/.*available: //'))"
    else
        echo "tier $tier: $passed/$(echo $EFFECTS | wc -w) effects pass ($MODE)"
    fi
done
exit $status
