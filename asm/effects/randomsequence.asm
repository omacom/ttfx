; effects/randomsequence.asm - "Prints the input data in a random sequence"
; (src/effects/random_sequence.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Randomsequence):

struc RANDOMSEQUENCE
    .speed:             resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_frames:      resq 1          ; fits an i32 (marshal checks)
    .final_direction:   resq 1
endstruc

%define RS_FADE_LEN         8           ; Gradient::with_steps(2 stops, 7)
%define RS_SCENE            NAME_LITERAL + 0    ; new_scene(.., "")

section .text

; randomsequence_build: RandomSequence::build.
randomsequence_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    ; characters_per_tick = max(int(speed * len(input_characters)), 1)
    cvtsi2sd xmm0, qword [input_count]
    movsd   xmm1, [rbx + RANDOMSEQUENCE.speed]
    mulsd   xmm0, xmm1
    call    f64_to_i64
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [rs_per_tick], rax
    mov     rax, [request]
    mov     rax, [rax + RQ_BACKGROUND]
    mov     [rs_pair], rax              ; every fade starts at the background
    call    rs_final_color_map
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [rs_pending], rax           ; a fresh array: it becomes pending
    mov     [rs_pending_count], rdx
    mov     r12, rax
    mov     r13, rdx
    xor     r14d, r14d
.char:
    cmp     r14, r13
    jae     .shuffle
    mov     ebp, [r12 + r14 * 4]        ; slot
    mov     edi, ebp
    xor     esi, esi
    call    set_visibility
    mov     edi, ebp
    mov     esi, RS_SCENE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax                   ; scene
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; the final gradient's color at the input coordinate, faded in from
    ; the background
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [rs_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [rs_final_map]
    mov     rdi, [rcx + rax * 8]
    call    rs_fade
    mov     edi, r15d
    mov     esi, ebp
    mov     rdx, rax
    xor     ecx, ecx
    call    rs_add_fade
.activate:
    mov     edi, ebp
    mov     esi, r15d
    call    scene_activate
    inc     r14
    jmp     .char
.dynamic:
    ; ExistingColorHandling::Dynamic: fade to the input colors
    mov     rax, [ch_fg]
    mov     rax, [rax + rbp * 8]
    mov     [rsp], rax
    mov     rax, [ch_bg]
    mov     rdi, [rax + rbp * 8]
    cmp     rdi, NONE
    jne     .dyn_bg
    cmp     qword [rsp], NONE
    je      .neutral
    xor     edx, edx
    jmp     .dyn_fg
.dyn_bg:
    call    rs_fade
    lea     rdi, [rs_bg_fade]
    mov     ecx, RS_FADE_LEN
    mov     rsi, rax
    rep movsq
    lea     rdx, [rs_bg_fade]
.dyn_fg:
    xor     eax, eax
    mov     rdi, [rsp]
    cmp     rdi, NONE
    je      .dyn_apply
    push    rdx
    push    rdx
    call    rs_fade
    pop     rdx
    pop     rdx
.dyn_apply:
    mov     rcx, rdx                    ; bg fade or 0
    mov     rdx, rax                    ; fg fade or 0
    mov     edi, r15d
    mov     esi, ebp
    call    rs_add_fade
    jmp     .activate
.neutral:
    mov     edi, 0x808080               ; DYNAMIC_NEUTRAL_GRAY
    call    rs_fade
    mov     edi, r15d
    mov     esi, ebp
    mov     rdx, rax
    xor     ecx, ecx
    call    rs_add_fade
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     rdx, [effect_config]
    mov     edx, [rdx + RANDOMSEQUENCE.final_frames]
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .activate
.shuffle:
    mov     rdi, r12
    mov     rsi, r13
    call    rng_shuffle32
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rs_fade(rdi=color) -> rax = Gradient::with_steps([background, color], 7)
; spectrum (RS_FADE_LEN colors, in rs_fade_spectrum; reused by each call).
rs_fade:
    mov     [rs_pair + 8], rdi
    lea     rdi, [rs_pair]
    mov     esi, 2
    lea     rdx, [rs_seven]
    mov     ecx, 1
    lea     r8, [rs_fade_spectrum]
    call    gradient_new
    lea     rax, [rs_fade_spectrum]
    ret

; rs_add_fade(edi=scene, esi=slot, rdx=fg spectrum or 0, rcx=bg spectrum or
; 0): apply_gradient_to_symbols([input symbol], frames, fg, bg). Both
; spectra have RS_FADE_LEN colors, so the cyclic distribution pairs them
; index by index and gives each pair one frame of the single symbol.
rs_add_fade:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     rax, [ch_sym]
    mov     r12, [rax + rsi * 8]
    mov     r13, rdx
    mov     r14, rcx
    mov     rax, [effect_config]
    mov     r15d, [rax + RANDOMSEQUENCE.final_frames]
    xor     ebp, ebp
.frame:
    mov     rcx, NONE
    test    r13, r13
    jz      .bg
    mov     rcx, [r13 + rbp * 8]
.bg:
    mov     r8, NONE
    test    r14, r14
    jz      .add
    mov     r8, [r14 + rbp * 8]
.add:
    mov     edi, ebx
    mov     rsi, r12
    mov     edx, r15d
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    cmp     ebp, RS_FADE_LEN
    jb      .frame
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rs_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
rs_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + RANDOMSEQUENCE.final_steps]
    mov     rcx, [rbx + RANDOMSEQUENCE.final_step_count]
    mov     rsi, [rbx + RANDOMSEQUENCE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [rs_final_spectrum], rax
    mov     rdi, [rbx + RANDOMSEQUENCE.final_stops]
    mov     rsi, [rbx + RANDOMSEQUENCE.final_stop_count]
    mov     rdx, [rbx + RANDOMSEQUENCE.final_steps]
    mov     rcx, [rbx + RANDOMSEQUENCE.final_step_count]
    mov     r8, [rs_final_spectrum]
    call    gradient_new
    mov     rdi, [rs_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [rs_final_map_width], rax
    push    qword [rbx + RANDOMSEQUENCE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [rs_final_map], rax
    pop     rbx
    ret

; randomsequence_next_frame -> eax = 1 for a frame, 0 when done: reveal
; characters_per_tick characters from the end of the shuffled list.
randomsequence_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [rs_pending_count], 0
    jne     .tick
    call    active_empty
    test    eax, eax
    jnz     .finished
.tick:
    mov     r12, [rs_per_tick]
    mov     r13, [rs_pending]
.reveal:
    test    r12, r12
    jz      .update
    mov     rbx, [rs_pending_count]
    test    rbx, rbx
    jz      .update                     ; the remaining pops are no-ops
    dec     rbx
    mov     [rs_pending_count], rbx
    mov     edi, [r13 + rbx * 4]
    push    rdi
    call    set_visible
    pop     rdi
    call    active_insert
    dec     r12
    jmp     .reveal
.update:
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
rs_seven:           dq 7

section .tstate
alignb 8
rs_per_tick:        resq 1
rs_pending:         resq 1          ; u32 slots, popped from the end
rs_pending_count:   resq 1
rs_final_spectrum:  resq 1
rs_final_map:       resq 1
rs_final_map_width: resq 1
rs_pair:            resq 2
rs_fade_spectrum:   resq 16
rs_bg_fade:         resq RS_FADE_LEN
