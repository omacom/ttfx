# Porting to the ttfx assembly engine

Read this before touching `asm/`. The plan and its reasoning are in
`plans/asm-x86.md`. This is the working manual.

## How it fits together

- The Rust binary is the front end. It handles the CLI, input reading, blank-input
  checks, `--random-effect`, RNG seeding and signal handlers.
- Every run is offered to the assembly engine (`src/asm/`, `asm/lib.asm`). The engine
  either **declines before doing anything observable**, in which case the Rust engine
  runs the effect, or it runs the effect to the end.
- Output must be **byte-identical** to the Rust engine. The Rust engine is the oracle,
  and Rust is never changed to match the asm.
- `build.rs` assembles `asm/lib.asm` with NASM. It is one translation unit, and every
  file is `%include`d from `lib.asm`.
- NASM 3.x is required. If it isn't on PATH, set it with
  `export NASM=/tmp/claude-1000/-home-dhh-Work-omacom-ttfx/460835a3-07de-429e-921a-0ba805ca040b/scratchpad/tools/usr/bin/nasm`.
- Build with `cargo build --release`. If NASM is missing, cargo fails and says so.

## Verifying

- **Effects:** `tools/asm/oracle.sh <effect> [quick|full]` runs the binary with
  `TTFX_ASM=0` (Rust) and `TTFX_ASM=force` (asm) across inputs, seeds, anchors, color
  modes and the option sets in `tools/asm/cases/<effect>.txt`. It compares stdout,
  stderr and exit status.
  - Add option sets to the cases file covering every option the effect has, including
    non-default easings, directions and gradients.
  - `full` must pass before an effect is done.
- **Shared utilities:** `cargo test --release --test asm_diff` compares asm functions
  against the Rust originals through the SysV thunks in `asm/tests.asm`.
  - Add a thunk and a test for every utility you port. Each test holds `engine()`
    first, because the engine's state is global and cargo runs tests in parallel.
  - Compare the results **and** any RNG state afterwards, and use large, structured
    input sets (boundaries, not only random values).
- **Speed:** `TTFX_ASM=0` vs `TTFX_ASM=force` on
  `--canvas-width 200 --canvas-height 50 --ignore-terminal-dimensions`, pinned with
  `taskset -c 8`. Report both numbers.

## Conventions

- **Calling convention:** arguments in `rdi, rsi, rdx, rcx, r8, r9` and `xmm0-xmm3`;
  results in `rax` and `xmm0`. **`rbx, rbp, r12-r15` are callee-saved**, so push what you
  use. Everything else, including every vector register and every `k` register, is
  clobbered by calls unless the callee's header says otherwise. Document clobbers in the
  function's header comment.
- **Position-independent code.** Rust links PIE:
  - Use RIP-relative `[label]` or `[label + const]`, which `default rel` provides.
  - **Never** write `[label + reg*scale]`. Instead `lea rax, [label]`, then `[rax + reg*8]`.
  - `mov eax, label` and absolute `dq label` data in read-only sections are also not
    allowed. Tables of pointers go in a `section .data.rel.ro progbits alloc write noexec`.
  - After building, `readelf -rW target/release/build/ttfx-*/out/ttfx_asm.o | grep -E '32S|_32 '`
    must print nothing.
- **State:**
  - All mutable per-run state goes in `section .tstate`, which is zeroed at the start of
    every run.
  - Never use `.bss` or `.data` for per-run state; `.bss` is only for the few
    persistent run-independent variables in `lib.asm`/`sys.asm`.
  - Allocate with `alloc` (bump arena, 64-byte aligned, zeroed) or reserve a region with
    `reserve` for big growable arrays. There is no free. Reserved regions are released
    automatically on the next run.
- **Errors:**
  - `FAIL label` returns `OUT_ERROR` with the message at `label` (define it with
    `STR label, "text"`). Rust prints `Error: <text>`, so match Rust's message exactly.
  - Internal impossibilities use `fatal`.
- **Calling C:** libm (`pow`, `sin`, `cos`, `sincos`, `exp2`, `hypot`) and Rust callbacks
  go through `CCALL fn`, which aligns the stack. Only `xmm0/xmm1` (and `rdi`...) carry
  arguments, and the callee clobbers all caller-saved registers.
- **Output:** never write to fds yourself. The engine's run loop owns output, pacing,
  signals and the clock.
- **Style:** comments state what upstream Rust function a routine transcribes, and why for
  anything subtle. Match the tone of the existing files: short, factual, no tutorials.

## Floating point: match the oracle binary, not the source

- The oracle is the **compiled** Rust binary, and LLVM rewrites some libm calls. It has
  been observed to lower:
  - `x.powf(2.0)` to `x * x` (`mulsd`)
  - `x.powf(0.5)` to `sqrtsd`
  - `2.0f64.powf(x)` to `exp2(x)`
  - a `sin(x)`/`cos(x)` pair on the same `x` to `sincos(x)`
- Other exponents stay as `pow` calls. `(p * PI / 2.0).cos()` and the like stay `cos`
  calls.
- **Always check the function you port:**
  - Build a symbolized oracle with
    `CARGO_PROFILE_RELEASE_STRIP=false CARGO_PROFILE_RELEASE_DEBUG=1 cargo build --release --no-default-features --target-dir /tmp/<you>-prof`.
  - Then `objdump -d --no-show-raw-insn /tmp/<you>-prof/release/ttfx | awk '/<.*your_function.*>:$/{p=1} p&&/^$/{p=0} p'`
    and read the `call`s, `mulsd` and `sqrtsd`.
  - Inlined functions show up inside their callers.
- Keep Rust's expression order exactly. There is no FMA (`vfmadd*`) anywhere, and no
  `rcp`/`rsqrt`. MXCSR stays at its default.
- Casts:
  - Rust `f as i64` saturates and maps NaN to 0, whereas `cvttsd2si` gives
    `0x8000000000000000` on overflow and NaN. Guard wherever inputs can be non-finite or
    huge.
  - `round_half_even` is `roundsd x, x, 0` then `cvttsd2si` for finite values; see
    `pycompat.rs` for the non-finite behavior.
  - Integer `//` and `%` follow Python (`floor_div`, `py_mod`).
- RNG draws must happen in exactly Rust's order and count. Use `rng_below`,
  `rng_randint`, `rng_randrange`, `rng_random` and `rng_uniform`, which match
  `src/utils/rng.rs` helper for helper.

## Colors and symbols

- **Colors** are u64 values: `0xRRGGBB` in the low 24 bits. A color built from an xterm
  code keeps that code in bits 32-39 and sets bit 40. `NONE` (-1) means no color.
  - Gradients keep the stop colors as given; generated colors are plain RGB.
- **Symbols** are packed u64 values: the UTF-8 bytes in the low bytes, with the length in
  bits 32-39 (at most 4 bytes, i.e. one codepoint). `utf8_pack` builds one from a
  codepoint. Multi-codepoint symbols are not supported: decline them in the Rust
  marshalling.
- **Visuals** are u32 handles (pool offset | length << 24) made by `visual_make(fg, bg,
  symbol, attribute bits)`. They are interned, so equal visuals share a handle.

- **Coordinates** are u64 values: the column as a signed i32 in the low 32 bits and the
  row as a signed i32 in the high 32 bits. Functions returning coordinate lists allocate
  the array with `alloc` and return `rax = pointer, rdx = count`.
- **Easings** are ids in `Easing` enum order (Linear = 0 ... InOutBounce = 30):
  `ease(edi = id, xmm0 = t) -> xmm0`.

## Porting an effect

1. Read `src/effects/<name>.rs` completely, plus every engine function it calls. The
   Python upstream is not available; the Rust code is the specification.
2. Write `asm/effects/<name>.asm` with a `struc` for its config, `<name>_build` and
   `<name>_next_frame`, following `asm/effects/decrypt.asm`. Add it to
   `asm/effects/registry.asm`: an `%include` and its row in `effect_table`.
3. Add its arm to `marshal` in `src/asm/effects.rs`, pushing words in the `struc`'s order.
   Decline (return `Err`) any configuration you do not support, but aim to support all of
   them.
4. Add `tools/asm/cases/<name>.txt` and run `tools/asm/oracle.sh <name> full` until it
   passes. Then measure the speed.
5. Only change shared engine files (`asm/engine/*`, `asm/utils/*`, `asm/lib.asm`,
   `asm/ttfx.inc`) when the engine lacks something. Keep such changes minimal and
   additive, and list them in your report so they can be merged across effects.
