# Assembly performance follow-up to PR #35

**Latest:** [Round five](round5/README.md) rebases onto PR #35 at `badde3d`
(threaded rendering and batched motion) and records fresh measurements.
[Round three](round3/README.md) and [round four](round4/README.md) are historical
results against `189840b`; this page and [round two](round2/README.md) compare
against `ac940f2`.

Baseline: [`omacom/ttfx#35`](https://github.com/omacom/ttfx/pull/35), commit
`ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`. Both binaries are built from that
revision with the same release profile and lockfile; the candidate adds the
changes described below. Measurements were taken on September 25, 2026.

## Changes

1. **Stagger the character field arrays by one cache line.** The original
   structure-of-arrays allocations are all page-aligned. Equally sized fields
   for a given character therefore compete for the same L1 cache set. Reserving
   a small prefix and offsetting each field by a different multiple of 64 bytes
   spreads these accesses across sets. Arrays retain their capacity, alignment,
   lazy commitment and original unmapping bookkeeping. Reserve sizes remain a
   multiple of 2 MiB so that transparent huge-page alignment is preserved; this
   avoids straddling extra huge pages on systems that enable THP. No per-tick
   instructions are added.
2. **Share immutable wave frames.** The waves effect already constructs a
   template, but copies every frame into each character's scene one at a time.
   Scenes can point at the shared template because playback state is in the
   scene record. Copy the count, easing duration and initial head cache; preserve
   the existing per-character construction for preexisting colors/bold. Any
   later append uses the engine's existing relocation path.

This CPU has a 32 KiB, eight-way L1 data cache with 64 sets and 64-byte lines
(as reported by Linux sysfs). Sampling identified time in character field access
and wave frame construction.
The cache-set explanation is supported by the layout and timing experiments;
hardware cache-miss counters were not collected.

## Method

- AMD Ryzen 5 7600X (Zen 4), Linux 7.2.3-arch1-3, glibc 2.44. Transparent
  huge pages were set to `always` by the existing system configuration.
- Rust 1.98.1, NASM 3.01, `cargo build --release --locked`, default features.
- 200x50 canvas, 190x46 ASCII text from the oracle's `big` fixture, seed 1,
  `--frame-rate 0 --ignore-terminal-dimensions`; output to `/dev/null`.
- `matrix` and `thunderstorm` use `--virtual-clock`.
- Pin parent and children to logical CPU 4. One warmup and five measured runs
  per engine per effect, with shuffled interleaving. All timing samples and
  binary/input SHA-256 hashes are retained in JSON.
- Wall-clock timings include process startup. Compilation and oracle jobs were
  stopped during the recorded final runs; normal desktop applications remained
  open. No governor or system tuning was applied.
- Both recorded final runs compare the two assembly engines directly. The
  second JSON is an independent repeat. Variation between runs is retained,
  not discarded.

These are **same-machine comparisons against the PR's assembly engine**. The
PR's published absolute timings were measured on Zen 5; this machine is Zen 4.
These results do not establish the size of the improvement on Zen 5.

## Results

All 37 effects improved in both final runs. Geometric mean speedups:

| Run | Best of 5 | Median of 5 |
|---|---:|---:|
| [Assembly-only pairs](pr35-zen4.json) | 1.883x | 1.880x |
| [Independent repeat](pr35-zen4-repeat.json) | 1.884x | 1.882x |

For `waves`, peak resident memory also fell from **83.8 MiB
to 73.9 MiB** (median of three runs, Linux `wait4`
`ru_maxrss`, same input and arguments; [raw measurements](waves-memory.json)).

The table below uses the first paired run. Times are milliseconds, best of five.

| Effect | Original asm | Candidate asm | Speedup |
|---|---:|---:|---:|
| beams | 53.94 | 43.80 | 1.23x |
| binarypath | 972.47 | 440.29 | 2.21x |
| blackhole | 429.48 | 155.63 | 2.76x |
| bouncyballs | 151.50 | 75.91 | 2.00x |
| bubbles | 269.85 | 121.49 | 2.22x |
| burn | 93.54 | 58.96 | 1.59x |
| colorshift | 73.75 | 42.13 | 1.75x |
| crumble | 212.64 | 101.73 | 2.09x |
| decrypt | 64.90 | 47.28 | 1.37x |
| errorcorrect | 51.93 | 40.11 | 1.29x |
| expand | 143.42 | 61.06 | 2.35x |
| fireworks | 419.45 | 150.65 | 2.78x |
| highlight | 17.07 | 12.46 | 1.37x |
| laseretch | 209.10 | 118.31 | 1.77x |
| matrix | 73.81 | 63.77 | 1.16x |
| middleout | 98.46 | 35.71 | 2.76x |
| orbittingvolley | 71.40 | 35.11 | 2.03x |
| overflow | 136.49 | 68.39 | 2.00x |
| pour | 96.44 | 48.95 | 1.97x |
| print | 36.74 | 24.03 | 1.53x |
| rain | 116.03 | 56.26 | 2.06x |
| randomsequence | 17.73 | 12.27 | 1.44x |
| rings | 388.85 | 159.69 | 2.44x |
| scattered | 144.42 | 60.41 | 2.39x |
| slice | 123.61 | 36.80 | 3.36x |
| slide | 111.65 | 35.42 | 3.15x |
| smoke | 46.77 | 36.37 | 1.29x |
| spotlights | 63.41 | 49.02 | 1.29x |
| spray | 115.04 | 50.52 | 2.28x |
| swarm | 578.67 | 254.02 | 2.28x |
| sweep | 19.41 | 13.93 | 1.39x |
| synthgrid | 25.16 | 17.54 | 1.43x |
| thunderstorm | 80.94 | 56.67 | 1.43x |
| unstable | 187.73 | 81.44 | 2.31x |
| vhstape | 117.17 | 49.57 | 2.36x |
| waves | 118.96 | 58.51 | 2.03x |
| wipe | 17.21 | 12.31 | 1.40x |

## Correctness

`cargo test --release --locked` passed all 57 tests, including the 21 assembly
utility differential tests and the existing easing, geometry and engine goldens.
`TTFX_ASM=force python3 tools/tests/resize_behavior.py target/ttfx-optimized`
also passed every terminal resize/restart check. The assembly object has no
absolute 32-bit relocations and remains PIE-compatible.

The final binary passed **16,377 oracle cases with zero failures**:
all 37 effects, using `quick` for 36 effects and `full` for the modified waves
effect (3,141 cases). Each case compared stdout, stderr and exit status against
`TTFX_ASM=0` in the same binary. The tested binary's SHA-256 matches both
benchmark files. [Per-effect results and binary hash](oracle-summary.json).

`tools/asm/hash-output.py` streams stdout and stderr independently into a byte
count and SHA-256 digest while preserving the child's exit status. It is used
only for oracle verification to avoid writing multi-gigabyte frame dumps to
disk. It does not limit frames, replace the effect, or participate in timing.
The standard `oracle.sh` without this wrapper still performs direct bytewise
comparison and can be used instead.

## Reproduce

NASM >= 3.0 must be available on PATH, or set `NASM` to its executable. The
assembly benchmarks force the engine; a binary without it fails instead of
silently measuring the Rust fallback.

```bash
# Reuse a registered baseline worktree if one already exists.
git worktree list
git worktree add --detach ~/Worktrees/ttfx/pr35-baseline ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75
cargo build --release --locked --manifest-path ~/Worktrees/ttfx/pr35-baseline/Cargo.toml
cargo build --release --locked
python3 tools/asm/bench.py \
  ~/Worktrees/ttfx/pr35-baseline/target/release/ttfx target/release/ttfx \
  --cpu 4 --runs 5 --output target/bench-paired.json
# Add --rust to also measure the baseline's Rust engine.

cargo test --release --locked
export BIN="$PWD/tools/asm/hash-output.py"
export TTFX_ORACLE_REAL_BIN="$PWD/target/release/ttfx"
for cases in tools/asm/cases/*.txt; do
  effect=$(basename "$cases" .txt)
  mode=quick
  [ "$effect" != waves ] || mode=full
  bash tools/asm/oracle.sh "$effect" "$mode" || exit 1
done
```
