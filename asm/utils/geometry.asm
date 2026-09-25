; utils/geometry.asm - Coord and geometry math (src/utils/geometry.rs).
;
; Coordinates are packed u64 values (ttfx.inc): the column as a signed i32
; in the low half, the row in the high half. Results are the low 32 bits of
; Rust's i64 values. Functions that return a list allocate it from the arena
; and return rax = pointer, rdx = count, in Rust's push order; an empty
; list is a zero-length allocation.
;
; Float lowering follows the compiled oracle, not the source: powf(x, 2.0)
; is x * x, powf(x, 0.5) is sqrtsd with LLVM's fabs and -inf fix-ups, the
; sin/cos pair is one sincos call, and lengths are glibc hypot. Every
; round() is round_half_even (pycompat.asm) and every `as i64` saturates.

; The streaming ellipse (coords_in_circle_init / _next) keeps its state in
; caller-provided memory of CIRCLE_ITER_size bytes.
struc CIRCLE_ITER
    .x:         resq 1                  ; next column to open
    .x_end:     resq 1
    .y:         resq 1                  ; next row in the open column
    .y_end:     resq 1
    .h:         resq 1                  ; center column
    .k:         resq 1                  ; center row
    .a_squared: resq 1
    .b_squared: resq 1
    .column:    resq 1                  ; the open column
endstruc

section .text

; find_coords_on_circle(rdi=origin, rsi=radius, rdx=coords_limit,
;                       ecx=unique) -> rax = list, rdx = count.
; coords_limit 0 means round(2 * pi * radius); the x offset from the origin
; is doubled for the cell aspect; every point is rounded half-even. With
; unique set, a point equal to an earlier one is skipped.
find_coords_on_circle:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    ; [rsp] origin column, [rsp+8] origin row, [rsp+16] radius (all f64),
    ; [rsp+24] angle_step, [rsp+32] sin, [rsp+40] cos, [rsp+48] rounded x,
    ; [rsp+56] coords_limit
    xor     r14d, r14d                  ; count
    test    rsi, rsi
    jz      .empty
    mov     r12, rdi
    mov     r13d, ecx
    mov     rbx, rdx
    cvtsi2sd xmm2, rsi
    movsd   [rsp + 16], xmm2
    test    rbx, rbx
    jnz     .limit
    movsd   xmm0, [geo_two_pi]
    mulsd   xmm0, xmm2
    call    round_half_even
    mov     rbx, rax
.limit:
    test    rbx, rbx
    jle     .empty
    mov     [rsp + 56], rbx
    cvtsi2sd xmm1, rbx
    movsd   xmm0, [geo_two_pi]
    divsd   xmm0, xmm1
    movsd   [rsp + 24], xmm0            ; angle_step
    movsxd  rax, r12d
    cvtsi2sd xmm0, rax
    movsd   [rsp], xmm0
    mov     rax, r12
    sar     rax, 32
    cvtsi2sd xmm0, rax
    movsd   [rsp + 8], xmm0
    lea     rdi, [rbx * 8]
    call    alloc
    mov     r15, rax                    ; the list
    xor     ebp, ebp                    ; the seen set, only when unique
    test    r13d, r13d
    jz      .points
    mov     rdi, rbx
    call    coordset_new
    mov     rbp, rax
.points:
    xor     r13d, r13d                  ; i
.point:
    cmp     r13, [rsp + 56]
    jge     .done
    cvtsi2sd xmm0, r13
    mulsd   xmm0, [rsp + 24]            ; angle
    lea     rdi, [rsp + 32]
    lea     rsi, [rsp + 40]
    CCALL   sincos
    ; x = origin.column + radius * cos; x += x - origin.column
    movsd   xmm0, [rsp + 40]
    mulsd   xmm0, [rsp + 16]
    addsd   xmm0, [rsp]
    movapd  xmm1, xmm0
    subsd   xmm1, [rsp]
    addsd   xmm0, xmm1
    call    round_half_even
    mov     [rsp + 48], rax
    ; y = origin.row + radius * sin
    movsd   xmm0, [rsp + 32]
    mulsd   xmm0, [rsp + 16]
    addsd   xmm0, [rsp + 8]
    call    round_half_even
    mov     ecx, [rsp + 48]
    shl     rax, 32
    or      rax, rcx
    mov     r12, rax                    ; the point
    test    rbp, rbp
    jz      .push
    mov     rdi, rbp
    mov     rsi, r12
    call    coordset_insert
    test    eax, eax
    jz      .next
.push:
    mov     [r15 + r14 * 8], r12
    inc     r14
.next:
    inc     r13
    jmp     .point
.empty:
    xor     edi, edi
    call    alloc
    mov     r15, rax
.done:
    mov     rax, r15
    mov     rdx, r14
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; coordset_new(rdi=at most this many keys) -> rax = an open-addressing set
; of packed coordinates: a mask, then 16-byte (key, occupied) entries at
; +16. Capacity is at least twice the key count, so probing terminates.
coordset_new:
    push    rbx
    lea     rax, [rdi * 2]
    cmp     rax, 16
    jae     .size
    mov     eax, 16
.size:
    dec     rax
    lzcnt   rcx, rax
    mov     eax, 64
    sub     eax, ecx
    mov     ecx, eax
    mov     ebx, 1
    shl     rbx, cl                     ; capacity: the next power of two
    lea     rdi, [rbx * 8]
    lea     rdi, [rdi * 2 + 16]
    call    alloc
    dec     rbx
    mov     [rax], rbx                  ; mask
    pop     rbx
    ret

; coordset_insert(rdi=set, rsi=key) -> eax = 1 when the key was not there.
; Clobbers rcx, rdx, r8.
coordset_insert:
    mov     rax, rsi
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    lzcnt   rcx, qword [rdi]
    shrx    rax, rax, rcx               ; the top bits index the table
    mov     rdx, [rdi]
.probe:
    lea     r8, [rax * 2]
    cmp     qword [rdi + r8 * 8 + 24], 0
    je      .insert
    cmp     [rdi + r8 * 8 + 16], rsi
    je      .found
    inc     rax
    and     rax, rdx
    jmp     .probe
.insert:
    mov     [rdi + r8 * 8 + 16], rsi
    mov     qword [rdi + r8 * 8 + 24], 1
    mov     eax, 1
    ret
.found:
    xor     eax, eax
    ret

; coords_in_circle_init(rdi=state, rsi=center, rdx=diameter): start the
; streaming ellipse of geometry::coords_in_circle (a = diameter,
; b = diameter / 2). A zero diameter streams nothing.
coords_in_circle_init:
    movsxd  rax, esi
    mov     [rdi + CIRCLE_ITER.h], rax
    mov     rcx, rsi
    sar     rcx, 32
    mov     [rdi + CIRCLE_ITER.k], rcx
    mov     qword [rdi + CIRCLE_ITER.y], 0
    mov     qword [rdi + CIRCLE_ITER.y_end], -1
    test    rdx, rdx
    jz      .none
    mov     rcx, rax
    sub     rcx, rdx
    mov     [rdi + CIRCLE_ITER.x], rcx
    add     rax, rdx
    mov     [rdi + CIRCLE_ITER.x_end], rax
    cvtsi2sd xmm0, rdx
    movapd  xmm1, xmm0
    mulsd   xmm0, xmm0                  ; diameter.powf(2.0)
    movsd   [rdi + CIRCLE_ITER.a_squared], xmm0
    mulsd   xmm1, [geo_half]
    mulsd   xmm1, xmm1                  ; (diameter / 2.0).powf(2.0)
    movsd   [rdi + CIRCLE_ITER.b_squared], xmm1
    ret
.none:
    mov     qword [rdi + CIRCLE_ITER.x], 1
    mov     qword [rdi + CIRCLE_ITER.x_end], 0
    ret

; coords_in_circle_next(rdi=state) -> rax = the next coordinate, edx = 1;
; edx = 0 when the ellipse is exhausted. Column-major, rows ascending.
; Clobbers rcx, rsi, rdi, xmm0-xmm3.
coords_in_circle_next:
    push    rbx
    mov     rbx, rdi
.again:
    mov     rax, [rbx + CIRCLE_ITER.y]
    cmp     rax, [rbx + CIRCLE_ITER.y_end]
    jg      .column
    lea     rcx, [rax + 1]
    mov     [rbx + CIRCLE_ITER.y], rcx
    mov     ecx, [rbx + CIRCLE_ITER.column]
    shl     rax, 32
    or      rax, rcx
    mov     edx, 1
    pop     rbx
    ret
.column:
    mov     rdi, [rbx + CIRCLE_ITER.x]
    cmp     rdi, [rbx + CIRCLE_ITER.x_end]
    jg      .end
    lea     rax, [rdi + 1]
    mov     [rbx + CIRCLE_ITER.x], rax
    mov     [rbx + CIRCLE_ITER.column], rdi
    mov     rsi, [rbx + CIRCLE_ITER.h]
    mov     rdx, [rbx + CIRCLE_ITER.k]
    movsd   xmm2, [rbx + CIRCLE_ITER.a_squared]
    movsd   xmm3, [rbx + CIRCLE_ITER.b_squared]
    call    circle_column_range
    mov     [rbx + CIRCLE_ITER.y], rax
    mov     [rbx + CIRCLE_ITER.y_end], rdx
    jmp     .again
.end:
    xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret

; circle_column_range(rdi=x, rsi=h, rdx=k, xmm2=a_squared, xmm3=b_squared)
; -> rax = first row, rdx = last row (inclusive; empty when rax > rdx).
; circle_column_y_range: the y offset is (b^2 * (1 - (x - h)^2 / a^2)) ^ 0.5
; truncated. The oracle lowered that powf to sqrt, plus fabs (so -0 gives
; +0) and +inf for a -inf argument, before the saturating cast.
; Clobbers rcx, rdi, xmm0, xmm1.
circle_column_range:
    sub     rdi, rsi
    cvtsi2sd xmm0, rdi
    mulsd   xmm0, xmm0
    divsd   xmm0, xmm2                  ; x_component
    movsd   xmm1, [geo_one]
    subsd   xmm1, xmm0
    mulsd   xmm1, xmm3                  ; the powf argument
    sqrtsd  xmm0, xmm1
    andpd   xmm0, [geo_abs_mask]
    call    f64_to_i64
    ucomisd xmm1, [geo_neg_inf]
    jne     .offset
    jp      .offset
    mov     rax, 0x7fffffffffffffff     ; (-inf).powf(0.5) is +inf
.offset:
    mov     rcx, rax
    mov     rax, rdx
    sub     rax, rcx                    ; k - max_y_offset
    add     rdx, rcx                    ; k + max_y_offset
    ret

; find_coords_in_circle(rdi=center, rsi=diameter) -> rax = list, rdx = count.
; The streamed ellipse as a list: one pass to count, one to fill.
find_coords_in_circle:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, CIRCLE_ITER_size + 8
    mov     r12, rdi
    mov     r13, rsi
    mov     rdi, rsp
    mov     rdx, rsi
    mov     rsi, r12
    call    coords_in_circle_init
    xor     ebx, ebx
.count:
    mov     rdi, rsp
    call    coords_in_circle_next
    test    edx, edx
    jz      .counted
    inc     rbx
    jmp     .count
.counted:
    lea     rdi, [rbx * 8]
    call    alloc
    mov     r14, rax
    mov     rdi, rsp
    mov     rsi, r12
    mov     rdx, r13
    call    coords_in_circle_init
    xor     ebx, ebx
.fill:
    mov     rdi, rsp
    call    coords_in_circle_next
    test    edx, edx
    jz      .done
    mov     [r14 + rbx * 8], rax
    inc     rbx
    jmp     .fill
.done:
    mov     rax, r14
    mov     rdx, rbx
    add     rsp, CIRCLE_ITER_size + 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; find_coords_in_rect(rdi=origin, rsi=distance) -> rax = list, rdx = count.
; The full (2d + 1)^2 block, column-major; empty for distance <= 0.
find_coords_in_rect:
    push    rbx
    push    r12
    push    r13
    push    r14
    test    rsi, rsi
    jle     .empty
    movsxd  r12, edi                    ; column
    mov     r13, rdi
    sar     r13, 32                     ; row
    mov     r14, rsi
    lea     rax, [rsi * 2 + 1]
    mov     rdi, rax
    imul    rdi, rax
    shl     rdi, 3
    call    alloc
    mov     rbx, rax
    xor     r8d, r8d                    ; count
    mov     rcx, r12
    sub     rcx, r14                    ; column
    mov     r9, r12
    add     r9, r14                     ; last column
    mov     r10, r13
    add     r10, r14                    ; last row
.column:
    cmp     rcx, r9
    jg      .done
    mov     rdx, r13
    sub     rdx, r14                    ; row
.row:
    cmp     rdx, r10
    jg      .next
    mov     eax, ecx
    mov     rsi, rdx
    shl     rsi, 32
    or      rax, rsi
    mov     [rbx + r8 * 8], rax
    inc     r8
    inc     rdx
    jmp     .row
.next:
    inc     rcx
    jmp     .column
.empty:
    xor     edi, edi
    call    alloc
    mov     rbx, rax
    xor     r8d, r8d
.done:
    mov     rax, rbx
    mov     rdx, r8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; find_coords_on_rect(rdi=origin, rsi=half_width, rdx=half_height)
; -> rax = list, rdx = count. The perimeter: the first and last columns in
; full, two rows for every column between; empty when either half is 0.
; A negative half_width has no columns; a negative half_height keeps the
; middle columns' two rows and empties the edge columns, as Rust's ranges do.
find_coords_on_rect:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    test    rsi, rsi
    jz      .empty
    test    rdx, rdx
    jz      .empty
    test    rsi, rsi
    js      .empty
    movsxd  r12, edi                    ; column
    mov     r13, rdi
    sar     r13, 32                     ; row
    mov     r14, rsi
    mov     r15, rdx
    ; capacity: 2 * edge column rows + 2 * (2 * half_width - 1)
    lea     rax, [r15 * 2 + 1]
    xor     ecx, ecx
    test    r15, r15
    cmovs   rax, rcx
    lea     rdi, [r14 * 2 - 1]
    add     rdi, rax
    shl     rdi, 4
    call    alloc
    mov     rbx, rax
    xor     r8d, r8d                    ; count
    mov     rsi, r12
    sub     rsi, r14                    ; first column
    mov     rcx, rsi                    ; column
    mov     r9, r12
    add     r9, r14                     ; last column
    mov     r10, r13
    sub     r10, r15                    ; first row
    mov     r11, r13
    add     r11, r15                    ; last row
.column:
    cmp     rcx, r9
    jg      .done
    cmp     rcx, rsi
    je      .full
    cmp     rcx, r9
    je      .full
    mov     eax, ecx
    mov     rdx, r10
    shl     rdx, 32
    or      rax, rdx
    mov     [rbx + r8 * 8], rax
    inc     r8
    mov     eax, ecx
    mov     rdx, r11
    shl     rdx, 32
    or      rax, rdx
    mov     [rbx + r8 * 8], rax
    inc     r8
    jmp     .next
.full:
    mov     rdx, r10
.row:
    cmp     rdx, r11
    jg      .next
    mov     eax, ecx
    mov     rdi, rdx
    shl     rdi, 32
    or      rax, rdi
    mov     [rbx + r8 * 8], rax
    inc     r8
    inc     rdx
    jmp     .row
.next:
    inc     rcx
    jmp     .column
.empty:
    xor     edi, edi
    call    alloc
    mov     rbx, rax
    xor     r8d, r8d
.done:
    mov     rax, rbx
    mov     rdx, r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; find_length_of_line(rdi=coord1, rsi=coord2, edx=double_row_diff) -> xmm0.
; glibc hypot of the deltas, the row delta doubled when asked (as an
; addition, which is what the oracle emits for 2.0 * x).
; Clobbers everything a C call does.
find_length_of_line:
    movsxd  rax, esi
    movsxd  rcx, edi
    sub     rax, rcx
    cvtsi2sd xmm0, rax
    mov     rax, rsi
    sar     rax, 32
    mov     rcx, rdi
    sar     rcx, 32
    sub     rax, rcx
    cvtsi2sd xmm1, rax
    test    edx, edx
    jz      .hypot
    addsd   xmm1, xmm1
.hypot:
    CCALL   hypot
    ret

; extrapolate_along_ray(rdi=origin, rsi=target, xmm0=offset_from_target)
; -> rax = coord. Lerp past the target by offset along the (non-doubled)
; line, rounded; the target itself when the total distance is 0 or the
; points coincide.
extrapolate_along_ray:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    movsd   [rsp], xmm0
    xor     edx, edx
    call    find_length_of_line
    movsd   [rsp + 8], xmm0             ; base
    movsd   xmm1, [rsp]
    addsd   xmm1, xmm0                  ; total_distance
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    jne     .extrapolate
    jp      .extrapolate
    jmp     .target
.extrapolate:
    cmp     rbx, r12
    je      .target
    divsd   xmm1, [rsp + 8]             ; t
    movsd   xmm2, [geo_one]
    subsd   xmm2, xmm1                  ; 1 - t
    movsxd  rax, ebx
    cvtsi2sd xmm3, rax
    mulsd   xmm3, xmm2
    movsxd  rax, r12d
    cvtsi2sd xmm0, rax
    mulsd   xmm0, xmm1
    addsd   xmm0, xmm3
    call    round_half_even
    mov     [rsp + 16], rax
    mov     rax, rbx
    sar     rax, 32
    cvtsi2sd xmm3, rax
    mulsd   xmm3, xmm2
    mov     rax, r12
    sar     rax, 32
    cvtsi2sd xmm0, rax
    mulsd   xmm0, xmm1
    addsd   xmm0, xmm3
    call    round_half_even
    shl     rax, 32
    mov     ecx, [rsp + 16]
    or      rax, rcx
    jmp     .done
.target:
    mov     rax, r12
.done:
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

; find_coord_on_line(rdi=start, rsi=end, xmm0=t) -> rax = coord:
; (1 - t) * start + t * end per axis, rounded half-even.
find_coord_on_line:
    push    rbx
    movapd  xmm2, xmm0                  ; t
    movsd   xmm1, [geo_one]
    subsd   xmm1, xmm0                  ; 1 - t
    movsxd  rax, edi
    cvtsi2sd xmm3, rax
    mulsd   xmm3, xmm1
    movsxd  rax, esi
    cvtsi2sd xmm0, rax
    mulsd   xmm0, xmm2
    addsd   xmm0, xmm3
    call    round_half_even
    mov     ebx, eax
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm3, rax
    mulsd   xmm3, xmm1
    mov     rax, rsi
    sar     rax, 32
    cvtsi2sd xmm0, rax
    mulsd   xmm0, xmm2
    addsd   xmm0, xmm3
    call    round_half_even
    shl     rax, 32
    or      rax, rbx
    pop     rbx
    ret

; find_coord_on_bezier_curve(rdi=start, rsi=control points, rdx=control
; count, rcx=end, xmm0=t) -> rax = coord. De Casteljau with float
; intermediates, rounded once at the end. No control points is the line;
; one (every production path) stays in registers; more use the stack.
find_coord_on_bezier_curve:
    test    rdx, rdx
    jnz     .curve
    mov     rsi, rcx
    jmp     find_coord_on_line
.curve:
    push    rbx
    push    rbp
    push    r12
    movapd  xmm4, xmm0                  ; t
    movsd   xmm5, [geo_one]
    subsd   xmm5, xmm0                  ; 1 - t
    cmp     rdx, 1
    jne     .general
    movsxd  rax, edi
    cvtsi2sd xmm6, rax                  ; start column
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm7, rax                  ; start row
    mov     rax, [rsi]
    movsxd  rdx, eax
    cvtsi2sd xmm8, rdx                  ; control column
    sar     rax, 32
    cvtsi2sd xmm9, rax                  ; control row
    movsxd  rax, ecx
    cvtsi2sd xmm10, rax                 ; end column
    mov     rax, rcx
    sar     rax, 32
    cvtsi2sd xmm11, rax                 ; end row
    ; start.interpolate(control, t)
    movapd  xmm12, xmm5
    mulsd   xmm12, xmm6
    movapd  xmm0, xmm4
    mulsd   xmm0, xmm8
    addsd   xmm12, xmm0
    movapd  xmm13, xmm5
    mulsd   xmm13, xmm7
    movapd  xmm0, xmm4
    mulsd   xmm0, xmm9
    addsd   xmm13, xmm0
    ; control.interpolate(end, t)
    movapd  xmm14, xmm5
    mulsd   xmm14, xmm8
    movapd  xmm0, xmm4
    mulsd   xmm0, xmm10
    addsd   xmm14, xmm0
    movapd  xmm15, xmm5
    mulsd   xmm15, xmm9
    movapd  xmm0, xmm4
    mulsd   xmm0, xmm11
    addsd   xmm15, xmm0
    ; the point between them
    movapd  xmm0, xmm5
    mulsd   xmm0, xmm12
    movapd  xmm1, xmm4
    mulsd   xmm1, xmm14
    addsd   xmm0, xmm1
    movapd  xmm1, xmm5
    mulsd   xmm1, xmm13
    movapd  xmm2, xmm4
    mulsd   xmm2, xmm15
    addsd   xmm1, xmm2
    jmp     .round
.general:
    ; points[0..n+2] as (column, row) f64 pairs on the stack
    mov     rbp, rsp
    lea     rax, [rdx + 2]
    shl     rax, 4
    sub     rsp, rax
    and     rsp, -16
    mov     r12, rdx                    ; remaining - 2
    movsxd  rax, edi
    cvtsi2sd xmm0, rax
    movsd   [rsp], xmm0
    mov     rax, rdi
    sar     rax, 32
    cvtsi2sd xmm0, rax
    movsd   [rsp + 8], xmm0
    xor     ebx, ebx
    lea     r8, [rsp + 16]              ; points[1..]
.load:
    mov     rax, [rsi + rbx * 8]
    movsxd  rdx, eax
    cvtsi2sd xmm0, rdx
    movsd   [r8], xmm0
    sar     rax, 32
    cvtsi2sd xmm0, rax
    movsd   [r8 + 8], xmm0
    add     r8, 16
    inc     rbx
    cmp     rbx, r12
    jb      .load
    movsxd  rax, ecx
    cvtsi2sd xmm0, rax
    movsd   [r8], xmm0
    mov     rax, rcx
    sar     rax, 32
    cvtsi2sd xmm0, rax
    movsd   [r8 + 8], xmm0
    add     r12, 2                      ; remaining
.level:
    cmp     r12, 1
    jbe     .collapsed
    xor     ebx, ebx
    mov     rdx, rsp
.pair:
    lea     rax, [rbx + 1]
    cmp     rax, r12
    jae     .next_level
    ; points[i] = points[i].interpolate(points[i + 1], t)
    movsd   xmm0, [rdx]
    mulsd   xmm0, xmm5
    movsd   xmm1, [rdx + 16]
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1
    movsd   [rdx], xmm0
    movsd   xmm0, [rdx + 8]
    mulsd   xmm0, xmm5
    movsd   xmm1, [rdx + 24]
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1
    movsd   [rdx + 8], xmm0
    add     rdx, 16
    inc     rbx
    jmp     .pair
.next_level:
    dec     r12
    jmp     .level
.collapsed:
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp + 8]
    mov     rsp, rbp
.round:
    call    round_half_even
    mov     ebx, eax
    movapd  xmm0, xmm1
    call    round_half_even
    shl     rax, 32
    or      rax, rbx
    pop     r12
    pop     rbp
    pop     rbx
    ret

; find_length_of_bezier_curve(rdi=start, rsi=control points, rdx=control
; count, rcx=end) -> xmm0. The 10-sample polyline that stops at t = 0.9:
; the final span is omitted, faithfully (plan.md §5.4). Segment lengths use
; the doubled row delta.
find_length_of_bezier_curve:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15, rdi                    ; prev_coord
    xorpd   xmm0, xmm0
    movsd   [rsp], xmm0                 ; length
    mov     ebp, 1
.segment:
    cvtsi2sd xmm0, rbp
    divsd   xmm0, [geo_ten]             ; t
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rcx, r14
    call    find_coord_on_bezier_curve
    mov     rdi, r15
    mov     rsi, rax
    mov     r15, rax
    mov     edx, 1
    call    find_length_of_line
    addsd   xmm0, [rsp]
    movsd   [rsp], xmm0
    inc     ebp
    cmp     ebp, 10
    jb      .segment
    movsd   xmm0, [rsp]
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; find_normalized_distance_from_center(rdi=bottom, rsi=top, rdx=left,
;   rcx=right, r8=coord) -> eax = 1 and xmm0 = the distance in [0, 1], or
; eax = 0 when the coordinate is outside the rectangle (Rust's Err; the
; message is msg_not_in_rectangle). The math is graphics.asm's
; normalized_distance_from_center. Clobbers rcx, rdx, rsi, rdi, r8-r10, xmm0-xmm4.
find_normalized_distance_from_center:
    ; column - x_offset in 1..=right - x_offset, row likewise
    lea     r9, [rdx - 1]
    movsxd  rax, r8d
    sub     rax, r9
    mov     r10, rcx
    sub     r10, r9
    cmp     rax, 1
    jl      .outside
    cmp     rax, r10
    jg      .outside
    lea     r9, [rdi - 1]
    mov     rax, r8
    sar     rax, 32
    sub     rax, r9
    mov     r10, rsi
    sub     r10, r9
    cmp     rax, 1
    jl      .outside
    cmp     rax, r10
    jg      .outside
    mov     r9, r8
    sar     r9, 32
    movsxd  r8, r8d
    call    normalized_distance_from_center
    mov     eax, 1
    ret
.outside:
    xor     eax, eax
    ret

; normalized_distance_from_center(rdi=bottom, rsi=top, rdx=left, rcx=right,
;   r8=column, r9=row) -> xmm0. geometry::find_normalized_distance_from_center
; for a coordinate known to lie inside the rectangle. The oracle's compiler
; lowered powf(x, 2.0) to x * x and powf(x, 0.5) to sqrt; so does this.
normalized_distance_from_center:
    lea     rax, [rdi - 1]              ; y_offset
    lea     r10, [rdx - 1]              ; x_offset
    sub     rcx, r10                    ; right
    sub     rsi, rax                    ; top
    cvtsi2sd xmm2, rcx
    mulsd   xmm2, [geo_half]                ; center_x
    cvtsi2sd xmm3, rsi
    mulsd   xmm3, [geo_half]                ; center_y  (n / 2.0 == n * 0.5 exactly)
    sub     r8, r10                     ; column
    sub     r9, rax                     ; row
    ; max_distance = sqrt(right^2 + (top * 2)^2)
    cvtsi2sd xmm0, rcx
    mulsd   xmm0, xmm0
    lea     rax, [rsi * 2]
    cvtsi2sd xmm1, rax
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm4, xmm0
    ; distance = sqrt((column - cx)^2 + ((row - cy) * 2)^2)
    cvtsi2sd xmm0, r8
    subsd   xmm0, xmm2
    mulsd   xmm0, xmm0
    cvtsi2sd xmm1, r9
    subsd   xmm1, xmm3
    addsd   xmm1, xmm1
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    ; distance / (max_distance / 2.0)
    mulsd   xmm4, [geo_half]
    divsd   xmm0, xmm4
    ret

; utf8_pack(edi=codepoint) -> rax = packed symbol (bytes | length << 32).
utf8_pack:
    cmp     edi, 0x80
    jb      .one
    cmp     edi, 0x800
    jb      .two
    cmp     edi, 0x10000
    jb      .three
    mov     eax, edi
    shr     eax, 18
    or      eax, 0xF0
    mov     ecx, edi
    shr     ecx, 12
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 8
    or      eax, ecx
    mov     ecx, edi
    shr     ecx, 6
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 16
    or      eax, ecx
    mov     ecx, edi
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 24
    or      eax, ecx
    mov     rcx, 4 << 32
    or      rax, rcx
    ret
.three:
    mov     eax, edi
    shr     eax, 12
    or      eax, 0xE0
    mov     ecx, edi
    shr     ecx, 6
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 8
    or      eax, ecx
    mov     ecx, edi
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 16
    or      eax, ecx
    mov     rcx, 3 << 32
    or      rax, rcx
    ret
.two:
    mov     eax, edi
    shr     eax, 6
    or      eax, 0xC0
    mov     ecx, edi
    and     ecx, 0x3F
    or      ecx, 0x80
    shl     ecx, 8
    or      eax, ecx
    mov     rcx, 2 << 32
    or      rax, rcx
    ret
.one:
    mov     eax, edi
    mov     rcx, 1 << 32
    or      rax, rcx
    ret

section .rodata
align 16
geo_abs_mask:   dq 0x7fffffffffffffff, 0x7fffffffffffffff
geo_two_pi:     dq 0x401921fb54442d18   ; 2.0 * PI, as the oracle folded it
geo_one:        dq 1.0
geo_half:       dq 0.5
geo_ten:        dq 10.0
geo_neg_inf:    dq 0xfff0000000000000
STR msg_not_in_rectangle, "Coordinate is not within the rectangle."
