#!/usr/bin/env bash
# Byte-for-byte comparison of the assembly engine against the Rust engine in
# the same binary (plan §9.2): TTFX_ASM=0 runs Rust, TTFX_ASM=force runs the
# assembly engine and fails loudly if it declines. stdout, stderr and the exit
# status must all match.
#
# Usage: tools/asm/oracle.sh <effect> [quick|full]
#
# Effect-specific option sets live in tools/asm/cases/<effect>.txt, one
# argument list per line (blank lines and # comments ignored); each runs with
# several seeds and inputs in addition to the effect's defaults. A line
# "@global <args>" adds global arguments to every run (e.g. --virtual-clock
# for effects that read the clock, whose real-clock output is not
# reproducible).
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BIN="${BIN:-$ROOT/target/release/ttfx}"
EFFECT="${1:?usage: oracle.sh <effect> [quick|full]}"
MODE="${2:-quick}"
# Parity dumps get large and many oracles run at once: keep the scratch files
# on disk, not in a tmpfs /tmp that can fill up and truncate them.
TMPROOT="${ORACLE_TMP:-$ROOT/target/oracle-tmp}"
mkdir -p "$TMPROOT"
WORK="$(mktemp -d "$TMPROOT/run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# inputs
printf 'Hello, World!\nThis is ttfx.' > "$WORK/basic"
printf '\tTabbed\tline\n  indented   \n\n\ntrailing blank lines\n\n' > "$WORK/tabs"
printf 'abc\rX\nover\rwritten\r\n' > "$WORK/carriage"
printf 'héllo wörld ▓▒░\n日本語テキスト\n😀 emoji\n' > "$WORK/unicode"
printf 'x' > "$WORK/single"
printf '   \n  a\n' > "$WORK/leading"
python3 - "$WORK/big" <<'PY'
import sys
line = ('The quick brown fox jumps over the lazy dog 0123456789 ' * 4)[:190]
open(sys.argv[1], 'w').write('\n'.join(line for _ in range(46)))
PY
python3 - "$WORK/ragged" <<'PY'
import sys
lines = ['#' * (i * 7 % 23) + ' ' * (i % 3) + 'x' for i in range(14)]
open(sys.argv[1], 'w').write('\n'.join(lines))
PY
# ANSI input: 16/256/truecolor SGR, bold/reset, cursor motion, OSC titles
# and the supported private modes
printf '\e[31mred\e[0m plain \e[1;92mbright\e[39m bold\e[0m\n\e[38;5;208morange\e[48;5;17m on navy\e[0m\n\e[38;2;10;200;30mtrue\e[48;2;90;0;90mcolor\e[m\e]0;title\a end\n\e[?25l\e[2Cshift\e[1Dx\e[?25h\e[?7l tail\e[?7h\n\e[44m   \e[0m spaces\n' > "$WORK/ansi"
printf 'plain \e[7mreverse?\e[0m\n' > "$WORK/ansi-odd"
printf 'bad \e[5n sequence\n' > "$WORK/ansi-bad"

# A full disk leaves generated inputs empty, and then both engines fail the
# same way and every case "passes". Refuse to run on broken inputs.
for f in "$WORK"/*; do
    if [ ! -s "$f" ]; then
        echo "oracle: input $(basename "$f") is empty - is the scratch disk full?" >&2
        exit 2
    fi
done

pass=0
fail=0
global=()
check() {
    local name="$1"; shift
    local input="$1"; shift
    TTFX_ASM=0 "$BIN" "${global[@]}" "$@" < "$input" > "$WORK/r.out" 2> "$WORK/r.err"; local rs=$?
    TTFX_ASM=force "$BIN" "${global[@]}" "$@" < "$input" > "$WORK/a.out" 2> "$WORK/a.err"; local as=$?
    if [ $rs -eq $as ] && cmp -s "$WORK/r.out" "$WORK/a.out" && cmp -s "$WORK/r.err" "$WORK/a.err"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $name: $* (exit rust=$rs asm=$as)"
        cmp "$WORK/r.out" "$WORK/a.out" 2>&1 | head -1
        diff <(head -c 600 "$WORK/r.err") <(head -c 600 "$WORK/a.err") | head -6
    fi
}

seeds="1 2 3"
inputs="basic tabs unicode big"
if [ "$MODE" = full ]; then
    seeds="$(seq 1 12)"
    inputs="basic tabs carriage unicode single leading big ragged"
fi
big_canvas=(--canvas-width 200 --canvas-height 50 --ignore-terminal-dimensions)

# the effect's own option sets
options=("")
if [ -f "$ROOT/tools/asm/cases/$EFFECT.txt" ]; then
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; '@global '*) read -ra global <<< "${line#@global }"; continue ;; esac
        options+=("$line")
    done < "$ROOT/tools/asm/cases/$EFFECT.txt"
fi

for opts in "${options[@]}"; do
    # shellcheck disable=SC2086
    for input in $inputs; do
        for seed in $seeds; do
            extra=()
            [ "$input" = big ] && extra=("${big_canvas[@]}")
            check "$input [$opts]" "$WORK/$input" --seed "$seed" --frame-rate 0 "${extra[@]}" "$EFFECT" $opts
            check "$input/dump [$opts]" "$WORK/$input" --seed "$seed" --parity-dump "${extra[@]}" "$EFFECT" $opts
        done
    done
done

# terminal options, with the effect's defaults
for anchor in n ne e se s sw w nw c; do
    check "anchor-canvas=$anchor" "$WORK/basic" --seed 4 --frame-rate 0 --anchor-canvas "$anchor" --canvas-width 30 --canvas-height 6 "$EFFECT"
    check "anchor-text=$anchor" "$WORK/basic" --seed 4 --frame-rate 0 --anchor-text "$anchor" --canvas-width 30 --canvas-height 6 --ignore-terminal-dimensions "$EFFECT"
    COLUMNS=24 LINES=5 check "clipped=$anchor" "$WORK/tabs" --seed 5 --frame-rate 0 --anchor-canvas "$anchor" --anchor-text "$anchor" "$EFFECT"
done
check small-canvas "$WORK/big" --seed 6 --frame-rate 0 --canvas-width 20 --canvas-height 4 "$EFFECT"
check zero-canvas "$WORK/basic" --seed 6 --frame-rate 0 --canvas-width 0 --canvas-height 0 "$EFFECT"
COLUMNS=10 LINES=3 check env-dims "$WORK/big" --seed 7 --frame-rate 0 "$EFFECT"
check no-color "$WORK/basic" --seed 8 --frame-rate 0 --no-color "$EFFECT"
check xterm-colors "$WORK/basic" --seed 8 --frame-rate 0 --xterm-colors "$EFFECT"
check tab-width "$WORK/tabs" --seed 10 --frame-rate 0 --tab-width 3 "$EFFECT"
check no-eol "$WORK/basic" --seed 11 --frame-rate 0 --no-eol --no-restore-cursor "$EFFECT"
check reuse "$WORK/basic" --seed 12 --frame-rate 0 --reuse-canvas "$EFFECT"
check max-frames "$WORK/basic" --seed 13 --parity-dump --max-frames 5 "$EFFECT"
check virtual-clock "$WORK/basic" --seed 14 --frame-rate 0 --virtual-clock "$EFFECT"
for seed in 1 2 3; do
    for handling in ignore always dynamic; do
        check "ansi/$handling" "$WORK/ansi" --seed "$seed" --frame-rate 0 --existing-color-handling "$handling" "$EFFECT"
        check "ansi/$handling/dump" "$WORK/ansi" --seed "$seed" --parity-dump --existing-color-handling "$handling" "$EFFECT"
    done
    check "ansi/dynamic/xterm" "$WORK/ansi" --seed "$seed" --frame-rate 0 --xterm-colors --existing-color-handling dynamic "$EFFECT"
    check "ansi/dynamic/no-color" "$WORK/ansi" --seed "$seed" --frame-rate 0 --no-color --existing-color-handling always "$EFFECT"
done
check ansi-odd "$WORK/ansi-odd" --seed 15 --frame-rate 0 --existing-color-handling always "$EFFECT"
check ansi-bad "$WORK/ansi-bad" --seed 15 --frame-rate 0 "$EFFECT"
COLUMNS=40 LINES=30 check wrap "$WORK/big" --seed 16 --frame-rate 0 --wrap-text "$EFFECT"
COLUMNS=40 LINES=30 check wrap/dump "$WORK/big" --seed 16 --parity-dump --wrap-text "$EFFECT"
COLUMNS=6 LINES=8 check wrap-clipped "$WORK/ragged" --seed 17 --frame-rate 0 --wrap-text "$EFFECT"
check wrap-canvas "$WORK/ragged" --seed 17 --frame-rate 0 --wrap-text --canvas-width 5 --canvas-height -1 "$EFFECT"
check wrap-ignore "$WORK/tabs" --seed 18 --frame-rate 0 --wrap-text --canvas-width 4 --ignore-terminal-dimensions "$EFFECT"
check paced "$WORK/single" --seed 14 --frame-rate 2000 "$EFFECT"

echo "oracle $EFFECT: $pass passed, $fail failed"
[ $fail -eq 0 ]
