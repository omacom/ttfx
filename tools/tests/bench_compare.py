"""Compare two ttfx builds using identical, complete animations.

Runs the real CLI with pacing disabled and a virtual clock so timed effects do
the same work. Verifies output before timing, alternates execution order, and
reports medians. No third-party Python packages are required.

Example:
    python3 tools/tests/bench_compare.py /tmp/ttfx-before target/release/ttfx \
        --size 200x50 --repeats 15 --json /tmp/ttfx-comparison.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def digest(file) -> str:
    file.seek(0)
    checksum = hashlib.sha256()
    while chunk := file.read(1024 * 1024):
        checksum.update(chunk)
    return checksum.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--size", default="200x50", help="terminal columns x rows")
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--effects", nargs="+", help="default: every effect")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--input", type=Path, help="default: a block filling the terminal")
    parser.add_argument("--terminal-options", default="", help="e.g. '--no-color' or '--xterm-colors'")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--cpu", type=int, help="optionally pin to one CPU on Linux")
    parser.add_argument("--json", type=Path, help="save individual timings and output checksums")
    args = parser.parse_args()
    try:
        columns, rows = map(int, args.size.lower().split("x"))
    except ValueError:
        parser.error("--size must be COLUMNSxROWS")
    if min(columns, rows, args.repeats) < 1 or args.warmups < 0 or args.timeout <= 0:
        parser.error("dimensions, repeats, and timeout must be positive; warmups cannot be negative")
    if args.cpu is not None:
        if not hasattr(os, "sched_setaffinity"):
            parser.error("--cpu requires Linux")
        os.sched_setaffinity(0, {args.cpu})

    binaries = [str(args.before.resolve()), str(args.after.resolve())]
    env = {**os.environ, "COLUMNS": str(columns), "LINES": str(rows)}
    if args.input:
        data = args.input.read_bytes()
    else:
        width = max(1, columns - 10)
        lines = [f"benchmark line {i:03d} — the quick brown fox jumps over the lazy dog"
                 for i in range(max(1, rows - 4))]
        data = "\n".join((line * (width // len(line) + 1))[:width] for line in lines).encode()

    effects = args.effects
    if effects is None:
        help_text = subprocess.check_output([binaries[0], "--help"], text=True, env=env, timeout=args.timeout)
        commands = help_text.split("Commands:", 1)[1].split("Options:", 1)[0]
        effects = [line.split()[0] for line in commands.splitlines()
                   if line.strip() and line.split()[0] != "help"]
    report = {
        "platform": platform.platform(), "binaries": binaries, "size": [columns, rows],
        "cpu": args.cpu, "seed": args.seed, "repeats": args.repeats, "warmups": args.warmups,
        "terminal_options": shlex.split(args.terminal_options),
        "input_sha256": hashlib.sha256(data).hexdigest(), "input_bytes": len(data), "results": {},
    }
    report["binary_sha256"] = []
    for binary in binaries:
        with open(binary, "rb") as file:
            report["binary_sha256"].append(digest(file))
    print(f"{columns}x{rows}, {args.repeats} repetitions, seed {args.seed}, virtual clock, pacing off")
    print(f"{'effect':18} {'before ms':>11} {'after ms':>11} {'speedup':>9}")
    for effect in effects:
        commands = [[binary, "--seed", str(args.seed), "--frame-rate", "0", "--virtual-clock",
                     *report["terminal_options"], effect] for binary in binaries]

        def run(index, output):
            result = subprocess.run(commands[index], input=data, stdout=output,
                                    stderr=subprocess.PIPE, env=env, timeout=args.timeout)
            if result.returncode:
                raise RuntimeError(f"{commands[index]} exited {result.returncode}: {result.stderr.decode(errors='replace')}")
            return result.stderr

        outputs = []
        for index in range(2):
            with tempfile.TemporaryFile() as output:
                stderr = run(index, output)
                outputs.append((output.tell(), digest(output), stderr))
        if outputs[0] != outputs[1]:
            raise RuntimeError(f"{effect}: builds produce different output: {outputs}")

        times: list[list[float]] = [[], []]
        for repetition in range(args.warmups + args.repeats):
            for index in ([0, 1] if repetition % 2 == 0 else [1, 0]):
                start = time.perf_counter_ns()
                run(index, subprocess.DEVNULL)
                elapsed = (time.perf_counter_ns() - start) / 1_000_000
                if repetition >= args.warmups:
                    times[index].append(elapsed)
        medians = [statistics.median(samples) for samples in times]
        ratio = medians[0] / medians[1]
        report["results"][effect] = {
            "times_ms": times, "median_ms": medians, "speedup": ratio,
            "output_bytes": outputs[0][0], "output_sha256": outputs[0][1],
        }
        print(f"{effect:18} {medians[0]:11.2f} {medians[1]:11.2f} {ratio:8.3f}x", flush=True)
        if args.json:
            args.json.write_text(json.dumps(report, indent=2) + "\n")
    ratios = [result["speedup"] for result in report["results"].values()]
    print(f"Median effect speedup: {statistics.median(ratios):.3f}x")


if __name__ == "__main__":
    main()
