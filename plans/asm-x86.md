# ttfx-asm — an x86-64 assembly port of ttfx

A second implementation of ttfx written in hand-authored x86-64 assembly. It is a freestanding,
static, libc-free Linux binary. Its output is byte-identical to the Rust binary under a pinned
parity contract (§6), and it is assembled for several ISA tiers so the newest AMD and Intel
cores get code written for them.

The Rust port stays the reference implementation, and the seeded, virtual-clock Rust binary is
the oracle the asm port must match.

> Revision 3. This version incorporates two Codex reviews. The first, of revision 1, found 19
> issues, and the second pass found 6 more.
> Most were factual errors about the current codebase (libm inventory, `CharId` semantics,
> snapshot ticking, the renderer, harness invocation, glibc tunable names, `COLUMNS`/`LINES`
> precedence) or thin spots in the float, tty and CLI contracts. Each is addressed in place
> below.

## 0. Status (2026-09-25)

Work started with the tier for the development machine (Zen 5, `x86-64-v4`), so the order in
§10 is revised: v4 first, and the other tiers follow G1.

**G0 profile (Rust 0.3.3, 200×50).** The renderer (`update_render_cells` +
`get_formatted_output_string`) takes 20–46% of the gate effects' time, and
`step_animation`/`motion_move` take most of the rest. The hottest single instruction in
`step_animation` is the `Rc<CharacterVisual>` refcount increment, which misses cache and
accounts for about half of that function. That is the layout cost this port removes.

**Vertical slice.** `asm/` holds a freestanding, libc-free NASM binary that runs **decrypt** end to
end (built with `bin/build-asm`; 45 KB, static):

- plain-text input, the layout/anchoring rules, the visual pool, scenes and events, the renderer,
  tty framing, pacing and signals;
- `--parity-dump` / `--max-frames`;
- unsupported options exit 2, and ANSI input exits 3 so gaps can't pass as parity.

Verification is `tools/asm/oracle.sh full` (306 byte-identical cases against the Rust oracle:
seeds, all nine anchors, clipping, `COLUMNS`/`LINES`, tabs, `\r`, 4-byte UTF-8, error paths)
and `tools/asm/pty_compare.py` (a real pty at three sizes, 60 fps pacing, SIGINT/SIGTERM
teardown).

| decrypt, pinned, best of 3–7 | Rust | asm | speedup |
|---|---:|---:|---:|
| 200×50 → `/dev/null` | 366 ms | 25 ms | 14.6× |
| 200×50 → pipe | 414 ms | 63 ms | 6.6× |
| 200×50 → tmpfs file | 439 ms | 119 ms | 3.7× (kernel copy of 510 MB dominates) |
| 400×100 → `/dev/null` | 3,318 ms | 131 ms | 25× |
| `--version`, including fork+exec | 561 µs | 180 µs | |

**What made the difference, measured step by step (cycles at 200×50):**

1. Straight transcription with pooled visuals: 408M cycles.
2. Incremental cell grid: visual changes write through to the grid, and only movement or
   visibility forces a repaint. 249M.
3. Emission four cells per iteration, plus pruning only characters whose state changed: 203M.
4. Per-row storage and one iovec per row, so unchanged rows cost nothing: 129M.
5. A batched xoshiro generator, a cached head frame per scene, and pool hashes over the real
   bytes only: 114M.

These are layout and algorithm wins, not ISA wins. AVX-512 only appears in the renderer's
bounded copies, dirty-row scans and hashing. That agrees with §2.

**Next:**

- motion (paths, bezier, easing), which needs the `pow`/`hypot` ports of §6.2;
- the remaining gate effects (slide, rings, spotlights, burn), then G1;
- ANSI input;
- the generated CLI tables of §11.

## 1. Goals and non-goals

**Goals**

- **Byte-identical output to Rust ttfx under the parity contract** (§6): the same input, options,
  `--seed`, fixed terminal dimensions, virtual clock and math profile. Python parity is
  inherited through that contract, and the existing Python suites also run directly against the
  asm binary (§9.3).
- **All 37 effects and the full CLI surface**, including the hidden harness switches
  `--parity-dump`, `--virtual-clock`, `--m0-dump` and `--max-frames` (with the same dump
  framing and the same `frames=N` stderr line).
- **Peak single-thread throughput**, as an *unvalidated target* until gate G0 (§3): ≥2× the
  current Rust build as a geometric mean across the 35 non-time-gated effects, and a startup
  time (defined in §3) under 100 µs.
- **Multiple ISA tiers** in one fat binary, dispatched at startup (§5).
- **A freestanding binary** that uses raw syscalls, with no libc, no dynamic loader and no libm.

**Non-goals**

- macOS, BSD, Windows, 32-bit and ARM. The Rust build covers everything other than Linux x86-64.
- Replacing Rust. New effects land in Rust first, and the asm port follows.
- Multithreading in v1 (§13).

## 2. The current baseline and what the measurements actually say

Revision 1 attributed the speedups to optimizations that Rust **already has**. Per
`docs/optimization-2026-09-21.md` and the source, the current Rust build already:

- stores visuals as pre-formatted bytes (`FormattedSymbol`, `animation.rs:63`) and copies them
  with fixed 32- or 63-byte blocks, with a heap fallback for longer symbols;
- renders by selecting the maximum `(layer, character_id)` winner per cell in a reusable cell
  buffer (`terminal.rs:517`), with no sort and no per-frame allocation;
- uses an adaptive active set that switches between a sparse vector and a bitmap
  (`active_characters.rs`);
- caches ordered-map slots and short-circuits shared keys by pointer equality;
- removed most transient allocations (spotlights, for example, went from 8.8M to 64k
  allocations).

**Quick ISA experiment (2026-09-25).** Ryzen 9 9955HX (Zen 5), Rust 0.3.3, glibc 2.44, 200×50,
a 46×190 input, `--frame-rate 0`, pinned with `taskset -c 8`, best of 3. This is an indicative
single run, not a controlled benchmark.

| effect | default | `x86-64-v3` | `x86-64-v4` | `znver5` |
|---|---:|---:|---:|---:|
| beams | 224 ms | 218 | 220 | 223 |
| rings | 557 | 543 | 549 | 550 |
| waves | 415 | 411 | 412 | 413 |
| spotlights | 283 | 277 | 273 | 272 |
| slide | 83 | 81 | 79 | 79 |
| decrypt | 435 | 437 | 436 | 436 |

The output hashes were identical across these builds. A few things follow, and they are stated
no more strongly than the data allows:

- Compiler ISA flags buy **roughly 0–5%**. Auto-vectorization finds little to do here.
- `--no-color` is 10–15% faster. That measures the *incremental* cost of color formatting and the
  extra output bytes, not the renderer's total share. Cell selection, traversal, row joins and
  writes all remain in the no-color runs.
- **Where the time goes is not yet known.** Profiling is the first milestone (G0), not an
  assumption.

**The honest thesis.** Hand-written assembly beats this Rust only where it can use
representations and control flow the Rust code can't easily express, or where it removes
abstraction costs the optimizer cannot see through. The main candidates are:

- **Dense runtime handles** instead of string-keyed path, scene and waypoint lookups. The ids are
  `&str` / `Rc<str>` today.
- **Visual handles** instead of `Rc<CharacterVisual>` refcount traffic.
- **Struct-of-arrays hot fields** for the tick loop.
- **Register-pinned engine state** across the tick and dispatch recursion, with no
  bounds-check or `Option` plumbing.
- **Tier-specific kernels**: exact-length masked copies, bitmap walks and SIMD row compares.

Most of the first three could equally be done **in Rust**. The plan therefore measures them in
Rust first (G0), so the asm effort is justified by what asm adds *beyond* the best achievable
Rust, not beyond today's Rust.

## 3. Gates

The project is large: 22k lines of Rust become roughly 60–100k lines of assembly. It must fail
cheaply if the thesis is wrong.

**G0 — profile and prototype. This comes before any assembly.**

1. Install `perf` and profile five effects at 200×50: slide, decrypt, rings, spotlights and burn.
   Split the time into construction, `update` (motion, animation and event dispatch), visual
   updates, cell selection, byte emission and `write`. Record cycles, instructions, IPC,
   cache and branch misses, and allocations.
2. Prototype dense path, scene and waypoint handles and pooled visual handles **in Rust**, on a
   branch, and measure them with `bench_compare.py`.
3. Hand-write the asm renderer (cell selection plus emission) and the path-step and scene-step
   kernels, and link them into the Rust build through FFI for an apples-to-apples comparison.
4. **Decision.** Proceed with the full port only if the projected asm speedup over the *improved*
   Rust from step 2 is ≥1.5× on the geometric mean of those five effects. Otherwise, upstream
   the Rust improvements and stop. That is a good outcome, too.

**G1 — after A4** (the runtime, the engine and the five gate effects fully in asm, on the v3
tier only). The speedup must hold on real, complete runs:

- A geometric mean of ≥1.5× over the then-current Rust on the five gate effects, with no effect
  below 1.1×.
- Measured with `bench_compare.py` at 11 repetitions and 2 warmups, pinned, at both 200×50 and
  400×100.
- On two machines: Zen 5 and one AVX2-only Intel client core (Arrow Lake or Lunar Lake).
- Peak RSS no more than 1.5× Rust's.

If G1 fails, the multi-tier work, APX and packaging never start.

The **gate effects** are slide (motion), decrypt (heavy output), rings (paths rebuilt at
runtime), spotlights (dynamic appearance) and burn (callbacks plus spanning trees). They cover
the callback-heavy and dynamic-appearance workloads that revision 1's picks missed.

**Startup** is measured as the median wall time of `ttfx-asm --version`, spawned from a tight
loop, compared against a static `true`-equivalent baseline binary on the same machine. The
reported figure is the difference.

## 4. Toolchain and conventions

- **Assembler: NASM ≥ 3.0** (`extra/nasm`, not installed here yet). Its macro system and
  `%if`-per-tier assembly are central to the design. It encodes AVX-512 and AVX10. APX support
  must be validated on the NASM version we actually use, and GAS (binutils ≥ 2.43) is the
  fallback for the APX tier.
- **Linker:** `ld -static -nostdlib -z noexecstack --gc-sections`. The output is ELF64 only.
- **Internal register convention.** Arguments go in `rdi, rsi, rdx, rcx, r8, r9` and results in
  `rax`/`xmm0`. Callee-saved registers are `rbx, rbp, r12–r15`. The engine-context pointer is
  pinned in `r15`. **No raw base pointer is pinned.** All arena references are 32- or 64-bit
  offsets off `r15`-relative bases, so arena growth (§7.1) is always safe. SysV thunks
  (`ttfx_test_*`) wrap the functions the differential tests call.
- **Lint rules** (`tools/asm/lint.sh`):
  - MXCSR stays at the default (RNE, no FTZ, no DAZ).
  - No FMA outside the libm ports (§6.2).
  - No x87, and no `rcp*`/`rsqrt*`.
  - `vzeroupper` at every exit from a wide-vector region into SSE code.
  - No RWX pages and no self-modifying code.

## 5. ISA tiers and dispatch

### 5.1 Tiers — a dated capability matrix (2026-09)

The "Status" column separates what is documented, what we have tested, and what is assumed.

| Tier | Predicate | Hardware | Status |
|---|---|---|---|
| **v1** | x86-64 baseline | any 64-bit CPU | tested (forced on the dev machine) |
| **v3** | AVX2, BMI1/2, LZCNT, MOVBE, FMA, F16C, with OS YMM state | Haswell+, Zen 1+; Intel client Arrow Lake, Lunar Lake, Panther Lake (no AVX-512) | tested on Zen 5 in v3 mode; AVX2 Intel client **needed for G1** |
| **v4** | AVX-512 F/BW/CD/DQ/VL, with OS ZMM state | Zen 4, Zen 5, Sapphire/Emerald/Granite Rapids, AVX10.1/10.2 parts | Zen 5 tested. Zen 4 and Intel server are documented, **not tested**. |
| **apx** | v4 + APX-F with OS APX state | Intel Nova Lake and Diamond Rapids per Intel's ISA reference; shipping and performance **unverified** | SDE correctness only, experimental |

**Zen 6** has been enabled in LLVM with features beyond Zen 5. We assume it runs the v4 tier
correctly and make **no** tuning or APX assumption until it is measured.

**Optional capabilities**, detected independently of the tier and used only in separately gated
kernels: AVX-512 VBMI and VBMI2, the AVX10 version (leaf 0x24), and ERMS/FSRM.

**What each tier is expected to use** (every item is kept only if measured, §10):

- **v1**: SSE2 scalar code and 16-byte copies.
- **v3**: `tzcnt`/`blsr` bitmap walks, BMI2 shifts, 32-byte copies (with a separate path under 32
  bytes) and `vpshufb` digit formatting. PDEP and PEXT are avoided because they are slow
  microcode on Zen 1/2; uops.info measures register `PEXT` at a reciprocal throughput of about
  18–19 cycles there.
- **v4**: masked `vmovdqu8` for exact-length copies of ≤64 bytes, `k`-mask bitmap operations,
  and SIMD compares of row cell arrays (§7.5). Optional batched step kernels (§7.4).
- **apx**: 32 GPRs, NDD, `{nf}`, `push2`/`pop2` and `cfcmov` in the tick and dispatch paths.
  Whether that reduces spills is to be measured on silicon. Until then it is not claimed.

**Zen 4 versus Zen 5 tuning.** Zen 4 double-pumps 512-bit ops and microcodes `vpcompress*` with a
memory destination. The rule "compress to a register, then store" holds everywhere. Where a
kernel's best width differs by core, **both variants are assembled** and one is selected once at
startup through a kernel pointer table. A runtime flag cannot change `%if` expansion, which was
revision 1's contradiction. Only benchmarked kernels get variants.

### 5.2 Dispatch predicates

`_start` is assembled for baseline x86-64 only. It checks:

1. The CPUID max leaf is ≥ 7, and the extended max leaf is queried before any leaf `0x8000_00xx`.
2. **v3**: CPUID.1:ECX has OSXSAVE, AVX, FMA, MOVBE and F16C; XGETBV(0) has XCR0 bits 1 and 2
   (XMM and YMM state); CPUID.7.0:EBX has AVX2, BMI1 and BMI2; CPUID.8000_0001:ECX has LZCNT.
3. **v4**: v3, plus XCR0 bits 5–7 (opmask, ZMM_Hi256, Hi16_ZMM), plus CPUID.7.0:EBX has
   AVX512F, DQ, CD, BW and VL.
4. **apx**: v4, plus CPUID.7.1:EDX APX_F, plus XCR0 bit 19 (APX extended-GPR state).
5. The optional capabilities are recorded as independent flags.

`TTFX_ASM_TIER` forces any tier the hardware supports and refuses the rest. The
missing-state and missing-extension combinations are tested under Intel SDE with CPUID
overrides.

### 5.3 Fat binary

The engine and effects are assembled **once per tier** from the same sources, with a per-tier
symbol prefix. Tier-independent data (help text, CLI tables, hexterm) is shared. Assembling the
whole engine per tier is what lets APX change register allocation everywhere. Until G1 passes,
**only v3 is built.** v1, v4 and apx are added in A6.

## 6. The parity contract, and floating point

### 6.1 What "identical" means

Byte-identical stdout, stderr and exit code, given all of the following:

- the same argv, **including an explicit `--seed`**. Without one, Rust seeds from
  `/dev/urandom` (`rng.rs:30`), and ttfx-asm reads the same source so unseeded behavior matches in
  kind, not in bytes;
- the same stdin;
- the same terminal dimensions, **including the environment**. `get_terminal_dimensions`
  (`terminal.rs:704`) gives `COLUMNS` and `LINES` precedence *independently* over the ioctl
  result and the `(80, 24)` fallback, and accepts any value that parses as `i64` (zero and
  negative included). ttfx-asm implements exactly that precedence, and the oracle runs pin both
  variables (`bench_compare.py` relies on them);
- `--virtual-clock` or `--parity-dump`. **Real-clock** runs of matrix and thunderstorm are
  timing-dependent in both implementations, so they are covered by behavior tests, not byte
  parity.
- the same **math profile** (§6.2);
- no signals or resizes, except in the pty behavior tests, which have their own acceptance
  criteria (§8).

The virtual clock must reproduce `Clock` exactly (`ctx.rs:32`): a repeated floating-point
addition of `1/frame_rate`, with the 1/60 fallback when the frame rate is 0. It is not a
multiply.

**The RNG contract** is the full helper semantics *and* the generator state they leave behind:

- `randbelow(1)` still draws, and rejection sampling consumes draws exactly as Rust does;
- `choice` on a singleton still draws;
- the shuffle order;
- `--random-effect` selection;
- RNG continuation across a resize restart.

Differential tests compare the returned values and the **subsequent state**.

### 6.2 libm — inventory the compiled oracle, not just the source

`objdump -T target/release/ttfx` shows the oracle imports **`pow`, `sin`, `cos`, `sincos`,
`exp2` and `hypot`**. The source only says `powf`, `sin`, `cos` and `hypot` (`geometry.rs:218`).
LLVM rewrites some calls: `sin`+`cos` pairs become `sincos`, and some `powf(2.0, x)` become
`exp2`. What must be matched is **the oracle binary's behavior**, so A1 starts by recording the
exact lowering at every call site for the pinned toolchain. That means Rust 1.98.1, the release
profile in `Cargo.toml` (LTO, codegen-units 1) and target `x86_64-unknown-linux-gnu`. The same
record is needed for the musl build, if that is ever an oracle.

`hypot` must be ported as glibc's algorithm. It must not become `sqrt(x*x+y*y)`.

**Math profile is separate from the ISA tier.** glibc ifunc-selects variants of these functions:
an FMA variant when FMA and AVX2 are usable, an FMA4 variant on AMD family 15h, and generic SSE2
otherwise. So the oracle's math depends on the host CPU, independently of anything we choose.
The rules are:

- `ttfx-asm` has a **math profile** chosen at startup by **the same predicates glibc uses**, not
  by the asm tier. Forcing `TTFX_ASM_TIER=v1` on an FMA machine still uses the FMA profile,
  because that is what the oracle does on that machine.
- **Selection is per function, not global.** On glibc 2.44, `sin` and `cos` resolve through
  `ifunc-avx-fma4.h`, which picks FMA, then **AVX**, then FMA4, then SSE2. `pow` and `exp2`
  resolve through `ifunc-fma.h`, which picks FMA or SSE2. A1 writes the per-function resolver
  table into `tools/asm/lowering.md`, and ttfx-asm reproduces it. The AVX variant of
  `sin`/`cos` is the same C compiled with `-mavx` (VEX encoding, no FMA). A1 either proves it
  bit-identical to SSE2, in which case the asm port aliases the two, or ports it as a third
  profile.
- For testing, `TTFX_ASM_MATH=sse2|avx|fma` forces the profile. The oracle is forced to match
  through glibc's tunable, whose feature names on 2.44 are unsuffixed:
  - `GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2,-FMA` gives the AVX variant of `sin`/`cos` and the
    SSE2 variant of `pow`/`exp2`;
  - adding `,-AVX,-FMA4` gives SSE2 throughout.

  (Codex verified locally that the `-AVX2_Usable` spellings are ignored on 2.44.) The oracle
  harness checks which variant resolved (via a `LD_DEBUG=bindings` probe, or `dladdr` in a tiny
  C helper) and doesn't just trust the tunable string.
- **FMA4** (Bulldozer family) is out of scope. On those CPUs ttfx-asm uses the SSE2 profile and is
  documented as not bit-matched to the oracle.
- **Pin the glibc build.** The parity CI records the glibc version and build id, because
  algorithms change between releases. glibc 2.28 and 2.29, for example, replaced exp, log, pow,
  sin and cos.

**Porting and licensing.**

- `pow`, `exp2` and the log and exp cores come from ARM optimized-routines, which is MIT/Apache-2.0
  upstream. They are ported from the originals.
- `sin`, `cos` and `sincos` are IBM code under LGPL-2.1 as shipped in glibc, and `hypot` is glibc
  code. **The licensing is decided in A1, before those files are written.** The options are an
  LGPL-licensed `asm/math/` directory with notices, or a fallback that statically links glibc's
  `libm.a` objects, which gives up "libc-free" but stays static.

**Numeric conversions.** Each one has an explicit spec, with macros and tests:

- Rust `as` float-to-integer casts **saturate and map NaN to 0**, whereas `cvt(t)sd2si` returns
  the integer-indefinite value. Every conversion site gets a guard, on every tier.
- `round_half_even` (`pycompat.rs:6`) has its own non-finite behavior, and the port copies it
  exactly.
- `f64::min`/`max` NaN semantics differ from `minsd`/`maxsd` operand order. They are ported per
  call site, preserving signed zero.
- **Decimal→`f64` parsing of CLI arguments** must be correctly rounded, as Rust's `parse::<f64>`
  is. The port uses Eisel-Lemire plus a big-decimal fallback, tested against Rust on 10⁸ random
  strings and on known hard cases.

## 7. Engine design

All of `plan.md` §4–§5 and `docs/ordering-inventory.md` still hold. What follows changes the
representation, never the semantics.

### 7.1 Memory lifetimes

There are three regions, each `mmap`-backed and addressed only by offset, so `mremap` growth is
safe:

- **Process region:** the CLI tables, parsed config and effect registry. Allocated once.
- **Run region:** the character store, paths, scenes, event tables, the visual pool and effect
  state. **It is reset on resize restart**, mirroring the engine drop in `main.rs:25`, and RNG
  state carries over as in Rust.
- **Reusable scratch:** the tick snapshot, render cells, frame output buffers and per-frame
  temporaries.

Objects replaced during a run (paths rebuilt by rings, re-registered scenes, appearances changed
by matrix and spotlights) go to **size-class free lists** inside the run region, so long runs
don't grow without bound. Peak RSS and growth over a long matrix run are measured and gated
(§3).

### 7.2 Identity and keys

- **`CharId` is the arena slot index** (`character.rs:3`). **`character_id`** is the separate
  Python-compatible identity. Today their ascending orders agree, and every storage change must
  preserve that invariant, which gets its own debug assertion.
- **Runtime-interned handles.** Path, scene and waypoint names become dense `u32` handles through
  an intern table that also works **at runtime**, not only at build time. Effects create paths
  and scenes mid-run.
- **Event keys are the full `WaypointKey`** (`events.rs:30`): the name, the coordinate and the
  Bézier controls, interned as a single key. Equal records on different paths still collide,
  as they do today.
- **Ordered-map semantics are preserved:** replacing a key keeps its insertion position;
  removal and reinsertion appends; an action appended to an event's list *during dispatch* of
  that event behaves exactly as in Rust.

### 7.3 Character storage

Hot fields go in struct-of-arrays form, with **the same widths as Rust** (`i64` coordinates and
layers, `f64` where Rust uses `f64`, and Rust's own counter widths). The CLI accepts, for
example, a 40,000-column canvas and `--final-gradient-frames 65536`, so narrow fields would
break accepted inputs. Compacting fields is an A6 optimization, allowed only behind a proof that
the value is bounded by validated input, with a checked wide fallback.

### 7.4 Ticking

This mirrors `EngineCtx::update` (`ctx.rs:679`) exactly:

1. Copy the active set into a **snapshot** in ascending `CharId` order, using reusable scratch.
2. Tick every snapshot member, motion first and then animation. Characters that a callback
   removes still get their scheduled tick, and characters a callback adds wait for the next
   update.
3. **Only after the pass,** prune inactive characters.

Path and scene state is re-fetched after every event emission.

**Optional batching (A6, measured).** A fast-path classifier on v4 can batch consecutive
snapshot characters whose step fires no event, crosses no segment boundary and draws no RNG.
A batch **ends at the first character that could emit anything**, and the characters after it
are reclassified against the state after its callbacks. The batch kernels use only IEEE basic
operations, in Rust's expression order.

### 7.5 Renderer

The renderer keeps the current winner-selection algorithm (the maximum `(layer, character_id)`
per cell), not a sort.

- **Visual pool:** each pooled visual's bytes are padded so a 64-byte load from any visual start
  is always in bounds. Symbols longer than the inline bound (Rust falls back to the heap above
  63 bytes) take a separate long-copy path. Copy kernels are tested at lengths 0–130 and at page
  boundaries.
- **Visual handles are immutable and generation-tagged.** Rust mutates uniquely owned visuals in
  place (`animation.rs:547`). ttfx-asm instead writes the new bytes to a fresh pool slot and
  issues a new handle, `(slot, generation)`. A freed slot's generation is bumped before it is
  reused, so a stale handle can never alias different bytes.
- **Row cache (A6, optional).** Keep the previous frame's per-row cell array of generation-tagged
  visual handles, and **compare it with SIMD**. If a row is identical, re-emit the previous row's
  bytes. Comparing the resolved cell arrays automatically covers movement, occlusion, reveal,
  clipping and anchor changes, which a dirty-bit scheme would miss. The cache is invalidated on
  resize. Because handles carry generations, equal handles really do mean equal bytes.

## 8. TTY, signals and I/O — an explicit contract

These are acceptance criteria for A2, transcribed from `engine/effect.rs::run_effect` and
`main.rs`. They are verified by the pty tests plus new cases.

**The rules are scoped by execution mode** (`main.rs:83`):

- `--m0-dump` returns before any handler is installed.
- `--parity-dump` installs no SIGINT handler, disables tty handling, and bypasses prep and
  restore.
- The rules below apply to **normal runs**. Each mode has its own test cases.

- **Redirected output** still gets the normal prep and restore framing.
- SIGTERM teardown and resize handling are **TTY-only**. SIGTERM restores the terminal, then
  **re-raises** itself. SIGINT exits 1 silently. SIGPIPE is restored to its default.
- **EIO** on the terminal (the terminal was closed) leads to a quiet exit. A failure writing to
  redirected output is reported differently. Both cases follow Rust exactly.
- **Resize** waits for a 50 ms quiet period, checks whether the layout changed, restarts with the
  RNG state carried over, and disables `--reuse-canvas` on the restart.
- `write` handles **short writes and EINTR**, and frame flush boundaries match Rust's. This
  matters for the pty byte-stream comparison.
- `rt_sigaction` is set up with `SA_RESTORER` and our own restorer stub.
- Terminal dimensions come from `TIOCGWINSZ`, with the same fallback as the `terminal_size` crate
  and Rust's `(80, 24)` default. The termios mode is only changed where Rust changes it. The
  `isatty` check (`TCGETS`) is not a license to alter the mode.

## 9. Verification

### 9.1 Harness prerequisites (a small Rust-repo PR, done first)

- `run_suite.sh`, `tty_compare.sh`, `m0_matrix.sh`, `cli_corpus.sh` and `benchmark.sh` hardcode
  `RUST=./target/release/ttfx`. Change them to `RUST=${RUST:-./target/release/ttfx}`.
- The Python behavior tests already take the binary as a positional argument, and
  `bench_compare.py` already takes two binaries.
- `run_suite.sh` caps runs at 400 frames, so it is **smoke coverage**. Complete-animation parity
  comes from the oracle suite below.

### 9.2 Oracle suite (`tools/asm/oracle.sh`)

Complete runs with no frame cap, under the §6.1 contract, comparing stdout, stderr and exit code.
The matrix covers the 37 effects × default config and the `cases.txt` configs, seeds, canvas
sizes (including 1×1 and 400×100), all nine anchors clipped and unclipped, the color modes and
existing-color modes, an adversarial input corpus, each built tier, and both math profiles.

A **random-config fuzzer** draws options from the CLI schema (§11) and shrinks failures to the
first differing frame.

CI runs in three bands:

- **Quick, per commit:** each effect × 3 seeds, at a small size.
- **Nightly:** the full matrix plus fuzzing.
- **Weekly:** the exhaustive jobs (hexterm 2²⁴, 10⁹-scale libm and RNG runs).

### 9.3 Differential unit tests (`cargo test --features asm-diff`)

Asm objects built with SysV thunks are linked into Rust tests. **Structured cases come first and
random volume second:**

- **pycompat and conversions:** every rounding boundary, ±0, NaN, ±∞ and the saturation edges.
  Also 10⁸ random bit patterns, with a decision recorded on whether NaN payload bits must match.
- **RNG:** each helper's values and the subsequent state, with singleton, rejection-boundary and
  shuffle cases.
- **libm:** `pow` on structured `(x, y)` pairs (the easing domains `t ∈ [0,1]` with the actual
  exponents used, integer and half-integer exponents, and the special cases), `exp2`, `sin`,
  `cos` and `sincos` over the angles effects produce, `hypot` including doubled-row arguments,
  then random volume. Every case runs under both math profiles.
- **Easing, geometry, graphics and hexterm**, as golden-plus-differential tests.
- **Engine scenarios.** Today's engine-trace fixtures are expected output, built by scenarios in
  `tests/engine_traces.rs:85`. **In A3, before G1,** those become **shared scenario drivers**
  that run against both engines, with these adversarial cases added: callbacks that add or remove active characters
  mid-update, actions appended during dispatch, re-activation during a segment event, and
  field-width extremes.

### 9.4 Asm-specific safety

- Guard pages after each region. Because corruption *between* objects inside a region is
  invisible to guard pages, there is also a debug build with canary words on every run-region
  allocation, checked each frame.
- Stack-alignment assertions in debug builds.
- Valgrind memcheck on v1 and v3; SDE for v4 and apx.
- `TTFX_ASM_TRACE=1`, which emits the Rust engine-trace format for diffing.

## 10. Milestones

- **G0 — profile and prototype** (§3). The go/no-go decision.
- **H — harness prerequisites** (§9.1).
- **A0 — runtime, v3 only.** NASM build, `bin/build-asm`, `_start` with the full dispatch
  predicates, the syscall layer, the three memory regions, the output buffering and the
  **§8 tty/signal contract**, tested with a trivial effect before anything else lands.
- **A1 — pure functions and math.** The oracle-lowering inventory, the math profiles and
  licensing, the libm ports, pycompat and conversions, the float parser, rng, easing, geometry,
  graphics, hexterm, the ordered map and the spanning trees.
- **A2 — CLI schema, input, canvas and renderer.** Exit criterion: `--m0-dump` parity across the
  `m0_matrix.sh` matrix.
- **A3 — engine.** Exit criteria: the shared scenario drivers and the adversarial
  callback, reentrancy and field-width tests (§9.3) all pass against both engines.
- **A4 — the five gate effects.** Then **gate G1** (§3).
- **A5 — the remaining 32 effects**, in `plan.md`'s wave order.
- **A6 — tiers and tuning.** Add v1, v4 (with the Zen 4 and Zen 5 kernel variants) and apx
  (SDE). Add batching, the row cache and field compaction. Every change goes through
  `bench_compare.py` and is kept only on a measured win, with a `docs/optimization-*.md` note.
- **A7 — ship.** `bin/test` gains the asm stages, CI gets NASM and SDE, a `ttfx-asm` split
  package is added, and the README gets a benchmark table. Parity CI **blocks** any release that
  claims parity. Until then the asm job may be allowed to fail on the Rust side, so Rust
  development is never blocked.

## 11. CLI

Clap metadata alone can't provide assembly field offsets or validator semantics, so the CLI is
built from an **explicit schema** instead:

- `tools/asm/cli_schema.toml` lists every option with its name, value kind, validator id, default,
  multiplicity and config field.
- `tools/asm/gen_cli`, a Rust tool linking the ttfx library, **cross-checks the schema against the
  clap tree** and fails on any mismatch in names, defaults, choices or hidden flags.
- It emits the asm tables, the `--help` blobs and the bash and zsh completion blobs, and CI checks
  that the generated output is fresh.

Validators are **ported as code**, not described: PositiveInt, the ratio ranges, ColorArg
(hex or xterm), the choice lists and float parsing (§6.2).

**The parser must match clap in these respects:**

- duplicate options;
- negative numeric values;
- option placement before or after the effect;
- `--` handling;
- unknown and ambiguous options;
- missing values;
- every diagnostic's text and stream.

`cli_corpus.sh` is extended from 19 cases toward full coverage of these behaviors before A2
closes.

## 12. Repository layout

```
asm/
  ttfx.inc                  # tier constants, register pins, ABI + helper macros
  include/                  # struc layouts, syscall numbers, tier macro bodies
  rt/                       # _start, cpuid/xgetbv dispatch, syscalls, vdso, regions, io, signals
  math/                     # conversions, float parser, pow/exp2/sin/cos/sincos/hypot (sse2 + fma)
  utils/                    # rng, easing, geometry, graphics, hexterm, spanning_tree, ordered_map
  engine/                   # input, canvas, terminal, intern, visual_pool, animation, motion,
                            # events, particles, active set, renderer
  effects/                  # one .asm per effect, mirroring src/effects/*.rs
  gen/                      # generated CLI tables/help/completions (committed, freshness-checked)
bin/build-asm               # → target/asm/ttfx-asm
tools/asm/
  cli_schema.toml, gen_cli/, oracle.sh, fuzz_configs.py, lint.sh, lowering.md
tests/asm_diff.rs           # behind the `asm-diff` feature
```

Every asm file names the Rust file and function it transcribes. `tools/asm/lowering.md` records
the §6.2 call-site inventory.

## 13. Risks and open questions

- **Effort.** G0 exists to kill the project early if its thesis fails. Effects are repetitive, so
  macros for "scene + gradient + frames" and "path + waypoints + events" should keep them near
  2× the Rust line count.
- **libm exactness, licensing and oracle variance across CPUs and glibc versions** (§6.2).
  Resolve these in A1. The FMA question also bears on today's Rust-versus-Python parity, because
  CPython uses the same glibc. Record the finding in `plan.md` §5.20.
- **APX.** New tooling and unverified silicon, so it stays experimental and is never the
  packaging default until it has been measured on real hardware.
- **Spec drift.** Oracle CI surfaces drift immediately. Parity must be green before any asm
  release.
- **Future parallelism.** Overlapping frame N's emission with frame N+1's simulation needs no
  semantic change. Worth revisiting after A6, once profiles show the renderer's real share.
