; utils/rng.asm - xoshiro256++ with the Python-shaped helpers of
; src/utils/rng.rs. Every helper consumes draws exactly as the Rust one does;
; that draw order is the parity contract.
;
; The generator runs ahead in batches with its state in registers, and draws
; are served from the batch. The raw sequence does not depend on how it is
; consumed, so this is exactly the Rust sequence without a store-to-load
; round trip through the state on every draw.

%define RNG_BATCH   512

section .text

; rng_seed(rdi=seed): SplitMix64 expansion into the xoshiro state.
rng_seed:
    mov     rsi, 0x9E3779B97F4A7C15
    mov     r8, 0xBF58476D1CE4E5B9
    mov     r9, 0x94D049BB133111EB
    lea     r10, [rng_state]
    xor     ecx, ecx
.next:
    add     rdi, rsi
    mov     rax, rdi
    mov     rdx, rax
    shr     rdx, 30
    xor     rax, rdx
    imul    rax, r8
    mov     rdx, rax
    shr     rdx, 27
    xor     rax, rdx
    imul    rax, r9
    mov     rdx, rax
    shr     rdx, 31
    xor     rax, rdx
    mov     [r10 + rcx * 8], rax
    inc     ecx
    cmp     ecx, 4
    jb      .next
    mov     qword [rng_pos], RNG_BATCH  ; the first draw generates a batch
    ret

; rng_load(rdi=4 x u64 state): continue from a state handed in by Rust.
rng_load:
    mov     rax, [rdi]
    mov     [rng_state], rax
    mov     rax, [rdi + 8]
    mov     [rng_state + 8], rax
    mov     rax, [rdi + 16]
    mov     [rng_state + 16], rax
    mov     rax, [rdi + 24]
    mov     [rng_state + 24], rax
    mov     qword [rng_pos], RNG_BATCH
    ret

; rng_store(rdi=4 x u64 out): the logical state - as if every draw so far
; had been taken one at a time, which is where Rust's generator would be.
rng_store:
    push    rdi
    mov     rcx, [rng_pos]
    cmp     rcx, RNG_BATCH
    jb      .partial
    lea     rsi, [rng_state]
    jmp     .copy
.partial:
    ; replay the consumed part of the batch from the batch's starting state
    mov     r8, [rng_batch_start]
    mov     r9, [rng_batch_start + 8]
    mov     r10, [rng_batch_start + 16]
    mov     rdx, [rng_batch_start + 24]
.step:
    test    rcx, rcx
    jz      .stepped
    mov     r11, r9
    shl     r11, 17
    xor     r10, r8
    xor     rdx, r9
    xor     r9, r10
    xor     r8, rdx
    xor     r10, r11
    rol     rdx, 45
    dec     rcx
    jmp     .step
.stepped:
    lea     rsi, [rng_scratch]
    mov     [rsi], r8
    mov     [rsi + 8], r9
    mov     [rsi + 16], r10
    mov     [rsi + 24], rdx
.copy:
    pop     rdi
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     rax, [rsi + 8]
    mov     [rdi + 8], rax
    mov     rax, [rsi + 16]
    mov     [rdi + 16], rax
    mov     rax, [rsi + 24]
    mov     [rdi + 24], rax
    ret

; rng_next -> rax: the next xoshiro256++ output.
; Clobbers rcx, rdx, r8, r9, r10, r11.
rng_next:
    mov     rcx, [rng_pos]
    cmp     rcx, RNG_BATCH
    jae     .refill
.take:
    lea     rax, [rng_buf]
    mov     rax, [rax + rcx * 8]
    inc     rcx
    mov     [rng_pos], rcx
    ret
.refill:
    mov     r8, [rng_state]
    mov     r9, [rng_state + 8]
    mov     r10, [rng_state + 16]
    mov     rdx, [rng_state + 24]
    mov     [rng_batch_start], r8
    mov     [rng_batch_start + 8], r9
    mov     [rng_batch_start + 16], r10
    mov     [rng_batch_start + 24], rdx
    push    rbx
    lea     rbx, [rng_buf]
    xor     ecx, ecx
.generate:
    ; four draws per pass (RNG_BATCH is a multiple of 4)
%assign i 0
%rep 4
    lea     rax, [r8 + rdx]
    rol     rax, 23
    add     rax, r8                     ; result
    mov     [rbx + rcx * 8 + i * 8], rax
    mov     r11, r9
    shl     r11, 17                     ; t
    xor     r10, r8                     ; s2 ^= s0
    xor     rdx, r9                     ; s3 ^= s1
    xor     r9, r10                     ; s1 ^= s2
    xor     r8, rdx                     ; s0 ^= s3
    xor     r10, r11                    ; s2 ^= t
    rol     rdx, 45                     ; s3 = rotl(s3, 45)
%assign i i + 1
%endrep
    add     ecx, 4
    cmp     ecx, RNG_BATCH
    jb      .generate
    pop     rbx
    mov     [rng_state], r8
    mov     [rng_state + 8], r9
    mov     [rng_state + 16], r10
    mov     [rng_state + 24], rdx
    xor     ecx, ecx
    jmp     .take

; rng_below(rdi=n > 0) -> rax in [0, n): bit-mask rejection sampling.
; n == 1 still draws (and may reject) exactly like Rust's randbelow.
rng_below:
    push    rbx
    push    r12
    mov     r12, rdi
    lea     rax, [rdi - 1]
%if TIER >= 3
    lzcnt   rax, rax                    ; 64 for n == 1
    mov     ebx, 64
    sub     ebx, eax                    ; bits
%else
    xor     ebx, ebx                    ; bits: 0 for n == 1
    bsr     rax, rax
    jz      .bits
    lea     ebx, [eax + 1]
.bits:
%endif
    mov     eax, 1
    cmp     ebx, eax
    cmovb   ebx, eax                    ; bits.max(1)
    mov     eax, 64
    sub     eax, ebx
    mov     ebx, eax                    ; shift = 64 - bits
.again:
    ; rng_next, its batch read inlined
    mov     rcx, [rng_pos]
    cmp     rcx, RNG_BATCH
    jae     .refill
    lea     rax, [rng_buf]
    mov     rax, [rax + rcx * 8]
    inc     rcx
    mov     [rng_pos], rcx
.drawn:
%if TIER >= 3
    shrx    rax, rax, rbx
%else
    mov     ecx, ebx
    shr     rax, cl
%endif
    cmp     rax, r12
    jae     .again
    pop     r12
    pop     rbx
    ret
.refill:
    call    rng_next
    jmp     .drawn

; rng_randint(rdi=a, rsi=b) -> rax in [a, b].
rng_randint:
    push    rbx
    mov     rbx, rdi
    sub     rsi, rdi
    lea     rdi, [rsi + 1]
    call    rng_below
    add     rax, rbx
    pop     rbx
    ret

; rng_randrange(rdi=a, rsi=b) -> rax in [a, b).
rng_randrange:
    push    rbx
    mov     rbx, rdi
    sub     rsi, rdi
    mov     rdi, rsi
    call    rng_below
    add     rax, rbx
    pop     rbx
    ret

; rng_random -> xmm0 in [0, 1): (next >> 11) * 2^-53, Python random().
; Clobbers rcx, rdx, r8-r11.
rng_random:
    call    rng_next
    shr     rax, 11
    cvtsi2sd xmm0, rax
    mulsd   xmm0, [two_pow_minus_53]
    ret

; RNG_BITS53: rax = next >> 11, the integer behind rng_random (random() is
; exactly rax * 2^-53), with the batch read inlined for hot loops. So
; random() < c is exactly rax < ceil(c * 2^53); see rng_threshold.
; Clobbers rcx, and rdx, r8-r11 when the batch refills.
%macro RNG_BITS53 0
    mov     rcx, [rng_pos]
    cmp     rcx, RNG_BATCH
    jae     %%refill
    lea     rax, [rng_buf]
    mov     rax, [rax + rcx * 8]
    inc     rcx
    mov     [rng_pos], rcx
    jmp     %%done
%%refill:
    call    rng_next
%%done:
    shr     rax, 11
%endmacro

; rng_threshold(xmm0=c >= 0) -> rax: the T with random() < c exactly when
; RNG_BITS53 < T, i.e. ceil(c * 2^53) capped at 2^53. Clobbers xmm0, xmm1.
rng_threshold:
    mulsd   xmm0, [two_pow_53]
    movsd   xmm1, [two_pow_53]
    minsd   xmm0, xmm1
%if TIER >= 2
    roundsd xmm0, xmm0, 2               ; toward +inf
    cvttsd2si rax, xmm0
%else
    ; ceil of a value in [0, 2^53]: truncate, then up when that lost a part
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    ucomisd xmm0, xmm1
    jbe     .ceiled
    inc     rax
.ceiled:
%endif
    ret

; rng_uniform(xmm0=a, xmm1=b) -> xmm0 = a + (b - a) * random().
rng_uniform:
    sub     rsp, 24
    movsd   [rsp], xmm0
    movsd   [rsp + 8], xmm1
    call    rng_random
    movsd   xmm1, [rsp + 8]
    subsd   xmm1, [rsp]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rsp]
    add     rsp, 24
    ret

; rng_shuffle32(rdi=u32 array, rsi=length) / rng_shuffle64(rdi=u64 array,
; rsi=length): Fisher-Yates from the top, CPython's loop
; (for i in reversed(range(1, n)): j = randbelow(i + 1); swap).
rng_shuffle32:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
.next:
    dec     r12
    jle     .done
    lea     rdi, [r12 + 1]
    call    rng_below
    mov     ecx, [rbx + r12 * 4]
    mov     edx, [rbx + rax * 4]
    mov     [rbx + r12 * 4], edx
    mov     [rbx + rax * 4], ecx
    jmp     .next
.done:
    pop     r12
    pop     rbx
    ret

rng_shuffle64:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
.next:
    dec     r12
    jle     .done
    lea     rdi, [r12 + 1]
    call    rng_below
    mov     rcx, [rbx + r12 * 8]
    mov     rdx, [rbx + rax * 8]
    mov     [rbx + r12 * 8], rdx
    mov     [rbx + rax * 8], rcx
    jmp     .next
.done:
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
two_pow_minus_53:   dq 0x3CA0000000000000   ; 1.0 / (1 << 53)
two_pow_53:         dq 0x4340000000000000   ; 1 << 53

section .tstate
alignb 64
rng_buf:    resq RNG_BATCH
rng_state:  resq 4
rng_batch_start: resq 4
rng_scratch: resq 4
rng_pos:    resq 1
