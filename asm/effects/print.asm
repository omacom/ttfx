; effects/print.asm - "Lines are printed one at a time following a print head"
; (src/effects/print_effect.rs).
;
; Config (src/asm/effects.rs, the Print arm).
;
; Rows are the RowTopToBottom groups, trimmed in place as Row.__init__ and
; the carriage return trim them, so each group's slot array is the row: the
; first pr_pos slots of the current row are typed, the rest untyped, and
; every row before pr_cur is a processed row (fully typed). Print draws no
; random numbers.

struc PRINT
    .return_speed:      resq 1          ; f64 print_head_return_speed
    .print_speed:       resq 1
    .easing:            resq 1          ; print_head_easing id
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; path name
%define PR_CARRIAGE_RETURN  NAME_LITERAL + 0

%define PR_SPACE            0x100000020 ; " " packed
%define PR_WHITE            0xffffff

section .text

; print_build: PrintIterator.__init__ (the typing head) + Print::build.
print_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    ; the typing head at (1, 1), added before anything else
    mov     edi, 0x2588                 ; █
    call    utf8_pack
    mov     rdi, rax
    mov     rsi, (1 << 32) | 1
    call    add_character
    mov     [pr_head], eax
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [pr_dynamic], al
    ; the final gradient mapping (built before the dynamic check upstream;
    ; it draws nothing, so building it unconditionally is equivalent)
    call    pr_final_map
    ; the frame symbols: █ ▓ ▒ ░ and the character's own
    lea     rbx, [pr_block_codes]
    xor     r12d, r12d
.block:
    mov     edi, [rbx + r12 * 4]
    call    utf8_pack
    lea     rcx, [pr_symbols]
    mov     [rcx + r12 * 8], rax
    inc     r12d
    cmp     r12d, 4
    jb      .block
    ; one row per input row, top to bottom, fill characters included
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, GROUP_ROW_TOP_TO_BOTTOM
    call    get_characters_grouped
    mov     [pr_rows], rax
    mov     [pr_row_count], rdx
    test    rdx, rdx
    jz      .no_rows
    mov     r12, rax
    mov     r13, rdx
.row:
    mov     rdi, r12
    call    pr_make_row
    add     r12, 16
    dec     r13
    jnz     .row
    mov     qword [pr_cur], 0
    mov     qword [pr_pos], 0
    mov     byte [pr_typing], 1
    mov     qword [pr_last_column], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.no_rows:
    ; pending_rows.remove(0) on an empty list panics upstream
    lea     rdi, [pr_msg_no_rows]
    mov     esi, pr_msg_no_rows_len
    jmp     fatal

; pr_make_row(rdi=group record): PrintIterator.Row.__init__ - trims the
; group in place, then gives each kept character its typed scene.
pr_make_row:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     [rsp], rdi
    mov     r12, [rdi]                  ; slots
    mov     r13, [rdi + 8]              ; count
    ; a row of spaces keeps only its first character
    mov     rax, PR_SPACE
    mov     rcx, [ch_sym]
    xor     ebx, ebx
.space:
    cmp     rbx, r13
    jae     .all_spaces
    mov     edx, [r12 + rbx * 4]
    cmp     [rcx + rdx * 8], rax
    jne     .extent
    inc     rbx
    jmp     .space
.all_spaces:
    mov     r13d, 1
    jmp     .trimmed
.extent:
    ; right extent: the rightmost non-fill input column
    mov     rax, [ch_flags]
    mov     rcx, [ch_icol]
    mov     r8, 0x8000000000000000
    xor     ebx, ebx
.max:
    cmp     rbx, r13
    jae     .keep
    mov     edx, [r12 + rbx * 4]
    inc     rbx
    test    word [rax + rdx * 2], CF_FILL
    jnz     .max
    movsxd  r9, dword [rcx + rdx * 4]
    cmp     r9, r8
    cmovg   r8, r9
    jmp     .max
.keep:
    xor     ebx, ebx
    xor     r9d, r9d                    ; kept
.filter:
    cmp     rbx, r13
    jae     .filtered
    mov     edx, [r12 + rbx * 4]
    inc     rbx
    movsxd  r10, dword [rcx + rdx * 4]
    cmp     r10, r8
    jg      .filter
    mov     [r12 + r9 * 4], edx
    inc     r9
    jmp     .filter
.filtered:
    mov     r13, r9
.trimmed:
    mov     rax, [rsp]
    mov     [rax + 8], r13
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .done
    mov     r14d, [r12 + rbx * 4]
    inc     rbx
    ; moved to (input column, 1)
    mov     rsi, [ch_icol]
    mov     esi, [rsi + r14 * 4]
    mov     rax, 1 << 32
    or      rsi, rax
    mov     edi, r14d
    call    set_coordinate
    mov     edi, r14d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     rax, [ch_sym]
    mov     rax, [rax + r14 * 8]
    mov     [pr_symbols + 32], rax
    cmp     byte [pr_dynamic], 0
    jne     .dynamic
    ; white -> the final color in 5 steps over the five symbols; the frames
    ; depend on the input symbol and final color only, so later characters
    ; with the same pair copy the first one's scene (when neither scene
    ; applies preexisting colors)
    mov     edi, r14d
    call    pr_final_color
    mov     rbp, rax
    mov     ecx, r15d
    shl     rcx, SCENE_SHIFT
    add     rcx, [scenes]
    test    dword [rcx + SC_FLAGS], SCF_PREEXISTING | SCF_PRE_BOLD
    jnz     .head_gradient
    mov     rdi, [pr_symbols + 32]
    mov     rsi, rbp
    mov     rdx, NONE
    call    visual_run_find
    test    rax, rax
    jz      .head_template
    mov     eax, [rax]                  ; the template scene
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     edi, r15d
    mov     rsi, [rax + SC_FRAMES]
    mov     edx, [rax + SC_COUNT]
    call    scene_append_frames
    jmp     .activate
.head_template:
    push    rcx                         ; the empty memo entry
    push    rcx
    mov     edi, 8
    call    alloc
    mov     dword [rax], 1
    mov     [rax + 4], r15d
    lea     r8, [rax + 4]
    pop     rcx
    pop     rcx
    mov     rdi, [pr_symbols + 32]
    mov     rsi, rbp
    mov     rdx, NONE
    call    visual_run_keep
.head_gradient:
    lea     rdi, [pr_fg_spectrum]
    mov     rsi, rbp
    call    pr_head_gradient
    mov     r9d, eax
    lea     r8, [pr_fg_spectrum]
    push    0
    push    0
    mov     edi, r15d
    lea     rsi, [pr_symbols]
    mov     edx, 5
    mov     ecx, 3
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.dynamic:
    ; white -> each input color present; neither: a white head, then the
    ; symbol without colors
    xor     ebp, ebp                    ; fg count
    mov     rsi, [ch_fg]
    mov     rsi, [rsi + r14 * 8]
    cmp     rsi, NONE
    je      .dyn_bg
    lea     rdi, [pr_fg_spectrum]
    call    pr_head_gradient
    mov     ebp, eax
.dyn_bg:
    xor     eax, eax                    ; bg count
    mov     rsi, [ch_bg]
    mov     rsi, [rsi + r14 * 8]
    cmp     rsi, NONE
    je      .dyn_pair
    lea     rdi, [pr_bg_spectrum]
    call    pr_head_gradient
.dyn_pair:
    mov     ecx, ebp
    or      ecx, eax
    jz      .dyn_plain
    ; spectra (0 for an absent gradient) and counts
    xor     edx, edx
    lea     rcx, [pr_bg_spectrum]
    test    eax, eax
    cmovz   rcx, rdx
    xor     r8d, r8d
    lea     r9, [pr_fg_spectrum]
    test    ebp, ebp
    cmovnz  r8, r9
    mov     r9d, ebp
    push    rax
    push    rcx
    mov     edi, r15d
    lea     rsi, [pr_symbols]
    mov     edx, 5
    mov     ecx, 3
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.dyn_plain:
    lea     rdi, [pr_fg_spectrum]
    mov     qword [pr_pair_stops], PR_WHITE
    mov     qword [pr_pair_stops + 8], PR_WHITE
    mov     r8, rdi
    lea     rdi, [pr_pair_stops]
    mov     esi, 2
    lea     rdx, [pr_four_steps]
    mov     ecx, 1
    call    gradient_new
    mov     r9d, eax
    lea     r8, [pr_fg_spectrum]
    push    0
    push    0
    mov     edi, r15d
    lea     rsi, [pr_symbols]
    mov     edx, 4
    mov     ecx, 3
    call    scene_apply_gradient
    add     rsp, 16
    mov     edi, r15d
    mov     rsi, [pr_symbols + 32]
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.activate:
    mov     edi, r14d
    mov     esi, r15d
    call    scene_activate
    jmp     .char
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; pr_head_gradient(rdi=out spectrum, rsi=color) -> eax = length:
; Gradient::with_steps([white, color], 5).
pr_head_gradient:
    mov     r8, rdi
    mov     qword [pr_pair_stops], PR_WHITE
    mov     [pr_pair_stops + 8], rsi
    lea     rdi, [pr_pair_stops]
    mov     esi, 2
    lea     rdx, [pr_five_steps]
    mov     ecx, 1
    jmp     gradient_new

; pr_final_color(edi=slot) -> rax: the final gradient at the input
; coordinate, white outside the text rectangle (character_final_color_map).
pr_final_color:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rdi * 4]
    cmp     rax, [text_bottom]
    jl      .white
    cmp     rax, [text_top]
    jg      .white
    cmp     rcx, [text_left]
    jl      .white
    cmp     rcx, [text_right]
    jg      .white
    sub     rax, [text_bottom]
    imul    rax, [pr_final_map_width]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [pr_final_map_ptr]
    mov     rax, [rcx + rax * 8]
    ret
.white:
    mov     eax, PR_WHITE
    ret

; pr_final_map: Gradient::new(final stops, final steps) and its coordinate
; mapping over the text rectangle.
pr_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + PRINT.final_steps]
    mov     rcx, [rbx + PRINT.final_step_count]
    mov     rsi, [rbx + PRINT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [pr_final_spectrum], rax
    mov     rdi, [rbx + PRINT.final_stops]
    mov     rsi, [rbx + PRINT.final_stop_count]
    mov     rdx, [rbx + PRINT.final_steps]
    mov     rcx, [rbx + PRINT.final_step_count]
    mov     r8, [pr_final_spectrum]
    call    gradient_new
    mov     rdi, [pr_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [pr_final_map_width], rax
    push    qword [rbx + PRINT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [pr_final_map_ptr], rax
    pop     rbx
    ret

; pr_hide_head(edi=slot, rsi=payload): SET_INVISIBLE_CALLBACK.
pr_hide_head:
    xor     esi, esi
    jmp     set_visibility

; pr_all_fill(rdi=slots, rsi=count) -> eax = 1 when every one is a fill
; character (vacuously for none).
pr_all_fill:
    mov     rcx, [ch_flags]
    xor     edx, edx
.next:
    cmp     rdx, rsi
    jae     .yes
    mov     eax, [rdi + rdx * 4]
    inc     rdx
    test    word [rcx + rax * 2], CF_FILL
    jnz     .next
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

; print_next_frame -> eax = 1 for a frame, 0 when done.
print_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     byte [pr_typing], 0
    jne     .step
    call    active_empty
    test    eax, eax
    jnz     .finished
.step:
    ; the print head performing a carriage return
    mov     edi, [pr_head]
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    jne     .tick
    mov     rax, [pr_cur]
    shl     rax, 4
    add     rax, [pr_rows]
    mov     r12, [rax]                  ; slots
    mov     r13, [rax + 8]              ; count
    mov     rbx, [pr_pos]
    cmp     rbx, r13
    jae     .row_done
    ; type min(untyped, print_speed) characters
    mov     rbp, r13
    sub     rbp, rbx
    mov     rax, [effect_config]
    mov     rax, [rax + PRINT.print_speed]
    cmp     rax, rbp
    cmovl   rbp, rax
.type:
    test    rbp, rbp
    jle     .typed
    dec     rbp
    mov     r14d, [r12 + rbx * 4]
    inc     rbx
    mov     edi, r14d
    call    set_visible
    mov     edi, r14d
    call    active_insert
    mov     rax, [ch_icol]
    movsxd  rax, dword [rax + r14 * 4]
    mov     [pr_last_column], rax
    jmp     .type
.typed:
    mov     [pr_pos], rbx
    jmp     .tick
.row_done:
    mov     rax, [pr_cur]
    inc     rax
    cmp     rax, [pr_row_count]
    jae     .last_row
    mov     [pr_cur], rax
    mov     qword [pr_pos], 0
    ; move every processed row up one
    mov     r14, [pr_rows]
    mov     r15, rax
.up_row:
    mov     r12, [r14]
    mov     r13, [r14 + 8]
    xor     ebx, ebx
.up_char:
    cmp     rbx, r13
    jae     .up_next
    mov     edi, [r12 + rbx * 4]
    inc     rbx
    call    char_coord
    mov     rcx, 1 << 32
    lea     rsi, [rax + rcx]
    call    set_coordinate
    jmp     .up_char
.up_next:
    add     r14, 16
    dec     r15
    jnz     .up_row
    ; r14 = the new current row, r14 - 16 the last processed one
    mov     rdi, [r14 - 16]
    mov     rsi, [r14 - 8]
    call    pr_all_fill
    test    eax, eax
    jnz     .head
    mov     rdi, [r14]
    mov     rsi, [r14 + 8]
    call    pr_all_fill
    test    eax, eax
    jnz     .head
    ; keep left extent <= column <= text right
    mov     r12, [r14]
    mov     r13, [r14 + 8]
    mov     rax, [ch_flags]
    mov     rcx, [ch_icol]
    mov     r8, 0x7fffffffffffffff
    xor     ebx, ebx
.min:
    cmp     rbx, r13
    jae     .retain
    mov     edx, [r12 + rbx * 4]
    inc     rbx
    test    word [rax + rdx * 2], CF_FILL
    jnz     .min
    movsxd  r9, dword [rcx + rdx * 4]
    cmp     r9, r8
    cmovl   r8, r9
    jmp     .min
.retain:
    mov     r10, [text_right]
    xor     ebx, ebx
    xor     r9d, r9d
.retain_char:
    cmp     rbx, r13
    jae     .retained
    mov     edx, [r12 + rbx * 4]
    inc     rbx
    movsxd  r11, dword [rcx + rdx * 4]
    cmp     r11, r8
    jl      .retain_char
    cmp     r11, r10
    jg      .retain_char
    mov     [r12 + r9 * 4], edx
    inc     r9
    jmp     .retain_char
.retained:
    mov     [r14 + 8], r9
    test    r9, r9
    jz      .empty_row
.head:
    ; the head returns from the last typed column to the row's first
    mov     ebx, [pr_head]
    mov     esi, [pr_last_column]
    mov     rax, 1 << 32
    or      rsi, rax
    mov     edi, ebx
    call    set_coordinate
    mov     edi, ebx
    call    set_visible
    mov     rax, [r14]
    mov     eax, [rax]
    mov     rcx, [ch_icol]
    mov     r12d, [rcx + rax * 4]       ; target column
    mov     edi, ebx
    call    paths_clear
    mov     rax, [effect_config]
    movsd   xmm0, [rax + PRINT.return_speed]
    mov     esi, [rax + PRINT.easing]
    mov     edi, ebx
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, PR_CARRIAGE_RETURN
    call    path_new
    mov     r13d, eax
    mov     edi, eax
    mov     rsi, 1 << 32
    or      rsi, r12
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebx
    mov     esi, r13d
    call    path_activate
    ; later registrations are duplicates, suppressed upstream
    cmp     byte [pr_registered], 0
    jne     .registered
    mov     byte [pr_registered], 1
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, PR_CARRIAGE_RETURN
    mov     r8d, ACT_CALLBACK
    lea     r9, [pr_hide_head]
    call    event_register
    add     rsp, 16
.registered:
    mov     edi, ebx
    call    active_insert
    jmp     .tick
.last_row:
    mov     byte [pr_typing], 0
.tick:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.empty_row:
    ; current_row.untyped_chars[0] on an empty row panics upstream
    lea     rdi, [pr_msg_empty_row]
    mov     esi, pr_msg_empty_row_len
    jmp     fatal

section .rodata
align 8
pr_five_steps:      dq 5
pr_four_steps:      dq 4
; █ ▓ ▒ ░
pr_block_codes:     dd 0x2588, 0x2593, 0x2592, 0x2591
STR pr_msg_no_rows, "ttfx: asm engine: print: no rows", 10
STR pr_msg_empty_row, "ttfx: asm engine: print: empty row after trimming", 10

section .tstate
alignb 8
pr_head:            resq 1
pr_rows:            resq 1          ; (u32 slots, count) per row
pr_row_count:       resq 1
pr_cur:             resq 1
pr_pos:             resq 1
pr_last_column:     resq 1
pr_final_spectrum:  resq 1
pr_final_map_ptr:   resq 1
pr_final_map_width: resq 1
pr_symbols:         resq 5
pr_pair_stops:      resq 2
pr_fg_spectrum:     resq 16
pr_bg_spectrum:     resq 16
pr_typing:          resb 1
pr_dynamic:         resb 1
pr_registered:      resb 1
