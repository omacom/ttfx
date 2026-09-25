#!/usr/bin/env bash
# M0 parity matrix: byte-compare Python and Rust first-frame dumps across
# inputs x terminal-config variants. Exit 0 iff everything matches.
set -u
cd "$(dirname "$0")/../.."

RUST=${RUST:-./target/release/ttfx}
PY="python3 tools/parity/m0_dump.py"
export COLUMNS=80 LINES=24

pass=0
fail=0
failed_cases=()

inputs_dir=tools/parity/inputs
mkdir -p "$inputs_dir"

# --- inputs ---
printf 'Hello, World!' > "$inputs_dir/simple.txt"
printf 'line one\nsecond line is longer\n\tindented\nshort\n' > "$inputs_dir/multiline.txt"
printf 'a\n\n\nb with trailing spaces   \n  leading\n' > "$inputs_dir/ragged.txt"
printf '\x1b[31mred\x1b[0m plain \x1b[1;32mboldgreen\x1b[0m\n\x1b[38;2;255;0;128mrgb\x1b[0m \x1b[48;5;42mbg8\x1b[0m\n' > "$inputs_dir/colored.txt"
printf '\x1b[93mbright\x1b[39mdefault\n\x1b[34mblue\x1b[1mboldblue\x1b[22munbold\x1b[0m\n' > "$inputs_dir/colorstate.txt"
printf 'over\rwritten\nnext\x1b[2Cgap\n' > "$inputs_dir/cursor.txt"
printf 'tab\ttab\t\tend\n' > "$inputs_dir/tabs.txt"
python3 -c "print('wide line ' * 12)" > "$inputs_dir/wide.txt"

# --- config variants ---
declare -A variants=(
  [default]=""
  [anchor_c]="--anchor-canvas c --anchor-text c --canvas-width 60 --canvas-height 20"
  [anchor_ne]="--anchor-canvas ne --anchor-text ne --canvas-width 60 --canvas-height 20"
  [anchor_mixed]="--anchor-canvas n --anchor-text se --canvas-width 40 --canvas-height 12"
  [canvas_terminal]="--canvas-width 0 --canvas-height 0"
  [canvas_small]="--canvas-width 12 --canvas-height 4"
  [wrap]="--wrap-text --canvas-width 20"
  [tab8]="--tab-width 8"
  [xterm]="--xterm-colors"
  [nocolor]="--no-color"
  [always]="--existing-color-handling always"
  [always_xterm]="--existing-color-handling always --xterm-colors"
  [always_nocolor]="--existing-color-handling always --no-color"
  [ignore_dims]="--ignore-terminal-dimensions --canvas-width 120 --canvas-height 40"
)

for input in "$inputs_dir"/*.txt; do
  for variant in "${!variants[@]}"; do
    opts=${variants[$variant]}
    name="$(basename "$input" .txt)/$variant"
    py_out=$($PY $opts < "$input" 2>&1)
    py_rc=$?
    rust_out=$($RUST --m0-dump $opts < "$input" 2>&1)
    rust_rc=$?
    if [ "$py_rc" -ne "$rust_rc" ]; then
      fail=$((fail + 1))
      failed_cases+=("$name (exit: py=$py_rc rust=$rust_rc)")
      continue
    fi
    if [ "$py_rc" -ne 0 ]; then
      pass=$((pass + 1))  # both errored: condition parity
      continue
    fi
    if [ "$py_out" == "$rust_out" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      failed_cases+=("$name")
      if [ "${VERBOSE:-0}" == "1" ]; then
        diff <(printf '%s' "$py_out" | cat -A) <(printf '%s' "$rust_out" | cat -A) | head -20
      fi
    fi
  done
done

echo "M0 parity: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed_cases[@]}"
  exit 1
fi
