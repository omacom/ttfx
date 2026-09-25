; tests.asm - SysV entry points for tests/asm_diff.rs, which compares asm
; functions against their Rust originals on large input sets. Each thunk
; preserves callee-saved registers and aligns nothing it does not need to:
; the functions it wraps never call C unless they use CCALL.
;
; Name them ttfx_test_<module>_<function>. Keep this file test-only glue:
; no logic beyond marshalling arguments.

section .text

; ttfx_test_rng_randint(rdi=state[4] in/out, rsi=a, rdx=b) -> rax
global ttfx_test_rng_randint
ttfx_test_rng_randint:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    call    rng_load
    mov     rdi, r12
    mov     rsi, r13
    call    rng_randint
    mov     r14, rax
    mov     rdi, rbx
    call    rng_store
    mov     rax, r14
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ttfx_test_rng_uniform(rdi=state[4] in/out, xmm0=a, xmm1=b) -> xmm0
global ttfx_test_rng_uniform
ttfx_test_rng_uniform:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    movsd   [rsp], xmm0
    movsd   [rsp + 8], xmm1
    call    rng_load
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp + 8]
    call    rng_uniform
    movsd   [rsp], xmm0
    mov     rdi, rbx
    call    rng_store
    movsd   xmm0, [rsp]
    add     rsp, 16
    pop     rbx
    ret

; ttfx_test_rng_shuffle64(rdi=state[4] in/out, rsi=array, rdx=length)
global ttfx_test_rng_shuffle64
ttfx_test_rng_shuffle64:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    call    rng_load
    mov     rdi, r12
    mov     rsi, r13
    call    rng_shuffle64
    mov     rdi, rbx
    call    rng_store
    pop     r13
    pop     r12
    pop     rbx
    ret

; ttfx_test_arena_reset(): a fresh arena for the list-returning functions,
; releasing the previous one (tests never run an effect, which would do
; this itself).
global ttfx_test_arena_reset
ttfx_test_arena_reset:
    push    rbx
    call    release_regions
    mov     rdi, 1 << 38
    call    reserve
    mov     [arena_ptr], rax
    pop     rbx
    ret

; The internal functions below take SysV-shaped arguments and preserve the
; callee-saved registers, so their thunks are tail jumps.
global ttfx_test_pycompat_round_half_even
global ttfx_test_pycompat_f64_to_i64
global ttfx_test_pycompat_floor_div
global ttfx_test_pycompat_py_mod
ttfx_test_pycompat_round_half_even: jmp round_half_even  ; (xmm0) -> rax
ttfx_test_pycompat_f64_to_i64:      jmp f64_to_i64       ; (xmm0) -> rax
ttfx_test_pycompat_floor_div:       jmp floor_div        ; (rdi, rsi) -> rax
ttfx_test_pycompat_py_mod:          jmp py_mod           ; (rdi, rsi) -> rax

; Lists come back as rax = pointer, rdx = count: a two-word C struct.
global ttfx_test_geometry_coords_on_circle
global ttfx_test_geometry_coords_in_circle
global ttfx_test_geometry_coords_in_rect
global ttfx_test_geometry_coords_on_rect
global ttfx_test_geometry_extrapolate_along_ray
global ttfx_test_geometry_coord_on_bezier_curve
global ttfx_test_geometry_coord_on_line
global ttfx_test_geometry_length_of_bezier_curve
global ttfx_test_geometry_length_of_line
global ttfx_test_geometry_circle_iter_init
ttfx_test_geometry_coords_on_circle:      jmp find_coords_on_circle      ; (rdi=origin, rsi=radius, rdx=limit, ecx=unique)
ttfx_test_geometry_coords_in_circle:      jmp find_coords_in_circle      ; (rdi=center, rsi=diameter)
ttfx_test_geometry_coords_in_rect:        jmp find_coords_in_rect        ; (rdi=origin, rsi=distance)
ttfx_test_geometry_coords_on_rect:        jmp find_coords_on_rect        ; (rdi=origin, rsi=half_width, rdx=half_height)
ttfx_test_geometry_extrapolate_along_ray: jmp extrapolate_along_ray      ; (rdi=origin, rsi=target, xmm0=offset) -> rax
ttfx_test_geometry_coord_on_bezier_curve: jmp find_coord_on_bezier_curve ; (rdi=start, rsi=control, rdx=count, rcx=end, xmm0=t) -> rax
ttfx_test_geometry_coord_on_line:         jmp find_coord_on_line         ; (rdi=start, rsi=end, xmm0=t) -> rax
ttfx_test_geometry_length_of_bezier_curve: jmp find_length_of_bezier_curve ; (rdi=start, rsi=control, rdx=count, rcx=end) -> xmm0
ttfx_test_geometry_length_of_line:        jmp find_length_of_line        ; (rdi=a, rsi=b, edx=double) -> xmm0
ttfx_test_geometry_circle_iter_init:      jmp coords_in_circle_init      ; (rdi=state, rsi=center, rdx=diameter)

; ttfx_test_geometry_circle_iter_next(rdi=state, rsi=out coord) -> eax = 1
; while coordinates remain.
global ttfx_test_geometry_circle_iter_next
ttfx_test_geometry_circle_iter_next:
    push    rbx
    mov     rbx, rsi
    call    coords_in_circle_next
    mov     [rbx], rax
    mov     eax, edx
    pop     rbx
    ret

; ttfx_test_geometry_normalized_distance(rdi=bottom, rsi=top, rdx=left,
; rcx=right, r8=coord, r9=out f64) -> eax = 1 when inside.
global ttfx_test_geometry_normalized_distance
ttfx_test_geometry_normalized_distance:
    push    rbx
    mov     rbx, r9
    call    find_normalized_distance_from_center
    movsd   [rbx], xmm0
    pop     rbx
    ret

global ttfx_test_color_adjust_color_brightness
global ttfx_test_color_shift_color_towards
ttfx_test_color_adjust_color_brightness: jmp adjust_color_brightness     ; (rdi=color, xmm0=brightness) -> rax
ttfx_test_color_shift_color_towards:     jmp shift_color_towards         ; (rdi=color, rsi=target, xmm0=factor) -> rax, rdx

; ttfx_test_color_random_color(rdi=state[4] in/out) -> rax
global ttfx_test_color_random_color
ttfx_test_color_random_color:
    push    rbx
    push    r12
    mov     rbx, rdi
    call    rng_load
    call    random_color
    mov     r12, rax
    mov     rdi, rbx
    call    rng_store
    mov     rax, r12
    pop     r12
    pop     rbx
    ret
