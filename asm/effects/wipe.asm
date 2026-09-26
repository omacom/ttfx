; effects/wipe.asm - "Performs a wipe across the terminal to reveal
; characters" (src/effects/wipe.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Wipe).
;
; The groups from get_characters_grouped are 16-byte records, but the
; SequenceEaser works over u64 elements. It is handed the group array with
; the group count as its length: only its pointer arithmetic is used, so an
; element offset e maps to the group record at groups + 2 * e.
;
; ch_user0 holds each character's "wipe" scene index.

struc WIPE
    .direction:         resq 1          ; CharacterGroup (GROUP_*)
    .delay:             resq 1
    .ease:              resq 1          ; easing id
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_frames:      resq 1          ; fits i32 (marshal checks)
    .final_direction:   resq 1
endstruc

%define WIPE_SCENE          NAME_LITERAL + 0

section .text

; wipe_build: Wipe::build.
wipe_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [effect_config]
    mov     edi, FILTER_INPUT
    mov     esi, [rbx + WIPE.direction]
    call    get_characters_grouped
    mov     [wipe_groups], rax
    lea     rdi, [wipe_easer]
    mov     rsi, rax
    mov     ecx, [rbx + WIPE.ease]
    mov     r8d, 100
    call    sequence_easer_new
    call    wipe_final_map
    ; the per-character wipe gradient: spectrum[0] -> the final color
    mov     rdi, [rbx + WIPE.final_steps]
    mov     rcx, [rbx + WIPE.final_step_count]
    mov     esi, 2
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [wipe_pair_spectrum], rax
    mov     rax, [wipe_spectrum]
    mov     rax, [rax]
    mov     [wipe_pair_stops], rax
    mov     qword [wipe_last_fg], NONE
    ; dynamic handling: sum(final steps) + 1 frames of the input colors
    mov     rcx, [rbx + WIPE.final_steps]
    mov     rdx, [rbx + WIPE.final_step_count]
    mov     eax, 1
.sum:
    test    rdx, rdx
    jz      .summed
    dec     rdx
    add     rax, [rcx + rdx * 8]
    jmp     .sum
.summed:
    mov     [wipe_dynamic_frames], rax
    mov     rax, [rbx + WIPE.delay]
    mov     [wipe_delay_left], rax
    ; one "wipe" scene per input character (no RNG, so order is free)
    mov     r12, [input_chars]
    mov     r13, [input_count]
    xor     ebp, ebp
.char:
    cmp     rbp, r13
    jae     .built
    mov     r15d, [r12 + rbp * 4]       ; slot
    mov     edi, r15d
    mov     esi, WIPE_SCENE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    mov     rcx, [ch_user0]
    mov     [rcx + r15 * 8], rax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; final fg from the coordinate map
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r15 * 4]
    sub     rax, [text_bottom]
    imul    rax, [wipe_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r15 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [wipe_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [wipe_last_fg]
    je      .gradient
    mov     [wipe_last_fg], rax
    mov     [wipe_pair_stops + 8], rax
    lea     rdi, [wipe_pair_stops]
    mov     esi, 2
    mov     rdx, [rbx + WIPE.final_steps]
    mov     rcx, [rbx + WIPE.final_step_count]
    mov     r8, [wipe_pair_spectrum]
    call    gradient_new
    mov     [wipe_pair_len], eax
.gradient:
    ; apply_gradient_to_symbols with one symbol and an fg gradient: one
    ; frame per spectrum color (the visuals shared by symbol and final color)
    push    rbp
    push    r13
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r15 * 8]
    mov     rsi, [wipe_pair_spectrum]
    mov     edx, [wipe_pair_len]
    mov     rcx, NONE
    mov     r8, [wipe_last_fg]
    call    visual_run
    mov     edi, r14d
    mov     rsi, rax
    mov     ecx, [rbx + WIPE.final_frames]
    call    visual_frames
    pop     r13
    pop     rbp
    inc     rbp
    jmp     .char
.dynamic:
    push    rbp
    push    r13
    mov     r13, [wipe_dynamic_frames]
.frame:
    test    r13, r13
    jle     .framed
    mov     rcx, [ch_fg]
    mov     rcx, [rcx + r15 * 8]
    mov     r8, [ch_bg]
    mov     r8, [r8 + r15 * 8]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r15 * 8]
    mov     edi, r14d
    mov     edx, [rbx + WIPE.final_frames]
    xor     r9d, r9d
    call    scene_add_frame
    dec     r13
    jmp     .frame
.framed:
    pop     r13
    pop     rbp
    inc     rbp
    jmp     .char
.built:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; wipe_final_map (rbx = config): Gradient::new(final stops, final steps) and
; its coordinate mapping over the text rectangle.
wipe_final_map:
    mov     rdi, [rbx + WIPE.final_steps]
    mov     rcx, [rbx + WIPE.final_step_count]
    mov     rsi, [rbx + WIPE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [wipe_spectrum], rax
    mov     rdi, [rbx + WIPE.final_stops]
    mov     rsi, [rbx + WIPE.final_stop_count]
    mov     rdx, [rbx + WIPE.final_steps]
    mov     rcx, [rbx + WIPE.final_step_count]
    mov     r8, [wipe_spectrum]
    call    gradient_new
    mov     rdi, [wipe_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [wipe_map_width], rax
    sub     rsp, 8
    push    qword [rbx + WIPE.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     [wipe_map], rax
    ret

; wipe_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
wipe_next_frame:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    active_empty
    test    eax, eax
    jz      .run
    lea     rdi, [wipe_easer]
    call    sequence_easer_is_complete
    test    eax, eax
    jnz     .finished
.run:
    mov     rax, [wipe_delay_left]
    test    rax, rax
    jz      .step
    dec     rax
    mov     [wipe_delay_left], rax
    jmp     .update
.step:
    lea     rdi, [wipe_easer]
    call    sequence_easer_step
    ; added groups: activate, reveal, track
    mov     rbx, [rax + SequenceStep.added]
    mov     r12, [rax + SequenceStep.added_count]
    call    wipe_group_record
.add_group:
    test    r12, r12
    jz      .added
    mov     r13, [rbx]                  ; slots
    mov     r14, [rbx + 8]              ; count
.add_char:
    test    r14, r14
    jz      .add_next
    mov     r15d, [r13]
    mov     edi, r15d
    mov     rax, [ch_user0]
    mov     esi, [rax + r15 * 8]
    call    scene_activate
    mov     edi, r15d
    call    set_visible
    mov     edi, r15d
    call    active_insert
    add     r13, 4
    dec     r14
    jmp     .add_char
.add_next:
    add     rbx, 16
    dec     r12
    jmp     .add_group
.added:
    ; removed groups: deactivate, rewind the scene, hide
    lea     rax, [wipe_easer + SequenceEaser.result]
    mov     rbx, [rax + SequenceStep.removed]
    mov     r12, [rax + SequenceStep.removed_count]
    call    wipe_group_record
.remove_group:
    test    r12, r12
    jz      .removed
    mov     r13, [rbx]
    mov     r14, [rbx + 8]
.remove_char:
    test    r14, r14
    jz      .remove_next
    mov     r15d, [r13]
    mov     edi, r15d
    mov     esi, NONE
    call    scene_deactivate
    mov     rax, [ch_user0]
    mov     edi, [rax + r15 * 8]
    call    scene_reset
    mov     edi, r15d
    xor     esi, esi
    call    set_visibility
    add     r13, 4
    dec     r14
    jmp     .remove_char
.remove_next:
    add     rbx, 16
    dec     r12
    jmp     .remove_group
.removed:
    mov     rax, [effect_config]
    mov     rax, [rax + WIPE.delay]
    mov     [wipe_delay_left], rax
.update:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; wipe_group_record: rbx = an easer element pointer -> the group record it
; stands for (groups + 2 * (element - groups)). Clobbers rax.
wipe_group_record:
    mov     rax, [wipe_groups]
    sub     rbx, rax
    lea     rbx, [rax + rbx * 2]
    ret

section .tstate
alignb 8
wipe_easer:             resb SequenceEaser_size
alignb 8
wipe_groups:            resq 1
wipe_spectrum:          resq 1
wipe_map:               resq 1
wipe_map_width:         resq 1
wipe_pair_stops:        resq 2
wipe_pair_spectrum:     resq 1
wipe_pair_len:          resq 1
wipe_last_fg:           resq 1
wipe_dynamic_frames:    resq 1
wipe_delay_left:        resq 1
