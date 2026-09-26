#!/usr/bin/env python3
"""Compare two assembly engines on PR #35's workload, interleaving runs.

Both binaries must contain the assembly engine: TTFX_ASM=force rejects fallback.
Use --rust to include the baseline binary's Rust engine. JSON keeps every sample.
"""

import argparse
import hashlib
import json
import math
import os
import platform
import random
import resource
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    affinity = parser.add_mutually_exclusive_group()
    affinity.add_argument("--cpu", type=int, default=min(os.sched_getaffinity(0)))
    affinity.add_argument("--cpus", type=int, nargs="+", help="allow multiple CPUs for threaded rendering")
    parser.add_argument("--threads", choices=("auto", "1"), default="auto")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--effects", nargs="+")
    parser.add_argument("--canvas-width", type=int, default=200)
    parser.add_argument("--canvas-height", type=int, default=50)
    parser.add_argument("--text-width", type=int, default=190)
    parser.add_argument("--text-height", type=int, default=46)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--input-file", type=Path)
    parser.add_argument("--rust", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 1 or args.warmups < 0:
        parser.error("runs must be positive and warmups nonnegative")
    if min(args.canvas_width, args.canvas_height, args.text_width, args.text_height) < 1:
        parser.error("canvas and text dimensions must be positive")
    baseline, candidate = args.baseline.resolve(), args.candidate.resolve()
    hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (baseline, candidate)}
    if hashes[baseline] == hashes[candidate]:
        parser.error("baseline and candidate contain identical binaries")
    effects = args.effects or sorted(p.stem for p in Path(__file__).with_name("cases").glob("*.txt"))
    phrase = "The quick brown fox jumps over the lazy dog 0123456789 "
    line = (phrase * ((args.text_width + len(phrase) - 1) // len(phrase)))[:args.text_width]
    data = args.input_file.read_bytes() if args.input_file else "\n".join([line] * args.text_height).encode()
    engines = {"baseline": (baseline, "force"), "candidate": (candidate, "force")}
    if args.rust:
        engines["rust"] = (baseline, "0")
    cpus = sorted(set(args.cpus or [args.cpu]))
    os.sched_setaffinity(0, cpus)
    environment = {**os.environ, "COLUMNS": str(args.canvas_width), "LINES": str(args.canvas_height),
                   "TTFX_ASM_THREADS": args.threads}
    result = {
        "platform": platform.platform(),
        "cpu": cpus[0] if len(cpus) == 1 else None,
        "cpus": cpus,
        "TTFX_ASM_THREADS": args.threads,
        "cpu_model": next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
        "runs": args.runs,
        "warmups": args.warmups,
        "TTFX_ASM_TIER": os.environ.get("TTFX_ASM_TIER"),
        "LD_PRELOAD": os.environ.get("LD_PRELOAD"),
        "thp_policy": Path("/sys/kernel/mm/transparent_hugepage/enabled").read_text().strip(),
        "input_sha256": hashlib.sha256(data).hexdigest(),
        "input_bytes": len(data),
        "input_file": str(args.input_file.resolve()) if args.input_file else None,
        "text_width": args.text_width if not args.input_file else None,
        "text_height": args.text_height if not args.input_file else None,
        "binaries": {name: {"path": str(path), "sha256": hashes[path], "TTFX_ASM": mode} for name, (path, mode) in engines.items()},
        "effects": {},
    }
    order_rng = random.Random(35)
    with tempfile.TemporaryFile() as source, open(os.devnull, "wb") as sink:
        source.write(data)
        for effect in effects:
            flags = ["--seed", str(args.seed), "--frame-rate", "0", "--canvas-width", str(args.canvas_width), "--canvas-height", str(args.canvas_height), "--ignore-terminal-dimensions"]
            if effect in {"matrix", "thunderstorm"}:
                flags.append("--virtual-clock")
            flags.append(effect)
            samples = {name: [] for name in engines}
            cpu_samples = {name: [] for name in engines}
            for iteration in range(args.warmups + args.runs):
                order = list(engines)
                order_rng.shuffle(order)
                for name in order:
                    path, mode = engines[name]
                    source.seek(0)
                    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
                    start = time.perf_counter_ns()
                    subprocess.run([str(path), *flags], stdin=source, stdout=sink, stderr=subprocess.PIPE, env={**environment, "TTFX_ASM": mode}, check=True, timeout=120)
                    elapsed = (time.perf_counter_ns() - start) / 1e6
                    usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    cpu_ms = 1000 * (usage_after.ru_utime + usage_after.ru_stime - usage_before.ru_utime - usage_before.ru_stime)
                    if iteration >= args.warmups:
                        samples[name].append(elapsed)
                        cpu_samples[name].append(cpu_ms)
            row = {name: {"ms": times, "best_ms": min(times), "median_ms": statistics.median(times)} for name, times in samples.items()}
            for name, times in cpu_samples.items():
                row[name].update(cpu_ms=times, best_cpu_ms=min(times), median_cpu_ms=statistics.median(times))
            row["args"] = flags
            row["speedup_best"] = row["baseline"]["best_ms"] / row["candidate"]["best_ms"]
            row["speedup_median"] = row["baseline"]["median_ms"] / row["candidate"]["median_ms"]
            row["speedup_cpu_median"] = row["baseline"]["median_cpu_ms"] / row["candidate"]["median_cpu_ms"]
            result["effects"][effect] = row
            print(f"{effect:18} {row['baseline']['best_ms']:9.2f} -> {row['candidate']['best_ms']:9.2f} ms  {row['speedup_best']:.3f}x (median {row['speedup_median']:.3f}x)", flush=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
    result["geomean_speedup_best"] = math.exp(statistics.mean(math.log(row["speedup_best"]) for row in result["effects"].values()))
    result["geomean_speedup_median"] = math.exp(statistics.mean(math.log(row["speedup_median"]) for row in result["effects"].values()))
    result["geomean_speedup_cpu_median"] = math.exp(statistics.mean(math.log(row["speedup_cpu_median"]) for row in result["effects"].values()))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Geometric mean: {result['geomean_speedup_best']:.3f}x best, {result['geomean_speedup_median']:.3f}x median")


if __name__ == "__main__":
    main()
