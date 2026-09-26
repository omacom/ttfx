# Second assembly optimization pass

> Historical measurements against PR #35 at `ac940f2`. See the [September 26 refresh](../round3/README.md) for the current comparison against `189840b`.

On the Ryzen 5 7600X (Zen 4), this version is **2.47x faster overall than
PR #35's assembly** and **1.31x faster than our first optimized version**.
Every one of the 37 effects improves in both best and median time in the
recorded comparisons. Waves improves by approximately **4.9x** over the PR.

This is a same-machine comparison, not a Zen 5 measurement or a claim that
no further optimization is possible.

## Implementation

- **Keep scene playback state together.** Each scene is one 64-byte record,
  replacing two separated 32-byte planes. Eased playback needs fields from
  both halves; placing them together materially improves locality.
- **Check for existing visuals before formatting.** The symbol, foreground,
  background and attributes determine the visual under the run's fixed
  output settings. Hash those fields first and return the pooled handle on
  a hit, avoiding repeated SGR-string construction. Full keys are compared;
  a hash collision never counts as a match.
- **Use a short path for ordinary numeric conversions.** x86 returns
  `i64::MIN` for invalid/overflowing conversions. A signed-overflow check
  on subtracting one identifies that result. Ordinary values return early;
  boundary values, NaNs and infinities retain the original exact behavior.
- **Simplify unobserved motion.** When a character has no segment-event
  subscribers, keep its path pointer and remaining distance in registers.
  Preserve every subtraction in its original order. Paths with subscribers
  still use the original reentrant callback walk.
- **Avoid huge-page commitment for sparse prefixes.** Character arrays,
  render lists and active bitmaps request normal pages for their first
  2 MiB. Dense arenas, scene/path data and later offsets retain the system
  policy. No system configuration changes are required.

The first round's character-array staggering and shared wave frames remain.
[Research sources, alternatives and discarded experiments](research.md)
include AMD and Agner Fog guidance, LLVM BOLT/MCA, ISPC and STOKE.

## Main benchmark

- Original: `ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`, still PR #35's head
  when checked at the end of this pass.
- Round one: `9ce2b34a762e219201e0cb937246a7c8f623feff`.
- AMD Ryzen 5 7600X; Linux 7.2.3-arch1-3; rustc 1.98.1; NASM 3.01.
- Same release profile, default features and lockfile. `TTFX_ASM=force`.
- 200x50 canvas, 190x46 ASCII fixture, seed 1, frame rate 0, stdout to
  `/dev/null`; matrix and thunderstorm use the virtual clock.
- Logical CPU 4; one warmup and five measured runs for each binary/effect,
  deterministically shuffled interleaving. Times include process startup.
- Compilation and oracle jobs were stopped for all timing runs. Normal
  desktop applications remained open. The system's existing THP policy was
  `always`; no governor or system policy was changed.
- The renderer and animation execute fully, including formatting and output
  syscalls. No frames are skipped and no output-device shortcut is used.

| Comparison | Best-of-five geometric mean | Median geometric mean |
|---|---:|---:|
| [Original PR vs round two](pr35-zen4.json) | 2.475x | 2.451x |
| [Independent repeat](pr35-zen4-repeat.json) | 2.472x | 2.451x |
| [Round one vs round two](round1-zen4.json) | 1.311x | 1.304x |

All samples, arguments, input hashes and binary hashes are in those files.
Times below are milliseconds, best of five, from the first paired run.

| Effect | Original PR | Round two | Speedup |
|---|---:|---:|---:|
| beams | 52.96 | 22.91 | 2.31x |
| binarypath | 968.71 | 348.96 | 2.78x |
| blackhole | 431.14 | 140.32 | 3.07x |
| bouncyballs | 149.94 | 67.99 | 2.21x |
| bubbles | 265.11 | 110.98 | 2.39x |
| burn | 92.67 | 43.89 | 2.11x |
| colorshift | 73.31 | 27.97 | 2.62x |
| crumble | 210.91 | 86.08 | 2.45x |
| decrypt | 64.44 | 33.29 | 1.94x |
| errorcorrect | 51.29 | 31.56 | 1.63x |
| expand | 143.66 | 52.49 | 2.74x |
| fireworks | 418.10 | 132.61 | 3.15x |
| highlight | 17.08 | 6.16 | 2.77x |
| laseretch | 207.76 | 105.27 | 1.97x |
| matrix | 73.39 | 57.22 | 1.28x |
| middleout | 98.71 | 30.11 | 3.28x |
| orbittingvolley | 70.87 | 30.70 | 2.31x |
| overflow | 136.49 | 45.93 | 2.97x |
| pour | 96.59 | 42.49 | 2.27x |
| print | 36.80 | 19.89 | 1.85x |
| rain | 116.23 | 50.65 | 2.29x |
| randomsequence | 17.70 | 9.18 | 1.93x |
| rings | 389.05 | 149.77 | 2.60x |
| scattered | 144.58 | 52.24 | 2.77x |
| slice | 122.32 | 32.38 | 3.78x |
| slide | 110.55 | 28.04 | 3.94x |
| smoke | 47.57 | 23.49 | 2.02x |
| spotlights | 65.44 | 44.58 | 1.47x |
| spray | 115.34 | 45.62 | 2.53x |
| swarm | 578.60 | 237.03 | 2.44x |
| sweep | 19.08 | 8.64 | 2.21x |
| synthgrid | 24.38 | 10.57 | 2.31x |
| thunderstorm | 80.56 | 27.11 | 2.97x |
| unstable | 187.31 | 73.43 | 2.55x |
| vhstape | 117.24 | 35.65 | 3.29x |
| waves | 118.76 | 24.23 | 4.90x |
| wipe | 17.43 | 6.60 | 2.64x |

A separate [three-engine run](pr35-rust-zen4.json), using the same workload
and five interleaved samples, also reports the original revision's Rust engine
(`TTFX_ASM=0`) alongside both assembly versions. Final assembly is
**5.504x** faster than that Rust engine by best-time geometric mean
and **5.458x** by median. In this run the assembly-to-assembly
speedup is 2.463x best / 2.446x median.

| Effect | Rust | Original assembly | Final assembly |
|---|---:|---:|---:|
| beams | 270.00 | 54.40 | 24.60 |
| binarypath | 860.82 | 979.89 | 349.25 |
| matrix | 186.25 | 74.00 | 56.46 |
| waves | 546.45 | 118.87 | 24.88 |

Times are milliseconds, best of five; all 37 effects are in the linked JSON.

## Additional workloads

These compare round two against **round one**, rather than the original PR.
Each covers all 37 effects with one warmup and three interleaved samples.
Every effect improves in both best and median time in all four runs.

| Workload | Best geometric mean | Median geometric mean |
|---|---:|---:|
| [80x24 canvas; 70x18 text; seed 7](holdout-small.json) | 1.458x | 1.456x |
| [240x70 canvas; 220x60 text; seed 19](holdout-large.json) | 1.283x | 1.274x |
| [80x24 canvas; colored Unicode input; seed 29](holdout-unicode.json) | 1.536x | 1.513x |
| [Standard workload; THP disabled for both processes](holdout-thp-disabled.json) | 1.157x | 1.152x |

The THP control uses [a small preload constructor](disable-thp.c) that sets
`PR_SET_THP_DISABLE` equally for both processes. It leaves system settings
untouched. This control separates the other improvements from the sparse-page
hint's benefit. The timing gains survive when that hint is redundant.

## Memory

Peak resident memory, MiB; median of three Linux `wait4` `ru_maxrss`
measurements using the main workload. [Raw samples and hashes](memory.json).

| Effect | Original PR | Round one | Round two |
|---|---:|---:|---:|
| waves | 83.7 | 73.8 | 21.2 |
| highlight | 69.7 | 69.7 | 20.9 |
| binarypath | 247.7 | 247.7 | 199.2 |

## Correctness

The final binary passed all **57 release tests**, including the assembly
utility differential tests over large structured/random inputs. All terminal
resize/restart checks passed. The assembly object has no absolute 32-bit
relocations and remains PIE-compatible. An additional 222 cross-effect smoke
comparisons covered ASCII, Unicode, ANSI colors and color modes.

The full 37-effect assembly oracle suite passed **91,641 cases with zero
failures**. Each case compares stdout/stderr byte counts and SHA-256 digests,
plus exit status, with the Rust engine in the same binary. All effects ran in
`full` mode. [Per-effect results and matching binary hash](oracle-summary.json).

### Upstream CI checks and an inherited discrepancy

The local `./bin/test` run with assembly enabled passed its release tests, all
19 CLI cases, and the
signal and terminal-close behavior checks. It then reported **352/354** Python
frame-parity cases passing. The two failures, `decrypt-dynamic` with seeds 42
and 1337, also fail with the **unmodified PR #35 assembly**. Forcing the Rust
engine passes them. Direct comparisons confirm the original and optimized
assembly output are byte-identical for both inputs; the original and optimized
Rust outputs also match. [Arguments and exact output hashes](upstream-parity.json).
These inherited discrepancies remain; the 91,641-case suite does not cover
these particular seed/configuration combinations.

The checks after that failure were run separately with `TTFX_ASM=force`:
all **41** complete terminal byte-stream comparisons and every resize check
pass. Re-running Python frame parity with `TTFX_ASM=0` passes **354/354**.
[CI-check summary](ci-summary.json). macOS and musl builds were not tested locally.

[The native hash wrapper](../../tools/asm/hash-output.c) has the same output
contract as the existing Python wrapper: stdout and stderr byte counts and
SHA-256 digests, plus the child's exit status. It drains both pipes concurrently
with `poll`, and was checked against Python on two 4 MiB streams, exits 0/7,
and SIGTERM. It reduces process-startup overhead in the large verification
suite. It is **never used for performance measurements**. OpenSSL is only a
build dependency for this optional testing tool, not the application.

## Reproduce

Build the original and round-one revisions in registered worktrees under
`~/Worktrees/ttfx/`, following the first report's worktree instructions, and
save their release binaries. NASM 3.x must be available or selected with `NASM`.

```bash
export NASM=/path/to/nasm
cargo build --release --locked
python3 tools/asm/bench.py /path/to/original-ttfx target/release/ttfx \
  --cpu 4 --runs 5 --rust --output target/round2-benchmark.json
python3 tools/asm/bench.py /path/to/round1-ttfx target/release/ttfx \
  --cpu 4 --runs 3 --canvas-width 80 --canvas-height 24 \
  --text-width 70 --text-height 18 --seed 7 --output target/small.json

cargo test --release --locked
TTFX_ASM=force python3 tools/tests/resize_behavior.py target/release/ttfx
cc -O2 -Wall -Wextra tools/asm/hash-output.c -lcrypto -o target/hash-output
export BIN="$PWD/target/hash-output"
export TTFX_ORACLE_REAL_BIN="$PWD/target/release/ttfx"
for cases in tools/asm/cases/*.txt; do
  effect=$(basename "$cases" .txt)
  bash tools/asm/oracle.sh "$effect" full || exit 1
done
```

The Python hash wrapper can be substituted when a C compiler/OpenSSL development
headers are unavailable. Omitting the wrapper uses the oracle's original
bytewise comparison and requires considerably more scratch disk space.
