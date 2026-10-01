# Circle-coordinate deduplication — 2026-10-01

`find_coords_on_circle` maintained a hash set even when duplicates were allowed.
When uniqueness was required, it checked membership and then inserted the same
point. The change creates a set only when deduplication can be needed and uses
`insert`'s result to decide whether to append a point. Coordinate arithmetic,
iteration order, the public API, and vector growth are unchanged. The optimization
and benchmark use safe Rust and add no dependencies.

This improves the inner loop of circle construction, shared by blackhole, rings,
and swarm. Blackhole also constructs a circle during its collapse transition.
Complete-animation performance is mostly unchanged; the measured gains are local
to this helper.

All **48 focused benchmarks** improved: **1.148–5.017× throughput**, with
**13.8–79.7% fewer user-space CPU cycles**. Allocation calls and requested bytes
fell in 30 cases and were unchanged in the other 18. Every case improved on
throughput, CPU time, and cycles under simultaneous confidence intervals.

| Radius / limit / unique | Time per call, before → after | User cycles, before → after | Allocation calls | Requested bytes | Throughput gain |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 / true | 82.27 → 37.73 ns | 228.76 → 99.46 | 2 → 1 | 148 → 64 | 2.180× |
| 1 / 2 / true | 180.49 → 156.17 ns | 475.97 → 407.61 | 2 → 2 | 148 → 148 | 1.156× |
| 10 / automatic / true | 9.69 → 7.99 µs | 25,579 → 21,025 | 11 → 11 | 6,364 → 6,364 | 1.214× |
| 100 / automatic / true | 84.08 → 66.30 µs | 231,483 → 185,980 | 18 → 18 | 67,596 → 67,596 | 1.268× |
| 100 / 1000 / false | 124.26 → 24.77 µs | 328,652 → 66,654 | 19 → 9 | 102,428 → 32,704 | 5.017× |

<details>
<summary>All 48 focused cases</summary>

Values are medians; times, cycles, allocation calls, and requested bytes are per helper call. Limit 0 selects the automatic point count.

| Case (radius / limit / unique) | Elapsed ns | CPU ns | User cycles | Allocation calls | Requested bytes | Throughput gain |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 / false | 79.29 → 34.76 | 80.92 → 36.20 | 227.69 → 99.33 | 2 → 1 | 148 → 64 | 2.281× |
| 1 / 1 / true | 82.27 → 37.73 | 83.76 → 40.10 | 228.76 → 99.46 | 2 → 1 | 148 → 64 | 2.180× |
| 1 / 2 / false | 152.16 → 63.46 | 154.08 → 65.20 | 404.92 → 168.90 | 2 → 1 | 148 → 64 | 2.398× |
| 1 / 2 / true | 180.49 → 156.17 | 182.60 → 158.26 | 475.97 → 407.61 | 2 → 2 | 148 → 148 | 1.156× |
| 1 / 0 / false | 594.19 → 211.78 | 598.32 → 215.64 | 1612.73 → 562.78 | 4 → 2 | 428 → 192 | 2.806× |
| 1 / 0 / true | 711.74 → 574.83 | 715.84 → 578.40 | 1985.64 → 1555.62 | 4 → 4 | 428 → 428 | 1.238× |
| 1 / 1000 / false | 62561.81 → 24439.47 | 62932.00 → 24880.00 | 168635.32 → 66661.65 | 12 → 9 | 33228 → 32704 | 2.560× |
| 1 / 1000 / true | 89288.49 → 62378.74 | 89736.00 → 62756.00 | 235802.66 → 163332.05 | 6 → 6 | 972 → 972 | 1.431× |
| 3 / 1 / false | 86.21 → 38.21 | 88.28 → 40.00 | 228.73 → 99.60 | 2 → 1 | 148 → 64 | 2.256× |
| 3 / 1 / true | 85.57 → 36.41 | 87.34 → 38.10 | 229.02 → 99.10 | 2 → 1 | 148 → 64 | 2.350× |
| 3 / 2 / false | 129.98 → 58.11 | 132.26 → 60.16 | 404.77 → 168.92 | 2 → 1 | 148 → 64 | 2.237× |
| 3 / 2 / true | 172.84 → 149.03 | 175.40 → 151.47 | 474.69 → 407.31 | 2 → 2 | 148 → 148 | 1.160× |
| 3 / 0 / false | 2233.72 → 579.46 | 2247.46 → 592.55 | 5894.88 → 1534.75 | 8 → 4 | 2044 → 960 | 3.855× |
| 3 / 0 / true | 2774.35 → 2276.35 | 2787.31 → 2289.00 | 7259.78 → 5960.22 | 8 → 8 | 2044 → 2044 | 1.219× |
| 3 / 1000 / false | 64018.42 → 25171.84 | 64568.00 → 25656.00 | 173006.68 → 66642.59 | 14 → 9 | 34892 → 32704 | 2.543× |
| 3 / 1000 / true | 85619.84 → 61917.74 | 86080.00 → 62456.00 | 241648.30 → 168859.28 | 10 → 10 | 4172 → 4172 | 1.383× |
| 10 / 1 / false | 87.41 → 37.80 | 89.14 → 39.84 | 228.61 → 99.10 | 2 → 1 | 148 → 64 | 2.312× |
| 10 / 1 / true | 88.50 → 39.32 | 90.36 → 41.36 | 228.21 → 102.13 | 2 → 1 | 148 → 64 | 2.251× |
| 10 / 2 / false | 156.16 → 64.82 | 157.74 → 66.64 | 404.99 → 168.14 | 2 → 1 | 148 → 64 | 2.409× |
| 10 / 2 / true | 180.57 → 155.45 | 182.18 → 157.40 | 474.48 → 407.35 | 2 → 2 | 148 → 148 | 1.162× |
| 10 / 0 / false | 7988.02 → 1714.17 | 8027.22 → 1749.76 | 20893.86 → 4467.54 | 11 → 5 | 6364 → 1984 | 4.660× |
| 10 / 0 / true | 9692.88 → 7985.17 | 9743.79 → 8023.86 | 25578.99 → 21024.99 | 11 → 11 | 6364 → 6364 | 1.214× |
| 10 / 1000 / false | 72444.88 → 25278.67 | 72904.00 → 25704.00 | 192265.59 → 66645.69 | 16 → 9 | 41452 → 32704 | 2.866× |
| 10 / 1000 / true | 98684.09 → 70589.02 | 99104.00 → 70980.00 | 262221.86 → 187698.06 | 13 → 13 | 12780 → 12780 | 1.398× |
| 50 / 1 / false | 85.40 → 37.00 | 87.50 → 39.18 | 229.53 → 100.28 | 2 → 1 | 148 → 64 | 2.308× |
| 50 / 1 / true | 87.58 → 37.66 | 89.74 → 39.42 | 229.43 → 99.53 | 2 → 1 | 148 → 64 | 2.325× |
| 50 / 2 / false | 154.12 → 64.06 | 156.20 → 66.08 | 404.68 → 169.16 | 2 → 1 | 148 → 64 | 2.406× |
| 50 / 2 / true | 177.50 → 154.50 | 179.34 → 156.32 | 475.05 → 406.53 | 2 → 2 | 148 → 148 | 1.149× |
| 50 / 0 / false | 34922.03 → 8012.58 | 35153.86 → 8210.17 | 93416.65 → 21381.08 | 16 → 8 | 33788 → 16320 | 4.358× |
| 50 / 0 / true | 42999.89 → 35011.98 | 43259.37 → 35248.06 | 116680.41 → 94069.57 | 16 → 16 | 33788 → 33788 | 1.228× |
| 50 / 1000 / false | 97343.53 → 25261.26 | 97872.00 → 25668.00 | 257565.62 → 66615.07 | 18 → 9 | 67596 → 32704 | 3.853× |
| 50 / 1000 / true | 124552.01 → 95774.94 | 125028.00 → 96236.00 | 332913.81 → 256131.21 | 18 → 18 | 67596 → 67596 | 1.300× |
| 100 / 1 / false | 83.77 → 36.87 | 85.54 → 38.80 | 228.36 → 99.17 | 2 → 1 | 148 → 64 | 2.272× |
| 100 / 1 / true | 76.06 → 32.79 | 77.86 → 34.22 | 228.32 → 99.33 | 2 → 1 | 148 → 64 | 2.320× |
| 100 / 2 / false | 146.00 → 60.88 | 148.00 → 62.48 | 404.65 → 168.12 | 2 → 1 | 148 → 64 | 2.398× |
| 100 / 2 / true | 174.06 → 151.58 | 175.52 → 153.58 | 475.99 → 407.67 | 2 → 2 | 148 → 148 | 1.148× |
| 100 / 0 / false | 68645.19 → 15726.79 | 69140.00 → 16060.00 | 184971.64 → 42206.39 | 18 → 9 | 67596 → 32704 | 4.365× |
| 100 / 0 / true | 84082.73 → 66295.61 | 84508.00 → 66748.00 | 231482.88 → 185980.28 | 18 → 18 | 67596 → 67596 | 1.268× |
| 100 / 1000 / false | 124259.36 → 24768.53 | 124732.00 → 25156.00 | 328652.12 → 66654.06 | 19 → 9 | 102428 → 32704 | 5.017× |
| 100 / 1000 / true | 148830.67 → 120203.11 | 149380.00 → 120644.00 | 402933.60 → 328535.38 | 19 → 19 | 102428 → 102428 | 1.238× |
| 200 / 1 / false | 86.31 → 38.38 | 87.96 → 40.12 | 229.18 → 99.44 | 2 → 1 | 148 → 64 | 2.249× |
| 200 / 1 / true | 86.94 → 37.84 | 88.56 → 39.90 | 229.33 → 99.40 | 2 → 1 | 148 → 64 | 2.297× |
| 200 / 2 / false | 150.57 → 62.82 | 152.26 → 64.82 | 404.78 → 168.90 | 2 → 1 | 148 → 64 | 2.397× |
| 200 / 2 / true | 176.47 → 153.33 | 178.74 → 156.74 | 474.90 → 409.32 | 2 → 2 | 148 → 148 | 1.151× |
| 200 / 0 / false | 138712.49 → 31911.87 | 139272.00 → 32372.00 | 368213.48 → 83673.56 | 20 → 10 | 135196 → 65472 | 4.347× |
| 200 / 0 / true | 165142.63 → 130871.94 | 165648.00 → 131392.00 | 460214.52 → 369171.28 | 20 → 20 | 135196 → 135196 | 1.262× |
| 200 / 1000 / false | 114474.88 → 23863.67 | 115044.00 → 24276.00 | 322179.66 → 66519.05 | 19 → 9 | 102428 → 32704 | 4.797× |
| 200 / 1000 / true | 129835.84 → 105044.04 | 130332.00 → 105496.00 | 395896.48 → 323024.85 | 19 → 19 | 102428 → 102428 | 1.236× |

</details>

Some complete-animation medians are slightly slower; none shows a statistically
detected regression under the simultaneous intervals. Small changes cannot be
excluded on this VM. Allocation counts and requested bytes match in all 37 effects.

<details>
<summary>All 37 complete-animation checks</summary>

Intervals describe the median paired before/after ratio, with the simultaneous confidence method described below. Ratios above 1 favor the optimization. An interval containing 1 remains compatible with small gains or losses. Allocation calls and requested bytes are identical before and after for every effect.

| Effect | Wall ms, before → after | Wall ratio interval | CPU-time ratio interval | User-cycle ratio interval | Counter samples per build |
| --- | ---: | ---: | ---: | ---: | ---: |
| beams | 59.55 → 59.37 | [0.973, 1.032] | [0.985, 1.032] | [0.992, 1.022] | 21 |
| binarypath | 415.37 → 409.68 | [0.986, 1.027] | [0.984, 1.019] | [0.988, 1.015] | 61 |
| blackhole | 298.52 → 297.26 | [0.927, 1.027] | [0.977, 1.014] | [0.978, 1.010] | 61 |
| bouncyballs | 137.30 → 135.52 | [0.989, 1.089] | [0.972, 1.019] | [0.981, 1.010] | 21 |
| bubbles | 211.47 → 211.93 | [0.982, 1.022] | [0.999, 1.023] | [0.996, 1.018] | 61 |
| burn | 94.50 → 94.90 | [0.964, 1.019] | [0.994, 1.017] | [0.989, 1.010] | 61 |
| colorshift | 102.26 → 101.48 | [0.980, 1.041] | [0.967, 1.038] | [0.975, 1.023] | 21 |
| crumble | 237.82 → 239.86 | [0.970, 1.018] | [0.995, 1.019] | [0.994, 1.017] | 61 |
| decrypt | 77.65 → 76.89 | [0.960, 1.037] | [0.942, 1.151] | [0.971, 1.028] | 21 |
| errorcorrect | 80.07 → 77.82 | [0.975, 1.046] | [0.969, 1.033] | [0.981, 1.029] | 21 |
| expand | 81.64 → 80.14 | [0.978, 1.051] | [0.948, 1.042] | [0.943, 1.030] | 21 |
| fireworks | 262.97 → 260.72 | [0.960, 1.054] | [0.958, 1.034] | [0.969, 1.022] | 21 |
| highlight | 15.31 → 14.84 | [1.017, 1.052] | [1.010, 1.044] | [0.997, 1.015] | 61 |
| laseretch | 211.35 → 212.22 | [0.737, 1.074] | [0.991, 1.014] | [0.992, 1.010] | 61 |
| matrix | 108.59 → 111.33 | [0.932, 1.010] | [0.994, 1.011] | [0.999, 1.006] | 61 |
| middleout | 47.34 → 46.80 | [0.988, 1.035] | [0.998, 1.023] | [0.996, 1.014] | 61 |
| orbittingvolley | 77.56 → 77.28 | [0.991, 1.009] | [0.988, 1.064] | [0.972, 1.028] | 21 |
| overflow | 58.38 → 57.84 | [0.987, 1.022] | [0.963, 1.054] | [0.990, 1.013] | 21 |
| pour | 86.00 → 84.83 | [0.964, 1.032] | [0.997, 1.019] | [0.993, 1.015] | 61 |
| print | 34.33 → 33.78 | [0.977, 1.075] | [0.946, 1.070] | [0.980, 1.028] | 21 |
| rain | 127.82 → 127.41 | [0.993, 1.032] | [0.979, 1.041] | [0.993, 1.025] | 21 |
| randomsequence | 20.28 → 19.90 | [0.926, 1.094] | [0.972, 1.057] | [0.992, 1.028] | 21 |
| rings | 413.97 → 412.22 | [0.864, 1.028] | [0.925, 1.037] | [0.956, 1.035] | 21 |
| scattered | 125.34 → 124.45 | [0.973, 1.013] | [0.991, 1.019] | [0.988, 1.013] | 61 |
| slice | 42.22 → 41.42 | [1.004, 1.037] | [0.898, 1.051] | [0.873, 1.061] | 21 |
| slide | 67.69 → 67.14 | [0.984, 1.030] | [0.968, 1.042] | [0.965, 1.011] | 21 |
| smoke | 42.75 → 42.02 | [1.006, 1.044] | [0.942, 1.063] | [0.954, 1.060] | 21 |
| spotlights | 141.80 → 143.89 | [0.968, 1.028] | [0.982, 1.025] | [0.976, 1.023] | 61 |
| spray | 127.43 → 127.77 | [0.963, 1.020] | [0.994, 1.024] | [0.992, 1.017] | 61 |
| swarm | 523.13 → 515.17 | [0.960, 1.052] | [0.964, 1.052] | [0.971, 1.034] | 21 |
| sweep | 20.99 → 20.32 | [0.985, 1.071] | [0.998, 1.051] | [1.000, 1.016] | 61 |
| synthgrid | 30.72 → 29.72 | [0.976, 1.077] | [0.987, 1.030] | [0.995, 1.015] | 61 |
| thunderstorm | 71.19 → 70.82 | [0.980, 1.038] | [0.981, 1.084] | [0.984, 1.024] | 21 |
| unstable | 136.93 → 136.30 | [0.914, 1.019] | [0.988, 1.021] | [0.995, 1.008] | 61 |
| vhstape | 99.94 → 99.29 | [0.992, 1.029] | [0.973, 1.031] | [0.988, 1.018] | 21 |
| waves | 74.05 → 73.81 | [0.975, 1.035] | [0.989, 1.015] | [0.989, 1.007] | 61 |
| wipe | 17.11 → 16.42 | [0.992, 1.109] | [1.001, 1.082] | [0.990, 1.036] | 21 |

</details>

Baseline: `921bd551c308c235e01c5867f0199efe0691c271`. Measurements used Rust 1.98.1,
LLVM 22.1.8, Linux 6.6.87.2 under WSL2, glibc 2.43, and an Intel Xeon E5-2696 v4.
Both focused binaries were built from the same workspace path with locked
dependencies, release optimization, LTO, and one codegen unit. Processes were
pinned to CPU 8. No other investigation builds or tests ran during timing.

The matrix covers radii 1, 3, 10, 50, 100, and 200; limits 1, 2, automatic, and
1000; and both uniqueness settings. Each measurement generates and drops fresh
coordinate vectors, with inputs and results passed through `black_box`. Two
warmups precede 17 samples per build, alternating execution order. The radius-3,
two-point unique case received 61 additional samples; its original samples were
retained, giving 78 samples per build. Reported speedups divide the separate
before/after medians. The gate uses exact, distribution-free confidence intervals
for the median of paired speedup ratios, with a 5% family-wise error rate over
48 × 3 focused checks and 37 × 3 complete-animation checks.

The loop's elapsed time comes from `Instant`. `perf stat` records
`cycles:u,instructions:u,task-clock:u`; process counters include startup and
shutdown, amortized over 2,500–500,000 calls. Allocation measurements run
separately and count successful malloc/calloc/realloc/aligned-allocation requests.
Per-call totals subtract a zero-iteration run from a 1000-iteration run, with
equal-length arguments. Bytes mean requested allocation traffic, including
reallocation requests. DHAT independently confirmed the one-point case: removing
the set saved 1,001 allocations and 84,084 bytes across the initial call plus
1,000 timed calls.

Complete animations use a 200×50 canvas, seed 1, virtual time, no pacing, and
output to `/dev/null`. Wall times have 17 samples per build; hardware counters and
CPU time have 21 samples, or 61 for cases investigated after initial readings.

Validation passed:

- 704 exact coordinate-vector comparisons, including negative/zero parameters
  and extreme `i64` coordinates and radii.
- 2,664 complete CLI output comparisons covering all effects, two seeds, six
  inputs, three color modes, and single-threaded and threaded rendering.
- `./bin/test`: 44 Rust tests, 19 CLI contract checks, 354 Python-reference parity
  checks, 41 terminal byte-stream parity checks, and signal, close, and resize suites.

The focused harness is included below so this report can be reproduced without
adding permanent benchmark infrastructure. In a throwaway checkout, save it as
`benches/circle.rs` and temporarily add this target to `Cargo.toml`:

```toml
[[bench]]
name = "circle"
harness = false
```

<details>
<summary>Safe Rust benchmark harness</summary>

```rust
//! Run every case with `cargo bench --bench circle`, or select one with
//! `cargo bench --bench circle -- RADIUS LIMIT UNIQUE ITERATIONS` (UNIQUE is 0 or 1).
//! Each JSON line reports time spent generating and dropping the coordinate lists.

use std::hint::black_box;
use std::time::Instant;
use ttfx::utils::geometry::{find_coords_on_circle, Coord};

fn measure(radius: i64, limit: i64, unique: bool, iterations: u64) {
    let origin = Coord::new(37, 12);
    let points = find_coords_on_circle(origin, radius, limit, unique);
    let started = Instant::now();
    for _ in 0..iterations {
        let points = find_coords_on_circle(
            black_box(origin),
            black_box(radius),
            black_box(limit),
            black_box(unique),
        );
        black_box(&points);
    }
    println!(
        "{{\"radius\":{radius},\"limit\":{limit},\"unique\":{unique},\"iterations\":{iterations},\"elapsed_ns\":{},\"points\":{}}}",
        started.elapsed().as_nanos(),
        points.len(),
    );
}

fn main() {
    let args: Vec<_> = std::env::args()
        .skip(1)
        .filter(|arg| arg != "--bench")
        .collect();
    if args.is_empty() {
        for radius in [1, 3, 10, 50, 100, 200] {
            for limit in [1, 2, 0, 1000] {
                for unique in [false, true] {
                    let count = if limit == 0 {
                        (2.0 * std::f64::consts::PI * radius as f64).round() as u64
                    } else {
                        limit as u64
                    };
                    let iterations = (1_500_000 / count).clamp(2500, 500_000);
                    measure(radius, limit, unique, iterations);
                }
            }
        }
    } else {
        assert_eq!(args.len(), 4, "expected RADIUS LIMIT UNIQUE ITERATIONS");
        assert!(args[2] == "0" || args[2] == "1", "UNIQUE must be 0 or 1");
        measure(
            args[0].parse().expect("invalid radius"),
            args[1].parse().expect("invalid limit"),
            args[2] == "1",
            args[3].parse().expect("invalid iteration count"),
        );
    }
}
```

</details>

Build the baseline and optimized geometry from the same checkout path, using
this identical harness, manifest target, toolchain, lockfile, and compiler
settings for both. Copy each emitted executable outside the build directory
before rebuilding the other version.

Run all 48 cases with `cargo bench --bench circle --locked`. Select a case with
`cargo bench --bench circle --locked -- 100 1000 0 2500`. For external counters,
first build with `cargo bench --bench circle --no-run --locked`, then run the
emitted executable:

```sh
taskset -c 8 perf stat -e cycles:u,instructions:u,task-clock:u -- \
  target/release/deps/circle-<hash> 100 1000 0 2500
valgrind --tool=dhat --dhat-out-file=circle.dhat \
  target/release/deps/circle-<hash> 1 1 1 1000
```

Choose an available CPU for affinity. Compare saved before/after executables
using the same arguments and iteration counts, warm up each case, alternate
execution order, and retain every sample. Divide elapsed nanoseconds by
iterations for ns/call; calls/second is iterations × 10⁹ / elapsed nanoseconds.
CPU counters include process startup and shutdown, as in the original measurements.

For an independent allocation check, compare DHAT total block and byte counts
for the saved executables with the same case and iteration count. DHAT uses
its own accounting, so keep that cross-check separate from the requested-byte
traffic reported above.

Complete-animation wall timings can be reproduced with the repository's existing
`tools/tests/bench_compare.py`, using before/after release CLI executables:

```sh
python3 tools/tests/bench_compare.py /tmp/ttfx-before /tmp/ttfx-after \
  --size 200x50 --seed 1 --repeats 17 --warmups 2 --cpu 8 \
  --json /tmp/ttfx-circle-effects.json
```
