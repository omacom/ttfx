; effects/expand.asm - "Expands the text from a single point"
; (src/effects/expand.rs).
;
; Every character starts at the canvas center and travels to its input
; coordinate on one eased path (layer 1 while moving, 0 on arrival) while a
; distance-synced scene fades it from the first final-gradient color to its
; own final color. No RNG draws.

struc EXPAND
    .easing:            resq 1
    .speed:             resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

section .text

; expand_build: Expand::build.
expand_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    ex_final_color_map
    mov     qword [ex_last_color], NONE
    ; both of Rust's passes use TopToBottomLeftToRight, which draws nothing;
    ; the first only fills the final color map, read here directly
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r15
    jae     .built
    mov     r12d, [r14 + rbx * 4]
    ; motion.set_coordinate(canvas center)
    mov     rsi, [center_row]
    shl     rsi, 32
    mov     eax, [center_col]
    or      rsi, rax
    mov     edi, r12d
    call    set_coordinate
    ; new_path(movement_speed, expand_easing) with the input coordinate
    mov     rax, [effect_config]
    movsd   xmm0, [rax + EXPAND.speed]
    mov     esi, [rax + EXPAND.easing]
    mov     edi, r12d
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax
    mov     edi, r12d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
    ; the path's (auto) name for the events
    mov     r13, rbp
    shl     r13, 7                      ; PATH_SIZE
    add     r13, [paths]
    mov     r13d, [r13 + PA_NAME]
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, r13d
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, r13d
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    add     rsp, 16
    mov     edi, r12d
    mov     esi, ebp
    call    path_activate
    ; gradient scene, synced to distance
    mov     edi, r12d
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; final color at the input coordinate; consecutive characters mostly
    ; share it, so the two-stop gradient is rebuilt only when it changes
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [ex_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [ex_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [ex_last_color]
    je      .apply
    mov     [ex_last_color], rax
    lea     rdi, [ex_fg_spectrum]
    mov     rsi, rax
    call    ex_pair_gradient
    mov     [ex_fg_len], eax
.apply:
    ; apply_gradient_to_symbols([symbol], 5, fg spectrum): a frame per
    ; color, the visuals shared by symbol and final color
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    lea     rsi, [ex_fg_spectrum]
    mov     edx, [ex_fg_len]
    mov     rcx, NONE
    mov     r8, [ex_last_color]
    call    visual_run
    mov     edi, ebp
    mov     rsi, rax
    mov     ecx, 5
    call    visual_frames
.activate:
    mov     edi, r12d
    mov     esi, ebp
    call    scene_activate
    inc     rbx
    jmp     .char
.dynamic:
    call    ex_dynamic_scene
    jmp     .activate
.built:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ex_dynamic_scene(r12d=slot, ebp=scene): the existing-color-handling
; dynamic branch - gradients from the first final color to each input color
; present (duration 1), or one uncolored frame when there are none.
ex_dynamic_scene:
    push    r13
    push    r14
    sub     rsp, 8
    mov     qword [ex_last_color], NONE ; the fg spectrum is reused below
    xor     r13d, r13d                  ; fg spectrum or 0
    xor     r14d, r14d                  ; bg spectrum or 0
    mov     rax, [ch_fg]
    mov     rsi, [rax + r12 * 8]
    cmp     rsi, NONE
    je      .bg
    lea     rdi, [ex_fg_spectrum]
    call    ex_pair_gradient
    mov     [ex_fg_len], eax
    lea     r13, [ex_fg_spectrum]
.bg:
    mov     rax, [ch_bg]
    mov     rsi, [rax + r12 * 8]
    cmp     rsi, NONE
    je      .apply
    lea     rdi, [ex_bg_spectrum]
    call    ex_pair_gradient
    mov     [ex_bg_len], eax
    lea     r14, [ex_bg_spectrum]
.apply:
    mov     rax, r13
    or      rax, r14
    jz      .plain
    mov     edi, ebp
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + r12 * 8]
    mov     edx, 1
    mov     ecx, 1
    mov     r8, r13
    xor     r9d, r9d
    test    r13, r13
    jz      .no_fg
    mov     r9d, [ex_fg_len]
.no_fg:
    xor     eax, eax
    test    r14, r14
    jz      .no_bg
    mov     eax, [ex_bg_len]
.no_bg:
    push    rax
    push    r14
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .done
.plain:
    mov     edi, ebp
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r12 * 8]
    mov     edx, 1
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    ret

; ex_pair_gradient(rdi=out spectrum, rsi=end color) -> eax = length:
; Gradient::with_steps([final spectrum[0], end], 10).
ex_pair_gradient:
    mov     r8, rdi
    mov     rax, [ex_final_spectrum]
    mov     rax, [rax]
    mov     [ex_pair_stops], rax
    mov     [ex_pair_stops + 8], rsi
    lea     rdi, [ex_pair_stops]
    mov     esi, 2
    lea     rdx, [ex_ten_steps]
    mov     ecx, 1
    jmp     gradient_new

; ex_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
ex_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + EXPAND.final_steps]
    mov     rcx, [rbx + EXPAND.final_step_count]
    mov     rsi, [rbx + EXPAND.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [ex_final_spectrum], rax
    mov     rdi, [rbx + EXPAND.final_stops]
    mov     rsi, [rbx + EXPAND.final_stop_count]
    mov     rdx, [rbx + EXPAND.final_steps]
    mov     rcx, [rbx + EXPAND.final_step_count]
    mov     r8, [ex_final_spectrum]
    call    gradient_new
    mov     rdi, [ex_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [ex_map_width], rax
    push    qword [rbx + EXPAND.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [ex_map], rax
    pop     rbx
    ret

; expand_next_frame -> eax = 1 while characters are active, 0 when done.
expand_next_frame:
    sub     rsp, 8
    call    active_empty
    test    eax, eax
    jnz     .done
    call    update
    mov     eax, 1
    add     rsp, 8
    ret
.done:
    xor     eax, eax
    add     rsp, 8
    ret

section .rodata
align 8
ex_ten_steps:   dq 10

section .tstate
alignb 8
ex_final_spectrum:  resq 1
ex_map:             resq 1
ex_map_width:       resq 1
ex_last_color:      resq 1
ex_pair_stops:      resq 2
ex_fg_spectrum:     resq 16
ex_bg_spectrum:     resq 16
ex_fg_len:          resd 1
ex_bg_len:          resd 1
