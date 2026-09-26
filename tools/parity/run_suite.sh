#!/usr/bin/env bash
# Effect parity suite: byte-compare Python and Rust frame dumps for every case
# in cases.txt (format: name|input_file|cli_args). Usage: run_suite.sh [filter]
set -u
cd "$(dirname "$0")/../.."

RUST=${RUST:-./target/release/ttfx}
PY="python3 tools/parity/dump.py"
export COLUMNS=80 LINES=24
FILTER="${1:-}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shared inputs
inputs=tools/parity/inputs
mkdir -p "$inputs"
printf 'Hello, World!\nThis is ttfx.\nRust vs Python' > "$inputs/basic.txt"
printf 'x' > "$inputs/single.txt"
printf '\x1b[31mred\x1b[0m plain \x1b[1;32mboldgreen\x1b[0m\n\x1b[38;2;255;0;128mrgb\x1b[0m \x1b[48;5;42mbg8\x1b[0m\n' > "$inputs/colored.txt"
python3 -c "
lines = ['The quick brown fox jumps over the lazy dog %d' % i for i in range(8)]
print('\n'.join(lines))" > "$inputs/paragraph.txt"

pass=0; fail=0; failed_cases=()
while IFS='|' read -r name input args; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  for seed in 42 1337; do
    $PY --seed "$seed" --max-frames 400 $args < "$inputs/$input" > "$tmp/py.dump" 2>"$tmp/py.err"
    py_rc=$?
    $RUST --seed "$seed" --parity-dump --max-frames 400 $args < "$inputs/$input" > "$tmp/rs.dump" 2>"$tmp/rs.err"
    rs_rc=$?
    if [ $py_rc -ne $rs_rc ]; then
      fail=$((fail+1)); failed_cases+=("$name seed=$seed (exit py=$py_rc rs=$rs_rc)")
      continue
    fi
    if cmp -s "$tmp/py.dump" "$tmp/rs.dump"; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); failed_cases+=("$name seed=$seed (first diff byte: $(cmp "$tmp/py.dump" "$tmp/rs.dump" 2>&1 | head -1))")
    fi
  done
done < tools/parity/cases.txt

echo "effect parity: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then printf 'FAILED: %s\n' "${failed_cases[@]}"; exit 1; fi
