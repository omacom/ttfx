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
