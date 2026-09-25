; effects/sweep.asm - "Sweep across the canvas to reveal uncolored text,
; reverse sweep to color the text" (src/effects/sweep.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Sweep).
;
; Every character (input and fill) gets an initial_sweep and a second_sweep
; scene, created in top-to-bottom, left-to-right order so the RNG draws line
; up. A SequenceEaser (in_out_circ, 100 steps) walks the first sweep's groups,
; then the second's.

struc SWEEP
    .symbols:           resq 1          ; *const u64 packed sweep symbols
    .symbol_count:      resq 1
    .first_direction:   resq 1          ; GROUP_*
    .second_direction:  resq 1          ; GROUP_*
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define SW_INITIAL      NAME_LITERAL + 0
%define SW_SECOND       NAME_LITERAL + 1
%define SW_GRAY_COUNT   5
%define SW_IN_OUT_CIRC  21

; ch_user0: the initial_sweep scene (low half) and second_sweep (high half)

section .text

; sweep_build: Sweep::build.
sweep_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     ; [rsp] final fg, [rsp+8] final bg
    mov     rbx, [effect_config]
    call    sw_final_color_map
    ; the second sweep's palette: the spectrum, or the input colors (dynamic)
    mov     rax, [sw_spectrum]
    mov     [sw_palette], rax
    mov     rax, [sw_spectrum_len]
    mov     [sw_palette_len], rax
    cmp     qword [cfg_existing_colors], 1
    jne     .memos
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    lea     rdi, [rdx * 8 + 8]
    shl     rdi, 1
    call    alloc
    mov     r14, rax
    xor     r15d, r15d                  ; palette length
    xor     ebp, ebp
.palette:
    cmp     rbp, r13
    jae     .palette_done
    mov     edi, [r12 + rbp * 4]
    mov     rax, [ch_fg]
    mov     rax, [rax + rdi * 8]
    cmp     rax, NONE
    je      .palette_bg
    mov     [r14 + r15 * 8], rax
    inc     r15
.palette_bg:
    mov     rax, [ch_bg]
    mov     rax, [rax + rdi * 8]
    cmp     rax, NONE
    je      .palette_next
    mov     [r14 + r15 * 8], rax
    inc     r15
.palette_next:
    inc     rbp
    jmp     .palette
.palette_done:
    test    r15, r15
    jz      .memos
    mov     [sw_palette], r14
    mov     [sw_palette_len], r15
.memos:
    ; memos of (symbol, color index) -> handle for both sweeps
    mov     rdi, [rbx + SWEEP.symbol_count]
    imul    rdi, rdi, SW_GRAY_COUNT * 4
    call    alloc
    mov     [sw_gray_memo], rax
    mov     rdi, [rbx + SWEEP.symbol_count]
    imul    rdi, [sw_palette_len]
    shl     rdi, 2
    call    alloc
    mov     [sw_color_memo], rax
    ; the scenes, per character in top-to-bottom, left-to-right order
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [rsp + 16], rdx
    mov     r12, rax
    xor     r13d, r13d
.char:
    cmp     r13, [rsp + 16]
    jae     .groups
    mov     ebp, [r12 + r13 * 4]        ; slot
    ; the final colors
    mov     rax, [ch_flags]
    test    word [rax + rbp * 2], CF_FILL
    jnz     .fill
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     rax, [rax + rbp * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rbp * 8]
    jmp     .colors
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [sw_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [sw_map]
    mov     rax, [rcx + rax * 8]
    mov     rcx, NONE
    jmp     .colors
.fill:
    mov     rax, NONE
    mov     rcx, rax
    cmp     qword [cfg_existing_colors], 1
    je      .colors
    xor     eax, eax                    ; 000000
.colors:
    mov     [rsp], rax
    mov     [rsp + 8], rcx
    ; initial_sweep: the symbols in random grays, then the symbol in 808080
    mov     edi, ebp
    mov     esi, SW_INITIAL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    xor     r15d, r15d
.gray:
    cmp     r15, [rbx + SWEEP.symbol_count]
    jae     .gray_done
    mov     edi, SW_GRAY_COUNT
    call    rng_below
    mov     rdi, [sw_gray_memo]
    lea     rsi, [sw_grays]
    mov     edx, SW_GRAY_COUNT
    call    sw_memo_visual
    mov     esi, eax
    mov     edi, r14d
    mov     edx, 5
    call    scene_add_frame_visual
    inc     r15
    jmp     .gray
.gray_done:
    mov     edi, r14d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     ecx, 0x808080
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    ; second_sweep: the symbols in random palette colors, then the final look
    mov     edi, ebp
    mov     esi, SW_SECOND
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     rcx, [ch_user0]
    mov     [rcx + rbp * 8], r14d
    mov     [rcx + rbp * 8 + 4], eax
    mov     r14d, eax
    xor     r15d, r15d
.color:
    cmp     r15, [rbx + SWEEP.symbol_count]
    jae     .color_done
    mov     rdi, [sw_palette_len]
    call    rng_below
    mov     rdi, [sw_color_memo]
    mov     rsi, [sw_palette]
    mov     rdx, [sw_palette_len]
    call    sw_memo_visual
    mov     esi, eax
    mov     edi, r14d
    mov     edx, 5
    call    scene_add_frame_visual
    inc     r15
    jmp     .color
.color_done:
    mov     edi, r14d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     rcx, [rsp]
    mov     r8, [rsp + 8]
    xor     r9d, r9d
    call    scene_add_frame
    inc     r13
    jmp     .char
.groups:
    mov     rsi, [rbx + SWEEP.first_direction]
    call    sw_group_sequence
    mov     [sw_seq_first], rax
    mov     [sw_seq_first_len], rdx
    mov     rsi, [rbx + SWEEP.second_direction]
    call    sw_group_sequence
    mov     [sw_seq_second], rax
    mov     [sw_seq_second_len], rdx
    lea     rdi, [sw_easer]
    mov     rsi, [sw_seq_first]
    mov     rdx, [sw_seq_first_len]
    mov     ecx, SW_IN_OUT_CIRC
    mov     r8d, 100
    call    sequence_easer_new
    mov     byte [sw_first_phase], 1
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sw_memo_visual(eax=color index, rdi=memo, rsi=colors, rdx=color count;
; r15 = symbol index) -> eax = the (symbol, color) visual, no bg, no attrs.
sw_memo_visual:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    imul    rdx, r15
    lea     r12, [rdx + rax]            ; memo index
    mov     edx, [rbx + r12 * 4]
    test    edx, edx
    jnz     .hit
    mov     rdi, [rsi + rax * 8]
    mov     rcx, [effect_config]
    mov     rcx, [rcx + SWEEP.symbols]
    mov     rdx, [rcx + r15 * 8]
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     [rbx + r12 * 4], eax
    mov     edx, eax
.hit:
    mov     eax, edx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; sw_group_sequence(rsi=GROUP_*) -> rax = u64 array of group record
; pointers, rdx = count: get_characters_grouped(fills filter, direction) in
; the form SequenceEaser takes.
sw_group_sequence:
    push    rbx
    push    r12
    push    r13
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    call    get_characters_grouped
    mov     r12, rax
    mov     r13, rdx
    lea     rdi, [rdx * 8 + 8]
    call    alloc
    xor     ecx, ecx
.group:
    cmp     rcx, r13
    jae     .done
    mov     rdx, rcx
    shl     rdx, 4
    add     rdx, r12
    mov     [rax + rcx * 8], rdx
    inc     rcx
    jmp     .group
.done:
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; sw_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
sw_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SWEEP.final_steps]
    mov     rcx, [rbx + SWEEP.final_step_count]
    mov     rsi, [rbx + SWEEP.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [sw_spectrum], rax
    mov     rdi, [rbx + SWEEP.final_stops]
    mov     rsi, [rbx + SWEEP.final_stop_count]
    mov     rdx, [rbx + SWEEP.final_steps]
    mov     rcx, [rbx + SWEEP.final_step_count]
    mov     r8, [sw_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [sw_spectrum_len], rax
    mov     rdi, [sw_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [sw_map_width], rax
    push    qword [rbx + SWEEP.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [sw_map], rax
    pop     rbx
    ret

; sweep_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
sweep_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     byte [sw_complete], 0
    je      .step
    call    active_empty
    test    eax, eax
    jnz     .finished
.step:
    lea     rdi, [sw_easer]
    call    sequence_easer_step
    mov     r12, [rax + SequenceStep.added]
    mov     r13, [rax + SequenceStep.added_count]
    xor     r14d, r14d
.group:
    cmp     r14, r13
    jae     .stepped
    mov     rax, [r12 + r14 * 8]
    mov     rbx, [rax]                  ; slots
    mov     r15, [rax + 8]              ; count
    xor     ebp, ebp
.activate:
    cmp     rbp, r15
    jae     .insert
    mov     edi, [rbx + rbp * 4]
    cmp     byte [sw_first_phase], 0
    je      .second
    call    set_visible
    mov     edi, [rbx + rbp * 4]
    mov     rax, [ch_user0]
    mov     esi, [rax + rdi * 8]        ; initial_sweep
    jmp     .scene
.second:
    mov     rax, [ch_user0]
    mov     esi, [rax + rdi * 8 + 4]    ; second_sweep
.scene:
    call    scene_activate
    inc     rbp
    jmp     .activate
.insert:
    xor     ebp, ebp
.insert_next:
    cmp     rbp, r15
    jae     .next_group
    mov     edi, [rbx + rbp * 4]
    call    active_insert
    inc     rbp
    jmp     .insert_next
.next_group:
    inc     r14
    jmp     .group
.stepped:
    lea     rdi, [sw_easer]
    call    sequence_easer_is_complete
    test    eax, eax
    jz      .tick
    cmp     byte [sw_first_phase], 0
    je      .done_sweeping
    ; the second sweep takes over the easer
    lea     rdi, [sw_easer]
    mov     rax, [sw_seq_second]
    mov     [rdi + SequenceEaser.sequence], rax
    mov     rax, [sw_seq_second_len]
    mov     [rdi + SequenceEaser.length], rax
    call    sequence_easer_reset
    mov     byte [sw_first_phase], 0
    jmp     .tick
.done_sweeping:
    mov     byte [sw_complete], 1
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

section .rodata
align 8
; A0A0A0, 808080, 404040, 202020, 101010
sw_grays:       dq 0xa0a0a0, 0x808080, 0x404040, 0x202020, 0x101010

section .tstate
alignb 8
sw_easer:           resb SequenceEaser_size
sw_spectrum:        resq 1
sw_spectrum_len:    resq 1
sw_map:             resq 1
sw_map_width:       resq 1
sw_palette:         resq 1
sw_palette_len:     resq 1
sw_gray_memo:       resq 1
sw_color_memo:      resq 1
sw_seq_first:       resq 1
sw_seq_first_len:   resq 1
sw_seq_second:      resq 1
sw_seq_second_len:  resq 1
sw_first_phase:     resb 1
sw_complete:        resb 1
