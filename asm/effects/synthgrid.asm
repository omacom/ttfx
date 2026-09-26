; effects/synthgrid.asm - "Create a grid which fills with characters
; dissolving into the final text" (src/effects/synthgrid.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Synthgrid):
;
; Grid lines are consecutive added slots, so a line is (first slot, count)
; plus how many of its characters are extended. Extension reveals from the
; front; Rust's collapse reverses the fully extended list once and then
; hides from its front, which is hiding from the back of the line, so the
; extended characters are always a prefix [first, first + ext).
;
; Groups (blocks) keep their members in one flat array in group-number
; order. pending_groups is a shuffled array of group numbers consumed from
; the front; the group tracker is an i64 per group number.

struc SYNTHGRID
    .grid_stops:        resq 1          ; *const u64
    .grid_stop_count:   resq 1
    .grid_steps:        resq 1          ; *const i64
    .grid_step_count:   resq 1
    .grid_direction:    resq 1
    .text_stops:        resq 1          ; *const u64
    .text_stop_count:   resq 1
    .text_steps:        resq 1          ; *const i64
    .text_step_count:   resq 1
    .text_direction:    resq 1
    .row_symbol:        resq 1          ; packed symbol
    .column_symbol:     resq 1          ; packed symbol
    .gen_symbols:       resq 1          ; *const u64 packed symbols
    .gen_symbol_count:  resq 1
    .max_active_blocks: resq 1          ; f64
endstruc

; grid line record
%define SG_LN_FIRST        0               ; u32 first slot
%define SG_LN_COUNT        4               ; u32 characters
%define SG_LN_EXT          8               ; u32 extended prefix length
%define SG_LN_STEP         12              ; u32 characters per extend/collapse
%define SG_LINE_SIZE       16

%define SG_PH_GRID_EXPAND  0
%define SG_PH_ADD_CHARS    1
%define SG_PH_COLLAPSE     2
%define SG_PH_COMPLETE     3

section .text

; synthgrid_build: SynthGrid::build.
synthgrid_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     rbx, [effect_config]
    ; --- the grid gradient, mapped over the whole canvas
    mov     rdi, [rbx + SYNTHGRID.grid_steps]
    mov     rcx, [rbx + SYNTHGRID.grid_step_count]
    mov     rsi, [rbx + SYNTHGRID.grid_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + SYNTHGRID.grid_stops]
    mov     rsi, [rbx + SYNTHGRID.grid_stop_count]
    mov     rdx, [rbx + SYNTHGRID.grid_steps]
    mov     rcx, [rbx + SYNTHGRID.grid_step_count]
    mov     r8, r12
    call    gradient_new
    cmp     qword [canvas_top], 1
    jl      .bad_max
    cmp     qword [canvas_right], 1
    jl      .bad_max
    mov     rdi, r12
    mov     esi, eax
    mov     edx, 1
    mov     rcx, [canvas_top]
    mov     r8d, 1
    mov     r9, [canvas_right]
    push    qword [rbx + SYNTHGRID.grid_direction]
    call    gradient_map
    add     rsp, 8
    mov     [sg_grid_map], rax
    ; --- the text gradient (its spectrum feeds the dissolve colors)
    mov     rdi, [rbx + SYNTHGRID.text_steps]
    mov     rcx, [rbx + SYNTHGRID.text_step_count]
    mov     rsi, [rbx + SYNTHGRID.text_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [sg_text_spectrum], rax
    mov     rdi, [rbx + SYNTHGRID.text_stops]
    mov     rsi, [rbx + SYNTHGRID.text_stop_count]
    mov     rdx, [rbx + SYNTHGRID.text_steps]
    mov     rcx, [rbx + SYNTHGRID.text_step_count]
    mov     r8, [sg_text_spectrum]
    call    gradient_new
    mov     [sg_text_spectrum_len], rax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    cmp     rcx, 1
    jl      .bad_max
    cmp     r9, 1
    jl      .bad_max
    cmp     rdx, 1
    jl      .bad_max
    cmp     r8, 1
    jl      .bad_max
    cmp     rdx, rcx
    jg      .bad_min
    cmp     r8, r9
    jg      .bad_min
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [sg_text_map_width], rax
    mov     rdi, [sg_text_spectrum]
    mov     esi, [sg_text_spectrum_len]
    push    qword [rbx + SYNTHGRID.text_direction]
    call    gradient_map
    add     rsp, 8
    mov     [sg_text_map], rax
    ; memo of (generation symbol, spectrum color) -> handle
    mov     rdi, [rbx + SYNTHGRID.gen_symbol_count]
    imul    rdi, [sg_text_spectrum_len]
    shl     rdi, 2
    call    alloc
    mov     [sg_gen_memo], rax
    ; --- grid lines: room for the four borders plus one per row and column
    mov     rdi, [canvas_top]
    add     rdi, [canvas_right]
    add     rdi, 4
    shl     rdi, 4                      ; SG_LINE_SIZE
    call    alloc
    mov     [sg_lines], rax
    xor     edi, edi
    mov     esi, 1                      ; bottom row
    call    sg_make_grid_line
    xor     edi, edi
    mov     rsi, [canvas_top]
    call    sg_make_grid_line
    mov     edi, 1
    mov     esi, 1                      ; left column
    call    sg_make_grid_line
    mov     edi, 1
    mov     rsi, [canvas_right]
    call    sg_make_grid_line
    ; row and column indexes (each list ends with its sentinel)
    mov     rdi, [canvas_top]
    lea     rdi, [rdi * 8 + 16]
    call    alloc
    mov     [sg_row_indexes], rax
    mov     rdi, [canvas_right]
    lea     rdi, [rdi * 8 + 16]
    call    alloc
    mov     [sg_column_indexes], rax
    mov     rax, [canvas_right]
    lea     rcx, [rax + rax]
    cmp     [canvas_top], rcx
    jle     .by_columns
    mov     rdi, [canvas_top]
    call    sg_find_even_gap
    lea     r12, [rax + 1]              ; row_gap
    lea     r13, [r12 + r12]            ; column_gap
    jmp     .gaps
.by_columns:
    mov     rdi, [canvas_right]
    call    sg_find_even_gap
    lea     r13, [rax + 1]              ; column_gap (>= 1)
    mov     r12, r13
    shr     r12, 1                      ; row_gap = column_gap // 2
.gaps:
    mov     [rsp], r13
    ; range(bottom + row_gap, top, max(row_gap, 1))
    mov     r14, r12
    mov     eax, 1
    cmp     r14, 1
    cmovl   r14, rax                    ; row step
    lea     r15, [r12 + 1]              ; row_index
    xor     ebp, ebp                    ; row count
.rows:
    cmp     r15, [canvas_top]
    jge     .rows_done
    mov     rax, [canvas_top]
    sub     rax, r15
    cmp     rax, 2
    jl      .row_next
    mov     rax, [sg_row_indexes]
    mov     [rax + rbp * 8], r15
    inc     rbp
    xor     edi, edi
    mov     rsi, r15
    call    sg_make_grid_line
.row_next:
    add     r15, r14
    jmp     .rows
.rows_done:
    mov     rax, [canvas_top]
    inc     rax
    mov     rcx, [sg_row_indexes]
    mov     [rcx + rbp * 8], rax
    inc     rbp
    mov     [sg_row_index_count], rbp
    ; range(left + column_gap, right, max(column_gap, 1))
    mov     r13, [rsp]
    mov     r14, r13
    mov     eax, 1
    cmp     r14, 1
    cmovl   r14, rax
    lea     r15, [r13 + 1]
    xor     ebp, ebp
.columns:
    cmp     r15, [canvas_right]
    jge     .columns_done
    mov     rax, [canvas_right]
    sub     rax, r15
    cmp     rax, 2
    jl      .column_next
    mov     rax, [sg_column_indexes]
    mov     [rax + rbp * 8], r15
    inc     rbp
    mov     edi, 1
    mov     rsi, r15
    call    sg_make_grid_line
.column_next:
    add     r15, r14
    jmp     .columns
.columns_done:
    mov     rax, [canvas_right]
    inc     rax
    mov     rcx, [sg_column_indexes]
    mov     [rcx + rbp * 8], rax
    inc     rbp
    mov     [sg_column_index_count], rbp
    call    sg_collect_groups
    call    sg_build_dissolves
    ; shuffle pending_groups (the group numbers, in group order)
    mov     rdi, [sg_group_count]
    shl     rdi, 3
    call    alloc
    mov     [sg_pending], rax
    xor     ecx, ecx
.order:
    cmp     rcx, [sg_group_count]
    jae     .shuffle
    mov     [rax + rcx * 8], rcx
    inc     rcx
    jmp     .order
.shuffle:
    mov     rdi, [sg_pending]
    mov     rsi, [sg_group_count]
    call    rng_shuffle64
    mov     qword [sg_pending_next], 0
    mov     byte [sg_phase], SG_PH_GRID_EXPAND
    cmp     qword [sg_group_count], 0
    jne     .built
    ; no groups: every input character is shown and active at once
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.show:
    cmp     rbx, r13
    jae     .built
    mov     edi, [r12 + rbx * 4]
    call    set_visible
    mov     edi, [r12 + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .show
.built:
    mov     qword [sg_active_groups], 0
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.bad_max:
    FAIL    msg_sg_max
.bad_min:
    FAIL    msg_sg_min

; sg_find_even_gap(rdi=dimension) -> rax: SynthGrid::find_even_gap. The gap
; closest to (dimension - 2) // 5 among i in (dimension-2 .. 4] with
; (dimension-2) % i <= 1, the first (largest) on ties; 4 when none; 0 when
; dimension - 2 <= 0.
sg_find_even_gap:
    sub     rdi, 2
    jle     .zero
    mov     r8, rdi
    mov     rax, rdi
    mov     ecx, 5
    cqo
    idiv    rcx
    mov     r9, rax                     ; target (dimension > 0: plain division)
    mov     r10, -1                     ; best gap, none yet
    xor     r11d, r11d                  ; its key
    mov     rsi, r8                     ; i
.scan:
    cmp     rsi, 4
    jle     .done
    mov     rax, r8
    cqo
    idiv    rsi
    cmp     rdx, 1
    jg      .next
    mov     rax, rsi
    sub     rax, r9
    mov     rcx, rax
    neg     rcx
    cmovs   rcx, rax                    ; |i - target|
    cmp     r10, -1
    je      .take
    cmp     rcx, r11
    jge     .next
.take:
    mov     r10, rsi
    mov     r11, rcx
.next:
    dec     rsi
    jmp     .scan
.done:
    mov     rax, r10
    cmp     rax, -1
    jne     .ret
    mov     eax, 4
.ret:
    ret
.zero:
    xor     eax, eax
    ret

; sg_make_grid_line(edi=0 horizontal / 1 vertical, rsi=row or column):
; GridLine::new via make_grid_line. A horizontal line spans columns
; left..=right on its row, a vertical one rows bottom..top (top excluded) on
; its column. Each character: added at (0, 0), one scene with one frame of
; the grid color at its coordinate, activated, layer 2, then moved.
sg_make_grid_line:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, edi                   ; direction
    mov     r13, rsi                    ; fixed row / column
    mov     rbx, [effect_config]
    mov     r14, [rbx + SYNTHGRID.row_symbol]
    mov     eax, 3
    test    r12d, r12d
    jz      .kind
    mov     r14, [rbx + SYNTHGRID.column_symbol]
    mov     eax, 1
.kind:
    ; the line record
    mov     rcx, [sg_line_count]
    shl     rcx, 4
    add     rcx, [sg_lines]
    mov     [rsp], rcx
    mov     edx, [char_count]
    mov     [rcx + SG_LN_FIRST], edx
    mov     dword [rcx + SG_LN_COUNT], 0
    mov     dword [rcx + SG_LN_EXT], 0
    mov     [rcx + SG_LN_STEP], eax
    inc     qword [sg_line_count]
    mov     r15d, 1                     ; the running column / row
.each:
    test    r12d, r12d
    jnz     .vertical
    cmp     r15, [canvas_right]
    jg      .done
    mov     rbp, r13
    shl     rbp, 32
    or      rbp, r15                    ; (column r15, row r13)
    jmp     .make
.vertical:
    cmp     r15, [canvas_top]
    jge     .done
    mov     rbp, r15
    shl     rbp, 32
    mov     eax, r13d
    or      rbp, rax                    ; (column r13, row r15)
.make:
    mov     rdi, r14
    xor     esi, esi
    call    add_character
    mov     ebx, eax                    ; slot
    mov     edi, eax
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    push    rax
    push    rax
    ; sg_grid_map[(row - 1) * right + column - 1]
    mov     rax, rbp
    sar     rax, 32
    dec     rax
    imul    rax, [canvas_right]
    movsxd  rcx, ebp
    add     rax, rcx
    mov     rcx, [sg_grid_map]
    mov     rcx, [rcx + rax * 8 - 8]
    mov     edi, [rsp]
    mov     rsi, r14
    mov     edx, 1
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    pop     rsi
    pop     rsi
    mov     edi, ebx
    call    scene_activate
    mov     edi, ebx
    mov     esi, 2
    call    set_layer
    mov     edi, ebx
    mov     rsi, rbp
    call    set_coordinate
    mov     rcx, [rsp]
    inc     dword [rcx + SG_LN_COUNT]
    inc     r15
    jmp     .each
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sg_collect_groups: the blocks between consecutive row and column indexes,
; row-major inside each block; a block with any character is a group.
sg_collect_groups:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    ; members: at most one per canvas cell; groups: at most one per member
    mov     rdi, [canvas_top]
    imul    rdi, [canvas_right]
    mov     [rsp + 32], rdi
    shl     rdi, 2
    call    alloc
    mov     [sg_members], rax
    mov     rdi, [rsp + 32]
    shl     rdi, 3
    add     rdi, 8
    call    alloc
    mov     [sg_groups], rax            ; (u32 start, u32 count) per group
    mov     qword [sg_group_count], 0
    xor     r15d, r15d                  ; member count
    mov     qword [rsp], 1              ; prev_row_index
    xor     ebx, ebx                    ; row list position
.row:
    cmp     rbx, [sg_row_index_count]
    jae     .done
    mov     rax, [sg_row_indexes]
    mov     rax, [rax + rbx * 8]
    mov     [rsp + 8], rax              ; row_index
    mov     qword [rsp + 16], 1         ; prev_column_index
    xor     ebp, ebp                    ; column list position
.column:
    cmp     rbp, [sg_column_index_count]
    jae     .row_done
    mov     rax, [rsp + 8]
    cmp     rax, [canvas_top]
    jne     .block
    inc     qword [rsp + 8]             ; make sure the top row is included
.block:
    mov     [rsp + 24], r15             ; group start
    mov     r12, [rsp]                  ; row
.block_row:
    cmp     r12, [rsp + 8]
    jge     .block_done
    mov     r13, [rsp + 16]             ; column
    mov     rax, [sg_column_indexes]
    mov     r14, [rax + rbp * 8]        ; column_index
.block_column:
    cmp     r13, r14
    jge     .block_row_next
    mov     rsi, r12
    shl     rsi, 32
    mov     eax, r13d
    or      rsi, rax
    call    char_at_input_coord
    cmp     eax, NONE
    je      .no_char
    mov     rcx, [sg_members]
    mov     [rcx + r15 * 4], eax
    inc     r15
.no_char:
    inc     r13
    jmp     .block_column
.block_row_next:
    inc     r12
    jmp     .block_row
.block_done:
    mov     rax, [rsp + 24]
    cmp     r15, rax
    je      .next_column
    mov     rcx, [sg_group_count]
    mov     rdx, [sg_groups]
    mov     [rdx + rcx * 8], eax
    mov     r8, r15
    sub     r8, rax
    mov     [rdx + rcx * 8 + 4], r8d
    inc     qword [sg_group_count]
.next_column:
    mov     rax, [sg_column_indexes]
    mov     rax, [rax + rbp * 8]
    mov     [rsp + 16], rax
    inc     rbp
    jmp     .column
.row_done:
    mov     rax, [rsp + 8]
    mov     [rsp], rax
    inc     rbx
    jmp     .row
.done:
    mov     [sg_member_count], r15
    mov     rdi, [sg_group_count]
    shl     rdi, 3
    call    alloc
    mov     [sg_tracker], rax
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sg_build_dissolves: per group, per member, in order: a dissolve scene of
; randint(15, 30) frames (choice of symbol, then choice of spectrum color,
; duration 2), the final frame (input symbol, final colors, duration 1),
; activated, and SCENE_COMPLETE -> update_group_tracker(group_number).
sg_build_dissolves:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    xor     r15d, r15d                  ; group number
.group:
    cmp     r15, [sg_group_count]
    jae     .done
    mov     rax, [sg_groups]
    mov     r13d, [rax + r15 * 8]       ; member index
    mov     r14d, [rax + r15 * 8 + 4]
    add     r14, r13                    ; member end
.member:
    cmp     r13, r14
    jae     .next_group
    mov     rax, [sg_members]
    mov     ebx, [rax + r13 * 4]        ; slot
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax                   ; dissolve scene
    mov     edi, 15
    mov     esi, 30
    call    rng_randint
    mov     ebp, eax
.frame:
    test    ebp, ebp
    jz      .final
    mov     rax, [effect_config]
    mov     rdi, [rax + SYNTHGRID.gen_symbol_count]
    call    rng_below
    mov     [rsp], rax                  ; symbol index
    mov     rdi, [sg_text_spectrum_len]
    call    rng_below
    mov     rcx, [rsp]
    imul    rcx, [sg_text_spectrum_len]
    add     rcx, rax                    ; memo index
    mov     rdx, [sg_gen_memo]
    mov     esi, [rdx + rcx * 4]
    test    esi, esi
    jnz     .have_visual
    mov     [rsp + 8], rcx
    mov     rdx, [sg_text_spectrum]
    mov     rdi, [rdx + rax * 8]        ; fg
    mov     rdx, [effect_config]
    mov     rdx, [rdx + SYNTHGRID.gen_symbols]
    mov     rax, [rsp]
    mov     rdx, [rdx + rax * 8]        ; symbol
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     rcx, [rsp + 8]
    mov     rdx, [sg_gen_memo]
    mov     [rdx + rcx * 4], eax
    mov     esi, eax
.have_visual:
    mov     edi, r12d
    mov     edx, 2
    call    scene_add_frame_visual
    dec     ebp
    jmp     .frame
.final:
    ; final colors: character_final_color_map, (None, None) for fill
    mov     rcx, NONE
    mov     r8, NONE
    mov     rax, [ch_flags]
    test    word [rax + rbx * 2], CF_INPUT
    jz      .final_frame
    cmp     qword [cfg_existing_colors], 1
    jne     .gradient_color
    mov     rax, [ch_fg]
    mov     rcx, [rax + rbx * 8]
    mov     rax, [ch_bg]
    mov     r8, [rax + rbx * 8]
    jmp     .final_frame
.gradient_color:
    mov     rax, [ch_sym]
    mov     rax, [rax + rbx * 8]
    mov     rdx, (1 << 32) | ' '
    cmp     rax, rdx
    je      .final_frame
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    sub     rax, [text_bottom]
    imul    rax, [sg_text_map_width]
    mov     rdx, [ch_icol]
    movsxd  rdx, dword [rdx + rbx * 4]
    add     rax, rdx
    sub     rax, [text_left]
    mov     rdx, [sg_text_map]
    mov     rcx, [rdx + rax * 8]
.final_frame:
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edi, r12d
    mov     edx, 1
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, ebx
    mov     esi, r12d
    call    scene_activate
    ; SCENE_COMPLETE on this scene's name -> update_group_tracker
    mov     rax, r12
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     ecx, [rax + SC_NAME]
    push    0
    push    r15
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     r8d, ACT_CALLBACK
    lea     r9, [sg_update_group_tracker]
    call    event_register
    add     rsp, 16
    inc     r13
    jmp     .member
.next_group:
    inc     r15
    jmp     .group
.done:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sg_update_group_tracker(edi=slot, rsi=group number): the effect callback
; update_group_tracker.
sg_update_group_tracker:
    mov     rax, [sg_tracker]
    dec     qword [rax + rsi * 8]
    ret

; synthgrid_next_frame -> eax = 1 for a frame, 0 when done.
synthgrid_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     rax, [sg_pending_next]
    cmp     rax, [sg_group_count]
    jb      .run
    cmp     byte [sg_phase], SG_PH_COMPLETE
    jne     .run
    call    active_empty
    test    eax, eax
    jnz     .finished
.run:
    movzx   eax, byte [sg_phase]
    cmp     eax, SG_PH_GRID_EXPAND
    je      .expand
    cmp     eax, SG_PH_ADD_CHARS
    je      .add
    cmp     eax, SG_PH_COLLAPSE
    je      .collapse
    jmp     .update
.expand:
    ; extend every line that is not yet extended; none left -> AddChars
    xor     r12d, r12d                  ; any extended this frame
    xor     ebx, ebx
.expand_line:
    cmp     rbx, [sg_line_count]
    jae     .expand_done
    mov     r13, rbx
    shl     r13, 4
    add     r13, [sg_lines]
    mov     eax, [r13 + SG_LN_EXT]
    cmp     eax, [r13 + SG_LN_COUNT]
    jae     .expand_next
    mov     r12d, 1
    mov     ebp, [r13 + SG_LN_STEP]
.extend:
    test    ebp, ebp
    jz      .expand_next
    dec     ebp
    mov     eax, [r13 + SG_LN_EXT]
    cmp     eax, [r13 + SG_LN_COUNT]
    jae     .extend
    inc     dword [r13 + SG_LN_EXT]
    mov     edi, [r13 + SG_LN_FIRST]
    add     edi, eax
    call    set_visible
    jmp     .extend
.expand_next:
    inc     rbx
    jmp     .expand_line
.expand_done:
    test    r12d, r12d
    jnz     .update
    mov     byte [sg_phase], SG_PH_ADD_CHARS
    jmp     .update
.add:
    mov     rax, [sg_pending_next]
    cmp     rax, [sg_group_count]
    jae     .add_check
    ; active_groups < total_group_count * max_active_blocks
    cvtsi2sd xmm0, qword [sg_active_groups]
    cvtsi2sd xmm1, qword [sg_group_count]
    mov     rcx, [effect_config]
    mulsd   xmm1, [rcx + SYNTHGRID.max_active_blocks]
    ucomisd xmm1, xmm0
    jbe     .add_check
    mov     rcx, [sg_pending]
    mov     r12, [rcx + rax * 8]        ; group number
    inc     qword [sg_pending_next]
    mov     rcx, [sg_groups]
    mov     ebx, [rcx + r12 * 8]
    mov     r13d, [rcx + r12 * 8 + 4]
    add     r13, rbx
.add_member:
    cmp     rbx, r13
    jae     .add_check
    mov     rax, [sg_members]
    mov     ebp, [rax + rbx * 4]
    mov     edi, ebp
    call    set_visible
    mov     edi, ebp
    call    active_insert
    mov     rax, [sg_tracker]
    inc     qword [rax + r12 * 8]
    inc     rbx
    jmp     .add_member
.add_check:
    mov     rax, [sg_pending_next]
    cmp     rax, [sg_group_count]
    jb      .update
    cmp     qword [sg_active_groups], 0
    jne     .update
    call    active_empty
    test    eax, eax
    jz      .update
    mov     byte [sg_phase], SG_PH_COLLAPSE
    jmp     .update
.collapse:
    ; collapse every line that is not yet collapsed; none left -> Complete
    xor     r12d, r12d
    xor     ebx, ebx
.collapse_line:
    cmp     rbx, [sg_line_count]
    jae     .collapse_done
    mov     r13, rbx
    shl     r13, 4
    add     r13, [sg_lines]
    cmp     dword [r13 + SG_LN_EXT], 0
    je      .collapse_next
    mov     r12d, 1
    mov     ebp, [r13 + SG_LN_STEP]
.shrink:
    test    ebp, ebp
    jz      .collapse_next
    dec     ebp
    mov     eax, [r13 + SG_LN_EXT]
    test    eax, eax
    jz      .shrink
    dec     eax
    mov     [r13 + SG_LN_EXT], eax
    mov     edi, [r13 + SG_LN_FIRST]
    add     edi, eax
    xor     esi, esi
    call    set_visibility
    jmp     .shrink
.collapse_next:
    inc     rbx
    jmp     .collapse_line
.collapse_done:
    test    r12d, r12d
    jnz     .update
    mov     byte [sg_phase], SG_PH_COMPLETE
.update:
    call    update
    ; active_groups = the groups whose tracker is nonzero
    xor     eax, eax
    xor     ecx, ecx
    mov     rdx, [sg_tracker]
    mov     r8, [sg_group_count]
.count:
    cmp     rcx, r8
    jae     .counted
    cmp     qword [rdx + rcx * 8], 0
    setne   r9b
    movzx   r9d, r9b
    add     rax, r9
    inc     rcx
    jmp     .count
.counted:
    mov     [sg_active_groups], rax
    mov     eax, 1
    jmp     .ret
.finished:
    xor     eax, eax
.ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
STR msg_sg_max, "max_row and max_column must be greater than 0."
STR msg_sg_min, "min_row and min_column must be less than or equal to max_row and max_column."

section .tstate
alignb 8
sg_grid_map:           resq 1
sg_text_spectrum:      resq 1
sg_text_spectrum_len:  resq 1
sg_text_map:           resq 1
sg_text_map_width:     resq 1
sg_gen_memo:           resq 1
sg_lines:              resq 1
sg_line_count:         resq 1
sg_row_indexes:        resq 1
sg_row_index_count:    resq 1
sg_column_indexes:     resq 1
sg_column_index_count: resq 1
sg_members:            resq 1
sg_member_count:       resq 1
sg_groups:             resq 1
sg_group_count:        resq 1
sg_tracker:            resq 1
sg_pending:            resq 1
sg_pending_next:       resq 1
sg_active_groups:      resq 1
sg_phase:           resb 1
