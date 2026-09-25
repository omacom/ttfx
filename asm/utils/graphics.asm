; utils/graphics.asm - Gradient generation, fraction lookup and coordinate
; mappings (src/utils/graphics.rs). Colors use the u64 format of ttfx.inc;
; generated colors are plain RGB, stops keep their xterm codes.
;
; Gradients are NOT float lerps: channel deltas use Python floor division and
; the exact end stop is appended per pair (plan.md §5.2).

section .text

; gradient_new(rdi=stops (u64 colors), esi=stop count, rdx=steps (i64),
;              ecx=step count, r8=spectrum out) -> eax = spectrum length.
; Gradient::new with do_loop = false. Step values reaching here are >= 1
; (the CLI validates them), so the per-pair error path cannot trigger.
gradient_new:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
    mov     r14, rdx
    mov     r15d, ecx
    mov     rbp, r8
    xor     ebx, ebx                    ; spectrum length
    cmp     r13d, 1
    jne     .pairs
    ; one stop: steps[0] copies of it
    mov     rcx, [r14]
    mov     rax, [r12]
.single:
    test    rcx, rcx
    jle     .done
    mov     [rbp + rbx * 8], rax
    inc     ebx
    dec     rcx
    jmp     .single
.pairs:
    xor     r9d, r9d                    ; pair index
.pair:
    lea     eax, [r13d - 1]
    cmp     r9d, eax
    jae     .done
    ; step count: steps[min(pair, count - 1)]
    lea     eax, [r15d - 1]
    cmp     r9d, eax
    cmovb   eax, r9d
    mov     r10, [r14 + rax * 8]        ; step_count
    mov     eax, [r12 + r9 * 8]         ; start (RGB bits)
    mov     r11, [r12 + r9 * 8 + 8]     ; end (the whole color)
    ; per-channel start and floor-divided delta, channels in xmm-free regs
    sub     rsp, 48
    xor     ecx, ecx
.channel:
    mov     edx, eax
    shl     ecx, 3
    shr     edx, cl
    shr     ecx, 3
    movzx   edx, dl                     ; start channel (shift 0, 8, 16)
    mov     [rsp + rcx * 8], rdx
    mov     rdi, r11
    and     edi, 0xffffff
    shl     ecx, 3
    shr     edi, cl
    shr     ecx, 3
    movzx   edi, dil
    sub     rdi, rdx                    ; end - start
    push    rax
    mov     rax, rdi
    cqo
    idiv    r10
    ; floor: adjust when the remainder is nonzero and signs differ
    test    rdx, rdx
    jz      .exact
    xor     rdx, r10
    jns     .exact
    dec     rax
.exact:
    mov     [rsp + 8 + 24 + rcx * 8], rax   ; +8 for the pushed rax
    pop     rax
    inc     ecx
    cmp     ecx, 3
    jb      .channel
    ; i from (spectrum non-empty ? 1 : 0) up to step_count - 1
    xor     esi, esi
    test    ebx, ebx
    setnz   sil
.step:
    cmp     rsi, r10
    jge     .pair_end
    xor     edi, edi                    ; color being built
    xor     ecx, ecx
.clamp:
    mov     rax, [rsp + 24 + rcx * 8]
    imul    rax, rsi
    add     rax, [rsp + rcx * 8]
    xor     edx, edx
    cmp     rax, 0
    cmovl   rax, rdx
    mov     edx, 255
    cmp     rax, rdx
    cmovg   rax, rdx
    shl     ecx, 3
    shl     eax, cl
    shr     ecx, 3
    or      edi, eax
    inc     ecx
    cmp     ecx, 3
    jb      .clamp
    mov     [rbp + rbx * 8], rdi
    inc     ebx
    inc     rsi
    jmp     .step
.pair_end:
    add     rsp, 48
    mov     [rbp + rbx * 8], r11        ; the exact end stop
    inc     ebx
    inc     r9d
    jmp     .pair
.done:
    mov     eax, ebx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; gradient_capacity(rdi=steps, rcx=step count, rsi=stop count) -> rax = an
; upper bound on the spectrum length of Gradient::new(stops, steps).
gradient_capacity:
    mov     rax, 1
    cmp     rsi, 1
    jbe     .single
    dec     rsi                         ; pairs
    xor     edx, edx
.pair:
    cmp     rdx, rsi
    jae     .done
    lea     r8, [rcx - 1]
    cmp     rdx, r8
    cmovb   r8, rdx
    mov     r8, [rdi + r8 * 8]
    lea     rax, [rax + r8 + 1]
    inc     rdx
    jmp     .pair
.single:
    add     rax, [rdi]
.done:
    ret

; gradient_at_fraction(rdi=spectrum, esi=length, xmm0=fraction) -> rax = color.
; The first i in 1..=len with fraction <= i/len picks spectrum[i-1] - the
; exact float boundaries of get_color_at_fraction.
gradient_at_fraction:
    mov     esi, esi
    cvtsi2sd xmm1, rsi                  ; len
    mov     ecx, 1
.scan:
    cmp     ecx, esi
    jae     .last
    cvtsi2sd xmm2, rcx
    divsd   xmm2, xmm1
    ucomisd xmm0, xmm2
    jbe     .found
    inc     ecx
    jmp     .scan
.found:
    mov     rax, [rdi + rcx * 8 - 8]
    ret
.last:
    mov     rax, [rdi + rsi * 8 - 8]
    ret

; gradient_map(rdi=spectrum, esi=length, rdx=min_row, rcx=max_row,
;              r8=min_column, r9=max_column, [rsp+8]=direction) -> rax =
; a dense map: map[(row - min_row) * width + (column - min_column)] = color.
; build_coordinate_color_mapping; direction in GradientDirection order
; (vertical, horizontal, radial, diagonal). Callers validate the bounds.
gradient_map:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     [rsp], rdi                  ; spectrum
    mov     [rsp + 8], rsi              ; length
    mov     [rsp + 16], rdx             ; min_row
    mov     [rsp + 24], rcx             ; max_row
    mov     [rsp + 32], r8              ; min_column
    mov     [rsp + 40], r9              ; max_column
    mov     rax, [rsp + 56 + 48 + 8]
    mov     [rsp + 48], rax             ; direction
    mov     rbp, r9
    sub     rbp, r8
    inc     rbp                         ; width
    mov     rax, rcx
    sub     rax, rdx
    inc     rax
    imul    rax, rbp
    lea     rdi, [rax * 8]
    call    alloc
    mov     r15, rax                    ; the map
    mov     r12, [rsp + 16]             ; row
.row:
    cmp     r12, [rsp + 24]
    jg      .done
    mov     r13, [rsp + 32]             ; column
.column:
    cmp     r13, [rsp + 40]
    jg      .next_row
    mov     rax, [rsp + 48]
    cmp     rax, 1
    je      .horizontal
    cmp     rax, 2
    je      .radial
    cmp     rax, 3
    je      .diagonal
    ; vertical: (row - row_offset) / (max_row - row_offset)
    mov     rax, [rsp + 16]
    dec     rax                         ; row_offset
    mov     rcx, r12
    sub     rcx, rax
    mov     rdx, [rsp + 24]
    sub     rdx, rax
    jmp     .ratio
.horizontal:
    mov     rax, [rsp + 32]
    dec     rax
    mov     rcx, r13
    sub     rcx, rax
    mov     rdx, [rsp + 40]
    sub     rdx, rax
    jmp     .ratio
.diagonal:
    ; ((row - ro) * 2 + (column - co)) / ((max_row - ro) * 2 + (max_column - co))
    mov     rax, [rsp + 16]
    dec     rax
    mov     rcx, r12
    sub     rcx, rax
    add     rcx, rcx
    mov     rdx, [rsp + 24]
    sub     rdx, rax
    add     rdx, rdx
    mov     rax, [rsp + 32]
    dec     rax
    mov     r8, r13
    sub     r8, rax
    add     rcx, r8
    mov     r8, [rsp + 40]
    sub     r8, rax
    add     rdx, r8
.ratio:
    cvtsi2sd xmm0, rcx
    cvtsi2sd xmm1, rdx
    divsd   xmm0, xmm1
    jmp     .color
.radial:
    mov     rdi, [rsp + 16]
    mov     rsi, [rsp + 24]
    mov     rdx, [rsp + 32]
    mov     rcx, [rsp + 40]
    mov     r8, r13
    mov     r9, r12
    call    normalized_distance_from_center
.color:
    mov     rdi, [rsp]
    mov     rsi, [rsp + 8]
    call    gradient_at_fraction
    mov     rcx, r12
    sub     rcx, [rsp + 16]
    imul    rcx, rbp
    add     rcx, r13
    sub     rcx, [rsp + 32]
    mov     [r15 + rcx * 8], rax
    inc     r13
    jmp     .column
.next_row:
    inc     r12
    jmp     .row
.done:
    mov     rax, r15
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
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
    mulsd   xmm2, [half]                ; center_x
    cvtsi2sd xmm3, rsi
    mulsd   xmm3, [half]                ; center_y  (n / 2.0 == n * 0.5 exactly)
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
    mulsd   xmm4, [half]
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
align 8
half:   dq 0.5
