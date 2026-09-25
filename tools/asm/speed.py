#!/usr/bin/env python3
"""Rust vs asm engine wall time per effect, and their geometric-mean speedup.

Both engines run from the same binary (TTFX_ASM=0 / TTFX_ASM=force) on a
200x50 canvas with the oracle's 190x46 "big" text, --frame-rate 0, seed 1,
output to /dev/null, pinned to one core, best of N runs.

Usage: speed.py [--bin PATH] [--core N] [--runs N] [--asm-only] [effect ...]
"""
import argparse
import math
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLOCKED = {"matrix", "thunderstorm"}  # read the clock: time them on the virtual one

p = argparse.ArgumentParser()
p.add_argument("--bin", default=os.path.join(ROOT, "target/release/ttfx"))
p.add_argument("--core", default=os.environ.get("SPEED_CORE", "8"))
p.add_argument("--runs", type=int, default=5)
p.add_argument("--asm-only", action="store_true", help="skip the Rust runs")
p.add_argument("effects", nargs="*")
a = p.parse_args()

effects = a.effects or sorted(
    f[:-4] for f in os.listdir(os.path.join(ROOT, "asm/effects"))
    if f.endswith(".asm") and f != "registry.asm")

text = os.path.join(ROOT, "target/speed-input.txt")
line = ("The quick brown fox jumps over the lazy dog 0123456789 " * 4)[:190]
os.makedirs(os.path.dirname(text), exist_ok=True)
with open(text, "w") as f:
    f.write("\n".join(line for _ in range(46)))


def best(engine, effect):
    args = ["taskset", "-c", a.core, a.bin]
    if effect in CLOCKED:
        args.append("--virtual-clock")
    args += ["--seed", "1", "--frame-rate", "0", "--canvas-width", "200", "--canvas-height", "50",
             "--ignore-terminal-dimensions", effect]
    env = dict(os.environ, TTFX_ASM=engine)
    fastest = math.inf
    for _ in range(a.runs):
        with open(text) as stdin:
            start = time.perf_counter()
            r = subprocess.run(args, stdin=stdin, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
            elapsed = time.perf_counter() - start
        if r.returncode != 0:
            sys.exit(f"{effect} TTFX_ASM={engine} exited {r.returncode}: {r.stderr.decode()[:200]}")
        fastest = min(fastest, elapsed)
    return fastest * 1000


logs = []
print(f"{'effect':16} {'rust ms':>8} {'asm ms':>8} {'x':>6}")
for effect in effects:
    asm = best("force", effect)
    if a.asm_only:
        print(f"{effect:16} {'':>8} {asm:8.1f}", flush=True)
        continue
    rust = best("0", effect)
    logs.append(math.log(rust / asm))
    print(f"{effect:16} {rust:8.1f} {asm:8.1f} {rust / asm:6.2f}", flush=True)
if logs:
    print(f"geomean speedup {math.exp(sum(logs) / len(logs)):.2f}x over {len(logs)} effects")
