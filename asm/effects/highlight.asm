; effects/highlight.asm - "Run a specular highlight across the text"
; (src/effects/highlight.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Highlight). The effect draws no
; random numbers: its characters come in row/column order and its groups in
; grouping order.

struc HIGHLIGHT
    .brightness:        resq 1          ; f64
    .direction:         resq 1          ; GROUP_*
    .width:             resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define HL_SCENE            NAME_LITERAL + 0    ; "highlight"
%define HL_IN_OUT_CIRC      21

; ch_user0 holds each character's highlight scene index.

section .text

; highlight_build: Highlight::build.
highlight_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    ; groups in highlight direction, eased as a sequence of group indices
    mov     edi, FILTER_INPUT
    mov     rax, [effect_config]
    mov     esi, [rax + HIGHLIGHT.direction]
    call    get_characters_grouped
    mov     [hl_groups], rax
    mov     rbx, rdx
    lea     rdi, [rdx * 8 + 8]
    call    alloc
    xor     ecx, ecx
.index:
    cmp     rcx, rbx
    jae     .easer
    mov     [rax + rcx * 8], rcx
    inc     rcx
    jmp     .index
.easer:
    lea     rdi, [hl_easer]
    mov     rsi, rax
    mov     rdx, rbx
    mov     ecx, HL_IN_OUT_CIRC
    mov     r8d, 100
    call    sequence_easer_new
    ; the final gradient mapped over the text rectangle
    call    hl_final_color_map
    ; the highlight gradient: [base, bright, bright, base] in [3, width, 3]
    mov     rax, [effect_config]
    mov     rax, [rax + HIGHLIGHT.width]
    mov     qword [hl_steps], 3
    mov     [hl_steps + 8], rax
    mov     qword [hl_steps + 16], 3
    lea     rdi, [hl_steps]
    mov     ecx, 3
    mov     esi, 4
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [hl_spectrum], rax
    mov     qword [hl_last_base], NONE
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .built
    mov     ebp, [r12 + rbx * 4]
    cmp     qword [cfg_existing_colors], 1
    jne     .gradient
    ; dynamic: the input colors
    mov     rax, [ch_fg]
    mov     r14, [rax + rbp * 8]
    mov     rax, [ch_bg]
    mov     r15, [rax + rbp * 8]
    jmp     .colors
.gradient:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [hl_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [hl_final_map]
    mov     r14, [rcx + rax * 8]        ; base color
    mov     r15, NONE                   ; input bg color
.colors:
    cmp     r14, NONE
    je      .appearance
    cmp     r14, [hl_last_base]
    je      .appearance
    call    hl_highlight_gradient
.appearance:
    mov     edi, ebp
    xor     esi, esi
    mov     rdx, r14
    mov     rcx, r15
    call    set_appearance
    mov     edi, ebp
    mov     esi, HL_SCENE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     rcx, [ch_user0]
    mov     [rcx + rbp * 8], eax
    mov     [rsp], eax
    cmp     r14, NONE
    jne     .frames
    ; no base color: a single frame in the base colors
    mov     edi, eax
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 2
    mov     rcx, r14
    mov     r8, r15
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .visible
.frames:
    ; one frame per spectrum color, the visuals shared by symbol, base
    ; color (the spectrum's) and bg
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbp * 8]
    mov     rsi, [hl_spectrum]
    mov     rdx, [hl_spectrum_len]
    mov     rcx, r15
    mov     r8, r14
    call    visual_run
    mov     edi, [rsp]
    mov     rsi, rax
    mov     ecx, 2
    call    visual_frames
.visible:
    mov     edi, ebp
    mov     esi, 1
    call    set_visibility
    inc     rbx
    jmp     .char
.built:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; hl_highlight_gradient(r14=base color): Gradient::new([base, highlight,
; highlight, base], [3, width, 3]) into hl_spectrum, highlight being
; adjust_color_brightness(base, brightness). Remembers base in hl_last_base.
hl_highlight_gradient:
    mov     [hl_last_base], r14
    mov     rdi, r14
    mov     rax, [effect_config]
    movsd   xmm0, [rax + HIGHLIGHT.brightness]
    call    adjust_color_brightness
    mov     [hl_stops], r14
    mov     [hl_stops + 8], rax
    mov     [hl_stops + 16], rax
    mov     [hl_stops + 24], r14
    lea     rdi, [hl_stops]
    mov     esi, 4
    lea     rdx, [hl_steps]
    mov     ecx, 3
    mov     r8, [hl_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [hl_spectrum_len], rax
    ret

; hl_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
hl_final_color_map:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [effect_config]
    mov     rdi, [rbx + HIGHLIGHT.final_steps]
    mov     rcx, [rbx + HIGHLIGHT.final_step_count]
    mov     rsi, [rbx + HIGHLIGHT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + HIGHLIGHT.final_stops]
    mov     rsi, [rbx + HIGHLIGHT.final_stop_count]
    mov     rdx, [rbx + HIGHLIGHT.final_steps]
    mov     rcx, [rbx + HIGHLIGHT.final_step_count]
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
    mov     [hl_final_map_width], rax
    push    qword [rbx + HIGHLIGHT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [hl_final_map], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; highlight_next_frame -> eax = 1 for a frame, 0 when done.
highlight_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    active_empty
    test    eax, eax
    jz      .step
    lea     rdi, [hl_easer]
    call    sequence_easer_is_complete
    test    eax, eax
    jnz     .finished
.step:
    lea     rdi, [hl_easer]
    call    sequence_easer_step
    mov     r12, [rax + SequenceStep.added]
    mov     r13, [rax + SequenceStep.added_count]
.group:
    test    r13, r13
    jz      .update
    mov     rax, [r12]                  ; group index
    shl     rax, 4
    add     rax, [hl_groups]
    mov     r14, [rax]                  ; slots
    mov     r15, [rax + 8]              ; count
    xor     ebx, ebx
.member:
    cmp     rbx, r15
    jae     .next_group
    mov     ebp, [r14 + rbx * 4]
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8]
    call    scene_activate
    mov     edi, ebp
    call    active_insert
    inc     rbx
    jmp     .member
.next_group:
    add     r12, 8
    dec     r13
    jmp     .group
.update:
    call    update
    mov     eax, 1
    jmp     .done
.finished:
    xor     eax, eax
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .tstate
alignb 8
hl_easer:           resb SequenceEaser_size
hl_groups:          resq 1
hl_final_map:       resq 1
hl_final_map_width: resq 1
hl_spectrum:        resq 1
hl_spectrum_len:    resq 1
hl_last_base:       resq 1
hl_steps:           resq 3
hl_stops:           resq 4
