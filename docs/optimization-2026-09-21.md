# Optimization experiments, 2026-09-21

Comparison against commit `7203e35` (ttfx 0.3.2), rebuilt with the same Rust
1.98.1 toolchain and locked dependencies. Measurements use an AMD Ryzen 9
9955HX on Linux, release defaults, and CPU affinity. No native-CPU compiler
flags or dependency changes were used.

## Results

The six comparison sweeps show faster measured medians for all 37 effects.
Median effect speedups range from 1.10x to 1.14x. Spotlights benefits most:
1.80x at 200x50 with glibc, and 2.68x with the static musl build.

| Workload | Timed repetitions | Median effect speedup |
|---|---:|---:|
| glibc, 100x30, true color | 11 | 1.140x |
| glibc, 200x50, true color | 11 | 1.111x |
| glibc, 400x100, true color | 3–5 | 1.104x |
| glibc, 200x50, no color | 5 | 1.114x |
| glibc, 200x50, xterm color | 5 | 1.113x |
| musl, 200x50, true color | 5 | 1.139x |

At 400x100, spotlights improves from 2,513.93 ms to 1,291.55 ms (1.946x).
The smallest gains at that size are around 1–2%, close to timing noise.
Follow-up runs with 11–21 repetitions reproduced improvements of 1.1–2.2%
for vhstape and waves; their results are included separately in the CSV.
Single-character startup is unchanged at about 1.63 ms (501 repetitions).

[All per-effect results](benchmarks/2026-09-21.csv) include sample counts,
timing standard deviations, output sizes, and output hashes for every workload.

Selected timings for complete animations at 200x50 with glibc and true color:

| Effect | Before, ms | After, ms | Speedup |
|---|---:|---:|---:|
| spotlights | 410.81 | 228.47 | 1.798x |
| unstable | 178.38 | 141.96 | 1.257x |
| expand | 119.47 | 95.33 | 1.253x |
| scattered | 137.32 | 111.71 | 1.229x |
| blackhole | 429.09 | 349.41 | 1.228x |
| wipe | 42.18 | 34.65 | 1.217x |
| overflow | 105.91 | 88.43 | 1.198x |
| waves | 430.37 | 418.93 | 1.027x |

Separate allocation tracing at 200x50 confirms that much of the improvement
comes from removing transient allocations. These counts include successful
`malloc`, `calloc`, and `realloc` calls; tracing was disabled for timings.

| Effect | Before | After |
|---|---:|---:|
| spotlights | 8,821,114 | 63,942 |
| overflow | 6,949,064 | 211,546 |
| waves | 5,879,899 | 4,498,451 |

Spotlights' total requested allocation traffic falls from about 601 MB to
21.6 MB. Its peak live allocation size changes much less: 12.5 MB to 11.9 MB.

## Method

`tools/tests/bench_compare.py` runs complete animations through the real CLI.
It checks output length, SHA-256, and stderr before timing, alternates the order
of the two executables, and reports medians. Both builds receive identical
input, terminal dimensions, and seed. Frame pacing is disabled and the virtual
clock makes duration-driven effects perform the same work.

The default generated input fills most of the terminal. These results measure
CPU throughput with output redirected; configured animation durations and the
terminal emulator's drawing speed are separate concerns.

```sh
cargo build --release --locked
python3 tools/tests/bench_compare.py /tmp/ttfx-before target/release/ttfx \
  --size 200x50 --repeats 11 --warmups 2 --cpu 8 \
  --json /tmp/ttfx-comparison.json
```

Build `/tmp/ttfx-before` from the baseline commit with the same toolchain and
release settings. Omit `--cpu` where CPU affinity is unavailable. The JSON
records executable and input hashes, output hashes, and every timing sample.
Use `--terminal-options=--no-color` or `--terminal-options=--xterm-colors` to
check other color modes; `--input`, `--seed`, and `--effects` select workloads.

## Retained changes

- Construct generated RGB colors directly, retaining lowercase hex identity,
  hashing, and the existing fallback for extrapolated out-of-range channels.
- Replace rectangular gradient hash maps with dense storage, preserving each
  direction's iteration order and caller edits to the public `order` vector.
- Estimate gradient fraction indices, then check the original floating-point
  division boundaries. Exact boundaries and their adjacent floats retain the
  original color.
- Borrow symbol/color distributions during scene construction and move frame
  queues directly, removing intermediate allocations.
- Reuse uniquely owned visual and string allocations. Existing strong and
  weak references retain the original replacement semantics.
- Reuse ordered bitmap sets in spotlights and stream ellipse coordinates.
  Character visits and set differences remain in ascending ID order.
- Inline the cached ordered-map lookup and use native ties-to-even rounding
  for finite values, preserving the previous non-finite behavior.
- Copy formatted symbols in fixed 32- or 63-byte blocks using safe vector
  operations, then truncate the padding. This removes the renderer's raw
  pointer copy while retaining its constant-size-copy advantage.

## Rejected theories

Skipping reference-count updates when a scene kept displaying the same visual
made waves about 6% slower in the controlled comparison, so it was removed.
Variable-length renderer copies were slower than fixed-size copies; adding an
8-byte specialization did not improve on the 32/63-byte split.

Collecting the streaming ellipse iterator slowed the public vector-returning
API for small circles. The public function therefore retains an eager nested
loop, sharing the coordinate calculation with the iterator used by spotlights.
The final vector-building benchmark stays within about 1% of the original
across the tested diameters (0, 1, 2, 4, 8, 16, 64, and 128).

## Regression coverage

The checks exercise observable output as well as the library API:

- All 36 Rust tests in release and debug modes; all 36 release tests and a
  build for static musl.
- The repository's CLI corpus, signal/terminal-close checks, resize checks,
  354 Python frame-parity cases, and 41 tty byte-stream parity cases.
- The additional 154-case input/canvas parity matrix.
- During selection, 8,850 extra seeded native comparisons and 3,540 musl
  comparisons using the existing parity scenarios, capped at 1,000 frames
  per animation.
- 888 complete native and 888 complete musl animation comparisons across
  Unicode, ANSI-colored, and sparse input; four canvas sizes; multiple seeds
  and color modes.
- 480 additional complete custom configurations covering beam widths and
  falloffs, uneven gradients, tiny canvases, color handling, and Unicode
  symbols in spotlights, overflow, matrix, and waves.
- Twenty randomized library API runs comparing original and optimized builds:
  color conversion, brightness, gradient construction and lookup, appearance
  changes with retained strong/weak references, and scene playback/reset.
- AddressSanitizer and leak-detection tests, plus all 37 complete effects under
  AddressSanitizer with output checked against the original build. The CLI
  already skips arena teardown immediately before exit; the sanitizer harness
  enables normal teardown so leak detection checks library cleanup.

New permanent tests cover color identity, gradient boundary floats and mapping
order, halfway rounding and one million random floating-point bit patterns,
unequal symbol/gradient distributions, partial scene resets, visual ownership
and style transitions, inline/heap symbol boundaries, and empty ellipses.

## Direct comparison with Python TTE

A subsequent comparison of the optimized glibc build against unmodified Python
TTE 0.15.0 on CPython 3.14.7 measures a **33.0x median speedup** across the 35
effects without fixed wall-clock durations. Individual speedups range from
20.9x to 54.6x. Summing the best timings for each effect gives 238.05 seconds
for Python and 7.73 seconds for ttfx, a 30.8x aggregate speedup.

This uses the README's 200x50 workload (46 lines of 190 characters), best of
three runs per implementation, alternating execution order, and CPU 8 affinity.
Both real CLIs run with frame pacing disabled and output redirected to
`/dev/null`; every exit status and stderr is checked. Rust uses seed 1, while
Python uses its standard native RNG without the parity shim, so randomized
workloads vary between runs. Matrix and thunderstorm are excluded because
their completion times depend on fixed durations.

These are fresh end-to-end measurements, separate from the controlled
before/after Rust comparisons above. The earlier README's 27.5x figure used
five repetitions, so the difference between those headline numbers should
not be attributed entirely to this optimization pass.

[Raw Python comparison results](benchmarks/2026-09-21-python.json) include
every timing sample, the reference commit, and binary/input hashes.
