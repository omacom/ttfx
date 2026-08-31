#!/usr/bin/env bash
# Full byte-stream parity: the tty escape dance (prep, per-frame cursor moves,
# teardown) byte-compared between the shimmed reference and a real ttfx run.
# Runs a representative subset of cases with --frame-rate 0 plus the
# reuse-canvas / no-eol / no-restore-cursor teardown variants.
set -u
cd "$(dirname "$0")/../.."

RUST=./target/release/ttfx
PY="python3 tools/parity/tty_run.py"
export COLUMNS=80 LINES=24
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
inputs=tools/parity/inputs

pass=0; fail=0; failed_cases=()
run_case() {
  local name="$1"; shift
  local input="$1"; shift
  $PY --seed 42 --frame-rate 0 "$@" < "$inputs/$input" > "$tmp/py.bytes" 2>"$tmp/py.err"
  local py_rc=$?
  # --virtual-clock matches the shim's virtual clock so clock-dependent
  # effects (matrix, thunderstorm) are comparable; with a real clock their
  # phase transitions legitimately track wall time, not frame count.
  $RUST --seed 42 --frame-rate 0 --virtual-clock "$@" < "$inputs/$input" > "$tmp/rs.bytes" 2>"$tmp/rs.err"
  local rs_rc=$?
  if [ $py_rc -ne $rs_rc ]; then
    fail=$((fail+1)); failed_cases+=("$name (exit py=$py_rc rs=$rs_rc)"); return
  fi
  if cmp -s "$tmp/py.bytes" "$tmp/rs.bytes"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed_cases+=("$name ($(cmp "$tmp/py.bytes" "$tmp/rs.bytes" 2>&1 | head -1))")
  fi
}

# effect subcommands present in both implementations
mapfile -t effects < <($RUST --help 2>/dev/null | sed -n '/Commands:/,/Options:/p' | awk '/^  [a-z]/ {print $1}' | grep -vE '^(help|airstrike|automata|bubblepop|malfunction|reverselife|roses|sunshower|voronoi)$')
for effect in "${effects[@]}"; do
  run_case "tty-$effect" basic.txt "$effect"
done
run_case "tty-no-eol" basic.txt --no-eol randomsequence
run_case "tty-no-restore-cursor" basic.txt --no-restore-cursor randomsequence
run_case "tty-reuse-canvas" basic.txt --reuse-canvas randomsequence
run_case "tty-anchored" paragraph.txt --canvas-width 60 --canvas-height 20 --anchor-canvas c randomsequence

echo "tty byte-stream parity: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then printf 'FAILED: %s\n' "${failed_cases[@]}"; exit 1; fi
