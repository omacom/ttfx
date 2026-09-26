; effects/waves.asm - "Waves travel across the terminal leaving behind the
; characters" (src/effects/waves.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Waves).
;
; Every character gets an eased "wave" scene (auto id 0) and a "final" scene
; (auto id 1), activated by the wave's SCENE_COMPLETE. The wave scene is the
; same frame list for every character: the first character whose scene has no
; preexisting colors builds it with apply_gradient_to_symbols, exactly as Rust,
; and the others copy its frames (visual handle, duration) straight from it.
; No RNG is drawn, so the character order is free.

struc WAVES
    .symbols:           resq 1          ; *const u64 packed symbols
    .symbol_count:      resq 1
    .wave_stops:        resq 1          ; *const u64
    .wave_stop_count:   resq 1
    .wave_steps:        resq 1          ; *const i64
    .wave_step_count:   resq 1
    .wave_count:        resq 1          ; >= 1
    .wave_length:       resq 1          ; frame duration, fits i32 (marshal checks)
    .direction:         resq 1          ; CharacterGroup (GROUP_*)
    .ease:              resq 1          ; easing id
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define WV_WAVE             0           ; auto scene ids: new_scene("") twice
%define WV_FINAL            1
%define WV_FINAL_DURATION   10

section .text

; waves_build: Waves::build.
waves_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [effect_config]
    call    wv_final_map
    ; the wave gradient
    mov     rdi, [rbx + WAVES.wave_steps]
    mov     rcx, [rbx + WAVES.wave_step_count]
    mov     rsi, [rbx + WAVES.wave_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [wv_wave_spectrum], rax
    mov     rdi, [rbx + WAVES.wave_stops]
    mov     rsi, [rbx + WAVES.wave_stop_count]
    mov     rdx, [rbx + WAVES.wave_steps]
    mov     rcx, [rbx + WAVES.wave_step_count]
    mov     r8, [wv_wave_spectrum]
    call    gradient_new
    mov     [wv_wave_len], rax
    ; the final scene gradients start at the wave spectrum's last color
    mov     rcx, [wv_wave_spectrum]
    mov     rax, [rcx + rax * 8 - 8]
    mov     [wv_pair_stops], rax
    mov     rdi, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     esi, 2
    call    gradient_capacity
    shl     rax, 3
    mov     [wv_pair_bytes], rax
    mov     rdi, rax
    call    alloc
    mov     [wv_pair_spectrum], rax
    mov     rdi, [wv_pair_bytes]
    call    alloc
    mov     [wv_bg_spectrum], rax
    mov     qword [wv_last_fg], NONE
    mov     r12, [input_chars]
    mov     r13, [input_count]
    xor     ebp, ebp
.char:
    cmp     rbp, r13
    jae     .grouped
    mov     r15d, [r12 + rbp * 4]       ; slot
    ; --- the eased wave scene: the same for every character whose input
    ; colors don't enter it, so later ones clone the first one's
    mov     rax, [wv_template_scene]
    test    rax, rax
    jz      .wave_fresh
    cmp     qword [cfg_existing_colors], 0
    jne     .wave_clone
    mov     rcx, [ch_flags]
    test    word [rcx + r15 * 2], CF_PREEXISTING
    jnz     .wave_fresh
.wave_clone:
    mov     edi, r15d
    lea     esi, [eax - 1]
    mov     edx, WV_WAVE
    call    scene_copy
    mov     r14d, eax
    jmp     .final
.wave_fresh:
    mov     edi, r15d
    mov     esi, WV_WAVE
    xor     edx, edx
    mov     ecx, [rbx + WAVES.ease]
    call    scene_new
    mov     r14d, eax
    mov     edi, eax
    call    wv_wave_frames
    cmp     qword [wv_template_scene], 0
    jne     .final
    mov     rax, r14
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    test    dword [rax + SC_FLAGS], SCF_PREEXISTING | SCF_PRE_BOLD
    jnz     .final
    lea     eax, [r14d + 1]
    mov     [wv_template_scene], rax
.final:
    ; --- the final scene
    mov     edi, r15d
    mov     esi, WV_FINAL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    mov     edi, eax
    call    wv_final_frames
    jmp     .events
.dynamic:
    mov     edi, eax
    call    wv_dynamic_frames
.events:
    push    0
    push    0
    mov     edi, r15d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, WV_WAVE
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, WV_FINAL
    call    event_register
    add     rsp, 16
    mov     edi, r15d
    mov     esi, r14d
    call    scene_activate
    cmp     qword [cfg_existing_colors], 1
    jne     .next
    ; dynamic: show the input colors until the wave arrives
    mov     edi, r15d
    xor     esi, esi
    mov     rdx, [ch_fg]
    mov     rdx, [rdx + r15 * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + r15 * 8]
    call    set_appearance
.next:
    inc     rbp
    jmp     .char
.grouped:
    mov     edi, FILTER_INPUT
    mov     esi, [rbx + WAVES.direction]
    call    get_characters_grouped
    mov     [wv_groups], rax
    mov     [wv_group_count], rdx
    mov     qword [wv_group_pos], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; wv_wave_frames(edi=scene), rbx = config: wave_count times
; apply_gradient_to_symbols(wave symbols, wave_length, wave gradient).
wv_wave_frames:
    push    rbp
    push    r12
    push    r13
    mov     ebp, edi
    mov     r12, [rbx + WAVES.wave_count]
.wave:
    test    r12, r12
    jz      .done
    push    0                           ; no bg gradient
    push    0
    mov     edi, ebp
    mov     rsi, [rbx + WAVES.symbols]
    mov     rdx, [rbx + WAVES.symbol_count]
    mov     ecx, [rbx + WAVES.wave_length]
    mov     r8, [wv_wave_spectrum]
    mov     r9, [wv_wave_len]
    call    scene_apply_gradient
    add     rsp, 16
    dec     r12
    jmp     .wave
.done:
    pop     r13
    pop     r12
    pop     rbp
    ret

; wv_final_frames(edi=scene) with r15 = slot, rbx = config: one frame of
; the input symbol per color of Gradient([wave last, final color], final
; steps), duration 10. The gradient is rebuilt only when the final color
; changes.
wv_final_frames:
    push    rbp
    push    r12
    push    r13
    mov     ebp, edi
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r15 * 4]
    sub     rax, [text_bottom]
    imul    rax, [wv_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r15 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [wv_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [wv_last_fg]
    je      .frames
    mov     [wv_last_fg], rax
    mov     [wv_pair_stops + 8], rax
    lea     rdi, [wv_pair_stops]
    mov     esi, 2
    mov     rdx, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     r8, [wv_pair_spectrum]
    call    gradient_new
    mov     [wv_pair_len], rax
.frames:
    xor     r12d, r12d
.color:
    cmp     r12, [wv_pair_len]
    jae     .done
    mov     rcx, [wv_pair_spectrum]
    mov     rcx, [rcx + r12 * 8]
    mov     r8, NONE
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r15 * 8]
    mov     edi, ebp
    mov     edx, WV_FINAL_DURATION
    xor     r9d, r9d
    call    scene_add_frame
    inc     r12
    jmp     .color
.done:
    pop     r13
    pop     r12
    pop     rbp
    ret

; wv_dynamic_frames(edi=scene) with r15 = slot, rbx = config: the final
; scene under --existing-color-handling dynamic, from the input colors.
wv_dynamic_frames:
    push    rbp
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebp, edi
    mov     r12, [ch_fg]
    mov     r12, [r12 + r15 * 8]        ; fg or NONE
    mov     r13, [ch_bg]
    mov     r13, [r13 + r15 * 8]        ; bg or NONE
    mov     rax, [ch_sym]
    mov     rax, [rax + r15 * 8]
    mov     [wv_symbol], rax
    cmp     r12, NONE
    jne     .gradients
    cmp     r13, NONE
    jne     .gradients
    ; no colors: one plain frame
    mov     edi, ebp
    mov     rsi, rax
    mov     edx, WV_FINAL_DURATION
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .done
.gradients:
    xor     r14d, r14d                  ; fg spectrum length (0 = None)
    cmp     r12, NONE
    je      .bg
    mov     [wv_pair_stops + 8], r12
    lea     rdi, [wv_pair_stops]
    mov     esi, 2
    mov     rdx, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     r8, [wv_pair_spectrum]
    call    gradient_new
    mov     r14d, eax
    mov     qword [wv_last_fg], NONE    ; the pair spectrum no longer holds it
.bg:
    xor     eax, eax
    cmp     r13, NONE
    je      .apply
    mov     [wv_pair_stops + 8], r13
    lea     rdi, [wv_pair_stops]
    mov     esi, 2
    mov     rdx, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     r8, [wv_bg_spectrum]
    call    gradient_new
.apply:
    ; apply_gradient_to_symbols([symbol], 10, fg gradient, bg gradient)
    xor     r9d, r9d
    xor     r8d, r8d
    test    r14d, r14d
    jz      .bg_args
    mov     r9d, r14d
    mov     r8, [wv_pair_spectrum]
.bg_args:
    xor     ecx, ecx
    test    eax, eax
    jz      .call
    mov     rcx, [wv_bg_spectrum]
.call:
    push    rax                         ; bg count
    push    rcx                         ; bg spectrum
    mov     edi, ebp
    lea     rsi, [wv_symbol]
    mov     edx, 1
    mov     ecx, WV_FINAL_DURATION
    call    scene_apply_gradient
    add     rsp, 16
    cmp     r12, NONE
    jne     .done
    ; no fg: a last frame of the bg alone
    mov     edi, ebp
    mov     rsi, [wv_symbol]
    mov     edx, WV_FINAL_DURATION
    mov     rcx, NONE
    mov     r8, r13
    xor     r9d, r9d
    call    scene_add_frame
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; wv_final_map (rbx = config): Gradient::new(final stops, final steps) and
; its coordinate mapping over the text rectangle.
wv_final_map:
    mov     rdi, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     rsi, [rbx + WAVES.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [wv_final_spectrum], rax
    mov     rdi, [rbx + WAVES.final_stops]
    mov     rsi, [rbx + WAVES.final_stop_count]
    mov     rdx, [rbx + WAVES.final_steps]
    mov     rcx, [rbx + WAVES.final_step_count]
    mov     r8, [wv_final_spectrum]
    call    gradient_new
    mov     rdi, [wv_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [wv_map_width], rax
    sub     rsp, 8
    push    qword [rbx + WAVES.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     [wv_map], rax
    ret

; waves_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
waves_next_frame:
    push    rbx
    push    r12
    push    r13
    mov     rax, [wv_group_pos]
    cmp     rax, [wv_group_count]
    jb      .reveal
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .update
.reveal:
    ; the next group: visible and active
    inc     qword [wv_group_pos]
    shl     rax, 4
    add     rax, [wv_groups]
    mov     rbx, [rax]                  ; slots
    mov     r12, [rax + 8]              ; count
.char:
    test    r12, r12
    jz      .update
    mov     r13d, [rbx]
    mov     edi, r13d
    call    set_visible
    mov     edi, r13d
    call    active_insert
    add     rbx, 4
    dec     r12
    jmp     .char
.update:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .tstate
alignb 8
wv_groups:              resq 1
wv_group_count:         resq 1
wv_group_pos:           resq 1
wv_final_spectrum:      resq 1
wv_map:                 resq 1
wv_map_width:           resq 1
wv_wave_spectrum:       resq 1
wv_wave_len:            resq 1
wv_template_scene:      resq 1          ; the wave scene to clone, + 1 (0 = none yet)
wv_pair_stops:          resq 2
wv_pair_bytes:          resq 1
wv_pair_spectrum:       resq 1
wv_pair_len:            resq 1
wv_bg_spectrum:         resq 1
wv_last_fg:             resq 1
wv_symbol:              resq 1
