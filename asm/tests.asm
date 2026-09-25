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

; Easing utilities already follow SysV. Storage layouts are in easing.asm.
global ttfx_test_ease
ttfx_test_ease:
    jmp     ease

global ttfx_test_easing_tracker_new
ttfx_test_easing_tracker_new:
    jmp     easing_tracker_new

global ttfx_test_easing_tracker_step
ttfx_test_easing_tracker_step:
    jmp     easing_tracker_step

global ttfx_test_easing_tracker_reset
ttfx_test_easing_tracker_reset:
    jmp     easing_tracker_reset

global ttfx_test_easing_tracker_is_complete
ttfx_test_easing_tracker_is_complete:
    jmp     easing_tracker_is_complete

global ttfx_test_sequence_easer_new
ttfx_test_sequence_easer_new:
    jmp     sequence_easer_new

global ttfx_test_sequence_easer_step
ttfx_test_sequence_easer_step:
    jmp     sequence_easer_step

global ttfx_test_sequence_easer_reset
ttfx_test_sequence_easer_reset:
    jmp     sequence_easer_reset

global ttfx_test_sequence_easer_is_complete
ttfx_test_sequence_easer_is_complete:
    jmp     sequence_easer_is_complete
