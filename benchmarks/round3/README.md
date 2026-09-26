# Refresh against updated PR #35 — September 26, 2026

The updated branch is **about 1.10x faster overall than current PR #35**, and
**1.31x faster than the previous PR #36**, on this Ryzen 5 7600X with Linux's
transparent huge-page policy set to `always`. Small ASCII and colored Unicode
workloads improve by roughly **1.40x and 1.50x**. These are same-machine
geometric means across all 37 effects, not universal CPU or per-effect claims.

Upstream baseline: `189840b66521437352ef5822f30eba10ad5b4cc0`.
Final production source: `cfa5554531888d8193e1951c05d7c2e9a3b50cd5`.
Candidate SHA-256: `aab9bbf1e732c2ce84bfd7b88cbc9837792386612ad337b129b6186687c944e9`.

## Integration

The branch includes the complete updated `asm-zen5` history. It uses upstream's
CPU-tier dispatch, dozing, shared eased shapes, scene clones, visual interning,
RNG unrolling, motion paths, dirty-row renderer, and staggered reservations.
The earlier versions of those optimizations in #36 have been superseded.

The remaining production diff is **five assembly files, 51 insertions and eight
deletions**. Sparse character arrays, render lists, and update bitmaps request
normal pages for their initial 2 MiB. Dense arenas and later offsets retain
the system's policy. The hint now rounds the staggered allocation pointer down
to a page boundary and includes its offset in the advised length. All five
sparse prefixes within upstream's shared update reservation receive the hint.
Original mmap bases and lengths still govern release and resize restarts.

[Linux's madvise contract](https://man7.org/linux/man-pages/man2/madvise.2.html)
requires a page-aligned starting address. An unchanged merge of the earlier
hint with upstream's new allocator would violate that requirement.
[The mapping check](sparse-mapping-check.json) observed the expected `nh`
(no-huge-page) mappings; it used the initial integration binary, whose memory
hint is identical to the final version.

The old contiguous scene layout no longer establishes a gain with upstream's
new playback code, so the final branch retains upstream's split layout.
Several additional source experiments and a real LLVM BOLT attempt were
executed and rejected. See [the experiment report](experiments/README.md).
The additional pass after publishing this refresh is in [round four](../round4/README.md).

## Timing

Ratios are baseline time divided by candidate time. Greater than one is faster.
Every listed workload runs all 37 effects; samples alternate in deterministically
shuffled order after one warmup per engine/effect.

| Comparison | Samples | Best wall geomean | Median wall geomean | Median child CPU geomean |
|---|---:|---:|---:|---:|
| [Updated #35, main](pr35-latest.json) | 7 | 1.103x | 1.109x | 1.119x |
| [Updated #35, independent repeat](pr35-repeat.json) | 7 | 1.108x | 1.092x | 1.100x |
| [Previous #36 (`3eb2533`)](pr36-before.json) | 5 | 1.309x | 1.311x | 1.327x |
| [Small ASCII (80x24, seed 7)](holdout-small.json) | 5 | 1.405x | 1.377x | 1.463x |
| [Colored Unicode (80x24, seed 29)](holdout-unicode.json) | 5 | 1.497x | 1.486x | 1.634x |
| [Large ASCII (240x70, seed 19)](holdout-large.json) | 3 | 1.067x | 1.059x | 1.063x |
| [THP disabled in both processes](holdout-thp-disabled.json) | 3 | 0.990x | 0.992x | 0.991x |

The first two runs agree on roughly 10% overall improvement. This does **not**
improve every effect in every statistic: binarypath is about 0.5% slower in
both main runs; the repeat also has noisy median regressions for overflow and
slice despite improving their best times. Large-input results include small
individual regressions too. All raw samples are retained.

The THP-disabled control is approximately 1% slower overall: once huge-page
allocation is disabled, the hint is redundant and its system calls still have
a cost. This refresh does not establish an improvement on systems configured
that way. The control uses [the existing preload helper](../round2/disable-thp.c)
to set `PR_SET_THP_DISABLE` in both benchmark processes; system policy is untouched.

<details>
<summary>Main comparison: all effects, milliseconds, best of seven</summary>

| Effect | Updated #35 | Candidate | Best speedup | Median speedup |
|---|---:|---:|---:|---:|
| beams | 22.07 | 19.64 | 1.124x | 1.197x |
| binarypath | 236.23 | 237.49 | 0.995x | 0.996x |
| blackhole | 118.06 | 112.78 | 1.047x | 1.032x |
| bouncyballs | 59.92 | 56.06 | 1.069x | 1.074x |
| bubbles | 85.77 | 82.54 | 1.039x | 1.043x |
| burn | 34.64 | 32.74 | 1.058x | 1.055x |
| colorshift | 27.02 | 24.68 | 1.094x | 1.099x |
| crumble | 71.62 | 67.78 | 1.057x | 1.033x |
| decrypt | 33.32 | 29.25 | 1.139x | 1.159x |
| errorcorrect | 29.40 | 26.86 | 1.095x | 1.098x |
| expand | 34.59 | 32.96 | 1.049x | 1.054x |
| fireworks | 98.62 | 96.25 | 1.025x | 1.028x |
| highlight | 9.04 | 6.54 | 1.381x | 1.399x |
| laseretch | 74.34 | 72.75 | 1.022x | 1.022x |
| matrix | 43.81 | 41.35 | 1.059x | 1.055x |
| middleout | 20.50 | 18.12 | 1.131x | 1.124x |
| orbittingvolley | 27.99 | 25.54 | 1.096x | 1.178x |
| overflow | 25.85 | 25.00 | 1.034x | 1.111x |
| pour | 32.35 | 29.79 | 1.086x | 1.070x |
| print | 17.77 | 15.43 | 1.152x | 1.172x |
| rain | 35.75 | 32.45 | 1.102x | 1.116x |
| randomsequence | 9.77 | 7.29 | 1.340x | 1.296x |
| rings | 133.85 | 133.09 | 1.006x | 1.033x |
| scattered | 48.57 | 47.28 | 1.027x | 1.041x |
| slice | 20.37 | 18.23 | 1.118x | 1.111x |
| slide | 26.94 | 24.12 | 1.117x | 1.115x |
| smoke | 25.02 | 21.80 | 1.148x | 1.131x |
| spotlights | 50.01 | 47.81 | 1.046x | 1.061x |
| spray | 44.17 | 41.07 | 1.076x | 1.071x |
| swarm | 172.29 | 166.78 | 1.033x | 1.024x |
| sweep | 11.28 | 8.46 | 1.335x | 1.273x |
| synthgrid | 13.10 | 10.81 | 1.212x | 1.235x |
| thunderstorm | 27.99 | 25.27 | 1.108x | 1.113x |
| unstable | 48.15 | 46.79 | 1.029x | 1.033x |
| vhstape | 37.65 | 35.40 | 1.064x | 1.076x |
| waves | 25.44 | 22.42 | 1.135x | 1.132x |
| wipe | 9.13 | 7.13 | 1.281x | 1.310x |

</details>

## Peak resident memory

MiB, median of five interleaved Linux `wait4` / `ru_maxrss` measurements using
the standard workload. The complete per-process measurements and arguments
are in [memory.json](memory.json).

| Effect | Updated #35 | Candidate |
|---|---:|---:|
| waves | 69.9 | 37.7 |
| highlight | 57.5 | 23.9 |
| binarypath | 260.4 | 211.3 |
| matrix | 77.6 | 23.9 |

## Conditions and limits

- Ryzen 5 7600X (Zen 4), Linux 7.2.5-3-omarchy, rustc 1.98.1, NASM 3.01.
- Both revisions built with `cargo build --release --locked`, the same lockfile
  and default features; assembly at all four CPU tiers was linked. The benchmark
  uses `TTFX_ASM=force`; this CPU selects tier 4. A Rust fallback is an error.
- Standard input: 200x50 canvas, 190x46 ASCII text, seed 1, frame rate zero,
  stdout to `/dev/null`. Matrix and thunderstorm use the virtual clock.
- Parent and child pinned to logical CPU 2. No compiler, oracle, or BOLT jobs
  from this task ran during the final measurements. Desktop applications and
  a separate benchmark on CPU 4 remained active. Cache, power, and system
  resources are still shared; these are not measurements on an idle machine.
- Child CPU time is also recorded to distinguish scheduling delays from
  execution time. It does not eliminate cache, thermal, or SMT interference.
- No changed frame count, approximate math, changed random draws, output-device
  shortcut, extra application threads, or precomputed output.
- Interactive frame limits and terminal throughput can dominate wall time.
  Zen 5 and physical older-ISA machines were not measured.

## Correctness

[CI summary](ci-summary.json): all 57 release tests pass; assembly utility
comparisons pass 21/21 at each of tiers 1, 2, 3, and 4. The instruction-set
audit is clean for all four tiers and the baseline dispatcher. The CLI corpus
passes 19/19, complete terminal streams pass 41/41, and signal, terminal-close,
and resize/restart checks all pass. Lower tiers were forced on this Zen 4 CPU;
this is not testing on physical older processors.

The assembly-vs-Rust oracle passes **54,756/54,756 cases across all four tiers**,
covering all 37 effects at each tier (13,689 cases per tier):
[the complete record](oracle-summary.json). The earlier
[tier-4 checkpoint](oracle-tier4-summary.json) is retained as published history.
The sweep uses the upstream `quick` option matrix with the native SHA-256
wrapper. This refresh does not re-claim the earlier 91,641-case full-suite result
for the new binary.

**`./bin/test` exits 1:** its Python frame suite passes 352/354.
The Python parity entry point has two inherited colored-decrypt failures
(seeds 42 and 1337); both reproduce with updated #35. The final
candidate's output is byte-identical to upstream for each failing case:
[inherited failure comparison](inherited-decrypt.json). Forcing Rust passes
both cases. The terminal and resize checks that follow the failing suite
were run separately.

## Reproduction

Keep separate worktrees for upstream `189840b` and production source `cfa5554`.
Build each with the same NASM and toolchain, then save the release binaries:

```sh
NASM=/path/to/nasm cargo build --release --locked
python3 tools/asm/bench.py /path/to/upstream /path/to/candidate \
  --cpu 2 --runs 7 --output /tmp/pr35-comparison.json
python3 benchmarks/round3/measure-memory.py /path/to/upstream /path/to/candidate \
  --output /tmp/pr35-memory.json
```

The benchmark JSON includes the complete arguments, input hashes, binary hashes,
every wall/CPU sample, and huge-page policy. For the separate THP-disabled
control, compile the helper and preload it into the same command:

```sh
cc -O2 -shared -fPIC benchmarks/round2/disable-thp.c -o /tmp/disable-thp.so
LD_PRELOAD=/tmp/disable-thp.so python3 tools/asm/bench.py \
  /path/to/upstream /path/to/candidate --cpu 2 --runs 3 \
  --output /tmp/pr35-no-thp.json
```

The [binary manifest](binary-manifest.json) also identifies exploratory builds.
[Round one](../README.md) and [round two](../round2/README.md) are historical
comparisons with the old upstream baseline, not current performance claims.
