; utils/pycompat.asm - Python semantics where they differ from Rust's
; (src/utils/pycompat.rs): round(), // and %. Also Rust's own saturating
; float-to-integer cast, which every transcribed `as i64` needs because
; cvttsd2si returns the integer-indefinite value on overflow and NaN.

; ROUND_HALF_EVEN: rax = round_half_even(xmm0), inline. cvtsd2si rounds with
; MXCSR's default nearest-even mode, which is Python's round() for every
; value it can represent; it returns i64::MIN on overflow and NaN, and that
; (rare) result takes the full routine. Clobbers rcx and xmm0 on that path.
%macro ROUND_HALF_EVEN 0
    cvtsd2si rax, xmm0
    cmp     rax, 1                      ; overflows only for i64::MIN
    jno     %%done
    call    round_half_even
%%done:
%endmacro

; F64_TO_I64: rax = xmm0 as i64 (Rust's saturating cast), inline; the
; indefinite result takes f64_to_i64. Clobbers rcx on that path.
%macro F64_TO_I64 0
    cvttsd2si rax, xmm0
    cmp     rax, 1
    jno     %%done
    call    f64_to_i64
%%done:
%endmacro

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
; calls rint, which is exact); cvtsd2si does both at once in MXCSR's
; default mode, and only its i64::MIN result (a real -2^63, overflow or
; NaN) needs more. Finite values there are integers already, so the
; saturating cast finishes them. Non-finite values take the source's
; floor/diff path: floor(x) is x and diff is NaN, so neither comparison
; holds and the result is `floor as i64` plus its low bit. That gives
; NaN -> 0, -inf -> i64::MIN and +inf -> i64::MAX + 1, which wraps to
; i64::MIN exactly as the oracle's release build does.
; Clobbers rcx, xmm0.
round_half_even:
    cvtsd2si rax, xmm0
    cmp     rax, 1
    jo      .edge
    ret
.edge:
    movq    rax, xmm0
    mov     rcx, 0x7fffffffffffffff
    and     rax, rcx
    mov     rcx, 0x7ff0000000000000
    cmp     rax, rcx
    jl      f64_to_i64                  ; finite: already an integer
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
