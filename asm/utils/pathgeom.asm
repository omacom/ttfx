; utils/pathgeom.asm - the geometry motion needs (src/utils/geometry.rs):
; find_coord_on_line, find_length_of_line, find_coord_on_bezier_curve,
; find_length_of_bezier_curve. Coordinates are packed (column low 32 bits,
; row high 32 bits). Expression order follows Rust exactly; no FMA.

section .text

; round_half_even_i64(xmm0) -> rax: Python round() for finite values
; (round_ties_even, then a truncating conversion).
round_half_even_i64:
    roundsd xmm0, xmm0, 8               ; nearest-even, no precision exception
    cvttsd2si rax, xmm0
    ret

; coord_from_floats(xmm0=column, xmm1=row) -> rax = packed rounded coordinate.
coord_from_floats:
    roundsd xmm0, xmm0, 8
    cvttsd2si rax, xmm0
    roundsd xmm1, xmm1, 8
    cvttsd2si rcx, xmm1
    shl     rcx, 32
    mov     eax, eax
    or      rax, rcx
    ret

; coord_column_f(rdi=coord) -> xmm0; coord_row_f(rdi=coord) -> xmm0.
coord_column_f:
    movsxd  rax, edi
    cvtsi2sd xmm0, rax
    ret
coord_row_f:
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm0, rax
    ret

; line_coord(rdi=start, rsi=end, xmm0=t) -> rax. find_coord_on_line:
; x = (1 - t) * start + t * end per axis, then banker's rounding.
line_coord:
    movsd   xmm4, [pg_one]
    subsd   xmm4, xmm0                  ; 1 - t
    movsxd  rax, edi
    cvtsi2sd xmm1, rax
    mulsd   xmm1, xmm4
    movsxd  rax, esi
    cvtsi2sd xmm2, rax
    mulsd   xmm2, xmm0
    addsd   xmm1, xmm2                  ; column
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm2, rax
    mulsd   xmm2, xmm4
    mov     rax, rsi
    sar     rax, 32
    cvtsi2sd xmm3, rax
    mulsd   xmm3, xmm0
    addsd   xmm2, xmm3                  ; row
    movapd  xmm0, xmm1
    movapd  xmm1, xmm2
    jmp     coord_from_floats

; line_length(rdi=a, rsi=b, edx=double the row difference) -> xmm0.
; find_length_of_line: glibc hypot(column_diff, [2 *] row_diff).
; Clobbers the C caller-saved set.
line_length:
    movsxd  rax, esi
    movsxd  rcx, edi
    sub     rax, rcx
    cvtsi2sd xmm0, rax                  ; column_diff
    mov     rax, rsi
    sar     rax, 32
    mov     rcx, rdi
    sar     rcx, 32
    sub     rax, rcx
    cvtsi2sd xmm1, rax                  ; row_diff
    test    edx, edx
    jz      .call
    addsd   xmm1, xmm1                  ; 2.0 * row_diff (exact)
.call:
    CCALL   hypot
    ret

; bezier_coord(rdi=start, rsi=controls (packed coords), rdx=control count,
;              rcx=end, xmm0=t) -> rax. find_coord_on_bezier_curve:
; De Casteljau in floats, rounding only the final point.
bezier_coord:
    test    rdx, rdx
    jnz     .curve
    mov     rsi, rcx
    jmp     line_coord
.curve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    ; points: start, controls..., end as (column, row) float pairs
    lea     r12, [rdx + 2]              ; point count
    mov     rbx, rdi
    mov     r13, rcx
    movsd   [rsp], xmm0
    push    rsi
    mov     rdi, r12
    shl     rdi, 4
    call    alloc
    pop     rsi
    mov     r8, rax
    ; start
    mov     rdi, rbx
    call    .store_point
    ; controls
    xor     ecx, ecx
.controls:
    lea     rax, [r12 - 2]
    cmp     rcx, rax
    jae     .end_point
    mov     rdi, [rsi + rcx * 8]
    lea     rax, [rcx + 1]
    shl     rax, 4
    push    rcx
    lea     r9, [r8 + rax]
    call    .store_at
    pop     rcx
    inc     rcx
    jmp     .controls
.end_point:
    lea     rax, [r12 - 1]
    shl     rax, 4
    lea     r9, [r8 + rax]
    mov     rdi, r13
    call    .store_at
    ; repeated interpolation: points[i] = points[i].interpolate(points[i+1], t)
    movsd   xmm0, [rsp]
    movsd   xmm4, [pg_one]
    subsd   xmm4, xmm0                  ; 1 - t
    mov     r9, r12                     ; remaining
.level:
    cmp     r9, 1
    jbe     .result
    xor     ecx, ecx
.lerp:
    lea     rax, [r9 - 1]
    cmp     rcx, rax
    jae     .next_level
    mov     rax, rcx
    shl     rax, 4
    movsd   xmm1, [r8 + rax]            ; self.column
    mulsd   xmm1, xmm4
    movsd   xmm2, [r8 + rax + 16]       ; other.column
    mulsd   xmm2, xmm0
    addsd   xmm1, xmm2
    movsd   xmm2, [r8 + rax + 8]        ; self.row
    mulsd   xmm2, xmm4
    movsd   xmm3, [r8 + rax + 24]       ; other.row
    mulsd   xmm3, xmm0
    addsd   xmm2, xmm3
    movsd   [r8 + rax], xmm1
    movsd   [r8 + rax + 8], xmm2
    inc     rcx
    jmp     .lerp
.next_level:
    dec     r9
    jmp     .level
.result:
    movsd   xmm0, [r8]
    movsd   xmm1, [r8 + 8]
    call    coord_from_floats
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret
.store_point:
    mov     r9, r8
.store_at:
    movsxd  rax, edi
    cvtsi2sd xmm1, rax
    movsd   [r9], xmm1
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm1, rax
    movsd   [r9 + 8], xmm1
    ret

; bezier_length(rdi=start, rsi=controls, rdx=control count, rcx=end) -> xmm0.
; find_length_of_bezier_curve: nine samples at t = 1/10 .. 9/10, summing the
; doubled-row line lengths; the final 0.9 -> 1.0 span is omitted, faithfully.
bezier_length:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12, rdi                    ; start
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    xorpd   xmm0, xmm0
    movsd   [rsp], xmm0                 ; length
    mov     rbp, r12                    ; previous coordinate
    mov     ebx, 1
.sample:
    cmp     ebx, 10
    jae     .done
    cvtsi2sd xmm0, rbx
    divsd   xmm0, [pg_ten]              ; t as f64 / 10.0
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    mov     rcx, r15
    call    bezier_coord
    mov     [rsp + 8], rax
    mov     rdi, rbp
    mov     rsi, rax
    mov     edx, 1
    call    line_length
    addsd   xmm0, [rsp]
    movsd   [rsp], xmm0
    mov     rbp, [rsp + 8]
    inc     ebx
    jmp     .sample
.done:
    movsd   xmm0, [rsp]
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
pg_one:     dq 1.0
pg_ten:     dq 10.0
