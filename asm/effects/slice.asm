; effects/slice.asm - "Slices the input in half and slides it into place
; from opposite directions" (src/effects/slice.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Slice).
;
; The effect draws nothing from the RNG, and the active set and the
; renderer's painter order are both by slot, so characters are sent in
; Rust's order only for the auto path names' sake.

struc SLICE
    .direction:         resq 1          ; 0 vertical, 1 horizontal, 2 diagonal
    .speed:             resq 1          ; f64
    .ease:              resq 1          ; easing id
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define SL_VERTICAL     0
%define SL_HORIZONTAL   1

section .text

; slice_build: Slice::build.
slice_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    sl_final_colors
    movsd   xmm0, [rbx + SLICE.speed]
    movsd   [sl_speed], xmm0
    mov     eax, [rbx + SLICE.ease]
    mov     [sl_ease], eax
    mov     rax, [rbx + SLICE.direction]
    cmp     rax, SL_VERTICAL
    je      .vertical
    cmp     rax, SL_HORIZONTAL
    je      .horizontal
    ; diagonal: the first half of the diagonals from the bottom (origin
    ; column of the group's first character), the second half from the top
    ; (origin column of its last), interleaved
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_DIAG_BL_TO_TR
    call    get_characters_grouped
    mov     r12, rax                    ; groups
    mov     r13, rdx
    shr     r13, 1                      ; len(left) = n / 2
    mov     r15, rdx
    sub     r15, r13                    ; len(right)
    xor     r14d, r14d
.diag:
    cmp     r14, r13
    jae     .diag_right
    mov     rax, r14
    shl     rax, 4
    mov     rbp, [r12 + rax]            ; slots
    mov     rcx, [r12 + rax + 8]
    mov     eax, [rbp]
    mov     rdx, [ch_icol]
    mov     eax, [rdx + rax * 4]        ; column (row 0 = canvas.bottom - 1)
    mov     rdx, rax
    call    sl_send_group
.diag_right:
    cmp     r14, r15
    jae     .diag_next
    lea     rax, [r13 + r14]
    shl     rax, 4
    mov     rbp, [r12 + rax]
    mov     rcx, [r12 + rax + 8]
    mov     eax, [rbp + rcx * 4 - 4]
    mov     rdx, [ch_icol]
    mov     eax, [rdx + rax * 4]
    mov     rdx, [canvas_top]
    inc     rdx
    shl     rdx, 32
    or      rdx, rax
    call    sl_send_group
.diag_next:
    inc     r14
    cmp     r14, r15                    ; len(right) >= len(left)
    jb      .diag
    jmp     .done

.vertical:
    ; rows bottom to top: row i's left half from the top, the opposite
    ; row's right half from the bottom
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_ROW_BOTTOM_TO_TOP
    call    get_characters_grouped
    mov     r12, rax
    mov     r13, rdx
    xor     r14d, r14d
.row:
    cmp     r14, r13
    jae     .done
    mov     rax, r14
    shl     rax, 4
    mov     rbp, [r12 + rax]
    mov     r15, [r12 + rax + 8]
.left:
    test    r15, r15
    jz      .right_row
    mov     edi, [rbp]
    mov     rax, [ch_icol]
    movsxd  rsi, dword [rax + rdi * 4]
    cmp     rsi, [text_center_col]
    jg      .left_next
    mov     eax, esi
    mov     rsi, [canvas_top]
    inc     rsi
    shl     rsi, 32
    or      rsi, rax
    call    sl_send
.left_next:
    add     rbp, 4
    dec     r15
    jmp     .left
.right_row:
    mov     rax, r13
    sub     rax, r14
    dec     rax
    shl     rax, 4
    mov     rbp, [r12 + rax]
    mov     r15, [r12 + rax + 8]
.right:
    test    r15, r15
    jz      .row_next
    mov     edi, [rbp]
    mov     rax, [ch_icol]
    movsxd  rsi, dword [rax + rdi * 4]
    cmp     rsi, [text_center_col]
    jle     .right_next
    mov     esi, esi                    ; row 0 = canvas.bottom - 1
    call    sl_send
.right_next:
    add     rbp, 4
    dec     r15
    jmp     .right
.row_next:
    inc     r14
    jmp     .row

.horizontal:
    movsd   xmm0, [sl_speed]
    addsd   xmm0, xmm0                  ; movement_speed *= 2.0
    movsd   [sl_speed], xmm0
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, GROUP_COLUMN_R2L
    call    get_characters_grouped
    ; trim each column to the text rectangle in place; drop empty columns
    mov     r12, rax
    mov     r8, rdx                     ; groups in
    xor     r13d, r13d                  ; groups out
    xor     r9d, r9d
.trim:
    cmp     r9, r8
    jae     .trimmed
    mov     rax, r9
    shl     rax, 4
    mov     rsi, [r12 + rax]            ; slots
    mov     r10, [r12 + rax + 8]
    xor     r11d, r11d                  ; kept
    xor     ecx, ecx
.trim_char:
    cmp     rcx, r10
    jae     .trim_kept
    mov     edi, [rsi + rcx * 4]
    mov     rax, [ch_icol]
    movsxd  rax, dword [rax + rdi * 4]
    cmp     rax, [text_left]
    jl      .trim_skip
    cmp     rax, [text_right]
    jg      .trim_skip
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    cmp     rax, [text_bottom]
    jl      .trim_skip
    cmp     rax, [text_top]
    jg      .trim_skip
    mov     [rsi + r11 * 4], edi
    inc     r11
.trim_skip:
    inc     rcx
    jmp     .trim_char
.trim_kept:
    test    r11, r11
    jz      .trim_next
    mov     rax, r13
    shl     rax, 4
    mov     [r12 + rax], rsi
    mov     [r12 + rax + 8], r11
    inc     r13
.trim_next:
    inc     r9
    jmp     .trim
.trimmed:
    ; column i's bottom half from the left, the opposite column's top half
    ; from the right
    xor     r14d, r14d
.column:
    cmp     r14, r13
    jae     .done
    mov     rax, r14
    shl     rax, 4
    mov     rbp, [r12 + rax]
    mov     r15, [r12 + rax + 8]
.bottom:
    test    r15, r15
    jz      .top_column
    mov     edi, [rbp]
    mov     rax, [ch_irow]
    movsxd  rsi, dword [rax + rdi * 4]
    cmp     rsi, [text_center_row]
    jg      .bottom_next
    shl     rsi, 32                     ; column 0 = canvas.left - 1
    call    sl_send
.bottom_next:
    add     rbp, 4
    dec     r15
    jmp     .bottom
.top_column:
    mov     rax, r13
    sub     rax, r14
    dec     rax
    shl     rax, 4
    mov     rbp, [r12 + rax]
    mov     r15, [r12 + rax + 8]
.top:
    test    r15, r15
    jz      .column_next
    mov     edi, [rbp]
    mov     rax, [ch_irow]
    movsxd  rsi, dword [rax + rdi * 4]
    cmp     rsi, [text_center_row]
    jle     .top_next
    shl     rsi, 32
    mov     eax, [canvas_right]
    inc     eax
    or      rsi, rax
    call    sl_send
.top_next:
    add     rbp, 4
    dec     r15
    jmp     .top
.column_next:
    inc     r14
    jmp     .column

.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sl_send_group(rbp=u32 slots, rcx=count, rdx=origin): sl_send for each.
; Preserves rbx and r12-r15.
sl_send_group:
    push    r12
    push    r13
    push    r14
    mov     r12, rcx
    mov     r13, rdx
    mov     r14, rbp
.each:
    test    r12, r12
    jz      .out
    mov     edi, [r14]
    mov     rsi, r13
    call    sl_send
    add     r14, 4
    dec     r12
    jmp     .each
.out:
    pop     r14
    pop     r13
    pop     r12
    ret

; sl_send(edi=slot, rsi=origin): the send_to! macro - set the origin, a path
; to the input coordinate, activate it; then active_characters.extend and
; the closing set_character_visibility. Clobbers C.
sl_send:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    set_coordinate
    mov     edi, ebx
    movsd   xmm0, [sl_speed]
    mov     esi, [sl_ease]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r12d, eax
    mov     edi, ebx
    call    char_input_coord
    mov     edi, r12d
    mov     rsi, rax
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebx
    mov     esi, r12d
    call    path_activate
    mov     edi, ebx
    call    active_insert
    mov     edi, ebx
    call    set_visible
    pop     r13
    pop     r12
    pop     rbx
    ret

; sl_final_colors (rbx = config): the final gradient, its coordinate
; mapping over the text rectangle, and each input character's appearance
; (the mapped fg, or its input colors under dynamic handling).
sl_final_colors:
    push    r12
    push    r13
    push    r14
    mov     rdi, [rbx + SLICE.final_steps]
    mov     rcx, [rbx + SLICE.final_step_count]
    mov     rsi, [rbx + SLICE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + SLICE.final_stops]
    mov     rsi, [rbx + SLICE.final_stop_count]
    mov     rdx, [rbx + SLICE.final_steps]
    mov     rcx, [rbx + SLICE.final_step_count]
    mov     r8, r12
    call    gradient_new
    mov     rdi, r12
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [sl_map_width], rax
    sub     rsp, 8
    push    qword [rbx + SLICE.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     r12, rax                    ; map
    mov     r13, [input_count]
    xor     r14d, r14d
.char:
    cmp     r14, r13
    jae     .out
    mov     rax, [input_chars]
    mov     edi, [rax + r14 * 4]
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    sub     rax, [text_bottom]
    imul    rax, [sl_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rdi * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rdx, [r12 + rax * 8]
    mov     rcx, NONE
    jmp     .appear
.dynamic:
    mov     rdx, [ch_fg]
    mov     rdx, [rdx + rdi * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rdi * 8]
.appear:
    xor     esi, esi
    call    set_appearance
    inc     r14
    jmp     .char
.out:
    pop     r14
    pop     r13
    pop     r12
    ret

; slice_next_frame -> eax = 1 while characters are active, 0 when done.
slice_next_frame:
    sub     rsp, 8
    call    active_empty
    test    eax, eax
    jnz     .finished
    call    update
    mov     eax, 1
    add     rsp, 8
    ret
.finished:
    xor     eax, eax
    add     rsp, 8
    ret

section .tstate
alignb 8
sl_speed:               resq 1
sl_map_width:           resq 1
sl_ease:                resd 1
