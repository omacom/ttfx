#!/usr/bin/env bash
# Startup + throughput benchmark: ttfx vs the Python reference.
set -u
cd "$(dirname "$0")/../.."
RUST=${RUST:-./target/release/ttfx}
export COLUMNS=120 LINES=40
input=$(mktemp); trap 'rm -f "$input"' EXIT
python3 -c "print('\n'.join('benchmark line %03d with some text to render' % i for i in range(30)))" > "$input"

time_ms() { python3 -c "import subprocess,sys,time; t=time.monotonic(); subprocess.run(sys.argv[1:], stdin=open('$input'), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(round((time.monotonic()-t)*1000))" "$@"; }

echo "== startup (--help) =="
echo "ttfx:   $(time_ms $RUST --help) ms"
echo "python: $(time_ms python3 -c 'import sys; sys.path.insert(0, "reference/tte"); from terminaltexteffects.__main__ import main' ) ms (import only)"

echo "== full effect run, frame-rate 0, 30x46 input =="
for effect in randomsequence beams decrypt; do
  r=$(time_ms $RUST --seed 1 --frame-rate 0 --parity-dump $effect)
  p=$(time_ms python3 tools/parity/dump.py --seed 1 --frame-rate 0 $effect)
  echo "$effect: ttfx ${r}ms vs python ${p}ms"
done
