; effects/spray.asm - "Draws the characters spawning at varying rates from a
; single point" (src/effects/spray.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Spray):
;
; Every character gets its path, events and droplet scene in Rust's order,
; so the speed, spectrum and shuffle draws line up.

struc SPRAY
    .position:          resq 1          ; SprayPosition: n ne e se s sw w nw center
    .volume:            resq 1          ; f64
    .speed_min:         resq 1          ; f64
    .speed_max:         resq 1          ; f64
    .easing:            resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define SPRAY_N             0
%define SPRAY_NE            1
%define SPRAY_E             2
%define SPRAY_SE            3
%define SPRAY_S             4
%define SPRAY_SW            5
%define SPRAY_W             6
%define SPRAY_NW            7
%define SPRAY_CENTER        8

section .text

; spray_build: Spray::build.
spray_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    spray_final_color_map
    call    spray_origin
    mov     [spray_origin_coord], rax
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    lea     rdi, [rdx * 4 + 4]
    call    alloc
    mov     [spray_pending], rax
    mov     r13, [effect_config]
    xor     ebx, ebx
.char:
    cmp     rbx, r15
    jae     .shuffle
    mov     r12d, [r14 + rbx * 4]
    ; speed = uniform(range); start at the origin on a one-waypoint path
    movsd   xmm0, [r13 + SPRAY.speed_min]
    movsd   xmm1, [r13 + SPRAY.speed_max]
    call    rng_uniform
    movsd   [rsp], xmm0
    mov     edi, r12d
    mov     rsi, [spray_origin_coord]
    call    set_coordinate
    mov     edi, r12d
    movsd   xmm0, [rsp]
    mov     esi, [r13 + SPRAY.easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax                    ; path index
    mov     edi, r12d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; activated -> layer 1, complete -> layer 0
    mov     rax, rbp
    shl     rax, 7                      ; PATH_SIZE
    add     rax, [paths]
    mov     eax, [rax + PA_NAME]
    mov     [rsp + 4], eax
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, [rsp + 16 + 4]
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [rsp + 16 + 4]
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    add     rsp, 16
    ; the droplet scene
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp], eax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; with_steps([choice(final spectrum), final color], 7), 20 frames each
    mov     rdi, [spray_spectrum_len]
    call    rng_below
    mov     rbp, rax                    ; the start color's index
    mov     rcx, [spray_spectrum]
    mov     rax, [rcx + rax * 8]
    mov     [spray_pair], rax
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [spray_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [spray_map]
    mov     rax, [rcx + rax * 8]
    mov     [spray_pair + 8], rax
    ; apply_gradient_to_symbols([input symbol], 20, the pair's spectrum):
    ; a frame per color, the visuals shared by symbol and pair (colors fit
    ; in 41 bits, so the index above them keys the pair exactly)
    shl     rbp, 48
    or      rbp, rax
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    mov     rsi, rbp
    mov     rdx, NONE
    call    visual_run_find
    test    rax, rax
    jnz     .frames
    lea     rdi, [spray_pair]
    mov     esi, 2
    lea     rdx, [spray_seven]
    mov     ecx, 1
    lea     r8, [spray_pair_spectrum]
    call    gradient_new
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    lea     rsi, [spray_pair_spectrum]
    mov     edx, eax
    mov     rcx, NONE
    mov     r8, rbp
    call    visual_run
.frames:
    mov     edi, [rsp]
    mov     rsi, rax
    mov     ecx, 20
    call    visual_frames
    jmp     .activate
.dynamic:
    ; the input colors on the input symbol, 7 frames of 20
    xor     ebp, ebp
.dynamic_frame:
    mov     edi, [rsp]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r12 * 8]
    mov     edx, 20
    mov     rcx, [ch_fg]
    mov     rcx, [rcx + r12 * 8]
    mov     r8, [ch_bg]
    mov     r8, [r8 + r12 * 8]
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    cmp     ebp, 7
    jb      .dynamic_frame
.activate:
    mov     edi, r12d
    mov     esi, [rsp]
    call    scene_activate
    mov     edi, r12d
    mov     esi, [rsp + 4]              ; the path's name
    call    path_activate_name
    mov     rax, [spray_pending]
    mov     [rax + rbx * 4], r12d
    inc     rbx
    jmp     .char
.shuffle:
    mov     [spray_pending_count], r15
    mov     rdi, [spray_pending]
    mov     rsi, r15
    call    rng_shuffle32
    ; volume = max(int(len * spray_volume), 1)
    cvtsi2sd xmm0, r15
    mulsd   xmm0, [r13 + SPRAY.volume]
    cvttsd2si rax, xmm0
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [spray_volume], rax
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; spray_origin -> rax = the spray origin for the configured position (packed).
spray_origin:
    mov     rax, [effect_config]
    mov     rax, [rax + SPRAY.position]
    mov     rcx, [canvas_right]
    mov     rdx, [canvas_top]
    cmp     eax, SPRAY_CENTER
    je      .center
    ; column: n/s at right // 2, the west side at left, the east at right - 1
    mov     r8, rcx
    sar     r8, 1
    cmp     eax, SPRAY_N
    je      .row
    cmp     eax, SPRAY_S
    je      .row
    mov     r8d, 1
    cmp     eax, SPRAY_SW
    jae     .row                        ; sw w nw
    lea     r8, [rcx - 1]               ; ne e se
.row:
    ; row: the north side at top, w/e at top // 2, the south side at bottom
    mov     r9, rdx
    cmp     eax, SPRAY_N
    je      .pack
    cmp     eax, SPRAY_NE
    je      .pack
    cmp     eax, SPRAY_NW
    je      .pack
    sar     r9, 1
    cmp     eax, SPRAY_E
    je      .pack
    cmp     eax, SPRAY_W
    je      .pack
    mov     r9d, 1
.pack:
    mov     rax, r9
    shl     rax, 32
    mov     r8d, r8d
    or      rax, r8
    ret
.center:
    mov     rax, [center_row]
    shl     rax, 32
    mov     ecx, [center_col]
    or      rax, rcx
    ret

; spray_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
spray_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SPRAY.final_steps]
    mov     rcx, [rbx + SPRAY.final_step_count]
    mov     rsi, [rbx + SPRAY.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [spray_spectrum], rax
    mov     rdi, [rbx + SPRAY.final_stops]
    mov     rsi, [rbx + SPRAY.final_stop_count]
    mov     rdx, [rbx + SPRAY.final_steps]
    mov     rcx, [rbx + SPRAY.final_step_count]
    mov     r8, [spray_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [spray_spectrum_len], rax
    mov     rdi, [spray_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [spray_map_width], rax
    push    qword [rbx + SPRAY.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [spray_map], rax
    pop     rbx
    ret

; spray_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
spray_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [spray_pending_count], 0
    jne     .release
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .update
.release:
    mov     edi, 1
    mov     rsi, [spray_volume]
    call    rng_randint
    mov     rbx, rax
.pop:
    test    rbx, rbx
    jle     .update
    dec     rbx
    mov     rax, [spray_pending_count]
    test    rax, rax
    jz      .pop
    dec     rax
    mov     [spray_pending_count], rax
    mov     rcx, [spray_pending]
    mov     r12d, [rcx + rax * 4]
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
    jmp     .pop
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
spray_seven:        dq 7

section .tstate
alignb 8
spray_spectrum:         resq 1
spray_spectrum_len:     resq 1
spray_map:              resq 1
spray_map_width:        resq 1
spray_origin_coord:     resq 1
spray_pending:          resq 1
spray_pending_count:    resq 1
spray_volume:           resq 1
spray_pair:             resq 2
spray_pair_spectrum:    resq 16
