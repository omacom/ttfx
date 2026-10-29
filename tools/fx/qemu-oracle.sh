#!/usr/bin/env bash
# qemu-oracle.sh - run both engines on an emulated older CPU (qemu-user) and
# compare them, to show that fx's run-time kernel choice only uses what the
# CPU has and gives the same bytes on every path.
#
# Usage: tools/fx/qemu-oracle.sh [cpu ...]      (default: qemu64 Nehalem Haswell)
#
# qemu64 is x86-64 v1 (SSE2 only), Nehalem v2, Haswell v3 (AVX2). QEMU's TCG
# has no AVX-512, so fx's AVX-512 kernels only run natively. Each effect runs
# a reduced case set (both engines under the same emulated CPU, so glibc's
# libm picks the same variants for both); the full oracle runs natively
# (oracle.sh, oracle-simd.sh). JOBS sets the parallelism (default 6).
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BIN="${BIN:-$ROOT/target/release/ttfx}"
JOBS="${JOBS:-6}"
CPUS=("$@")
[ ${#CPUS[@]} -eq 0 ] && CPUS=(qemu64 Nehalem Haswell)
command -v qemu-x86_64 >/dev/null || { echo "qemu-x86_64 not found (pacman -S qemu-user)" >&2; exit 2; }
[ -x "$BIN" ] || { echo "Build ttfx first: cargo build --release" >&2; exit 2; }
# The emulated CPU must choose its own kernels regardless of the host's shell.
unset TTFX_NO_AVX512 TTFX_NO_AVX2

TMPROOT="${ORACLE_TMP:-$ROOT/target/oracle-tmp}"
mkdir -p "$TMPROOT" || exit 2
WORK="$(mktemp -d "$TMPROOT/qemu.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

printf 'Hello, World!\nThis is ttfx.' > "$WORK/basic"
printf 'héllo wörld ▓▒░\n日本語テキスト\n😀 emoji\n' > "$WORK/unicode"
printf '\e[31mred\e[0m plain \e[1;92mbright\e[0m\n\e[38;5;208morange\e[48;5;17m navy\e[0m\n\e[38;2;10;200;30mtrue\e[m end\n' > "$WORK/ansi"
python3 - "$WORK/medium" <<'PY'
import sys
line = ('The quick brown fox jumps over the lazy dog 0123456789 ' * 2)[:70]
open(sys.argv[1], 'w').write('\n'.join(line for _ in range(12)))
PY

run_effect() {
    local cpu="$1" effect="$2" pass=0 fail=0 global=() opts=""
    local cases="$ROOT/tools/fx/cases/$effect.txt" q=(qemu-x86_64 -cpu "$cpu")
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
        TTFX_FX=0 "${q[@]}" "$BIN" "${global[@]}" "$@" < "$WORK/$input" > "$w.r" 2> "$w.re"; local rs=$?
        TTFX_FX=force "${q[@]}" "$BIN" "${global[@]}" "$@" < "$WORK/$input" > "$w.a" 2> "$w.ae"; local as=$?
        grep -v '^qemu-x86_64: warning' "$w.re" > "$w.re2"; grep -v '^qemu-x86_64: warning' "$w.ae" > "$w.ae2"
        # These are successful-animation cases, so matching crashes/errors or
        # empty output are failures, too. force also rejects a silent fallback.
        if [ $rs -eq 0 ] && [ $as -eq 0 ] && [ -s "$w.r" ] && [ -s "$w.a" ] &&
            cmp -s "$w.r" "$w.a" && cmp -s "$w.re2" "$w.ae2"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1)); echo "FAIL $cpu $effect: $input $* (exit rust=$rs fx=$as)"
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
    echo "qemu $cpu $effect: $pass passed, $fail failed"
}
export -f run_effect
export ROOT BIN WORK

effects=()
for source in "$ROOT"/src/fx/effects/*.rs; do
    [ -f "$source" ] || continue
    effect="${source##*/}"
    [ "$effect" = mod.rs ] || effects+=("${effect%.rs}")
done
[ "${#effects[@]}" -gt 0 ] || { echo "No effects found" >&2; exit 2; }
status=0
for cpu in "${CPUS[@]}"; do
    out=$(for effect in "${effects[@]}"; do printf '%s %s\n' "$cpu" "$effect"; done |
        xargs -P "$JOBS" -L1 bash -c 'run_effect "$0" "$1"') || status=1
    echo "$out"
    bad=$(echo "$out" | grep -c '^qemu .* [1-9][0-9]* failed')
    total=$(echo "$out" | grep -c '^qemu ')
    echo "$cpu: $((total - bad))/${#effects[@]} effects pass ($total completed)"
    [ "$bad" -eq 0 ] && [ "$total" -eq "${#effects[@]}" ] || status=1
done
exit $status
