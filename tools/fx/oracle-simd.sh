#!/usr/bin/env bash
# oracle-simd.sh - run tools/fx/oracle.sh for every effect with each of fx's
# motion/RNG kernel choices: the widest the CPU runs, TTFX_NO_AVX512=1 and
# both TTFX_NO_AVX512=1/TTFX_NO_AVX2=1, at most JOBS (default 4)
# oracles at a time. Pass THREADS=1 to run fx single-threaded.
# Renderer dispatch is CPU-based; qemu-oracle.sh checks its baseline path.
#
# Usage: tools/fx/oracle-simd.sh [quick|full] [widest|no-avx512|no-avx2 ...]
# With no kernel arguments, run all three. CI selects one per matrix job.
# ORACLE_SHARD=N/M selects one of M disjoint effect groups (default 1/1).
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
MODE="${1:-quick}"
[ "$#" -eq 0 ] || shift
kernels=("$@")
[ "${#kernels[@]}" -gt 0 ] || kernels=(widest no-avx512 no-avx2)
for kernel in "${kernels[@]}"; do
    case "$kernel" in
        widest|no-avx512|no-avx2) ;;
        *) echo "Unknown SIMD choice: $kernel" >&2; exit 2 ;;
    esac
done
JOBS="${JOBS:-4}"
TMPROOT="${ORACLE_TMP:-$ROOT/target/oracle-tmp}"
mkdir -p "$TMPROOT" || exit 2
LOGS="$(mktemp -d "$TMPROOT/simd.XXXXXX")" || exit 2
trap 'rm -rf "$LOGS"' EXIT
effects=()
for source in "$ROOT"/src/fx/effects/*.rs; do
    [ -f "$source" ] || continue
    effect="${source##*/}"
    [ "$effect" = mod.rs ] || effects+=("${effect%.rs}")
done
[ "${#effects[@]}" -gt 0 ] || { echo "No effects found" >&2; exit 2; }

# Split the sorted effect list deterministically, without dropping any cases.
if [[ ! "${ORACLE_SHARD:-1/1}" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
    echo "ORACLE_SHARD must be N/M, with 1 <= N <= M" >&2
    exit 2
fi
shard="${BASH_REMATCH[1]}"
shards="${BASH_REMATCH[2]}"
if ! [ "$shard" -le "$shards" ] || ! [ "$shards" -le "${#effects[@]}" ]; then
    echo "ORACLE_SHARD must select a nonempty group of the available effects" >&2
    exit 2
fi
selected=()
for ((i = shard - 1; i < ${#effects[@]}; i += shards)); do
    selected+=("${effects[i]}")
done
effects=("${selected[@]}")

# An inherited override must not turn this into a reference/reference test or
# prevent the widest pass from exercising the runner's available kernels.
unset TTFX_FX TTFX_NO_AVX512 TTFX_NO_AVX2

status=0
for kernel in "${kernels[@]}"; do
    case "$kernel" in
    widest) env=() ;;
    no-avx512) env=(TTFX_NO_AVX512=1) ;;
    no-avx2) env=(TTFX_NO_AVX512=1 TTFX_NO_AVX2=1) ;;
    esac
    [ "${THREADS:-}" = 1 ] && env+=(TTFX_THREADS=1)
    if ! printf '%s\n' "${effects[@]}" |
        xargs -P "$JOBS" -I{} env "${env[@]}" "$ROOT/tools/fx/oracle.sh" {} "$MODE" 2>&1 |
        tee "$LOGS/$kernel.log"; then
        status=1
    fi
    total=$(grep -c '^oracle ' "$LOGS/$kernel.log")
    bad=$(grep '^oracle ' "$LOGS/$kernel.log" | grep -vc ' 0 failed')
    echo "$kernel: $((total - bad))/${#effects[@]} effects pass ($MODE; $total completed; shard $shard/$shards)"
    [ "$bad" -eq 0 ] && [ "$total" -eq "${#effects[@]}" ] || status=1
done
exit $status
