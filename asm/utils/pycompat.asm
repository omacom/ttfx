; utils/pycompat.asm - Python semantics where they differ from Rust's
; (src/utils/pycompat.rs): round(), // and %. Also Rust's own saturating
; float-to-integer cast, which every transcribed `as i64` needs because
; cvttsd2si returns the integer-indefinite value on overflow and NaN.

section .text

; f64_to_i64(xmm0) -> rax = xmm0 as i64 with Rust semantics: truncation,
; saturation at both ends, NaN -> 0. Clobbers rcx.
f64_to_i64:
    cvttsd2si rax, xmm0                 ; i64::MIN on overflow and NaN
    ucomisd xmm0, [pc_below_2p63]
    mov     rcx, 0x7fffffffffffffff
    cmova   rax, rcx                    ; >= 2^63 saturates high
    xor     ecx, ecx
    ucomisd xmm0, xmm0
    cmovp   rax, rcx                    ; NaN -> 0
    ret

; round_half_even(xmm0) -> rax: Python round() to i64 (pycompat.rs). Finite
; values round to nearest even and then convert like `as i64` (the oracle
; calls rint, which is exact, so roundsd matches). Non-finite values take
; the source's floor/diff path: floor(x) is x and diff is NaN, so neither
; comparison holds and the result is `floor as i64` plus its low bit. That
; gives NaN -> 0, -inf -> i64::MIN and +inf -> i64::MAX + 1, which wraps to
; i64::MIN exactly as the oracle's release build does.
; Clobbers rcx, xmm0.
round_half_even:
    movq    rax, xmm0
    mov     rcx, 0x7fffffffffffffff
    and     rax, rcx
    mov     rcx, 0x7ff0000000000000
    cmp     rax, rcx
    jge     .non_finite
    roundsd xmm0, xmm0, 0               ; nearest, ties to even
    jmp     f64_to_i64
.non_finite:
    call    f64_to_i64
    mov     rcx, rax
    and     ecx, 1
    add     rax, rcx
    ret

; floor_div(rdi=a, rsi=b) -> rax = a // b (Python floor division).
; b must be nonzero. Clobbers rdx.
floor_div:
    mov     rax, rdi
    cqo
    idiv    rsi
    test    rdx, rdx
    jz      .done
    xor     rdx, rsi                    ; remainder and divisor differ in sign
    jns     .done
    dec     rax
.done:
    ret

; py_mod(rdi=a, rsi=b) -> rax = a % b with the divisor's sign (Python %).
; b must be nonzero. Clobbers rcx, rdx.
py_mod:
    mov     rax, rdi
    cqo
    idiv    rsi
    mov     rax, rdx
    test    rax, rax
    jz      .done
    mov     rcx, rax
    xor     rcx, rsi
    jns     .done
    add     rax, rsi
.done:
    ret

section .rodata
align 8
pc_below_2p63:  dq 0x43dfffffffffffff   ; the largest f64 below 2^63
