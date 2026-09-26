# Further optimization exploration — September 26, 2026

This pass was performed **after** publishing the refresh of PR #36 at `6e9e162`.
The performance baseline for every experiment here is the refreshed binary
from source `cfa5554`, SHA-256
`aab9bbf1e732c2ce84bfd7b88cbc9837792386612ad337b129b6186687c944e9`.
The comparison against upstream #35 remains in [round three](../round3/README.md).

## Research and profiling

- [AMD's Ryzen optimization presentation](https://gpuopen.com/gdc-presentations/2024/GDC2024_AMD_Ryzen_Processor_Software_Optimization.pdf)
  discusses cache locality, data layout and profiling. It motivated testing
  path records with frequently accessed fields together, followed by a
  separate array for those fields. The measurements below determine the result;
  the guidance itself does not establish a speedup.
- [Linux's perf security documentation](https://docs.kernel.org/admin-guide/perf-security.html)
  confirms that the existing `perf_event_paranoid=2` setting permits per-process
  user-space profiling. A locally extracted perf 7.2.3 package and its two
  missing libraries enabled hardware-counter collection without changing system
  settings or installing system packages.
- [The xoshiro authors' vectorized generator](https://prng.di.unimi.it/xoshiro256%2B%2B-vect-speed.c)
  operates on multiple generator states. That approach changes the single
  xoshiro stream this program must reproduce. It was reviewed, not substituted
  for the existing generator, and contributes no claimed speedup.

Cycle sampling used the unoptimized, unstripped BOLT-input build from round
three (SHA-256 `bce7304c4647c16d378e854aa2ca3d9e866bc5aebd65409661bc19185f461d02`),
with symbols for the assembly routines, `cycles:u` and period 100003. The output
was discarded, `TTFX_ASM=force` was set, and the process ran on CPU 2 with the
standard 200x50 / 190x46 / seed-1 workload. Sampling is a hotspot guide;
short profiles are not precise estimates of small costs.

[Binarypath](binarypath-profile.txt) spends substantial time in path stepping,
coordinate interpolation, motion bookkeeping and render-cell ownership.
[Bouncyballs](bouncyballs-profile.txt), [rings](rings-profile.txt),
[swarm](swarm-profile.txt), and [fireworks](fireworks-profile.txt) confirm that
motion is a broad target. [Matrix](matrix-profile.txt) instead spends about a
third of sampled user cycles generating random values. [Waves](waves-profile.txt)
and [highlight](highlight-profile.txt) emphasize animation and rendering.
The [annotated line interpolation routine](line-annotate.txt) informed the AVX
trial. Ordinary cycle sampling can skid; these samples are not precise IBS data.

## Experiments

Every complete screening comparison covers all 37 effects, interleaves engine
order after a warmup, and retains wall and child-CPU samples. The screening
runs below **overlapped the four-job correctness sweep**, which ran on CPUs
other than 2 and its SMT sibling. Early builds also overlapped screening;
later builds were pinned to CPUs 0, 1, 3 and 5. Shared cache, power, and desktop
activity still affect timings. These samples select experiments for follow-up;
they do not replace round three's performance claim.

| Experiment | Samples | Best wall geomean | Median wall geomean |
|---|---:|---:|---:|
| [Defer cell ownership](deferred-bench.json) | 5 | 0.958x | 0.961x |
| [AVX line interpolation](vex-bench.json) | 5 | 1.002x | 1.005x |
| [Hot fields in first path cache line](path-layout-bench.json) | 5 | 1.001x | 1.000x |
| [Separate hot/cold path arrays](split-path-bench.json) | 5 | 0.998x | 0.991x |
| [Shared step cache, first version](memo-path-bench.json) | 5 | 1.001x | 0.996x |
| [Shared step cache, aligned version](memo-v3-bench.json) | 5 | 0.998x | 0.990x |
| [Blank-cell quads](space-quad-bench.json) | 7 | 0.985x | 0.997x |

Deferred ownership maintains the occupant lists immediately but resolves each
changed cell's final owner only once before rendering. Its queue and final
scans cost more than they saved. The AVX trial preserves the same double
operations, rounding and exceptional fallback. The two path layouts preserve
record contents; a prototype exposed `grow_array`'s requirement that count and
capacity remain adjacent, which was corrected before the recorded comparison.
The experiment adds an assembly-time assertion for that requirement.

The shared-path cache uses eight entries per immutable shared segment list.
It compares step, maximum steps, total-distance bits, easing, and the complete
walk index, then restores the exact coordinate, last distance and walk state.
Only reused lists without segment callbacks can use it; unsharing clears the
cache flag. The second version removes duplicate pointer setup on ordinary
paths, and the third aligns cache records to 64-byte boundaries.

[Interleaved hardware-counter measurements](memo-counters.json), three samples
per engine/effect, show why the cache is a tradeoff. For Binarypath, median
instructions fell from 2.369 billion to 2.128 billion (about 10%), but reported
L1-data misses rose from 76.0 million to 83.6 million, and cache misses from
33.5 million to 40.0 million. These are user-space PMU counts under the same
concurrent workload, not a controlled cache-latency experiment.

The blank-cell trial recognizes four `space_handle` values and emits their
four spaces directly. It uses SSE2 at lower tiers and VEX instructions at
AVX tiers. The added check also costs work in blocks containing other visuals.

Each completed source experiment was compared with the published binary on
all 37 effects using both colored Unicode (seed 29, 80x24) and the standard
large ASCII input (seed 1, 200x50). Reports retain exit status, output/error
lengths and SHA-256 digests. Passing these 74 cases is only a screening check,
not a replacement for the published branch's full oracle sweep.

## Final decision

**None of these experiments is retained in production.** The PR keeps the
measured round-three improvement and its smaller assembly diff.

After the oracle sweep and all compilation finished, the best cache variant
was measured again across all 37 effects. The [nine-sample standard repeat](memo-v2-repeat.json)
is **1.002x best / 1.004x median** overall; the
[five-sample small-input holdout](memo-v2-small.json) is
**0.998x best / 1.012x median**. Desktop applications and
the unrelated benchmark on CPU 4 remained active. Binarypath improves by
about 4–5% in the best times, but this does not establish a reliable aggregate
win worth the cache's extra memory and maintenance cost. The small-input
median is especially noisy; raw child-CPU and wall samples remain available.

The final production binary has passed **54,756/54,756** upstream `quick`
oracle cases, all 37 effects at each of four tiers. See
[the completed oracle summary](../round3/oracle-summary.json). The two
inherited Python colored-decrypt failures described in round three remain.

The useful remaining lead is reducing the shared-step cache's footprint while
retaining full key validation and callback semantics. The measured prototype
is preserved here so a later experiment can start from evidence rather than
repeating this work. It is not shipped or credited with a speedup.


## Reproduction

Use the NASM-enabled release build and benchmark commands from round three.
Every experiment's source patch is retained alongside its raw results and
[binary hashes](binary-manifest.json). Patches apply to the refreshed source;
`memo-v1`, `memo-v2` and `memo-v3` are alternative complete patches.

```bash
python3 tools/asm/bench.py target/refresh/final candidate \
  --cpu 2 --runs 7 --output comparison.json
LD_LIBRARY_PATH=target/toolchain/perf/usr/lib \
  target/toolchain/perf/usr/bin/perf record -e cycles:u -c 100003 \
  -o profile.data -- taskset -c 2 unstripped-ttfx [effect arguments]
```

The profile command also needs the input text and `TTFX_ASM=force`; the earlier
conditions list the complete benchmark dimensions. Clock-driven effects use
`--virtual-clock`. The experiment binaries, toolchain packages and raw perf
recordings remain in ignored `target/refresh/pass4` / `target/toolchain`;
readable profile reports and test records are committed here.
