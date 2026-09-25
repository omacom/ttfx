; effects/matrix.asm - matrix (src/effects/matrix.rs).
;
; Rain columns fall until --rain-time seconds of wall clock have passed
; (clock_wall: virtual under --parity-dump / --virtual-clock), then every
; column fills and the text resolves out of it.
;
; RainColumn lives in a 128-byte record. Its pending characters are always a
; suffix of its characters (pending.remove(0) only), so they are an index.
; Its visible characters are pushed at the back at most once per setup, so a
; buffer of the column's length with start/end indices holds them; front
; pops advance the start, and resolve_char / drop_column compact in place.
; pending_columns is a ring (a column is pending at most once), active and
; full are plain arrays of column indices.
;
; Colors are compared (Color ==) by their words; the marshalling tags hex
; stops spelled unlike Color::from_rgb so that equality matches Rust's.

struc matrix_config
    .highlight:         resq 1
    .rain:              resq 1          ; rain gradient stops
    .rain_count:        resq 1
    .symbols:           resq 1          ; packed symbols
    .symbol_count:      resq 1
    .fall_min:          resq 1          ; rain_fall_delay_range
    .fall_max:          resq 1
    .column_min:        resq 1          ; rain_column_delay_range
    .column_max:        resq 1
    .rain_time:         resq 1
    .symbol_swap:       resq 1          ; f64
    .color_swap:        resq 1          ; f64
    .resolve_delay:     resq 1
    .final_stops:       resq 1
    .final_stop_count:  resq 1
    .final_steps:       resq 1
    .final_step_count:  resq 1
    .final_frames:      resq 1
    .final_direction:   resq 1
endstruc

; RainColumn record
%define CO_CHARS        0               ; u32* characters, bottom to top
%define CO_LEN          8               ; u64 len(characters)
%define CO_PEND         16              ; u32 first pending character
%define CO_VSTART       20              ; u32 visible[0]
%define CO_VEND         24              ; u32 one past the last visible
%define CO_PHASE        28              ; u32 MX_RAIN / MX_FILL
%define CO_VIS          32              ; u32* visible buffer
%define CO_DROP         40              ; f64 column_drop_chance
%define CO_BASE         48              ; i64 base_rain_fall_delay
%define CO_DELAY        56              ; i64 active_rain_fall_delay
%define CO_LENGTH       64              ; i64 length
%define CO_HOLD         72              ; i64 hold_time
%define CO_IN_FULL      80              ; u8 in full_columns
%define CO_SHIFT        7

%define MX_RAIN         0
%define MX_FILL         1
%define MX_RESOLVE      2

%define MX_SCENE_RESOLVE    NAME_LITERAL

section .text

; matrix_build: Matrix::build.
matrix_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     rbx, [effect_config]
    mov     rax, [rbx + matrix_config.highlight]
    mov     [mx_highlight], rax
    mov     rax, [rbx + matrix_config.symbols]
    mov     [mx_symbols], rax
    mov     rax, [rbx + matrix_config.symbol_count]
    mov     [mx_symbol_count], rax
    mov     rax, [rbx + matrix_config.resolve_delay]
    mov     [mx_resolve_delay], rax
    movsd   xmm0, [rbx + matrix_config.symbol_swap]
    call    rng_threshold
    mov     [mx_symbol_swap], rax
    movsd   xmm0, [rbx + matrix_config.color_swap]
    call    rng_threshold
    mov     [mx_color_swap], rax
    cvtsi2sd xmm0, qword [rbx + matrix_config.rain_time]
    movsd   [mx_rain_time], xmm0
    ; rain_colors = Gradient(*rain_color_gradient, steps=6).spectrum
    lea     rdi, [mx_six]
    mov     ecx, 1
    mov     rsi, [rbx + matrix_config.rain_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [mx_rain], rax
    mov     r8, rax
    mov     rdi, [rbx + matrix_config.rain]
    mov     esi, [rbx + matrix_config.rain_count]
    lea     rdx, [mx_six]
    mov     ecx, 1
    call    gradient_new
    mov     [mx_rain_len], rax
    ; the final gradient and its coordinate mapping
    mov     rdi, [rbx + matrix_config.final_steps]
    mov     rcx, [rbx + matrix_config.final_step_count]
    mov     rsi, [rbx + matrix_config.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + matrix_config.final_stops]
    mov     esi, [rbx + matrix_config.final_stop_count]
    mov     rdx, [rbx + matrix_config.final_steps]
    mov     ecx, [rbx + matrix_config.final_step_count]
    mov     r8, r12
    call    gradient_new
    mov     r13d, eax
    ; build_coordinate_color_mapping(text_bottom, text_top, text_left, text_right)
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    cmp     rcx, 1
    jl      .bad_bounds
    cmp     r9, 1
    jl      .bad_bounds
    cmp     rdx, 1
    jl      .bad_bounds
    cmp     r8, 1
    jl      .bad_bounds
    cmp     rdx, rcx
    jg      .bad_order
    cmp     r8, r9
    jg      .bad_order
    mov     rdi, r12
    mov     esi, r13d
    push    0
    push    qword [rbx + matrix_config.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     r14, rax                    ; the map
    mov     r15, [text_right]
    sub     r15, [text_left]
    inc     r15                         ; its width
    ; resolve scenes for the input characters, top to bottom
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     rbp, rax
    mov     r12, rdx
    xor     r13d, r13d
.character:
    cmp     r13, r12
    jae     .columns
    mov     ebx, [rbp + r13 * 4]
    mov     edi, ebx
    mov     esi, MX_SCENE_RESOLVE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp], eax                  ; the scene
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; final color from the mapping; Gradient(highlight, final, steps=8)
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    sub     rax, [text_bottom]
    imul    rax, r15
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbx * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rax, [r14 + rax * 8]
    call    resolve_gradient_fg
    mov     [rsp + 8], eax              ; spectrum length
    mov     dword [rsp + 12], 0
.frame:
    mov     eax, [rsp + 12]
    cmp     eax, [rsp + 8]
    jae     .next_character
    lea     rcx, [mx_fg_spectrum]
    mov     rcx, [rcx + rax * 8]
    mov     edi, [rsp]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     rdx, [effect_config]
    mov     edx, [rdx + matrix_config.final_frames]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     dword [rsp + 12]
    jmp     .frame
.dynamic:
    ; ColorPair(input fg, input bg): gradients from the highlight to each
    xor     eax, eax
    mov     [rsp + 8], rax              ; fg spectrum length
    mov     [rsp + 16], rax             ; bg spectrum length
    mov     rax, [ch_fg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dynamic_bg
    call    resolve_gradient_fg
    mov     [rsp + 8], rax
.dynamic_bg:
    mov     rax, [ch_bg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dynamic_frames
    lea     rdi, [mx_pair]
    mov     rcx, [mx_highlight]
    mov     [rdi], rcx
    mov     [rdi + 8], rax
    mov     esi, 2
    lea     rdx, [mx_eight]
    mov     ecx, 1
    lea     r8, [mx_bg_spectrum]
    call    gradient_new
    mov     [rsp + 16], rax
.dynamic_frames:
    mov     rax, [ch_sym]
    mov     rax, [rax + rbx * 8]
    mov     [rsp + 24], rax
    mov     rax, [effect_config]
    mov     ecx, [rax + matrix_config.final_frames]
    mov     rax, [rsp + 8]
    or      rax, [rsp + 16]
    jz      .dynamic_plain
    mov     edi, [rsp]
    lea     rsi, [rsp + 24]
    mov     edx, 1
    xor     r8d, r8d
    mov     r9, [rsp + 8]
    test    r9, r9
    jz      .no_fg
    lea     r8, [mx_fg_spectrum]
.no_fg:
    xor     eax, eax
    mov     r10, [rsp + 16]
    test    r10, r10
    jz      .no_bg
    lea     rax, [mx_bg_spectrum]
.no_bg:
    push    r10
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .next_character
.dynamic_plain:
    mov     edi, [rsp]
    mov     rsi, [rsp + 24]
    mov     edx, ecx
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.next_character:
    inc     r13
    jmp     .character
.columns:
    ; one RainColumn per canvas column, left to right, bottom to top
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, GROUP_COLUMN_L2R
    call    get_characters_grouped
    mov     rbp, rax
    mov     r12, rdx
    mov     [mx_column_count], rdx
    mov     rdi, r12
    shl     rdi, CO_SHIFT
    call    alloc
    mov     [mx_columns], rax
    lea     rdi, [r12 * 4 + 4]
    call    alloc
    mov     [mx_pending], rax
    lea     rdi, [r12 * 4 + 4]
    call    alloc
    mov     [mx_active], rax
    lea     rdi, [r12 * 4 + 4]
    call    alloc
    mov     [mx_full], rax
    xor     r13d, r13d
.column:
    cmp     r13, r12
    jae     .shuffle
    mov     rbx, r13
    shl     rbx, CO_SHIFT
    add     rbx, [mx_columns]
    mov     rdi, r13
    shl     rdi, 4
    mov     rsi, [rbp + rdi + 8]        ; count
    mov     rdi, [rbp + rdi]            ; slots
    mov     [rbx + CO_CHARS], rdi
    mov     [rbx + CO_LEN], rsi
    ; column_chars.reverse()
    lea     rdx, [rdi + rsi * 4 - 4]
.reverse:
    cmp     rdi, rdx
    jae     .reversed
    mov     eax, [rdi]
    mov     ecx, [rdx]
    mov     [rdi], ecx
    mov     [rdx], eax
    add     rdi, 4
    sub     rdx, 4
    jmp     .reverse
.reversed:
    lea     rdi, [rsi * 4]
    call    alloc
    mov     [rbx + CO_VIS], rax
    mov     rax, [mx_drop_chance]
    mov     [rbx + CO_DROP], rax
    mov     rdi, rbx
    mov     esi, MX_RAIN
    call    setup_column
    mov     rax, [mx_pending]
    mov     [rax + r13 * 4], r13d
    inc     r13
    jmp     .column
.shuffle:
    mov     [mx_pending_count], r12
    mov     rdi, [mx_pending]
    mov     rsi, r12
    call    rng_shuffle32
    ; rain_start = time.time(), after build
    call    clock_wall
    movsd   [mx_rain_start], xmm0
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.bad_bounds:
    FAIL    msg_mx_bounds
.bad_order:
    FAIL    msg_mx_order

; resolve_gradient_fg(rax=color) -> rax = length of
; Gradient(highlight, color, steps=8) in mx_fg_spectrum.
resolve_gradient_fg:
    lea     rdi, [mx_pair]
    mov     rcx, [mx_highlight]
    mov     [rdi], rcx
    mov     [rdi + 8], rax
    mov     esi, 2
    lea     rdx, [mx_eight]
    mov     ecx, 1
    lea     r8, [mx_fg_spectrum]
    jmp     gradient_new

; setup_column(rdi=column, esi=MX_RAIN/MX_FILL): RainColumn.setup_column.
setup_column:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     [rbx + CO_PHASE], esi
    xor     r12d, r12d
.hide:
    cmp     r12, [rbx + CO_LEN]
    jae     .hidden
    mov     rax, [rbx + CO_CHARS]
    mov     r13d, [rax + r12 * 4]
    mov     edi, r13d
    xor     esi, esi
    call    set_visibility
    mov     edi, r13d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, r13d
    call    set_coordinate
    inc     r12
    jmp     .hide
.hidden:
    xor     eax, eax
    mov     [rbx + CO_PEND], eax
    mov     [rbx + CO_VSTART], eax
    mov     [rbx + CO_VEND], eax
    mov     rax, [effect_config]
    mov     rdi, [rax + matrix_config.fall_min]
    mov     rsi, [rax + matrix_config.fall_max]
    cmp     dword [rbx + CO_PHASE], MX_FILL
    jne     .delay
    ; max(floor_div(bound, 3), 1); the bounds are positive
    mov     ecx, 3
    mov     rax, rdi
    cqo
    idiv    rcx
    mov     edi, 1
    cmp     rax, rdi
    cmovg   rdi, rax
    mov     rax, rsi
    cqo
    idiv    rcx
    mov     esi, 1
    cmp     rax, rsi
    cmovg   rsi, rax
.delay:
    call    rng_randint
    mov     [rbx + CO_BASE], rax
    mov     qword [rbx + CO_DELAY], 0
    mov     rsi, [rbx + CO_LEN]
    mov     rax, rsi
    cmp     dword [rbx + CO_PHASE], MX_RAIN
    jne     .length
    ; randint(max(1, int(len * 0.1)), len)
    cvtsi2sd xmm0, rsi
    mulsd   xmm0, [mx_tenth]
    cvttsd2si rdi, xmm0
    mov     eax, 1
    cmp     rdi, rax
    cmovl   rdi, rax
    call    rng_randint
.length:
    mov     [rbx + CO_LENGTH], rax
    mov     qword [rbx + CO_HOLD], 0
    cmp     rax, [rbx + CO_LEN]
    jne     .done
    mov     edi, 20
    mov     esi, 45
    call    rng_randint
    mov     [rbx + CO_HOLD], rax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; recolor(edi=slot, rsi=fg): set_appearance(slot, current symbol, (fg, None)).
recolor:
    mov     rax, [ch_handle]
    mov     eax, [rax + rdi * 4]
    call    visual_meta
    mov     rdx, rsi
    mov     rsi, [rax + VH_SYMBOL]
    mov     rcx, NONE
    jmp     set_appearance

; rain_choice -> rax = random.choice(rain_colors).
rain_choice:
    mov     rdi, [mx_rain_len]
    call    rng_below
    mov     rcx, [mx_rain]
    mov     rax, [rcx + rax * 8]
    ret

; trim_column(rbx=column): RainColumn.trim_column. Preserves rbx.
trim_column:
    mov     eax, [rbx + CO_VSTART]
    cmp     eax, [rbx + CO_VEND]
    je      .done
    mov     rcx, [rbx + CO_VIS]
    mov     edi, [rcx + rax * 4]
    inc     eax
    mov     [rbx + CO_VSTART], eax
    xor     esi, esi
    call    set_visibility
    mov     eax, [rbx + CO_VEND]
    sub     eax, [rbx + CO_VSTART]
    cmp     eax, 1
    jbe     .done
    ; fade_last_character: random.choice(rain_colors[-3:]) at 0.65
    mov     rdi, [mx_rain_len]
    mov     rsi, rdi
    sub     rsi, 3
    xor     eax, eax
    cmp     rsi, rax
    cmovl   rsi, rax                    ; tail start
    sub     rdi, rsi
    push    rsi
    call    rng_below
    pop     rsi
    add     rax, rsi
    mov     rcx, [mx_rain]
    mov     rdi, [rcx + rax * 8]
    movsd   xmm0, [mx_fade]
    call    adjust_color_brightness
    mov     rsi, rax
    mov     eax, [rbx + CO_VSTART]
    mov     rcx, [rbx + CO_VIS]
    mov     edi, [rcx + rax * 4]
    jmp     recolor
.done:
    ret

; drop_column(rbx=column): RainColumn.drop_column - every visible character
; moves down a row; those leaving the canvas are hidden and dropped.
drop_column:
    push    r12
    push    r13
    push    r14
    mov     r12d, [rbx + CO_VSTART]     ; read
    mov     r13d, r12d                  ; write
.each:
    cmp     r12d, [rbx + CO_VEND]
    jae     .done
    mov     rax, [rbx + CO_VIS]
    mov     r14d, [rax + r12 * 4]
    mov     rax, [ch_row]
    mov     esi, [rax + r14 * 4]
    dec     esi
    shl     rsi, 32
    mov     rax, [ch_col]
    mov     eax, [rax + r14 * 4]
    or      rsi, rax
    mov     edi, r14d
    call    set_coordinate
    mov     rax, [ch_row]
    cmp     dword [rax + r14 * 4], 1    ; canvas.bottom
    jge     .keep
    mov     edi, r14d
    xor     esi, esi
    call    set_visibility
    jmp     .next
.keep:
    mov     rax, [rbx + CO_VIS]
    mov     [rax + r13 * 4], r14d
    inc     r13d
.next:
    inc     r12d
    jmp     .each
.done:
    mov     [rbx + CO_VEND], r13d
    pop     r14
    pop     r13
    pop     r12
    ret

; resolve_char(rbx=column) -> eax = slot: RainColumn.resolve_char.
resolve_char:
    mov     edi, [rbx + CO_VEND]
    sub     edi, [rbx + CO_VSTART]
    call    rng_below                   ; randint(0, len - 1)
    mov     ecx, [rbx + CO_VSTART]
    add     ecx, eax                    ; the removed position
    mov     rdx, [rbx + CO_VIS]
    mov     eax, [rdx + rcx * 4]
    ; close the gap from the tail
    mov     esi, [rbx + CO_VEND]
    dec     esi
    mov     [rbx + CO_VEND], esi
.shift:
    cmp     ecx, esi
    jae     .done
    mov     edi, [rdx + rcx * 4 + 4]
    mov     [rdx + rcx * 4], edi
    inc     ecx
    jmp     .shift
.done:
    ret

; column_tick(rdi=column): RainColumn.tick.
column_tick:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    cmp     qword [rbx + CO_DELAY], 0
    jne     .wait
    mov     eax, [rbx + CO_PEND]
    cmp     rax, [rbx + CO_LEN]
    jae     .no_pending
    ; the next pending character appears, highlighted
    mov     rcx, [rbx + CO_CHARS]
    mov     r12d, [rcx + rax * 4]
    inc     eax
    mov     [rbx + CO_PEND], eax
    mov     rdi, [mx_symbol_count]
    call    rng_below
    mov     rcx, [mx_symbols]
    mov     rsi, [rcx + rax * 8]
    mov     edi, r12d
    mov     rdx, [mx_highlight]
    mov     rcx, NONE
    call    set_appearance
    ; the previous bottom character loses the highlight
    mov     eax, [rbx + CO_VEND]
    cmp     eax, [rbx + CO_VSTART]
    je      .show
    call    rain_choice
    mov     rsi, rax
    mov     eax, [rbx + CO_VEND]
    mov     rcx, [rbx + CO_VIS]
    mov     edi, [rcx + rax * 4 - 4]
    call    recolor
.show:
    mov     edi, r12d
    call    set_visible
    mov     eax, [rbx + CO_VEND]
    mov     rcx, [rbx + CO_VIS]
    mov     [rcx + rax * 4], r12d
    inc     eax
    mov     [rbx + CO_VEND], eax
    jmp     .trim
.no_pending:
    mov     eax, [rbx + CO_VEND]
    cmp     eax, [rbx + CO_VSTART]
    je      .trim
    ; the bottom character loses the highlight
    mov     rcx, [rbx + CO_VIS]
    mov     r12d, [rcx + rax * 4 - 4]
    mov     rax, [ch_handle]
    mov     eax, [rax + r12 * 4]
    call    visual_meta
    mov     rcx, [rax + VH_FG]
    cmp     rcx, [mx_highlight]
    jne     .hold
    call    rain_choice
    mov     rsi, rax
    mov     edi, r12d
    call    recolor
.hold:
    cmp     qword [rbx + CO_HOLD], 0
    je      .drain
    dec     qword [rbx + CO_HOLD]
    jmp     .trim
.drain:
    cmp     dword [rbx + CO_PHASE], MX_RAIN
    jne     .trim
    call    rng_random
    comisd  xmm0, [rbx + CO_DROP]
    jae     .no_drop
    call    drop_column
.no_drop:
    call    trim_column
.trim:
    mov     eax, [rbx + CO_VEND]
    sub     eax, [rbx + CO_VSTART]
    cmp     rax, [rbx + CO_LENGTH]
    jbe     .rearm
    call    trim_column
.rearm:
    mov     rax, [rbx + CO_BASE]
    mov     [rbx + CO_DELAY], rax
    jmp     .swap
.wait:
    dec     qword [rbx + CO_DELAY]
.swap:
    ; randomly change the symbol and/or color of the visible characters
    mov     r12d, [rbx + CO_VSTART]
.each:
    cmp     r12d, [rbx + CO_VEND]
    jae     .done
    xor     r13d, r13d                  ; next symbol, 0 = none
    mov     r14, NONE                   ; next color, NONE = none
    RNG_BITS53
    cmp     rax, [mx_symbol_swap]
    jae     .color
    mov     rdi, [mx_symbol_count]
    call    rng_below
    mov     rcx, [mx_symbols]
    mov     r13, [rcx + rax * 8]
.color:
    RNG_BITS53
    cmp     rax, [mx_color_swap]
    jae     .chosen
    call    rain_choice
    mov     r14, rax
.chosen:
    test    r13, r13
    jnz     .compare
    cmp     r14, NONE
    je      .next
.compare:
    mov     rax, [rbx + CO_VIS]
    mov     r15d, [rax + r12 * 4]
    mov     rax, [ch_handle]
    mov     eax, [rax + r15 * 4]
    call    visual_meta
    mov     rsi, [rax + VH_SYMBOL]
    mov     rdx, [rax + VH_FG]
    xor     ebp, ebp                    ; nonzero once something differs
    test    r13, r13
    jz      .same_symbol
    cmp     r13, rsi
    setne   bpl
    mov     rsi, r13
.same_symbol:
    cmp     r14, NONE
    je      .same_color
    cmp     r14, rdx
    setne   al
    or      bpl, al
    mov     rdx, r14
.same_color:
    test    ebp, ebp
    jz      .next
    mov     edi, r15d
    mov     rcx, NONE
    call    set_appearance
.next:
    inc     r12d
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

; column_ptr(eax=index) -> rax = record.
%macro COLUMN_PTR 0
    shl     rax, CO_SHIFT
    add     rax, [mx_columns]
%endmacro

; pending_pop -> eax = pending_columns.pop(0). Clobbers rcx, rdx.
pending_pop:
    mov     rcx, [mx_pending]
    mov     rdx, [mx_pending_head]
    mov     eax, [rcx + rdx * 4]
    inc     rdx
    cmp     rdx, [mx_column_count]
    jb      .keep
    xor     edx, edx
.keep:
    mov     [mx_pending_head], rdx
    dec     qword [mx_pending_count]
    ret

; pending_push(edi=column index). Clobbers rax, rcx, rdx.
pending_push:
    mov     rax, [mx_pending_head]
    add     rax, [mx_pending_count]
    cmp     rax, [mx_column_count]
    jb      .put
    sub     rax, [mx_column_count]
.put:
    mov     rcx, [mx_pending]
    mov     [rcx + rax * 4], edi
    inc     qword [mx_pending_count]
    ret

; activate_pending: active_columns.append(pending_columns.pop(0)).
activate_pending:
    call    pending_pop
    mov     rcx, [mx_active]
    mov     rdx, [mx_active_count]
    mov     [rcx + rdx * 4], eax
    inc     qword [mx_active_count]
    ret

; retain_visible(rdi=u32 column list, rsi=count) -> rax = new count: keep
; the columns that still have visible characters, in order.
retain_visible:
    xor     eax, eax
    xor     ecx, ecx
.each:
    cmp     rcx, rsi
    jae     .done
    mov     edx, [rdi + rcx * 4]
    mov     r8, rdx
    shl     r8, CO_SHIFT
    add     r8, [mx_columns]
    mov     r9d, [r8 + CO_VEND]
    cmp     r9d, [r8 + CO_VSTART]
    je      .drop
    mov     [rdi + rax * 4], edx
    inc     rax
    jmp     .next
.drop:
    mov     byte [r8 + CO_IN_FULL], 0
.next:
    inc     rcx
    jmp     .each
.done:
    ret

; matrix_next_frame -> eax: Matrix::next_frame.
matrix_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [mx_phase], MX_RESOLVE
    je      .resolve
    ; columns join the rain
    cmp     qword [mx_column_delay], 0
    jne     .column_wait
    cmp     qword [mx_phase], MX_RAIN
    jne     .fill_all
    mov     edi, 1
    mov     esi, 3
    call    rng_randint
    mov     r12, rax
.join:
    test    r12, r12
    jle     .joined
    cmp     qword [mx_pending_count], 0
    je      .join_next
    call    activate_pending
.join_next:
    dec     r12
    jmp     .join
.joined:
    mov     rax, [effect_config]
    mov     rdi, [rax + matrix_config.column_min]
    mov     rsi, [rax + matrix_config.column_max]
    call    rng_randint
    mov     [mx_column_delay], rax
    jmp     .tick_active
.fill_all:
    cmp     qword [mx_pending_count], 0
    je      .fill_joined
    call    activate_pending
    jmp     .fill_all
.fill_joined:
    mov     qword [mx_column_delay], 1
    jmp     .tick_active
.column_wait:
    dec     qword [mx_column_delay]
.tick_active:
    xor     r12d, r12d
    mov     r13, [mx_active_count]
.active:
    cmp     r12, r13
    jae     .active_done
    mov     rax, [mx_active]
    mov     eax, [rax + r12 * 4]
    mov     ebx, eax
    COLUMN_PTR
    mov     rdi, rax
    call    column_tick
    mov     eax, ebx
    COLUMN_PTR
    mov     ecx, [rax + CO_PEND]
    cmp     rcx, [rax + CO_LEN]
    jb      .active_next
    cmp     dword [rax + CO_PHASE], MX_FILL
    jne     .maybe_reset
    cmp     byte [rax + CO_IN_FULL], 0
    jne     .maybe_reset
    mov     byte [rax + CO_IN_FULL], 1
    mov     rcx, [mx_full]
    mov     rdx, [mx_full_count]
    mov     [rcx + rdx * 4], ebx
    inc     qword [mx_full_count]
    jmp     .active_next
.maybe_reset:
    mov     ecx, [rax + CO_VEND]
    cmp     ecx, [rax + CO_VSTART]
    jne     .active_next
    mov     rdi, rax
    mov     esi, [mx_phase]             ; column_phase_for (rain or fill)
    call    setup_column
    mov     edi, ebx
    call    pending_push
.active_next:
    inc     r12
    jmp     .active
.active_done:
    mov     rdi, [mx_active]
    mov     rsi, [mx_active_count]
    call    retain_visible
    mov     [mx_active_count], rax
    ; fill done: every column is full
    cmp     qword [mx_phase], MX_FILL
    jne     .deadline
    cmp     qword [mx_pending_count], 0
    jne     .deadline
    xor     r12d, r12d
.all_full:
    cmp     r12, [mx_active_count]
    jae     .to_resolve
    mov     rax, [mx_active]
    mov     eax, [rax + r12 * 4]
    COLUMN_PTR
    mov     ecx, [rax + CO_PEND]
    cmp     rcx, [rax + CO_LEN]
    jb      .deadline
    cmp     dword [rax + CO_PHASE], MX_FILL
    jne     .deadline
    inc     r12
    jmp     .all_full
.to_resolve:
    mov     qword [mx_phase], MX_RESOLVE
    mov     qword [mx_active_count], 0
.deadline:
    ; effect_matrix.py:549 - the rain deadline on the wall clock
    cmp     qword [mx_phase], MX_RAIN
    jne     .emit
    mov     rax, [effect_config]
    cmp     qword [rax + matrix_config.rain_time], 0
    jle     .emit
    call    clock_wall
    subsd   xmm0, [mx_rain_start]
    comisd  xmm0, [mx_rain_time]
    jbe     .emit
    mov     byte [mx_rain_complete], 1
    mov     qword [mx_phase], MX_FILL
    xor     r12d, r12d
.drain_active:
    cmp     r12, [mx_active_count]
    jae     .fill_pending
    mov     rax, [mx_active]
    mov     eax, [rax + r12 * 4]
    COLUMN_PTR
    mov     qword [rax + CO_HOLD], 0
    mov     rcx, [mx_one]
    mov     [rax + CO_DROP], rcx
    inc     r12
    jmp     .drain_active
.fill_pending:
    xor     r12d, r12d
.fill_each:
    cmp     r12, [mx_pending_count]
    jae     .emit
    mov     rax, [mx_pending_head]
    add     rax, r12
    cmp     rax, [mx_column_count]
    jb      .fill_index
    sub     rax, [mx_column_count]
.fill_index:
    mov     rcx, [mx_pending]
    mov     eax, [rcx + rax * 4]
    COLUMN_PTR
    mov     rdi, rax
    mov     esi, MX_FILL
    call    setup_column
    inc     r12
    jmp     .fill_each

.resolve:
    xor     r12d, r12d
    mov     r13, [mx_full_count]
.full:
    cmp     r12, r13
    jae     .full_done
    mov     rax, [mx_full]
    mov     eax, [rax + r12 * 4]
    COLUMN_PTR
    mov     rbx, rax
    mov     rdi, rax
    call    column_tick
    mov     eax, [rbx + CO_VEND]
    cmp     eax, [rbx + CO_VSTART]
    je      .full_next
    cmp     qword [mx_resolve_delay], 0
    jne     .resolve_wait
    mov     edi, 1
    mov     esi, 4
    call    rng_randint
    push    r14
    push    r15
    mov     r14, rax
.resolve_each:
    test    r14, r14
    jle     .resolved
    mov     eax, [rbx + CO_VEND]
    cmp     eax, [rbx + CO_VSTART]
    je      .resolve_next
    call    resolve_char
    mov     r15d, eax
    mov     rcx, [ch_sym]
    mov     rcx, [rcx + r15 * 8]
    mov     rdx, (1 << 32) | ' '
    cmp     rcx, rdx
    jne     .activate
    mov     rcx, [ch_fg]
    cmp     qword [rcx + r15 * 8], NONE
    jne     .activate
    mov     rcx, [ch_bg]
    cmp     qword [rcx + r15 * 8], NONE
    jne     .activate
    mov     edi, r15d
    xor     esi, esi
    call    set_visibility
    jmp     .resolve_next
.activate:
    mov     edi, r15d
    mov     esi, MX_SCENE_RESOLVE
    call    scene_activate_name
    mov     edi, r15d
    call    active_insert
.resolve_next:
    dec     r14
    jmp     .resolve_each
.resolved:
    pop     r15
    pop     r14
    mov     rax, [effect_config]
    mov     rax, [rax + matrix_config.resolve_delay]
    mov     [mx_resolve_delay], rax
    jmp     .full_next
.resolve_wait:
    dec     qword [mx_resolve_delay]
.full_next:
    inc     r12
    jmp     .full
.full_done:
    mov     rdi, [mx_full]
    mov     rsi, [mx_full_count]
    call    retain_visible
    mov     [mx_full_count], rax

.emit:
    cmp     qword [mx_full_count], 0
    jne     .frame
    cmp     qword [mx_active_count], 0
    jne     .frame
    cmp     qword [mx_pending_count], 0
    jne     .frame
    cmp     byte [mx_rain_complete], 0
    je      .frame
    call    active_empty
    test    eax, eax
    jz      .frame
    cmp     byte [mx_final_shown], 0
    jne     .finished
    mov     byte [mx_final_shown], 1
.frame:
    call    update
    mov     eax, 1
    pop     r13
    pop     r12
    pop     rbx
    ret
.finished:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
mx_six:         dq 6
mx_eight:       dq 8
mx_tenth:       dq 0.1
mx_fade:        dq 0.65
mx_drop_chance: dq 0.08
mx_one:         dq 1.0
STR msg_mx_bounds, "max_row and max_column must be greater than 0."
STR msg_mx_order, "min_row and min_column must be less than or equal to max_row and max_column."

section .tstate
alignb 8
mx_highlight:       resq 1
mx_symbols:         resq 1
mx_symbol_count:    resq 1
mx_rain:            resq 1
mx_rain_len:        resq 1
mx_rain_time:       resq 1              ; f64
mx_rain_start:      resq 1              ; f64
mx_symbol_swap:     resq 1              ; rng_threshold of symbol_swap_chance
mx_color_swap:      resq 1              ; rng_threshold of color_swap_chance
mx_columns:         resq 1
mx_column_count:    resq 1
mx_pending:         resq 1
mx_pending_head:    resq 1
mx_pending_count:   resq 1
mx_active:          resq 1
mx_active_count:    resq 1
mx_full:            resq 1
mx_full_count:      resq 1
mx_column_delay:    resq 1
mx_resolve_delay:   resq 1
mx_phase:           resq 1
mx_pair:            resq 2
mx_fg_spectrum:     resq 16
mx_bg_spectrum:     resq 16
mx_rain_complete:   resb 1
mx_final_shown:     resb 1
