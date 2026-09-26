; effects/scattered.asm - "Text is scattered across the canvas and moves into
; position" (src/effects/scattered.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Scattered):
;
; Each character gets, in Rust's order: a random start coordinate, one auto
; path to its input coordinate with SetLayer events, and one distance-synced
; auto scene fading from the final gradient's first color to its own. Nothing
; draws from the RNG after build.

struc SCATTERED
    .movement_speed:    resq 1          ; f64
    .movement_easing:   resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_frames:      resq 1
    .final_direction:   resq 1
endstruc

%define SCAT_HOLD_FRAMES    25

section .text

; scattered_build: Scattered::build.
scattered_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    scat_final_color_map
    mov     qword [scat_last_fg], NONE
    mov     r13, [input_chars]
    mov     r14, [input_count]
    mov     r15, [effect_config]
    xor     ebx, ebx
.char:
    cmp     rbx, r14
    jae     .built
    mov     r12d, [r13 + rbx * 4]
    ; final colors: the input colors under dynamic, else the mapped gradient
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     rax, [rax + r12 * 8]
    mov     [scat_fg], rax
    mov     rax, [ch_bg]
    mov     rax, [rax + r12 * 8]
    mov     [scat_bg], rax
    jmp     .start
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [scat_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [scat_map]
    mov     rax, [rcx + rax * 8]
    mov     [scat_fg], rax
    mov     qword [scat_bg], NONE
.start:
    ; start coordinate: (1, 1) on a tiny canvas, else canvas.random_coord
    mov     rax, (1 << 32) | 1
    cmp     qword [canvas_right], 2
    jl      .place
    cmp     qword [canvas_top], 2
    jl      .place
    xor     edi, edi
    xor     esi, esi
    call    canvas_random_coord
.place:
    mov     edi, r12d
    mov     rsi, rax
    call    set_coordinate
    ; the path home
    mov     edi, r12d
    movsd   xmm0, [r15 + SCATTERED.movement_speed]
    mov     esi, [r15 + SCATTERED.movement_easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax                    ; path index
    mov     rsi, [ch_irow]
    mov     esi, [rsi + r12 * 4]
    shl     rsi, 32
    mov     rcx, [ch_icol]
    mov     ecx, [rcx + r12 * 4]
    or      rsi, rcx
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    PATH_PTR rax, rbp
    mov     eax, [rax + PA_NAME]
    mov     [rsp], eax                  ; path name
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, [rsp + 16]
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [rsp + 16]
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    add     rsp, 16
    mov     edi, r12d
    mov     esi, ebp
    call    path_activate
    mov     edi, r12d
    call    set_visible
    ; the gradient scene, synced to the path's distance
    mov     edi, r12d
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax                    ; scene index
    cmp     qword [cfg_existing_colors], 1
    jne     .gradient
    mov     edi, ebp
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r12 * 8]
    mov     rdx, [r15 + SCATTERED.final_frames]
    mov     rcx, [scat_fg]
    mov     r8, [scat_bg]
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .activate
.gradient:
    ; Gradient::with_steps([spectrum[0], final fg], 10); consecutive
    ; characters mostly share their final color, so the last one is kept
    mov     rax, [scat_fg]
    cmp     rax, [scat_last_fg]
    je      .apply
    mov     [scat_last_fg], rax
    mov     [scat_pair + 8], rax
    mov     rax, [scat_spectrum]
    mov     rax, [rax]
    mov     [scat_pair], rax
    lea     rdi, [scat_pair]
    mov     esi, 2
    lea     rdx, [scat_ten_steps]
    mov     ecx, 1
    lea     r8, [scat_char_spectrum]
    call    gradient_new
    mov     [scat_char_len], rax
.apply:
    ; apply_gradient_to_symbols([symbol], final frames, the spectrum): a
    ; frame per color, the visuals shared by symbol and final color
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    lea     rsi, [scat_char_spectrum]
    mov     rdx, [scat_char_len]
    mov     rcx, NONE
    mov     r8, [scat_last_fg]
    call    visual_run
    mov     edi, ebp
    mov     rsi, rax
    mov     rcx, [r15 + SCATTERED.final_frames]
    call    visual_frames
.activate:
    mov     edi, r12d
    mov     esi, ebp
    call    scene_activate
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .char
.built:
    mov     qword [scat_hold], SCAT_HOLD_FRAMES
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; scat_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
scat_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SCATTERED.final_steps]
    mov     rcx, [rbx + SCATTERED.final_step_count]
    mov     rsi, [rbx + SCATTERED.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [scat_spectrum], rax
    mov     rdi, [rbx + SCATTERED.final_stops]
    mov     rsi, [rbx + SCATTERED.final_stop_count]
    mov     rdx, [rbx + SCATTERED.final_steps]
    mov     rcx, [rbx + SCATTERED.final_step_count]
    mov     r8, [scat_spectrum]
    call    gradient_new
    mov     rdi, [scat_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [scat_map_width], rax
    push    qword [rbx + SCATTERED.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [scat_map], rax
    pop     rbx
    ret

; scattered_next_frame -> eax = 1 for a frame, 0 when done. The first 25
; frames hold the scattered start without ticking.
scattered_next_frame:
    sub     rsp, 8
    call    active_empty
    test    eax, eax
    jnz     .finished
    cmp     qword [scat_hold], 0
    je      .update
    dec     qword [scat_hold]
    jmp     .frame
.update:
    call    update
.frame:
    mov     eax, 1
    add     rsp, 8
    ret
.finished:
    xor     eax, eax
    add     rsp, 8
    ret

section .rodata
align 8
scat_ten_steps:     dq 10

section .tstate
alignb 8
scat_spectrum:      resq 1
scat_map:           resq 1
scat_map_width:     resq 1
scat_hold:          resq 1
scat_fg:            resq 1
scat_bg:            resq 1
scat_last_fg:       resq 1
scat_symbol:        resq 1
scat_pair:          resq 2
scat_char_spectrum: resq 16
scat_char_len:      resq 1
