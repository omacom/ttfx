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

## Engine API reference

Everything below is callable from an effect. Registers follow the conventions
above. "Clobbers C" means the full C caller-saved set: every register except
`rbx, rbp, r12-r15`, including all vector and `k` registers. Assume it for any
function whose header does not say otherwise. Rust names are given so you can
map `src/effects/*.rs` line by line.

### Effect contract

- **Registration:** add `dq <name>_build, <name>_next_frame` at its id in
  `asm/effects/registry.asm`. The ids are in `asm/effects/ids.inc`.
- **`<name>_build`:** `Effect::build`. Read your config through
  `[effect_config]` (a `struc`). Errors use `FAIL`.
- **`<name>_next_frame`:** returns `eax = 1` for a frame, 0 when done. It is the
  effect's `next_frame` minus `ctx.frame()`, because the engine paces, advances the
  clock and renders after you return 1.
  - Where Rust does `ctx.update(self); return Some(ctx.frame())`, call `update` and
    return 1.
  - Effects that emit a frame without updating just return 1.
- **Effect state:** globals in `section .tstate`, which are zeroed each run. For
  per-character state, use `ch_user0`/`ch_user1` or your own arrays (via `alloc` or
  `reserve`).

### Characters (engine/chars.asm, terminal.asm, render.asm)

Slots are u32. Field arrays are pointer globals indexed by slot, for example
`mov rax, [ch_row]` then `mov eax, [rax + rdi*4]`. See the list at the top of
`chars.asm`. Most effects read `ch_irow`/`ch_icol` (the input coordinate),
`ch_row`/`ch_col` (the current coordinate), `ch_sym`, `ch_fg`/`ch_bg` (the input
colors), `ch_flags` and `ch_layer`.

- **`get_characters(edi=FILTER_* bits, esi=SORT_*) -> rax=u32 slots, rdx=count`:**
  `terminal.get_characters(filter, sort)`.
  - `FILTER_INPUT`, `FILTER_INNER_FILL`, `FILTER_OUTER_FILL`, `FILTER_ADDED`.
    `CharacterFilter::default()` is `FILTER_INPUT`.
  - `SORT_RANDOM` draws from the RNG exactly like Rust.
- **`get_characters_grouped(edi=filter, esi=GROUP_*) -> rax=groups, rdx=count`:**
  each group is 16 bytes, `(u32* slots, u64 count)`.
- **Other lookups:** `char_at_input_coord(rsi=coord) -> eax slot/NONE`, `char_coord(edi)`,
  `char_input_coord(edi) -> rax`. Neighbors live in `ch_nbr` at `slot*16 + NBR_*`.
- **Mutations:**
  - `add_character(rdi=symbol, rsi=coord) -> eax slot`
  - `set_coordinate(edi, rsi=coord)`, the only way to move a character
  - `set_layer(edi, rsi)`
  - `set_visibility(edi, esi=0/1)`, or `set_visible(edi)`
- **Canvas:**
  - `canvas_random_coord(edi=outside, esi=within_text)`,
    `canvas_random_column/row(edi=within_text)`, `coord_in_canvas(rsi) -> eax`
  - Globals: `canvas_top`, `canvas_right`, `text_top/bottom/left/right`,
    `text_center_row/col`, `center_row/col`, all i64.
  - The canvas's `bottom`/`left` are 1.

### Scenes (engine/scene.asm)

Scenes are addressed by a u32 index. Names are u32:
- auto ids are their numbers (`AUTO` asks for the next one);
- literal names are `NAME_LITERAL + k`, with your own constants.

Rust keys events by name, so keep Rust's names distinct the same way.

- **Creation:**
  - `scene_new(edi=slot, esi=name/AUTO, edx=SCF_LOOPING|SCF_SYNC_STEP|SCF_SYNC_DISTANCE, ecx=easing id or NONE) -> eax`.
    This is `animation.new_scene(is_looping, sync, ease, id, uses_preexisting)`;
    preexisting colors are taken from the character automatically.
  - `scene_find(edi, esi=name) -> eax/NONE`.
- **Frames:**
  - `scene_add_frame(edi=scene, rsi=symbol, edx=duration, rcx=fg/NONE, r8=bg/NONE, r9d=ATTR_*)`
  - `scene_add_frame_visual(edi=scene, esi=handle, edx=duration)`, when you cached the
    visual yourself
  - `scene_apply_gradient(edi=scene, rsi=symbols, rdx=count, ecx=duration, r8=fg spectrum/0, r9=fg count, stack: bg spectrum/0, bg count)`
  - `scene_copy(edi=slot, esi=src, edx=name) -> eax` for `scene.clone()` inserted
    elsewhere, and `scene_reset(edi=scene)`
- **Activation:**
  - `scene_activate(edi=slot, esi=scene)` and `scene_activate_name(edi, esi=name)`
    (`ctx.activate_scene`)
  - `scene_deactivate(edi, esi=name/NONE)` and `scene_is_complete(edi) -> eax`
  - `step_animation(edi)` (`ctx.step_animation`)
- **Appearance:** `set_appearance(edi, rsi=symbol or 0 = input symbol, rdx=fg, rcx=bg)`
  and `reset_appearance(edi)`.
- **Visuals:**
  - `visual_make(rdi=fg, rsi=bg, rdx=symbol, ecx=ATTR_*) -> eax handle`
  - `visual_meta(eax=handle) -> rax`: the header is at `[rax + VH_SYMBOL/VH_FG/VH_BG/VH_ATTRS]`.
    This is how you read `current_character_visual.symbol/colors`
    (`mov rax, [ch_handle]; mov eax, [rax + rdi*4]; call visual_meta`).

### Motion (engine/motion.asm)

- **Paths:**
  - `path_new(edi=slot, xmm0=speed, esi=easing/NONE, rdx=layer or NONE_I64, rcx=hold_time, r8d=loop, r9d=name/AUTO) -> eax`
  - `path_find(edi, esi=name) -> eax`
- **Waypoints:** `path_new_waypoint(edi=path, rsi=coord, rdx=bezier controls/0, ecx=count, r8d=name/AUTO) -> rax=waypoint`.
  Controls are packed coordinates and are copied.
- **Activation:**
  - `path_activate(edi=slot, esi=path)` and `path_activate_name(edi, esi=name)`
  - `path_deactivate(edi, esi=name/NONE)`
  - `chain_paths(edi, rsi=u32 names, rdx=count, ecx=loop)`
- **Stepping:** `motion_move(edi)`. Path records are `[paths] + index*PATH_SIZE`
  (`PA_*` fields, for reading `current_step`, `max_steps` and so on), and
  `ch_path`/`ch_done_path` give the active and completed path indices.

### Events (engine/events.asm)

- **Registration:** `event_register(edi=slot, esi=EV_*, edx=CALLER_SCENE|PATH|WAYPOINT, rcx=name or waypoint record pointer, r8d=ACT_*, r9=arg0, [stack]=arg1)`.
  Push arg1, and pad to keep the stack as `push 0; push arg1; call; add rsp, 16`.
  - Actions: `ACT_ACTIVATE_PATH/SCENE` (name), `ACT_DEACTIVATE_PATH/SCENE` (name or NONE),
    `ACT_RESET_APPEARANCE`, `ACT_SET_LAYER`, `ACT_SET_COORDINATE`, and
    `ACT_CALLBACK` (arg0 = function, arg1 = payload).
  - A callback is `fn(edi=slot, rsi=payload)`, the effect's `dispatch_callback`. It may
    call any engine function.
- **Dispatch:** `handle_event(edi, esi, edx, rcx)` fires an event by hand (rare).
- **Reset:** `event_clear(edi)`.

### Update and the active set (engine/update.asm)

`update` (`ctx.update`), `tick(edi)`, `active_insert(edi)`, `active_remove(edi)`,
`active_contains(edi)`, `active_clear`, `active_empty -> eax`, `active_count -> rax`,
`is_active(edi)`.

Never write `ch_scene`, `ch_path` or `ch_flags`'s visible bit directly; the API
functions keep the render grid and the active set's prune candidates in step.

### Particles (engine/particles.asm)

A `POOL` struc lives in your memory.

- **Setup:**
  - `pool_init(rdi=pool, rsi=symbols, rdx=count, rcx=max/-1, r8=coord)`.
  - Set `POOL.reset` (the `RESET_*` bits, default `RESET_DEFAULT`) and
    `POOL.initializer`/`init_user` before acquiring.
  - `pool_preallocate(rdi, rsi=count)`.
- **Use:**
  - `pool_acquire(rdi, rsi=symbol/0) -> eax slot/NONE`
  - `pool_emit(rdi, rsi=origin, rdx=symbol/0, ecx=visible, r8=on_emit/0, r9=user) -> eax`
  - `pool_reclaim(rdi, esi=slot, edx=hide, ecx=deactivate)`
  - `pool_extend(rdi, rsi=slots, rdx=count)`

### Utilities

- **RNG** (utils/rng.asm): `rng_below(rdi=n)` (randbelow and choice),
  `rng_randint(rdi, rsi)`, `rng_randrange(rdi, rsi)`, `rng_random -> xmm0`,
  `rng_uniform(xmm0, xmm1)`, `rng_shuffle32/64(rdi=array, rsi=count)`.
- **Gradients** (utils/graphics.asm):
  - `gradient_capacity(rdi=steps, rcx=step count, rsi=stop count) -> rax` sizes the
    spectrum.
  - `gradient_new(rdi=stops, esi=stop count, rdx=steps, ecx=step count, r8=out) -> eax length`.
  - `gradient_at_fraction(rdi=spectrum, esi=len, xmm0) -> rax`.
  - `gradient_map(...)` gives a dense coordinate map; see its header.
  - `Gradient::with_steps(stops, n, false)` is `gradient_new` with one step count.
- **Colors** (utils/color.asm): `adjust_color_brightness(rdi, xmm0) -> rax`,
  `shift_color_towards`, `random_color`.
- **Geometry** (utils/geometry.asm): Rust's names, e.g. `find_coords_on_circle`,
  `find_coords_in_circle`, `find_coords_in_rect`, `find_coord_on_line`,
  `find_coord_on_bezier_curve`, `find_length_of_line`, `find_length_of_bezier_curve`,
  `extrapolate_along_ray`, `find_normalized_distance_from_center`. See each header.
- **pycompat:** `round_half_even(xmm0) -> rax`, `f64_to_i64` (a saturating `as`),
  `floor_div`, `py_mod`.
- **Easing** (utils/easing.asm): `ease(edi=id, xmm0) -> xmm0`, `easing_tracker_*` and
  `sequence_easer_*`; see the strucs there.
- **Clock:** `clock_wall -> xmm0` (`ctx.clock.now_wall()`) and
  `clock_monotonic -> xmm0`.
- **Symbols:** `utf8_pack(edi=codepoint) -> rax`.

### Not ported yet (Rust declines these for every effect)

The following are declined globally in `src/asm/ffi.rs`:
- ANSI input
- `--wrap-text`
- `--existing-color-handling always|dynamic`

Port your effect's dynamic-color branches anyway, reading `ch_fg`/`ch_bg` (NONE when
absent), so they work when the input side lands.
