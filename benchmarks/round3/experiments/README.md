# Experiments against the updated assembly engine

These are exploratory results, not the final acceptance benchmarks. The
production comparison is in [the parent directory](../README.md). The old
round-two speedups used `ac940f2`; this work uses PR #35 at `189840b`.

The integration candidate (`81bd379`) initially kept contiguous scene records
and sparse memory hints, while adopting upstream's other implementations.
The final source drops contiguous records too: only the sparse hints remain.

| Experiment | Result | Decision |
|---|---|---|
| Initial integration vs updated #35 | 1.102x best / 1.100x median geometric mean | Continue to controls and fresh measurements |
| Visual hits return before saving six registers; skip empty attribute loop | 1.009x / 1.010x over integration | Too small and inconsistent to retain |
| Same visual change plus CRC32 on tiers 2–4, scalar hash on tier 1 | CPU 2 repeat: 1.011x / 1.015x | Too small and inconsistent to retain |
| Memory bit test before saving registers in `doze_wake` | 0.998x / 1.010x | Discard |
| Cache exact ratios for paths without easing, using upstream's factor table | 0.993x / 1.013x | Discard |
| Contiguous scenes vs upstream's split scene layout, both with sparse hints | 0.994x / 1.004x | Keep upstream's layout |
| LLVM BOLT instrumentation and profile-guided optimization | Instrumented training finished; optimized binaries crashed on 15/37 validation effects | Reject both optimized binaries |

Ratios above compare best and median wall times across all 37 effects.
`crc.json` is specifically **contaminated by another benchmark starting on
CPU 4**; it must not be used as evidence of a gain. `crc-cpu2.json` is its
repeat on CPU 2. Other exploratory runs also experienced desktop load, and
the doze trial overlapped an experimental build. The small differences do
not justify added production complexity. Final comparisons use saved
binaries, CPU 2, interleaved samples, child CPU-time measurements, and no
concurrent compiler, oracle, or BOLT jobs from this task. An unrelated
benchmark remained active on CPU 4; cores still share system resources.

## BOLT: an executed experiment

Previously BOLT had only been researched. This time:

1. Downloaded LLVM BOLT 20.1.8 and its runtime from the official LLVM package
   repository into the ignored local build directory.
2. Built an unstripped release executable with `-Wl,--emit-relocs`.
3. Used the adjacent experimental NASM wrapper to give top-level text labels
   ELF function types and sizes. Set `NASM_REAL` to the actual NASM executable
   and `NASM` to this wrapper when reproducing.
4. Instrumented that executable with `llvm-bolt -instrument`, using
   `-instrumentation-file=... -instrumentation-file-append-pid`.
5. Ran all 37 effects with seed 73 and a separate 80x24 / 70x18 training input.
   All training processes exited successfully. Eight small Rust/assembly
   smoke runs also matched the original output.
6. Merged 45 profiles with `merge-fdata` and tried:
   - `-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions
     -split-all-cold -split-eh -dyno-stats`;
   - `-reorder-blocks=none -reorder-functions=cdsort -split-functions=false
     -peepholes=none -assume-abi=false`.
7. Compared complete colored-Unicode output with the unprocessed candidate,
   using seed 29 across all 37 effects. Each optimized binary matched 22
   effects and crashed with SIGSEGV on 15. Neither was benchmarked as a valid
   candidate or incorporated into the normal build.

The debugger located the conservative `print` failure in `sort_slots_stable`.
BOLT also reported internal calls and functions whose original entries it
could not patch. The annotation wrapper is a **prototype**, not a complete
function-boundary model: this assembly has shared tails and fallthrough
between named labels (`key_row_col` into `key_with_column`, for example).
Those need explicit modeling before another reordering experiment. These
results reject this integration attempt; they do not establish that BOLT
cannot optimize a properly described version of the engine.

The wrapper, command output, training arguments, validation hashes, and
debugger output are retained here. Binary hashes are in
[the manifest](../binary-manifest.json). No BOLT runtime or toolchain becomes
an application or build dependency.

[BOLT's official requirements and workflow](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/bolt/README.md)
guided the experiment. ISPC and STOKE remain research leads; neither was
implemented or credited with a speedup in this refresh.
