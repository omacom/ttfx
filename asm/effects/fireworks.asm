; effects/fireworks.asm - "Characters launch and explode like fireworks and
; fall into place" (src/effects/fireworks.rs).
;
; Config (src/asm/effects.rs, the Fireworks arm).
;
; Rust's shells are consecutive runs of the top-to-bottom order: shell 0 is
; always empty (the loop pushes the empty accumulator at the first
; boundary), and shell k >= 1 holds characters [(k - 1) * volume, k *
; volume). They are launched from the last one down, the empty shell last,
; and every launch draws the next delay, so only the count is kept here.

struc FIREWORKS
    .explode_anywhere:  resq 1
    .colors:            resq 1          ; *const u64
    .color_count:       resq 1
    .symbol:            resq 1          ; packed firework symbol
    .volume:            resq 1          ; f64
    .launch_delay:      resq 1
    .explode_distance:  resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; path names
%define FW_PATH_APEX        NAME_LITERAL + 0
%define FW_PATH_INPUT       NAME_LITERAL + 1
; scene names
%define FW_SCN_FALL         NAME_LITERAL + 0

%define FW_EASE_IN_OUT_QUART    12
%define FW_EASE_OUT_EXPO        17
%define FW_EASE_OUT_CIRC        20

%define FW_WHITE            0xffffff

section .text

; fireworks_build: Fireworks::build (prepare_waypoints, prepare_scenes).
fireworks_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    ; firework_volume = max(1, round(volume * input characters))
    cvtsi2sd xmm0, qword [input_count]
    movsd   xmm1, [rbx + FIREWORKS.volume]
    mulsd   xmm0, xmm1
    call    round_half_even
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [fw_volume], rax
    ; explode_distance = min(15, max(1, round(right * explode_distance)))
    cvtsi2sd xmm0, qword [canvas_right]
    mulsd   xmm0, [rbx + FIREWORKS.explode_distance]
    call    round_half_even
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     ecx, 15
    cmp     rax, 15
    cmovg   rax, rcx
    mov     [fw_distance], rax
    mov     qword [fw_delay], 0
    call    fw_prepare_waypoints
    call    fw_prepare_scenes
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; fw_prepare_waypoints: FireworksIterator.prepare_waypoints - the apex,
; explode and input paths of every character and their chain of events.
fw_prepare_waypoints:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40                     ; [rsp] origin, [+8] explode wpt,
                                        ; [+16] control, [+24] path index
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [fw_chars], rax
    mov     [fw_count], rdx
    ; shells: the empty one, then ceil(count / volume)
    xor     ecx, ecx
    test    rdx, rdx
    jz      .shells
    mov     rax, rdx
    add     rax, [fw_volume]
    dec     rax
    xor     edx, edx
    div     qword [fw_volume]
    lea     rcx, [rax + 1]
.shells:
    mov     [fw_shells], rcx
    xor     r12d, r12d                  ; position
    xor     r15d, r15d                  ; position within the shell
.char:
    cmp     r12, [fw_count]
    jae     .done
    mov     rax, [fw_chars]
    mov     ebx, [rax + r12 * 4]
    test    r15, r15
    jz      .boundary
    cmp     r15, [fw_volume]
    jne     .paths
    xor     r15d, r15d
.boundary:
    ; a new shell: origin and its explode circle
    xor     edi, edi
    mov     rsi, [canvas_right]
    call    rng_randrange
    mov     r13, rax                    ; origin_x
    mov     edi, 1                      ; canvas bottom
    mov     rax, [effect_config]
    cmp     qword [rax + FIREWORKS.explode_anywhere], 0
    jne     .min_row
    mov     rax, [ch_irow]
    movsxd  rdi, dword [rax + rbx * 4]
.min_row:
    mov     rsi, [canvas_top]
    inc     rsi
    call    rng_randrange
    shl     rax, 32
    mov     ecx, r13d
    or      rax, rcx
    mov     [fw_origin], rax
    mov     rdi, rax
    mov     rsi, [fw_distance]
    call    find_coords_in_circle
    mov     [fw_circle], rax
    mov     [fw_circle_count], rdx
.paths:
    inc     r15
    ; start at (origin_x, canvas bottom); apex: 0.35, out_expo, layer 2
    mov     rsi, 1 << 32
    mov     eax, r13d
    or      rsi, rax
    mov     edi, ebx
    call    set_coordinate
    mov     edi, ebx
    movsd   xmm0, [fw_speed_apex]
    mov     esi, FW_EASE_OUT_EXPO
    mov     edx, 2
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, FW_PATH_APEX
    call    path_new
    mov     edi, eax
    mov     rsi, [fw_origin]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; explode: uniform(0.2, 0.4), out_circ, layer 2, auto id
    movsd   xmm0, [fw_speed_explode_lo]
    movsd   xmm1, [fw_speed_explode_hi]
    call    rng_uniform
    mov     edi, ebx
    mov     esi, FW_EASE_OUT_CIRC
    mov     edx, 2
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     [rsp + 24], rax
    mov     rdi, [fw_circle_count]
    call    rng_below
    mov     rcx, [fw_circle]
    mov     rsi, [rcx + rax * 8]
    mov     [rsp + 8], rsi
    mov     edi, [rsp + 24]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; bloom: past the explode waypoint by distance // 2, raised 7 rows
    mov     rax, [fw_distance]
    sar     rax, 1
    cvtsi2sd xmm0, rax
    mov     rdi, [fw_origin]
    mov     rsi, [rsp + 8]
    call    extrapolate_along_ray
    mov     [rsp + 16], rax
    mov     rcx, rax
    sar     rcx, 32
    sub     rcx, 7
    mov     edx, 1
    cmp     rcx, 1
    cmovl   rcx, rdx
    shl     rcx, 32
    mov     r14d, eax                   ; bloom column
    mov     rsi, r14
    or      rsi, rcx
    mov     edi, [rsp + 24]
    lea     rdx, [rsp + 16]
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    ; input: 0.6, in_out_quart, layer 2, curving through (bloom column, 1)
    mov     edi, ebx
    movsd   xmm0, [fw_speed_input]
    mov     esi, FW_EASE_IN_OUT_QUART
    mov     edx, 2
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, FW_PATH_INPUT
    call    path_new
    mov     ebp, eax
    mov     rax, 1 << 32
    or      rax, r14
    mov     [rsp + 16], rax
    mov     edi, ebx
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebp
    lea     rdx, [rsp + 16]
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    ; apex -> explode -> input -> layer 0
    mov     rax, [rsp + 24]
    PATH_PTR rcx, rax
    mov     ebp, [rcx + PA_NAME]        ; the explode path's auto id
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, FW_PATH_APEX
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, ebp
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, ebp
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, FW_PATH_INPUT
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, FW_PATH_INPUT
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    mov     esi, FW_PATH_APEX
    call    path_activate_name
    inc     r12
    jmp     .char
.done:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; fw_prepare_scenes: FireworksIterator.prepare_scenes - per shell a color
; and its bloom gradient; per character the launch, bloom and fall scenes.
fw_prepare_scenes:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    fw_make_final_map
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [fw_dynamic], al
    xor     r12d, r12d                  ; shell
.shell:
    cmp     r12, [fw_shells]
    jae     .done
    mov     rbx, [effect_config]
    mov     rdi, [rbx + FIREWORKS.color_count]
    call    rng_below
    mov     rcx, [rbx + FIREWORKS.colors]
    mov     rax, [rcx + rax * 8]
    mov     [fw_color], rax
    ; Gradient::with_steps([color, white, color], 5)
    mov     [fw_stops], rax
    mov     qword [fw_stops + 8], FW_WHITE
    mov     [fw_stops + 16], rax
    lea     rdi, [fw_stops]
    mov     esi, 3
    lea     rdx, [fw_five_steps]
    mov     ecx, 1
    lea     r8, [fw_shell_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [fw_shell_len], rax
    ; the shell's characters
    test    r12, r12
    jz      .next_shell
    lea     r13, [r12 - 1]
    imul    r13, [fw_volume]            ; first position
    mov     r14, r13
    add     r14, [fw_volume]
    cmp     r14, [fw_count]
    cmova   r14, [fw_count]             ; end
.char:
    cmp     r13, r14
    jae     .next_shell
    mov     rax, [fw_chars]
    mov     edi, [rax + r13 * 4]
    call    fw_char_scenes
    inc     r13
    jmp     .char
.next_shell:
    inc     r12
    jmp     .shell
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; fw_char_scenes(edi=slot): one character of prepare_scenes' shell loop.
fw_char_scenes:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     rax, [ch_sym]
    mov     rax, [rax + rbx * 8]
    mov     [fw_sym], rax
    ; launch: the firework symbol in the shell color, then white; looping
    mov     esi, AUTO
    mov     edx, SCF_LOOPING
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax
    mov     edi, eax
    mov     rsi, [effect_config]
    mov     rsi, [rsi + FIREWORKS.symbol]
    mov     edx, 2
    mov     rcx, [fw_color]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r12d
    mov     rsi, [effect_config]
    mov     rsi, [rsi + FIREWORKS.symbol]
    mov     edx, 1
    mov     ecx, FW_WHITE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    ; bloom: the shell gradient over the input symbol, synced to steps
    mov     edi, ebx
    mov     esi, AUTO
    mov     edx, SCF_SYNC_STEP
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    xor     r14d, r14d
.bloom:
    cmp     r14, [fw_shell_len]
    jae     .fall
    lea     rax, [fw_shell_spectrum]
    mov     rcx, [rax + r14 * 8]
    mov     edi, r13d
    mov     rsi, [fw_sym]
    mov     edx, 2
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14
    jmp     .bloom
.fall:
    mov     edi, ebx
    mov     esi, FW_SCN_FALL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    cmp     byte [fw_dynamic], 0
    jne     .dynamic
    ; shell color -> final gradient color, 15 steps, 10 ticks each
    mov     rax, [fw_color]
    mov     [fw_stops], rax
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    sub     rax, [text_bottom]
    imul    rax, [fw_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbx * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [fw_final_map]
    mov     rax, [rcx + rax * 8]
    mov     [fw_stops + 8], rax
    lea     rdi, [fw_stops]
    lea     r8, [fw_fg_spectrum]
    call    fw_pair_gradient
    push    0
    push    0
    mov     edi, r14d
    lea     rsi, [fw_sym]
    mov     edx, 1
    mov     ecx, 10
    lea     r8, [fw_fg_spectrum]
    mov     r9d, eax
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.dynamic:
    ; gradients toward whichever input colors exist, else colorless
    xor     r15d, r15d                  ; fg count
    xor     ebp, ebp                    ; bg count
    mov     rax, [ch_fg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dyn_bg
    mov     rcx, [fw_color]
    mov     [fw_stops], rcx
    mov     [fw_stops + 8], rax
    lea     rdi, [fw_stops]
    lea     r8, [fw_fg_spectrum]
    call    fw_pair_gradient
    mov     r15d, eax
.dyn_bg:
    mov     rax, [ch_bg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dyn_frames
    mov     rcx, [fw_color]
    mov     [fw_stops], rcx
    mov     [fw_stops + 8], rax
    lea     rdi, [fw_stops]
    lea     r8, [fw_bg_spectrum]
    call    fw_pair_gradient
    mov     ebp, eax
.dyn_frames:
    mov     eax, r15d
    or      eax, ebp
    jz      .colorless
    push    rbp
    xor     eax, eax
    lea     rcx, [fw_bg_spectrum]
    test    ebp, ebp
    cmovz   rcx, rax
    push    rcx
    xor     r8d, r8d
    test    r15d, r15d
    jz      .dyn_apply
    lea     r8, [fw_fg_spectrum]
.dyn_apply:
    mov     edi, r14d
    lea     rsi, [fw_sym]
    mov     edx, 1
    mov     ecx, 10
    mov     r9d, r15d
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.colorless:
    mov     edi, r14d
    mov     rsi, [fw_sym]
    mov     edx, 10
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.activate:
    mov     edi, ebx
    mov     esi, r12d
    call    scene_activate
    ; apex complete -> bloom; input activated -> fall
    mov     rax, r13
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, FW_PATH_APEX
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [rax + SC_NAME]
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, FW_PATH_INPUT
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, FW_SCN_FALL
    call    event_register
    add     rsp, 16
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; fw_pair_gradient(rdi=two stops, r8=out) -> eax = length:
; Gradient::with_steps(stops, 15).
fw_pair_gradient:
    mov     esi, 2
    lea     rdx, [fw_fifteen_steps]
    mov     ecx, 1
    jmp     gradient_new

; fw_make_final_map: Gradient::new(final stops, final steps) and its coordinate
; mapping over the text rectangle.
fw_make_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + FIREWORKS.final_steps]
    mov     rcx, [rbx + FIREWORKS.final_step_count]
    mov     rsi, [rbx + FIREWORKS.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [fw_final_spectrum], rax
    mov     rdi, [rbx + FIREWORKS.final_stops]
    mov     rsi, [rbx + FIREWORKS.final_stop_count]
    mov     rdx, [rbx + FIREWORKS.final_steps]
    mov     rcx, [rbx + FIREWORKS.final_step_count]
    mov     r8, [fw_final_spectrum]
    call    gradient_new
    mov     rdi, [fw_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [fw_final_map_width], rax
    push    qword [rbx + FIREWORKS.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [fw_final_map], rax
    pop     rbx
    ret

; fireworks_next_frame -> eax = 1 when a frame should be rendered, 0 when
; done. Fireworks::next_frame: launch the last remaining shell once the
; delay runs out, then tick.
fireworks_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [fw_shells], 0
    jne     .shells
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .tick
.shells:
    cmp     qword [fw_delay], 0
    jg      .tick
    mov     rax, [fw_shells]
    dec     rax
    mov     [fw_shells], rax
    test    rax, rax
    jz      .delay                      ; the empty shell
    lea     r12, [rax - 1]
    imul    r12, [fw_volume]
    mov     r13, r12
    add     r13, [fw_volume]
    cmp     r13, [fw_count]
    cmova   r13, [fw_count]
.launch:
    cmp     r12, r13
    jae     .delay
    mov     rax, [fw_chars]
    mov     ebx, [rax + r12 * 4]
    mov     edi, ebx
    call    set_visible
    mov     edi, ebx
    call    active_insert
    inc     r12
    jmp     .launch
.delay:
    ; int(launch_delay * uniform(0.5, 1.5))
    movsd   xmm0, [fw_half]
    movsd   xmm1, [fw_one_half]
    call    rng_uniform
    mov     rax, [effect_config]
    cvtsi2sd xmm1, qword [rax + FIREWORKS.launch_delay]
    mulsd   xmm0, xmm1
    call    f64_to_i64
    mov     [fw_delay], rax
.tick:
    dec     qword [fw_delay]
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
fw_five_steps:          dq 5
fw_fifteen_steps:       dq 15
fw_speed_apex:          dq 0.35
fw_speed_explode_lo:    dq 0.2
fw_speed_explode_hi:    dq 0.4
fw_speed_input:         dq 0.6
fw_half:                dq 0.5
fw_one_half:            dq 1.5

section .tstate
alignb 8
fw_volume:              resq 1
fw_distance:            resq 1
fw_delay:               resq 1
fw_chars:               resq 1          ; input characters, top to bottom
fw_count:               resq 1
fw_shells:              resq 1          ; shells not launched yet
fw_origin:              resq 1
fw_circle:              resq 1          ; explode waypoint candidates
fw_circle_count:        resq 1
fw_color:               resq 1          ; the shell color
fw_sym:                 resq 1
fw_shell_len:           resq 1
fw_final_spectrum:      resq 1
fw_final_map:           resq 1
fw_final_map_width:     resq 1
fw_stops:               resq 3
fw_shell_spectrum:      resq 32
fw_fg_spectrum:         resq 32
fw_bg_spectrum:         resq 32
fw_dynamic:             resb 1
