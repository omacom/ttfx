; effects/smoke.asm - "Smoke floods the canvas colorizing any text it
; crosses" (src/effects/smoke.rs).
;
; RNG order is SmokeIterator.__init__'s: PrimsWeighted (starting coord and
; one weight per character), the BreadthFirst starting coord, then build()
; runs PrimsWeighted to completion. next_frame draws nothing; the flood
; follows BreadthFirst layers over the generated tree.

struc SMOKE
    .starting_color:    resq 1
    .smoke_symbols:     resq 1          ; *const u64 packed symbols
    .smoke_symbol_count: resq 1
    .smoke_stops:       resq 1          ; *const u64
    .smoke_stop_count:  resq 1
    .whole_canvas:      resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define SMK_PAINT           NAME_LITERAL + 0
%define SMK_SMOKE           NAME_LITERAL + 1

section .text

; smoke_build: SmokeIterator.__init__ + build().
smoke_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    xor     r12d, r12d
    cmp     qword [rbx + SMOKE.whole_canvas], 0
    sete    r12b                        ; limit to the text boundary
    mov     edi, r12d
    call    pw_new
    ; the fill start: a random coord's character, else BreadthFirst's own draw
    xor     edi, edi
    mov     esi, r12d
    call    canvas_random_coord
    mov     rsi, rax
    call    char_at_input_coord
    mov     edi, eax
    mov     esi, r12d
    call    bf_new
    ; the final gradient over the text rectangle
    call    smk_final_map
    ; smoke gradient: smoke stops then the final stops reversed, steps (3, 4)
    mov     rax, [rbx + SMOKE.smoke_stop_count]
    add     rax, [rbx + SMOKE.final_stop_count]
    mov     [smk_smoke_stop_count], rax
    lea     rdi, [rax * 8]
    call    alloc
    mov     [smk_smoke_stops], rax
    mov     rdi, rax
    mov     rsi, [rbx + SMOKE.smoke_stops]
    mov     rcx, [rbx + SMOKE.smoke_stop_count]
    rep     movsq
    mov     rcx, [rbx + SMOKE.final_stop_count]
    mov     rsi, [rbx + SMOKE.final_stops]
.reverse:
    mov     rax, [rsi + rcx * 8 - 8]
    mov     [rdi], rax
    add     rdi, 8
    dec     rcx
    jnz     .reverse
    lea     rdi, [smk_three_four]
    mov     ecx, 2
    mov     rsi, [smk_smoke_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [smk_smoke_spectrum], rax
    mov     rdi, [smk_smoke_stops]
    mov     rsi, [smk_smoke_stop_count]
    lea     rdx, [smk_three_four]
    mov     ecx, 2
    mov     r8, [smk_smoke_spectrum]
    call    gradient_new
    mov     [smk_smoke_len], rax
    ; paint gradient stops: the final stops then the character's final color
    mov     rax, [rbx + SMOKE.final_stop_count]
    inc     rax
    mov     [smk_paint_stop_count], rax
    lea     rdi, [rax * 8]
    call    alloc
    mov     [smk_paint_stops], rax
    mov     rdi, rax
    mov     rsi, [rbx + SMOKE.final_stops]
    mov     rcx, [rbx + SMOKE.final_stop_count]
    rep     movsq
    lea     rdi, [smk_five]
    mov     ecx, 1
    mov     rsi, [smk_paint_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [smk_paint_spectrum], rax
    ; every input and fill character, top to bottom, left to right
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     r13d, r13d
.character:
    cmp     r13, r15
    jae     .generate
    mov     edi, [r14 + r13 * 4]
    call    smk_character
    inc     r13
    jmp     .character
.generate:
    call    pw_run
    ; the starting character is never 'explored': start it by hand
    mov     edi, [bf_start]
    mov     esi, SMK_SMOKE
    call    scene_activate_name
    mov     edi, [bf_start]
    call    active_insert
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; smk_character(edi=slot): one character's paint and smoke scenes, the
; smoke -> paint event and its starting appearance.
smk_character:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    call    set_visible
    ; final colors (r12 fg, r13 bg) and base colors (r14 fg; bg is none)
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     r12, [rax + rbx * 8]
    mov     rax, [ch_bg]
    mov     r13, [rax + rbx * 8]
    xor     r14d, r14d                  ; 000000
    jmp     .paint
.mapped:
    xor     r12d, r12d                  ; black outside the text rectangle
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbx * 4]
    cmp     rax, [text_bottom]
    jl      .outside
    cmp     rax, [text_top]
    jg      .outside
    cmp     rcx, [text_left]
    jl      .outside
    cmp     rcx, [text_right]
    jg      .outside
    sub     rax, [text_bottom]
    imul    rax, [smk_map_width]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [smk_map]
    mov     r12, [rcx + rax * 8]
.outside:
    mov     r13, NONE
    mov     rax, [effect_config]
    mov     r14, [rax + SMOKE.starting_color]
.paint:
    mov     edi, ebx
    mov     esi, SMK_PAINT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    cmp     qword [cfg_existing_colors], 1
    jne     .paint_gradient
    mov     edi, ebp
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 5
    mov     rcx, r12
    mov     r8, r13
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .smoke
.paint_gradient:
    ; Gradient(*final stops, final fg, steps=5) over the input symbol: a
    ; frame per color, the visuals shared by symbol and final fg
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbx * 8]
    mov     rsi, r12
    mov     rdx, NONE
    call    visual_run_find
    test    rax, rax
    jnz     .paint_frames
    mov     rax, [smk_paint_stop_count]
    mov     rcx, [smk_paint_stops]
    mov     [rcx + rax * 8 - 8], r12
    mov     rdi, rcx
    mov     rsi, rax
    lea     rdx, [smk_five]
    mov     ecx, 1
    mov     r8, [smk_paint_spectrum]
    call    gradient_new
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbx * 8]
    mov     rsi, [smk_paint_spectrum]
    mov     edx, eax
    mov     rcx, NONE
    mov     r8, r12
    call    visual_run
.paint_frames:
    mov     edi, ebp
    mov     rsi, rax
    mov     ecx, 5
    call    visual_frames
.smoke:
    mov     edi, ebx
    mov     esi, SMK_SMOKE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     rax, [effect_config]
    cmp     qword [cfg_existing_colors], 1
    jne     .smoke_gradient
    xor     r15d, r15d
.smoke_frame:
    mov     rax, [effect_config]
    cmp     r15, [rax + SMOKE.smoke_symbol_count]
    jae     .event
    mov     rsi, [rax + SMOKE.smoke_symbols]
    mov     rsi, [rsi + r15 * 8]
    mov     edi, ebp
    mov     edx, 10
    mov     rcx, r12
    mov     r8, r13
    xor     r9d, r9d
    call    scene_add_frame
    inc     r15
    jmp     .smoke_frame
.smoke_gradient:
    ; the same frames for every character: the first one's, copied, unless
    ; either scene applies preexisting colors
    mov     ecx, ebp
    shl     rcx, SCENE_SHIFT
    add     rcx, [scenes]
    test    dword [rcx + SC_FLAGS], SCF_PREEXISTING | SCF_PRE_BOLD
    jnz     .smoke_apply
    mov     edx, [smk_smoke_template]
    test    edx, edx
    jz      .smoke_first
    dec     edx
    shl     rdx, SCENE_SHIFT
    add     rdx, [scenes]
    mov     edi, ebp
    mov     rsi, [rdx + SC_FRAMES]
    mov     edx, [rdx + SC_COUNT]
    call    scene_append_frames
    jmp     .event
.smoke_first:
    lea     ecx, [rbp + 1]
    mov     [smk_smoke_template], ecx
.smoke_apply:
    push    0
    push    0
    mov     edi, ebp
    mov     rsi, [rax + SMOKE.smoke_symbols]
    mov     rdx, [rax + SMOKE.smoke_symbol_count]
    mov     ecx, 3
    mov     r8, [smk_smoke_spectrum]
    mov     r9, [smk_smoke_len]
    call    scene_apply_gradient
    add     rsp, 16
.event:
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, SMK_SMOKE
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, SMK_PAINT
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    xor     esi, esi
    mov     rdx, r14
    mov     rcx, NONE
    call    set_appearance
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; smk_final_map: Gradient::new(final stops, final steps) mapped over the
; text rectangle.
smk_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SMOKE.final_steps]
    mov     rcx, [rbx + SMOKE.final_step_count]
    mov     rsi, [rbx + SMOKE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [smk_final_spectrum], rax
    mov     rdi, [rbx + SMOKE.final_stops]
    mov     rsi, [rbx + SMOKE.final_stop_count]
    mov     rdx, [rbx + SMOKE.final_steps]
    mov     rcx, [rbx + SMOKE.final_step_count]
    mov     r8, [smk_final_spectrum]
    call    gradient_new
    mov     rdi, [smk_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [smk_map_width], rax
    push    qword [rbx + SMOKE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [smk_map], rax
    pop     rbx
    ret

; smoke_next_frame -> eax = 1 for a frame, 0 when done.
smoke_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     byte [bf_complete], 0
    je      .flood
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .tick
.flood:
    call    bf_step
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.explored:
    cmp     rbx, r13
    jae     .tick
    mov     edi, [r12 + rbx * 4]
    mov     esi, SMK_SMOKE
    call    scene_activate_name
    mov     edi, [r12 + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .explored
.tick:
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
smk_three_four:     dq 3, 4
smk_five:           dq 5

section .tstate
smk_smoke_template: resd 1          ; scene + 1 whose frames every smoke scene copies
alignb 8
smk_map:                resq 1
smk_map_width:          resq 1
smk_final_spectrum:     resq 1
smk_smoke_stops:        resq 1
smk_smoke_stop_count:   resq 1
smk_smoke_spectrum:     resq 1
smk_smoke_len:          resq 1
smk_paint_stops:        resq 1
smk_paint_stop_count:   resq 1
smk_paint_spectrum:     resq 1
