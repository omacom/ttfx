# Rebase onto the threaded renderer and batched motion in PR #35

September 26, 2026. Baseline: PR #35 at
[`badde3de1f22244e721bba06ade77ad13d773548`](https://github.com/omacom/ttfx/commit/badde3de1f22244e721bba06ade77ad13d773548).
This supersedes the comparisons against `189840b` in rounds three and four.

The final change is about **4% faster across all 37 effects on one core**
(two independent nine-sample runs), and **5% faster by median on two physical
cores**, on this Ryzen 5 7600X. These are comparisons with the latest upstream
implementation, including its renderer thread, vectorized motion and RNG,
scene chunks, input-color fixes and stronger oracle. They are not a general
ranking of models or a result measured on Zen 5.

## Changes retained

- Use upstream's `reserve_small` for the shared active-update reservation and
  the renderer's three character arrays. Both touch short prefixes of large
  reserved regions. Upstream now supplies this allocator for character fields,
  particle pools and frame logs, so the old `reserve_sparse` helper is removed.
- On AVX2 and AVX-512, stop after the first interpolation when a group has no
  relevant curved lanes. For a line, the stored control point is the end point;
  the other two interpolations would be discarded. AVX-512 also defers loading
  and converting the otherwise unused end points.
- On AVX-512, bypass the subtract/add for the segment walk's overshoot case
  when its mask is empty. This shortens the dependency chain into the division.
  Groups containing overshooting lanes still execute the original arithmetic.

The arithmetic used to produce coordinates, including division and rounding,
retains its original order. No reciprocal approximation, FMA, frame omission,
RNG change or benchmark-specific behavior is introduced. Callback and mirror
invalidation logic is unchanged. The attempted eased-division shortcut and two
renderer shortcuts are not shipped.

Production source: `74fa0dac6a8d16197a832c6e66ff7c6a9d76b824`.
The [manifest](binary-manifest.json) records every saved binary's hash.
The pre-rebase branch is preserved locally at
`backup/perf-asm-cache-layout-before-rebase-20260926`.

## Measurements

Each row compares the same two release binaries with `TTFX_ASM=force`, identical
input/options, one warmup and randomized interleaving within each effect.
Values are geometric means over all 37 effects, baseline divided by candidate;
above 1 is faster. CPU time includes every thread in the child process.

| Workload | Best wall time | Median wall time | Median child CPU time |
|---|---:|---:|---:|
| [Standard, one core, 9 samples](pr35-single.json) | 1.044x | 1.037x | 1.039x |
| [Standard repeat, one core, 9 samples](pr35-repeat.json) | 1.039x | 1.038x | 1.043x |
| [Standard, two physical cores, 9 samples](pr35-threaded.json) | 1.042x | 1.052x | 1.053x |
| [AVX2 tier, one core, 9 samples](pr35-avx2.json) | 1.032x | 1.040x | 1.043x |
| [80×24, seed 11, 7 samples](holdout-small.json) | 1.102x | 1.106x | 1.132x |
| [300×80, seed 7, 3 samples](holdout-large.json) | 1.018x | 1.019x | 1.020x |
| [Colored Unicode, seed 29, 5 samples](holdout-unicode.json) | 1.127x | 1.127x | 1.169x |
| [THP disabled per process, 7 samples](holdout-thp-disabled.json) | 1.009x | 1.002x | 1.002x |

The standard input is 190×46 ASCII characters on a 200×50 canvas, seed 1,
frame rate zero, stdout `/dev/null`. Matrix and thunderstorm use the virtual
clock. The benchmark does not change their frame counts. CPU 2 is the single
core; CPUs 2 and 4 are separate physical cores for automatic threaded rendering.
The two binaries receive the same affinity and thread setting. Linux 7.2.5,
NASM 3.01, rustc 1.98.1, the locked dependencies and the normal release profile
are used throughout. Desktop applications remain active; small per-effect
fluctuations and individual regressions are visible in the raw samples.
Compilation, parity jobs and other test workloads do not overlap these timings.

THP is `[always] madvise never` on this machine. The per-process THP-disabled
control uses the existing preload helper, with no system setting changed;
its path is recorded in the JSON. The nearly flat median control shows that
most aggregate improvement here depends on avoiding sparse huge-page backing.

Compared with our own previous production binary, the
[separate comparison](pr36-before.json) is **1.014x best /
1.022x median** on one core. That includes all upstream
changes and must not be attributed solely to this PR's new optimizations.

## Memory and profiles

[Peak RSS](memory.json), median of five interleaved samples, standard input,
forced single-thread operation:

| Effect | Latest #35 | Candidate |
|---|---:|---:|
| waves | 51.4 MiB | 35.6 MiB |
| highlight | 33.1 MiB | 19.9 MiB |
| binarypath | 218.1 MiB | 219.2 MiB |
| matrix | 31.6 MiB | 19.1 MiB |

The native [wait4 sampler](measure-rss.c) avoids Python's larger pre-exec RSS
floor. [The driver](measure-memory.py) also records automatic-thread samples.
Binarypath's memory is effectively flat; this is not a universal RSS reduction.
The preliminary [sparse-only comparison](sparse-memory.json) used the older
Python-parent method and is retained as exploratory evidence, not the final
memory measurement.

Eight unstripped-baseline `cycles:u` profiles are retained here. They identify
motion batches, cell unlinking and rendering as recurring costs. Raw
[five-sample hardware counters](motion-counters.json) show roughly 1–1.5% fewer
retired instructions for the selected motion-heavy effects; cycle counts are
mixed, including a slower binarypath sample group. End-to-end paired wall and
CPU timings, rather than instruction counts alone, determine the performance
claim. Raw perf recordings remain in ignored `target/refresh/pass5`.

After all correctness jobs finished, a [15-sample confirmation](motion-confirmation.json)
rechecked seven effects: binarypath is 1.025x by median, bouncyballs 1.049x,
blackhole 1.034x, and all seven median ratios exceed 1. The separate
[AVX2 confirmation](avx2-confirmation.json) gives 1.058x for blackhole,
1.022x for burn and 1.032x for waves. These selected checks resolve noisy
individual results; the headline still uses the full 37-effect runs.

## Exploratory pass

These screening runs compare each idea with its immediate predecessor, not
necessarily with upstream; they are not additive speedups. The final fresh
measurements above are the release comparison.

| Idea | Best / median aggregate | Decision |
|---|---:|---|
| [Small pages for update bitmaps](bitmap-screen.json) | 1.019x / 1.020x | Keep; reuse upstream reserve_small |
| [Small pages for renderer character arrays](sparse-screen.json) | 1.004x / 1.006x | Keep; small timing gain, lower measured RSS |
| [Skip unused AVX-512 curve stages](curve-screen.json) | 1.006x / 1.002x | Keep; small gains in movement-heavy effects |
| [Skip overwritten eased ratio division](lazy-screen.json) | 1.009x / 1.001x | Drop; median gain too small |
| [Suppress identical visual-handle records](handle-screen.json) | 0.997x / 0.992x | Drop; slower overall |
| [Direct repaint for zero/one remaining occupant](vacated-screen.json) | 1.003x / 1.001x | Drop; neutral; two-core median regressed |
| [Skip masked overshoot arithmetic for in-segment groups](inside-screen.json) | 1.008x / 1.006x | Keep; small gain, notably binarypath |
| [Skip unused AVX2 curve stages](avx2-screen.json) | 1.013x / 1.013x | Keep; measured separately at tier 3 |

The cell repaint's [two-core screen](vacated-threaded.json) is also retained.
`curve-check`, `lazy-check`, `handle-check`, `vacated-check` and `inside-check`
record 148 successful output comparisons each: all 37 effects, ASCII and
colored Unicode, forced single-thread and automatic-thread operation. Comparisons
include exit status, stdout/stderr byte counts and SHA-256, and require success.
The stronger Rust oracle below checks considerably more options and tiers.

The source patches describe experimental file changes relative to the rebased
bitmap-only source (`4ab0cf0`). `sparse-mappings.patch` contains the final mapping
changes relative to upstream. `curve-skip`, `lazy-math`, `avx2-curve` and
`inside-segment` are alternative complete motion patches. The handle patch goes
on top of `lazy`; the vacated-cell patch includes the sparse renderer allocation
changes. `inside` is byte-identical to the production binary.

## Research used

The [Linux kernel's THP documentation](https://docs.kernel.org/admin-guide/mm/transhuge.html)
explains why touching small portions of large mappings can waste memory with
huge pages. This motivated checking the arrays newly introduced by upstream;
RSS and end-to-end measurements decide whether that applies here.
[Intel's instruction-set reference](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2a-manual.pdf)
documents the mask tests used to recognize groups that do not need extra work.
The optimization candidates come from this engine's profiles and data flow;
the sources do not predict their measured gains.

## Correctness

The [expanded quick oracle](oracle-summary.json) passes **59,344/59,344 cases**:
all 37 effects at each of tiers 1, 2, 3 and 4, with zero failed suites.
It compares the assembly engine with the same binary's Rust engine, including
the newly repaired ANSI option cases, expected-error cases and NaN/oversized
option regressions from upstream. Normal unpaced output exercises automatic
threading; parity dumps exercise the single-thread path.

[The complete standard suite](ci-summary.json) passes: 57 release tests,
19 CLI cases, 354 Python frame comparisons, 41 terminal byte-stream comparisons,
plus signal, terminal-close and resize behavior. All 21 assembly utility tests
also pass at every forced tier (84 checks), and the ISA audit is clean for all
four tiers and the baseline dispatcher. Upstream's decrypt fix resolves the two
Python failures inherited by rounds three/four. The final release binary is
byte-identical to the benchmarked candidate after this validation build.

## Reproduction

Build the baseline in a worktree at `badde3d` and the candidate with the same
NASM-enabled release configuration, and save the binaries separately:

```bash
NASM=/path/to/nasm-3.01/nasm cargo build --release --locked
python3 tools/asm/bench.py baseline candidate --cpu 2 --runs 9 --output single.json
python3 tools/asm/bench.py baseline candidate --cpus 2 4 --runs 9 --output threaded.json
TTFX_ASM_TIER=3 python3 tools/asm/bench.py baseline candidate --cpu 2 --runs 9 --output avx2.json
cc -O2 -Wall -Wextra benchmarks/round5/measure-rss.c -o target/measure-rss
python3 benchmarks/round5/measure-memory.py baseline candidate --sampler target/measure-rss --output memory.json
NASM=/path/to/nasm-3.01/nasm TTFX_ASM=force bin/test
```

For the oracle, compile `tools/asm/hash-output.c` as its header describes,
set `BIN` to that wrapper and `TTFX_ORACLE_REAL_BIN` to the candidate, then run
`tools/asm/oracle-tiers.sh quick 1 2 3 4`. This uses SHA-256 and byte counts
instead of storing very large output streams. The wrapper is never used for
performance measurements. Physical older-tier CPUs and other operating systems
were not tested.
