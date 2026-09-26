# Research and experiments for the second optimization pass

The objective was to improve the existing assembly engine while preserving
the Rust engine's output, floating-point behavior, random sequence, and
single-core benchmark conditions. Changing the language was allowed; keeping
NASM was a result of the measurements, not a prerequisite.

## Sources and their relevance

- [AMD's Ryzen optimization presentation](https://gpuopen.com/gdc-presentations/2024/GDC2024_AMD_Ryzen_Processor_Software_Optimization.pdf)
  describes Zen 4's cache hierarchy and prefetch behavior. Its discussion of
  locality informed experiments that place each scene's frequently accessed
  state in one cache line. This is an application of the guidance, not a
  hardware-counter diagnosis of this program.
- [Agner Fog's assembly optimization guide](https://agner.org/optimize/optimizing_assembly.pdf)
  discusses cache-set conflicts, dependency chains, predictable branches,
  and keeping loop state in registers. The conversion fast paths and the
  motion loop use these techniques without approximating arithmetic.
- [The Linux kernel's THP documentation](https://docs.kernel.org/admin-guide/mm/transhuge.html)
  explains the tradeoffs between larger pages, allocation costs, and sparse
  memory use. Small prefixes of character-field and bitmap reservations now
  request normal pages. Dense arenas keep the existing system policy. This
  is a per-mapping hint; no system settings change.
- [LLVM BOLT](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
  can optimize compiled binaries, including suitably structured assembly,
  using execution profiles. It needs an unstripped symbol table and benefits
  from retained relocations. This repository's NASM routines currently have
  zero-sized `NOTYPE` symbols, so reliable function discovery needs work.
  BOLT was researched, not executed; none of the reported gains are attributed
  to it. Ordinary Rust PGO also cannot optimize the separately assembled
  engine's instruction sequences.
- [Intel's ISPC comparison](https://www.intel.com/content/dam/develop/external/us/en/documents/simd-made-easy-with-intel-ispc.pdf)
  reports performance comparable to hand-written intrinsics in its examples,
  with one chart showing ISPC ahead. This is evidence that source language
  alone does not determine speed, not a prediction for terminal animations.
  The [ISPC performance guide](https://ispc.github.io/perfguide.html) emphasizes
  coherent memory access and control flow. It also documents lower accuracy
  in the default vector math library. A rewrite would need to preserve the
  engine's exact arithmetic and callback/RNG ordering; no ISPC port was built.
- [STOKE's research paper](https://arxiv.org/abs/1211.0557) reports synthesized
  instruction sequences that outperform expert assembly in some cases.
  Its demonstrated scope is small computational routines; that does not
  establish an end-to-end gain for this engine. STOKE was researched, not run.
- [LLVM MCA](https://llvm.org/docs/CommandGuide/llvm-mca.html) was used to inspect
  instruction scheduling for the ordinary float-to-integer conversion path.
  Its Zen 4 model estimated block throughput of 2.0 cycles for the old sequence
  and 0.5 for the new ordinary case. Those are static-model estimates, not
  measured application speedups; full-program timings determine acceptance.

## Experiments

Each trial used a saved binary. Exploratory measurements selected candidates;
the final report uses fresh runs with no compiler or oracle jobs running.

| Idea | Result |
|---|---|
| Move the separate scene-state plane by one cache line | Did not resolve the waves bottleneck; discarded. |
| Put each scene's complete 64-byte record together | Waves approximately twice as fast as round one in the initial paired trial; retained. |
| Fast ordinary numeric conversions, with exact exceptional fallbacks | Existing differential tests passed; retained. |
| Keep motion-loop state in registers when no segment callbacks exist | Reduced repeated bookkeeping; retained. The subtraction order stays unchanged. |
| Disable huge pages for the initial prefix of every reservation | Mixed results, including regressions; discarded. |
| Use normal pages only for sparse character arrays, lists and bitmaps | Better overall timing than the broad allocation experiment; retained. |
| Unroll random-number generation four draws at a time | No reliable gain in the selected RNG-heavy effects; discarded. |
| Look up a visual's logical key before formatting its SGR bytes | Improved overall time and especially repeated-visual workloads; retained. |
| Remove the second visual insertion probe and simplify table growth | Mixed results, including a matrix regression; discarded. |

No approximate math, reduced frame counts, changed random draws, special
`/dev/null` behavior, precomputed benchmark outputs, extra CPU cores, or
system-wide tuning contributes to the production changes.
