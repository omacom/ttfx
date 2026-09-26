; utils/rng.asm - xoshiro256++ with the Python-shaped helpers of
; src/utils/rng.rs. Every helper consumes draws exactly as the Rust one does;
; that draw order is the parity contract.
;
; The generator runs ahead in batches with its state in registers, and draws
; are served from the batch. The raw sequence does not depend on how it is
; consumed, so this is exactly the Rust sequence without a store-to-load
; round trip through the state on every draw.
;
; At TIER 4 a batch is eight lanes of RNG_LANE consecutive draws each,
; generated side by side in zmm registers. The state transition is linear
; over GF(2), so lane i's next start - RNG_BATCH - RNG_LANE draws past its
; end - is a fixed 256x256 bit matrix times its end state (rng_jump.inc);
; lane 0's is lane 7's end. The first batch after seeding runs scalar and
; records the lanes' end states.

%if TIER >= 4
%define RNG_LANES   8
%define RNG_LANE    256                 ; draws a lane (rng_jump.inc: 7 * 256 steps)
%define RNG_BATCH   (RNG_LANES * RNG_LANE)
%else
%define RNG_LANES   1
%define RNG_BATCH   512
%define RNG_LANE    RNG_BATCH
%endif

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
    mov     byte [rng_lanes_ok], 0
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
    mov     byte [rng_lanes_ok], 0
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
; Clobbers rcx only.
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
    call    rng_refill
    xor     ecx, ecx
    jmp     .take

; rng_refill: generate the next batch into rng_buf (rng_pos is left to the
; caller, which starts the batch at 0). Preserves every register but the
; flags, so the draw macros below can call it from anywhere.
rng_refill:
    push    rax
    push    rcx
    push    rdx
    push    rbx
    push    rsi
    push    r8
    push    r9
    push    r10
    push    r11
%if TIER >= 4
    cmp     byte [rng_lanes_ok], 0
    jne     .lanes
    mov     byte [rng_lanes_ok], 1
%endif
    mov     r8, [rng_state]
    mov     r9, [rng_state + 8]
    mov     r10, [rng_state + 16]
    mov     rdx, [rng_state + 24]
    mov     [rng_batch_start], r8
    mov     [rng_batch_start + 8], r9
    mov     [rng_batch_start + 16], r10
    mov     [rng_batch_start + 24], rdx
    lea     rbx, [rng_buf]
    xor     esi, esi                    ; lane
.lane:
    lea     rcx, [rbx + RNG_LANE * 8]
.generate:
    ; four draws per pass (RNG_LANE is a multiple of 4). The state update
    ; is two xors deep a step, the output a side chain off it.
%assign i 0
%rep 4
    lea     rax, [r8 + rdx]
    rol     rax, 23
    add     rax, r8                     ; result
    mov     [rbx + i * 8], rax
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
    add     rbx, 32
    cmp     rbx, rcx
    jb      .generate
%if TIER >= 4
    ; the lane's end state, for the vector batches
    lea     rax, [rng_lanes]
    mov     [rax + rsi * 8], r8
    mov     [rax + rsi * 8 + 64], r9
    mov     [rax + rsi * 8 + 128], r10
    mov     [rax + rsi * 8 + 192], rdx
%endif
    inc     esi
    cmp     esi, RNG_LANES
    jb      .lane
    mov     [rng_state], r8
    mov     [rng_state + 8], r9
    mov     [rng_state + 16], r10
    mov     [rng_state + 24], rdx
.done:
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rsi
    pop     rbx
    pop     rdx
    pop     rcx
    pop     rax
    ret
%if TIER >= 4
.lanes:
    ; eight lanes in zmm16-31 only, which legacy SSE code never touches, so
    ; no vzeroupper is needed; they and k1 are saved for the callers
    sub     rsp, 16 * 64
%assign i 0
%rep 16
    vmovdqu64 [rsp + i * 64], zmm %+ %eval(16 + i)
%assign i i + 1
%endrep
    kmovq   rax, k1
    push    rax
    push    rdi
    ; the jump: each lane's next start is the XOR of the matrix rows of
    ; its end state's set bits (zmm20-23 = the end states' words s0..s3,
    ; lane i in qword i; zmm16-19 = the starts)
    vmovdqu64 zmm20, [rng_lanes]
    vmovdqu64 zmm21, [rng_lanes + 64]
    vmovdqu64 zmm22, [rng_lanes + 128]
    vmovdqu64 zmm23, [rng_lanes + 192]
    vpxorq  zmm16, zmm16, zmm16
    vpxorq  zmm17, zmm17, zmm17
    vpxorq  zmm18, zmm18, zmm18
    vpxorq  zmm19, zmm19, zmm19
    lea     rsi, [rng_jump]
    lea     rdi, [rng_bits]
%assign w 0
%rep 4
    xor     ecx, ecx
.bit%[w]:
    vptestmq k1, zmm %+ %eval(20 + w), [rdi + rcx * 8]{1to8}
    vpxorq  zmm16{k1}, zmm16, [rsi]{1to8}
    vpxorq  zmm17{k1}, zmm17, [rsi + 8]{1to8}
    vpxorq  zmm18{k1}, zmm18, [rsi + 16]{1to8}
    vpxorq  zmm19{k1}, zmm19, [rsi + 24]{1to8}
    add     rsi, 32
    inc     ecx
    cmp     ecx, 64
    jb      .bit%[w]
%assign w w + 1
%endrep
    ; lane 0 starts the batch
    vmovq   [rng_batch_start], xmm16
    vmovq   [rng_batch_start + 8], xmm17
    vmovq   [rng_batch_start + 16], xmm18
    vmovq   [rng_batch_start + 24], xmm19
    ; RNG_LANE steps of all eight lanes, four at a time: zmm20-23 get the
    ; outputs, lane i in qword i, and a transpose turns them into four
    ; consecutive draws per lane (ymm halves stored at the lanes' blocks)
    vmovdqu64 zmm30, [rng_idx_lo]
    vmovdqu64 zmm31, [rng_idx_hi]
    lea     rbx, [rng_buf]
    lea     rcx, [rbx + RNG_LANE * 8]
.vgenerate:
%assign i 0
%rep 4
    vpaddq  zmm %+ %eval(20 + i), zmm16, zmm19
    vprolq  zmm %+ %eval(20 + i), zmm %+ %eval(20 + i), 23
    vpaddq  zmm %+ %eval(20 + i), zmm %+ %eval(20 + i), zmm16    ; result
    vpsllq  zmm24, zmm17, 17            ; t = s1 << 17
    vpxorq  zmm25, zmm19, zmm17         ; s3 ^ s1
    vpternlogq zmm17, zmm18, zmm16, 0x96    ; s1 ^= s2 ^ s0
    vpternlogq zmm18, zmm16, zmm24, 0x96    ; s2 ^= s0 ^ t
    vpxorq  zmm16, zmm16, zmm25         ; s0 ^= s3 ^ s1
    vprolq  zmm19, zmm25, 45            ; s3 = rotl(s3 ^ s1, 45)
%assign i i + 1
%endrep
    vpunpcklqdq zmm26, zmm20, zmm21     ; lanes 2c: draws j, j+1
    vpunpckhqdq zmm27, zmm20, zmm21     ; lanes 2c+1
    vpunpcklqdq zmm28, zmm22, zmm23     ; lanes 2c: draws j+2, j+3
    vpunpckhqdq zmm29, zmm22, zmm23
    vmovdqa64 zmm20, zmm30
    vpermi2q zmm20, zmm26, zmm28        ; lanes 0 | 2
    vmovdqa64 zmm21, zmm31
    vpermi2q zmm21, zmm26, zmm28        ; lanes 4 | 6
    vmovdqa64 zmm22, zmm30
    vpermi2q zmm22, zmm27, zmm29        ; lanes 1 | 3
    vmovdqa64 zmm23, zmm31
    vpermi2q zmm23, zmm27, zmm29        ; lanes 5 | 7
    vmovdqu64 [rbx], ymm20
    vextracti64x4 [rbx + 2 * RNG_LANE * 8], zmm20, 1
    vmovdqu64 [rbx + 4 * RNG_LANE * 8], ymm21
    vextracti64x4 [rbx + 6 * RNG_LANE * 8], zmm21, 1
    vmovdqu64 [rbx + 1 * RNG_LANE * 8], ymm22
    vextracti64x4 [rbx + 3 * RNG_LANE * 8], zmm22, 1
    vmovdqu64 [rbx + 5 * RNG_LANE * 8], ymm23
    vextracti64x4 [rbx + 7 * RNG_LANE * 8], zmm23, 1
    add     rbx, 32
    cmp     rbx, rcx
    jb      .vgenerate
    ; the end states, and lane 7's is where a whole batch leaves the stream
    vmovdqu64 [rng_lanes], zmm16
    vmovdqu64 [rng_lanes + 64], zmm17
    vmovdqu64 [rng_lanes + 128], zmm18
    vmovdqu64 [rng_lanes + 192], zmm19
    mov     rax, [rng_lanes + 56]
    mov     [rng_state], rax
    mov     rax, [rng_lanes + 64 + 56]
    mov     [rng_state + 8], rax
    mov     rax, [rng_lanes + 128 + 56]
    mov     [rng_state + 16], rax
    mov     rax, [rng_lanes + 192 + 56]
    mov     [rng_state + 24], rax
    pop     rdi
    pop     rax
    kmovq   k1, rax
%assign i 0
%rep 16
    vmovdqu64 zmm %+ %eval(16 + i), [rsp + i * 64]
%assign i i + 1
%endrep
    add     rsp, 16 * 64
    jmp     .done
%endif

; Draws with the position in a register, for hot loops. The sequence is
; the same as the functions', one draw per RNG_TAKE:
;   RNG_OPEN pos, base      pos = the batch position, base = rng_buf
;   RNG_TAKE dest, pos, base  dest = the next raw output (refills in place,
;                           preserving every other register)
;   RNG_TAKE53 dest, pos, base  dest = the next output >> 11, the integer
;                           behind rng_random (see RNG_BITS53)
;   RNG_CLOSE pos           write the position back
; Between RNG_OPEN and RNG_CLOSE no other RNG function may run: close
; before calling one and open again after. All operands are 64-bit
; registers; dest must differ from pos and base.
%macro RNG_OPEN 2
    mov     %1, [rng_pos]
    lea     %2, [rng_buf]
%endmacro

%macro RNG_TAKE 3
    cmp     %2, RNG_BATCH
    jb      %%ready
    call    rng_refill
    xor     %2, %2
%%ready:
    mov     %1, [%3 + %2 * 8]
    inc     %2
%endmacro

%macro RNG_TAKE53 3
    RNG_TAKE %1, %2, %3
    shr     %1, 11
%endmacro

%macro RNG_CLOSE 1
    mov     [rng_pos], %1
%endmacro

; rng_below(rdi=n > 0) -> rax in [0, n): bit-mask rejection sampling.
; n == 1 still draws (and may reject) exactly like Rust's randbelow.
; Clobbers rcx, rdx, r8.
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
    ; the position stays in rdx through the rejection loop
    lea     r8, [rng_buf]
    mov     rdx, [rng_pos]
%if TIER < 3
    mov     ecx, ebx
%endif
.again:
    cmp     rdx, RNG_BATCH
    jae     .refill
.take:
    mov     rax, [r8 + rdx * 8]
    inc     rdx
%if TIER >= 3
    shrx    rax, rax, rbx
%else
    shr     rax, cl
%endif
    cmp     rax, r12
    jae     .again
    mov     [rng_pos], rdx
    pop     r12
    pop     rbx
    ret
.refill:
    call    rng_refill
    xor     edx, edx
    jmp     .take

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
%if TIER >= 4
align 64
rng_idx_lo:         dq 0, 1, 8, 9, 2, 3, 10, 11
rng_idx_hi:         dq 4, 5, 12, 13, 6, 7, 14, 15
rng_bits:
%assign i 0
%rep 64
    dq 1 << i
%assign i i + 1
%endrep
rng_jump:
%include "utils/rng_jump.inc"
%endif

section .tstate
alignb 64
rng_buf:    resq RNG_BATCH
rng_state:  resq 4
rng_batch_start: resq 4
rng_scratch: resq 4
rng_pos:    resq 1
alignb 64
rng_lanes:  resq 32                     ; TIER 4: the lanes' end states, word-major
rng_lanes_ok: resb 1                    ; TIER 4: rng_lanes continue the stream
