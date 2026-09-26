#!/usr/bin/env bash
# qemu-oracle.sh - run both engines on an emulated older CPU (qemu-user) and
# compare them, to show that each tier's code only uses what its CPU has and
# that the tier is picked automatically.
#
# Usage: tools/asm/qemu-oracle.sh [cpu ...]      (default: qemu64 Nehalem Haswell)
#
# qemu64 is x86-64 v1 (tier 1), Nehalem v2 (tier 2), Haswell v3 (tier 3). QEMU's
# TCG has no AVX-512, so tier 4 can only run natively. Each effect runs a
# reduced case set (both engines under the same emulated CPU, so glibc's libm
# picks the same variants for both); the full oracle runs natively with
# TTFX_ASM_TIER (oracle-tiers.sh). JOBS sets the parallelism (default 6).
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BIN="${BIN:-$ROOT/target/release/ttfx}"
JOBS="${JOBS:-6}"
CPUS=("$@")
[ ${#CPUS[@]} -eq 0 ] && CPUS=(qemu64 Nehalem Haswell)
command -v qemu-x86_64 >/dev/null || { echo "qemu-x86_64 not found (pacman -S qemu-user)" >&2; exit 2; }

TMPROOT="${ORACLE_TMP:-$ROOT/target/oracle-tmp}"
mkdir -p "$TMPROOT"
WORK="$(mktemp -d "$TMPROOT/qemu.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf 'Hello, World!\nThis is ttfx.' > "$WORK/basic"
printf 'héllo wörld ▓▒░\n日本語テキスト\n😀 emoji\n' > "$WORK/unicode"
printf '\e[31mred\e[0m plain \e[1;92mbright\e[0m\n\e[38;5;208morange\e[48;5;17m navy\e[0m\n\e[38;2;10;200;30mtrue\e[m end\n' > "$WORK/ansi"
python3 - "$WORK/medium" <<'PY'
import sys
line = ('The quick brown fox jumps over the lazy dog 0123456789 ' * 2)[:70]
open(sys.argv[1], 'w').write('\n'.join(line for _ in range(12)))
PY

expect_tier() {
    case "$1" in qemu64) echo 1 ;; Nehalem|Westmere) echo 2 ;; *) echo 3 ;; esac
}

run_effect() {
    local cpu="$1" effect="$2" pass=0 fail=0 global=() opts=""
    local cases="$ROOT/tools/asm/cases/$effect.txt" q=(qemu-x86_64 -cpu "$cpu")
    if [ -f "$cases" ]; then
        local line
        while IFS= read -r line; do
            case "$line" in ''|'#'*) ;; '@global '*) read -ra global <<< "${line#@global }" ;;
                *) [ -z "$opts" ] && opts="$line" ;; esac
        done < "$cases"
    fi
    local w="$WORK/$cpu.$effect"
    check() {
        local input="$1"; shift
        TTFX_ASM=0 "${q[@]}" "$BIN" "${global[@]}" "$@" < "$WORK/$input" > "$w.r" 2> "$w.re"; local rs=$?
        TTFX_ASM=force "${q[@]}" "$BIN" "${global[@]}" "$@" < "$WORK/$input" > "$w.a" 2> "$w.ae"; local as=$?
        grep -v '^qemu-x86_64: warning' "$w.re" > "$w.re2"; grep -v '^qemu-x86_64: warning' "$w.ae" > "$w.ae2"
        if [ $rs -eq $as ] && cmp -s "$w.r" "$w.a" && cmp -s "$w.re2" "$w.ae2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1)); echo "FAIL $cpu $effect: $input $* (exit rust=$rs asm=$as)"
        fi
    }
    # shellcheck disable=SC2086
    for seed in 1 2; do
        check basic --seed $seed --frame-rate 0 "$effect"
        check unicode --seed $seed --frame-rate 0 "$effect" $opts
        check medium --seed $seed --parity-dump --canvas-width 80 --canvas-height 16 --ignore-terminal-dimensions "$effect"
        check ansi --seed $seed --frame-rate 0 --existing-color-handling dynamic "$effect"
    done
    check medium --seed 3 --frame-rate 0 --xterm-colors --canvas-width 40 --canvas-height 10 --wrap-text "$effect"
    check ansi --seed 3 --frame-rate 0 --existing-color-handling always --no-color "$effect"
    # the tier the engine picked on this CPU
    local tier
    tier=$(printf 'x' | TTFX_ASM_SHOW_TIER=1 TTFX_ASM=force "${q[@]}" "$BIN" "${global[@]}" --frame-rate 0 "$effect" 2>&1 >/dev/null |
           sed -n 's/^ttfx: asm engine tier //p')
    if [ "$tier" != "$(expect_tier "$cpu")" ]; then
        fail=$((fail + 1)); echo "FAIL $cpu $effect: picked tier '${tier}', expected $(expect_tier "$cpu")"
    fi
    echo "qemu $cpu $effect: $pass passed, $fail failed"
}
export -f run_effect expect_tier
export ROOT BIN WORK

effects=$(ls "$ROOT"/asm/effects/*.asm | xargs -n1 basename | sed 's/\.asm$//' | grep -vx registry)
status=0
for cpu in "${CPUS[@]}"; do
    out=$(for e in $effects; do echo "$cpu $e"; done | xargs -P "$JOBS" -L1 bash -c 'run_effect "$0" "$1"')
    echo "$out" | grep '^FAIL'
    bad=$(echo "$out" | grep -c '^qemu .* [1-9][0-9]* failed')
    total=$(echo "$out" | grep -c '^qemu ')
    echo "$cpu (tier $(expect_tier "$cpu")): $((total - bad))/$total effects pass"
    [ "$bad" -eq 0 ] || status=1
done
exit $status
