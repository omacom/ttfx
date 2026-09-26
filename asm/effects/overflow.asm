; effects/overflow.asm - overflow (src/effects/overflow.rs).
;
; Rows scroll up from the bottom of the canvas: randint(lower, upper) cycles
; of shuffled copies of the input rows colored by the overflow gradient,
; then the real rows (input and fill characters) in their final colors.
;
; Every row (OverflowIterator.Row) is a 32-byte record in one array in
; pending order, so pending_rows is an index into it. A copied row's
; characters are consecutive in added_chars, which never moves. Active rows
; are a u32 list of row indices, retained in order like Vec::retain.

struc of_config
    .stops:             resq 1          ; overflow gradient stops
    .stop_count:        resq 1
    .cycles_min:        resq 1          ; overflow_cycles_range
    .cycles_max:        resq 1
    .speed:             resq 1
    .final_stops:       resq 1
    .final_stop_count:  resq 1
    .final_steps:       resq 1
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; Row record
%define OF_SLOTS        0               ; u32* characters
%define OF_COUNT        8               ; u64 len(characters)
%define OF_FINAL        16              ; u32 Row.final_
%define OF_LAST         20              ; u32 spectrum index last applied, or NONE
%define OF_SHIFT        5

section .text

; overflow_build: Overflow::build.
overflow_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     rbx, [effect_config]
    call    of_final_color_map
    ; rows = get_characters_grouped(default filter, RowTopToBottom)
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_ROW_TOP_TO_BOTTOM
    call    get_characters_grouped
    mov     r12, rax                    ; groups
    mov     r13, rdx                    ; group count
    ; pointers to the group records, shuffled in place cycle after cycle
    lea     rdi, [r13 * 8 + 64]
    call    alloc
    mov     r14, rax
    xor     ecx, ecx
.pointer:
    cmp     rcx, r13
    jae     .cycles
    mov     rax, rcx
    shl     rax, 4
    add     rax, r12
    mov     [r14 + rcx * 8], rax
    inc     rcx
    jmp     .pointer
.cycles:
    xor     r15d, r15d                  ; cycles
    cmp     qword [rbx + of_config.cycles_max], 0
    jle     .reserve
    mov     rdi, [rbx + of_config.cycles_min]
    mov     rsi, [rbx + of_config.cycles_max]
    call    rng_randint
    mov     r15, rax
.reserve:
    ; rows: cycles * len(rows) copies plus at most canvas_top + 1 final rows
    mov     rax, r15
    imul    rax, r13
    add     rax, [canvas_top]
    inc     rax
    mov     [rsp], rax
    shl     rax, OF_SHIFT
    lea     rdi, [rax + 64]
    call    reserve
    mov     [of_rows], rax
    mov     rdi, [rsp]
    lea     rdi, [rdi * 4 + 64]
    call    reserve
    mov     [of_active], rax
    mov     qword [of_row_count], 0
    cmp     qword [cfg_existing_colors], 0
    je      .cycle                      ; input colors win: no visual cache
    call    of_symbol_ids
.cycle:
    test    r15, r15
    jz      .final_rows
    dec     r15
    mov     rdi, r14
    mov     rsi, r13
    call    rng_shuffle64
    xor     ebp, ebp                    ; row
.copy_row:
    cmp     rbp, r13
    jae     .cycle
    ; the copies land consecutively in added_chars
    mov     eax, [added_count]
    mov     rcx, [added_chars]
    lea     rax, [rcx + rax * 4]
    mov     rdx, [r14 + rbp * 8]
    mov     rcx, [rdx + 8]
    mov     [rsp + 8], rcx              ; count
    mov     rdx, [rdx]
    mov     [rsp + 16], rdx             ; source slots
    xor     esi, esi
    mov     rdi, rax
    call    of_push_row
    xor     ebx, ebx
.copy_char:
    cmp     rbx, [rsp + 8]
    jae     .copied
    mov     rax, [rsp + 16]
    mov     r12d, [rax + rbx * 4]       ; source slot
    mov     edi, r12d
    call    char_input_coord
    mov     rsi, rax
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    call    add_character
    ; uses_input_preexisting_colors, and the input colors (not the bold)
    mov     rcx, [ch_flags]
    or      word [rcx + rax * 2], CF_PREEXISTING
    mov     rcx, [ch_fg]
    mov     rdx, [rcx + r12 * 8]
    mov     [rcx + rax * 8], rdx
    mov     rcx, [ch_bg]
    mov     rdx, [rcx + r12 * 8]
    mov     [rcx + rax * 8], rdx
    mov     rcx, [of_symid]
    test    rcx, rcx
    jz      .copy_next
    mov     edx, [rcx + r12 * 4]        ; the copy has the source's symbol
    mov     [rcx + rax * 4], edx
.copy_next:
    inc     rbx
    jmp     .copy_char
.copied:
    inc     rbp
    jmp     .copy_row
.final_rows:
    ; the real rows, top to bottom, in their final appearance
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, GROUP_ROW_TOP_TO_BOTTOM
    call    get_characters_grouped
    mov     r12, rax
    mov     r13, rdx
    xor     ebp, ebp
.final_row:
    cmp     rbp, r13
    jae     .spectrum
    mov     r14, rbp
    shl     r14, 4
    add     r14, r12                    ; group record
    xor     ebx, ebx
.final_char:
    cmp     rbx, [r14 + 8]
    jae     .final_push
    mov     rax, [r14]
    mov     r15d, [rax + rbx * 4]       ; slot
    ; the symbol of current_character_visual
    mov     rax, [ch_handle]
    mov     eax, [rax + r15 * 4]
    call    visual_meta
    mov     rsi, [rax + VH_SYMBOL]
    cmp     qword [cfg_existing_colors], 1
    jne     .final_color
    mov     rdx, [ch_fg]
    mov     rdx, [rdx + r15 * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + r15 * 8]
    jmp     .appearance
.final_color:
    ; character_final_color_map: the mapped color inside the text box,
    ; 000000 outside it
    xor     edx, edx
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r15 * 4]
    sub     rax, [text_bottom]
    jl      .final_fg
    cmp     rax, [of_map_height]
    jge     .final_fg
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r15 * 4]
    sub     rcx, [text_left]
    jl      .final_fg
    cmp     rcx, [of_map_width]
    jge     .final_fg
    imul    rax, [of_map_width]
    add     rax, rcx
    mov     rdx, [of_map]
    mov     rdx, [rdx + rax * 8]
.final_fg:
    mov     rcx, NONE
.appearance:
    mov     edi, r15d
    call    set_appearance
    inc     rbx
    jmp     .final_char
.final_push:
    mov     rdi, [r14]
    mov     rcx, [r14 + 8]
    mov     esi, 1
    call    of_push_row
    inc     rbp
    jmp     .final_row
.spectrum:
    ; steps = max(canvas_top // max(1, len(stops) - 1), 1)
    mov     rbx, [effect_config]
    mov     rcx, [rbx + of_config.stop_count]
    dec     rcx
    mov     eax, 1
    cmp     rcx, 1
    cmovl   rcx, rax
    mov     rax, [canvas_top]
    cqo
    idiv    rcx
    cmp     rax, 1
    jge     .steps
    mov     eax, 1
.steps:
    mov     [of_steps], rax
    lea     rdi, [of_steps]
    mov     ecx, 1
    mov     rsi, [rbx + of_config.stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8 + 64]
    call    alloc
    mov     [of_spectrum], rax
    mov     rdi, [rbx + of_config.stops]
    mov     rsi, [rbx + of_config.stop_count]
    lea     rdx, [of_steps]
    mov     ecx, 1
    mov     r8, [of_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [of_spectrum_len], rax
    cmp     qword [of_symid], 0
    je      .no_cache
    ; the visual cache: one handle per (spectrum index, symbol id), 0 = unmade
    imul    rax, [of_nsym]
    lea     rdi, [rax * 4 + 64]
    call    alloc
    mov     [of_hcache], rax
.no_cache:
    mov     qword [of_delay], 0
    mov     qword [of_next], 0
    mov     qword [of_active_count], 0
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; of_symbol_ids(r15=cycles): number the distinct input symbols of the
; input characters (r12=groups, r13=group count) into of_symid, a per-slot
; array sized for the copies still to come. Preserves rbx, r12-r15.
of_symbol_ids:
    push    rbx
    push    rbp
    push    r14
    ; slots: every current one plus cycles copies of the input
    mov     rax, r15
    inc     rax
    mov     ecx, [char_count]
    imul    rax, rcx
    lea     rdi, [rax * 4 + 64]
    call    alloc
    mov     [of_symid], rax
    ; open-addressed symbol table: 16-byte (symbol, id) entries, at least
    ; twice as many as there are input characters
    mov     eax, [char_count]
    add     rax, rax
    mov     ecx, 16
    xor     edx, edx
.size:
    cmp     rcx, rax
    jae     .sized
    add     rcx, rcx
    inc     edx
    jmp     .size
.sized:
    add     edx, 4                      ; log2 of the entry count
    mov     ecx, 64
    sub     ecx, edx
    mov     [of_symshift], rcx
    mov     rdi, 16
    mov     ecx, edx
    shl     rdi, cl
    mov     [of_symmask], rdi
    shr     qword [of_symmask], 4
    dec     qword [of_symmask]
    add     rdi, 64
    call    alloc
    mov     [of_symtab], rax
    mov     qword [of_nsym], 0
    xor     ebp, ebp                    ; group
.group:
    cmp     rbp, r13
    jae     .done
    mov     r14, rbp
    shl     r14, 4
    add     r14, r12
    xor     ebx, ebx
.char:
    cmp     rbx, [r14 + 8]
    jae     .next_group
    mov     rax, [r14]
    mov     r8d, [rax + rbx * 4]        ; slot
    mov     rax, [ch_sym]
    mov     rdi, [rax + r8 * 8]
    ; probe
    mov     rax, 0x9E3779B97F4A7C15
    imul    rax, rdi
    mov     rcx, [of_symshift]
    shr     rax, cl
    mov     rsi, [of_symtab]
.probe:
    mov     rdx, rax
    shl     rdx, 4
    mov     rcx, [rsi + rdx]
    test    rcx, rcx
    jz      .new
    cmp     rcx, rdi
    je      .found
    inc     rax
    and     rax, [of_symmask]
    jmp     .probe
.new:
    mov     [rsi + rdx], rdi
    mov     rcx, [of_nsym]
    mov     [rsi + rdx + 8], rcx
    inc     qword [of_nsym]
.found:
    mov     ecx, [rsi + rdx + 8]
    mov     rax, [of_symid]
    mov     [rax + r8 * 4], ecx
    inc     rbx
    jmp     .char
.next_group:
    inc     rbp
    jmp     .group
.done:
    pop     r14
    pop     rbp
    pop     rbx
    ret

; of_push_row(rdi=slots, rcx=count, esi=final): pending_rows.push_back(Row).
of_push_row:
    mov     rax, [of_row_count]
    inc     qword [of_row_count]
    shl     rax, OF_SHIFT
    add     rax, [of_rows]
    mov     [rax + OF_SLOTS], rdi
    mov     [rax + OF_COUNT], rcx
    mov     [rax + OF_FINAL], esi
    mov     dword [rax + OF_LAST], NONE
    ret

; of_final_color_map: Gradient::new(final stops, final steps) mapped over the
; text rectangle (build_coordinate_color_mapping), row-major.
of_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + of_config.final_steps]
    mov     rcx, [rbx + of_config.final_step_count]
    mov     rsi, [rbx + of_config.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [of_final_spectrum], rax
    mov     rdi, [rbx + of_config.final_stops]
    mov     rsi, [rbx + of_config.final_stop_count]
    mov     rdx, [rbx + of_config.final_steps]
    mov     rcx, [rbx + of_config.final_step_count]
    mov     r8, [of_final_spectrum]
    call    gradient_new
    mov     rdi, [of_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [of_map_width], rax
    mov     rax, rcx
    sub     rax, rdx
    inc     rax
    mov     [of_map_height], rax
    push    qword [rbx + of_config.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [of_map], rax
    pop     rbx
    ret

; overflow_next_frame -> eax = 1 for a frame, 0 when done.
overflow_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rax, [of_next]
    cmp     rax, [of_row_count]
    jae     .done
    cmp     qword [of_delay], 0
    jne     .wait
    mov     rax, [effect_config]
    mov     edi, 1
    mov     rsi, [rax + of_config.speed]
    call    rng_randint
    mov     [rsp], rax
.push:
    cmp     qword [rsp], 0
    jle     .delay
    dec     qword [rsp]
    mov     rax, [of_next]
    cmp     rax, [of_row_count]
    jae     .delay                      ; out of rows: the rest do nothing
    ; move every active row up, recoloring the overflow rows by height
    xor     r12d, r12d
.active_row:
    cmp     r12, [of_active_count]
    jae     .next_row
    mov     rax, [of_active]
    mov     ebx, [rax + r12 * 4]
    shl     rbx, OF_SHIFT
    add     rbx, [of_rows]
    mov     rdi, rbx
    call    of_move_up
    cmp     dword [rbx + OF_FINAL], 0
    jne     .active_next
    mov     rax, [rbx + OF_SLOTS]
    mov     eax, [rax]
    mov     rcx, [ch_row]
    movsxd  rsi, dword [rcx + rax * 4]  ; head row
    mov     rax, [of_spectrum_len]
    dec     rax
    cmp     rsi, rax
    cmovg   rsi, rax
    mov     rdi, rbx
    call    of_set_color
.active_next:
    inc     r12
    jmp     .active_row
.next_row:
    ; pending_rows.pop_front(): setup, move_up, color, reveal
    mov     r13, [of_next]
    inc     qword [of_next]
    mov     rbx, r13
    shl     rbx, OF_SHIFT
    add     rbx, [of_rows]
    xor     r12d, r12d
.setup:
    cmp     r12, [rbx + OF_COUNT]
    jae     .setup_done
    mov     rax, [rbx + OF_SLOTS]
    mov     r14d, [rax + r12 * 4]
    ; (input column, 0) then one row up
    mov     rax, [ch_icol]
    mov     esi, [rax + r14 * 4]
    mov     rax, 1 << 32
    or      rsi, rax
    mov     edi, r14d
    call    set_coordinate
    inc     r12
    jmp     .setup
.setup_done:
    cmp     dword [rbx + OF_FINAL], 0
    jne     .reveal
    mov     rdi, rbx
    xor     esi, esi
    call    of_set_color
.reveal:
    xor     r12d, r12d
.reveal_char:
    cmp     r12, [rbx + OF_COUNT]
    jae     .activate
    mov     rax, [rbx + OF_SLOTS]
    mov     edi, [rax + r12 * 4]
    call    set_visible
    inc     r12
    jmp     .reveal_char
.activate:
    mov     rax, [of_active_count]
    inc     qword [of_active_count]
    mov     rcx, [of_active]
    mov     [rcx + rax * 4], r13d
    jmp     .push
.delay:
    xor     edi, edi
    mov     esi, 3
    call    rng_randint
    mov     [of_delay], rax
    jmp     .retain
.wait:
    dec     qword [of_delay]
.retain:
    ; active_rows.retain(head row <= canvas_top)
    mov     r8, [of_active]
    mov     r9, [of_rows]
    mov     r10, [ch_row]
    mov     r11, [canvas_top]
    xor     ecx, ecx                    ; read
    xor     edx, edx                    ; write
.keep:
    cmp     rcx, [of_active_count]
    jae     .kept
    mov     eax, [r8 + rcx * 4]
    mov     rsi, rax
    shl     rsi, OF_SHIFT
    mov     rsi, [r9 + rsi + OF_SLOTS]
    mov     esi, [rsi]
    movsxd  rsi, dword [r10 + rsi * 4]
    cmp     rsi, r11
    jg      .drop
    mov     [r8 + rdx * 4], eax
    inc     rdx
.drop:
    inc     rcx
    jmp     .keep
.kept:
    mov     [of_active_count], rdx
    call    update
    mov     eax, 1
    jmp     .out
.done:
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

; of_move_up(rdi=row): Row.move_up - every character one row up.
of_move_up:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    xor     r12d, r12d
.char:
    cmp     r12, [rbx + OF_COUNT]
    jae     .done
    mov     rax, [rbx + OF_SLOTS]
    mov     r13d, [rax + r12 * 4]
    mov     edi, r13d
    call    char_coord
    mov     rcx, 1 << 32
    lea     rsi, [rax + rcx]
    mov     edi, r13d
    call    set_coordinate
    inc     r12
    jmp     .char
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; of_set_color(rdi=row, rsi=spectrum index): Row.set_color(spectrum[index],
; None) - the input symbol in that color. The visual depends only on the
; symbol and the color, so a row already showing that index is unchanged.
of_set_color:
    cmp     [rdi + OF_LAST], esi
    je      .same
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     [rbx + OF_LAST], esi
    mov     rax, [of_spectrum]
    mov     r13, [rax + rsi * 8]        ; color
    xor     r12d, r12d
    mov     rax, [of_hcache]
    test    rax, rax
    jz      .char
    ; set_appearance through the (index, symbol) cache: the visual is
    ; (input symbol, color, no bg, no attributes) for every copy here
    push    r14
    push    r15
    imul    rsi, [of_nsym]
    lea     r14, [rax + rsi * 4]        ; this index's handles
.cached:
    cmp     r12, [rbx + OF_COUNT]
    jae     .cached_done
    mov     rax, [rbx + OF_SLOTS]
    mov     edi, [rax + r12 * 4]
    mov     rax, [of_symid]
    mov     r15d, [rax + rdi * 4]
    mov     eax, [r14 + r15 * 4]
    test    eax, eax
    jnz     .have
    mov     rax, [ch_sym]
    mov     rdx, [rax + rdi * 8]
    mov     rdi, r13
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     [r14 + r15 * 4], eax
    mov     rcx, [rbx + OF_SLOTS]
    mov     edi, [rcx + r12 * 4]
.have:
    ; (no doze_wake: a copy never joins the active set, so never dozes)
    SET_HANDLE
    inc     r12
    jmp     .cached
.cached_done:
    pop     r15
    pop     r14
    jmp     .done
.char:
    cmp     r12, [rbx + OF_COUNT]
    jae     .done
    mov     rax, [rbx + OF_SLOTS]
    mov     edi, [rax + r12 * 4]
    xor     esi, esi
    mov     rdx, r13
    mov     rcx, NONE
    call    set_appearance
    inc     r12
    jmp     .char
.done:
    pop     r13
    pop     r12
    pop     rbx
.same:
    ret

section .tstate
alignb 8
of_rows:            resq 1
of_row_count:       resq 1
of_next:            resq 1              ; first pending row
of_active:          resq 1              ; u32 row indices
of_active_count:    resq 1
of_delay:           resq 1
of_steps:           resq 1
of_spectrum:        resq 1
of_spectrum_len:    resq 1
of_final_spectrum:  resq 1
of_map:             resq 1
of_map_width:       resq 1
of_map_height:      resq 1
of_symid:           resq 1              ; u32 symbol id per slot, or 0 = no cache
of_symtab:          resq 1              ; (symbol, id) entries
of_symshift:        resq 1
of_symmask:         resq 1
of_nsym:            resq 1
of_hcache:          resq 1              ; u32 handles [index * nsym + id]
