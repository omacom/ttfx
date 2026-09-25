; effects/crumble.asm - "Characters lose color and crumble into dust,
; vacuumed up, and reformed" (src/effects/crumble.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Crumble):
;
; Every character gets, in Rust's order: an initial weak scene (auto), the
; fall path (auto), "weaken", the "top" and "input" paths, the strengthen
; flash and strengthen scenes (auto) and the distance-synced dust scene
; (auto, five rng.choice draws), then its five events. Characters sharing
; their (fg, bg) pair share the derived colors and gradients.

struc CRUMBLE
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define CR_S_WEAKEN         NAME_LITERAL + 0
; path names
%define CR_P_TOP            NAME_LITERAL + 0
%define CR_P_INPUT          NAME_LITERAL + 1

%define CR_EASE_OUT_QUINT   14
%define CR_EASE_OUT_BOUNCE  29

; stages
%define CR_FALLING          0
%define CR_VACUUMING        1
%define CR_RESETTING        2
%define CR_COMPLETE         3

%define CR_NEUTRAL_GRAY     0x808080
%define CR_WHITE            0xffffff

section .text

; crumble_build: Crumble::build.
crumble_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    cr_final_color_map
    ; dust symbols: * . ,
    mov     edi, '*'
    call    utf8_pack
    mov     [cr_dust_symbols], rax
    mov     edi, '.'
    call    utf8_pack
    mov     [cr_dust_symbols + 8], rax
    mov     edi, ','
    call    utf8_pack
    mov     [cr_dust_symbols + 16], rax
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r13, rax
    mov     r14, rdx
    mov     [cr_pending], rax           ; pending_chars: the same list
    mov     [cr_pending_count], rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r14
    jae     .built
    mov     r12d, [r13 + rbx * 4]
    ; (fg, bg): the input colors under dynamic, else (final color, none)
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     rdi, [rax + r12 * 8]
    mov     rax, [ch_bg]
    mov     rsi, [rax + r12 * 8]
    jmp     .colors
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [cr_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [cr_map]
    mov     rdi, [rcx + rax * 8]
    mov     rsi, NONE
.colors:
    cmp     byte [cr_key_valid], 0
    je      .derive
    cmp     rdi, [cr_key_fg]
    jne     .derive
    cmp     rsi, [cr_key_bg]
    je      .visible
.derive:
    call    cr_derive
.visible:
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [cr_symbol], rax
    mov     edi, r12d
    call    set_visible
    ; initial scene: the input symbol in the weak colors
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     edi, eax
    mov     rsi, [cr_symbol]
    mov     edx, 1
    mov     rcx, [cr_weak_fg]
    mov     r8, [cr_weak_bg]
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r12d
    mov     esi, ebp
    call    scene_activate
    ; fall path: to (column, canvas.bottom)
    mov     edi, r12d
    movsd   xmm0, [cr_fall_speed]
    mov     esi, CR_EASE_OUT_BOUNCE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax
    mov     rsi, 1 << 32                ; canvas.bottom = 1
    mov     rax, [ch_icol]
    mov     eax, [rax + r12 * 4]
    or      rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    PATH_PTR rax, rbp
    mov     eax, [rax + PA_NAME]
    mov     [cr_fall_name], eax
    ; weaken
    mov     edi, r12d
    mov     esi, CR_S_WEAKEN
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     edi, eax
    lea     rcx, [cr_weaken_fg]
    lea     rdx, [cr_weaken_bg]
    call    cr_apply
    ; top path: to (column, canvas.top) through the canvas center
    mov     edi, r12d
    movsd   xmm0, [cr_one]
    mov     esi, CR_EASE_OUT_QUINT
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, CR_P_TOP
    call    path_new
    mov     ebp, eax
    mov     rax, [center_row]
    shl     rax, 32
    mov     ecx, [center_col]
    or      rax, rcx
    mov     [cr_control], rax
    mov     rsi, [canvas_top]
    shl     rsi, 32
    mov     rax, [ch_icol]
    mov     eax, [rax + r12 * 4]
    or      rsi, rax
    mov     edi, ebp
    lea     rdx, [cr_control]
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    ; input path: back to the input coordinate
    mov     edi, r12d
    movsd   xmm0, [cr_one]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, CR_P_INPUT
    call    path_new
    mov     ebp, eax
    mov     rsi, [ch_irow]
    mov     esi, [rsi + r12 * 4]
    shl     rsi, 32
    mov     rax, [ch_icol]
    mov     eax, [rax + r12 * 4]
    or      rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; strengthen flash
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     edi, eax
    lea     rcx, [cr_flash_fg]
    lea     rdx, [cr_flash_bg]
    call    cr_apply
    mov     eax, ebp
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     eax, [rax + SC_NAME]
    mov     [cr_flash_name], eax
    ; strengthen: no colors at all (dynamic only) is one plain frame
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     edi, eax
    cmp     qword [cr_key_fg], NONE
    jne     .strengthen_gradient
    cmp     qword [cr_key_bg], NONE
    jne     .strengthen_gradient
    mov     rsi, [cr_symbol]
    mov     edx, 4
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .strengthen_named
.strengthen_gradient:
    lea     rcx, [cr_strengthen_fg]
    lea     rdx, [cr_strengthen_bg]
    call    cr_apply
.strengthen_named:
    mov     eax, ebp
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     eax, [rax + SC_NAME]
    mov     [cr_strengthen_name], eax
    ; dust: five random dust symbols, synced to the fall's distance
    mov     edi, r12d
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    xor     r15d, r15d
.dust:
    mov     edi, 3
    call    rng_below
    lea     rcx, [cr_dust_symbols]
    mov     rsi, [rcx + rax * 8]
    mov     edi, ebp
    mov     edx, 1
    mov     rcx, [cr_dust_fg]
    mov     r8, [cr_dust_bg]
    xor     r9d, r9d
    call    scene_add_frame
    inc     r15d
    cmp     r15d, 5
    jb      .dust
    mov     eax, ebp
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     ebp, [rax + SC_NAME]        ; dust name
    ; events
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, CR_S_WEAKEN
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, [cr_fall_name]
    call    event_register
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, CR_S_WEAKEN
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, CR_S_WEAKEN
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, ebp
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, CR_P_INPUT
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [cr_flash_name]
    call    event_register
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, [cr_flash_name]
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [cr_strengthen_name]
    call    event_register
    add     rsp, 16
    inc     rbx
    jmp     .char
.built:
    mov     rdi, [cr_pending]
    mov     rsi, [cr_pending_count]
    call    rng_shuffle32
    mov     qword [cr_fall_delay], 12
    mov     qword [cr_max_fall_delay], 12
    mov     qword [cr_min_fall_delay], 9
    mov     byte [cr_reset], 0
    mov     qword [cr_group_maxsize], 1
    mov     qword [cr_stage], CR_FALLING
    ; unvacuumed_chars: input_characters, shuffled
    mov     rdi, [input_count]
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     [cr_unvacuumed], rax
    mov     rcx, [input_count]
    mov     [cr_unvacuumed_count], rcx
    mov     rsi, [input_chars]
    xor     edx, edx
.copy:
    cmp     rdx, rcx
    jae     .shuffle
    mov     edi, [rsi + rdx * 4]
    mov     [rax + rdx * 4], edi
    inc     rdx
    jmp     .copy
.shuffle:
    mov     rdi, rax
    mov     rsi, rcx
    call    rng_shuffle32
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; cr_apply(edi=scene, rcx=fg gradient record, rdx=bg gradient record):
; apply_gradient_to_symbols([input symbol], 4, fg, bg). A record is
; (length, spectrum[16]); length 0 is None. Clobbers C.
cr_apply:
    sub     rsp, 8
    xor     eax, eax
    mov     r10, [rdx]
    test    r10, r10
    jz      .bg_none
    lea     rax, [rdx + 8]
.bg_none:
    push    r10
    push    rax
    xor     r8d, r8d
    mov     r9, [rcx]
    test    r9, r9
    jz      .fg_none
    lea     r8, [rcx + 8]
.fg_none:
    lea     rsi, [cr_symbol]
    mov     edx, 1
    mov     ecx, 4
    call    scene_apply_gradient
    add     rsp, 24
    ret

; cr_derive(rdi=fg or NONE, rsi=bg or NONE): the weak and dust colors and
; the weaken, strengthen flash and strengthen gradients of Crumble::build.
; Without dynamic handling fg is the final color and bg is NONE; with it and
; no input colors at all, the neutral gray stands in for fg where Rust uses
; it. Records the pair as the cache key. Clobbers C.
cr_derive:
    push    rbx
    push    rbp
    push    r12
    mov     [cr_key_fg], rdi
    mov     [cr_key_bg], rsi
    mov     byte [cr_key_valid], 1
    mov     rbx, rdi                    ; g
    mov     rbp, rsi                    ; bg
    cmp     rbx, NONE
    jne     .g
    cmp     rbp, NONE
    jne     .g
    mov     ebx, CR_NEUTRAL_GRAY
.g:
    ; weak / dust colors
    mov     rax, NONE
    mov     [cr_weak_fg], rax
    mov     [cr_weak_bg], rax
    mov     [cr_dust_fg], rax
    mov     [cr_dust_bg], rax
    cmp     rbx, NONE
    je      .bg_colors
    mov     rdi, rbx
    movsd   xmm0, [cr_weak_brightness]
    call    adjust_color_brightness
    mov     [cr_weak_fg], rax
    mov     rdi, rbx
    movsd   xmm0, [cr_dust_brightness]
    call    adjust_color_brightness
    mov     [cr_dust_fg], rax
.bg_colors:
    cmp     rbp, NONE
    je      .gradients
    mov     rdi, rbp
    movsd   xmm0, [cr_weak_brightness]
    call    adjust_color_brightness
    mov     [cr_weak_bg], rax
    mov     rdi, rbp
    movsd   xmm0, [cr_dust_brightness]
    call    adjust_color_brightness
    mov     [cr_dust_bg], rax
.gradients:
    ; weaken: weak -> dust in 9 steps, per channel present
    mov     rdi, [cr_weak_fg]
    mov     rsi, [cr_dust_fg]
    lea     r8, [cr_weaken_fg]
    mov     r12d, 9
    call    cr_pair
    mov     rdi, [cr_weak_bg]
    mov     rsi, [cr_dust_bg]
    lea     r8, [cr_weaken_bg]
    call    cr_pair
    ; strengthen flash: color -> white in 6 steps
    mov     rdi, rbx
    mov     esi, CR_WHITE
    lea     r8, [cr_flash_fg]
    mov     r12d, 6
    call    cr_pair
    mov     rdi, rbp
    mov     esi, CR_WHITE
    lea     r8, [cr_flash_bg]
    call    cr_pair
    ; strengthen: white -> color in 9 steps (the real fg, not the gray)
    mov     rsi, [cr_key_fg]
    mov     edi, CR_WHITE
    cmp     rsi, NONE
    jne     .strengthen_fg
    mov     rdi, rsi
.strengthen_fg:
    lea     r8, [cr_strengthen_fg]
    mov     r12d, 9
    call    cr_pair
    mov     rsi, rbp
    mov     edi, CR_WHITE
    cmp     rsi, NONE
    jne     .strengthen_bg
    mov     rdi, rsi
.strengthen_bg:
    lea     r8, [cr_strengthen_bg]
    call    cr_pair
    pop     r12
    pop     rbp
    pop     rbx
    ret

; cr_pair(rdi=from or NONE, rsi=to or NONE, r12=steps, r8=record):
; Gradient::with_steps([from, to], steps) into the record, or length 0
; (None) when either color is absent. Clobbers C except r12.
cr_pair:
    mov     qword [r8], 0
    cmp     rdi, NONE
    je      .none
    cmp     rsi, NONE
    je      .none
    push    r8
    mov     [cr_stops], rdi
    mov     [cr_stops + 8], rsi
    mov     [cr_steps], r12
    lea     rdi, [cr_stops]
    mov     esi, 2
    lea     rdx, [cr_steps]
    mov     ecx, 1
    add     r8, 8
    call    gradient_new
    pop     r8
    mov     [r8], rax
.none:
    ret

; cr_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
cr_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + CRUMBLE.final_steps]
    mov     rcx, [rbx + CRUMBLE.final_step_count]
    mov     rsi, [rbx + CRUMBLE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [cr_spectrum], rax
    mov     rdi, [rbx + CRUMBLE.final_stops]
    mov     rsi, [rbx + CRUMBLE.final_stop_count]
    mov     rdx, [rbx + CRUMBLE.final_steps]
    mov     rcx, [rbx + CRUMBLE.final_step_count]
    mov     r8, [cr_spectrum]
    call    gradient_new
    mov     rdi, [cr_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [cr_map_width], rax
    push    qword [rbx + CRUMBLE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [cr_map], rax
    pop     rbx
    ret

; crumble_next_frame -> eax = 1 for a frame, 0 when done. Crumble::next_frame.
crumble_next_frame:
    push    rbx
    push    r12
    push    r13
    mov     rax, [cr_stage]
    cmp     rax, CR_COMPLETE
    je      .finished
    cmp     rax, CR_VACUUMING
    je      .vacuuming
    cmp     rax, CR_RESETTING
    je      .resetting
    ; --- falling
    mov     rax, [cr_pending_pos]
    cmp     rax, [cr_pending_count]
    jae     .fall_check
    cmp     qword [cr_fall_delay], 0
    je      .fall_group
    dec     qword [cr_fall_delay]
    jmp     .fall_check
.fall_group:
    mov     edi, 1
    mov     rsi, [cr_group_maxsize]
    call    rng_randint
    mov     rbx, rax
.fall_one:
    test    rbx, rbx
    jle     .fall_delay
    dec     rbx
    mov     rax, [cr_pending_pos]
    cmp     rax, [cr_pending_count]
    jae     .fall_one
    inc     qword [cr_pending_pos]
    mov     rcx, [cr_pending]
    mov     r12d, [rcx + rax * 4]
    mov     edi, r12d
    mov     esi, CR_S_WEAKEN
    call    scene_activate_name
    mov     edi, r12d
    call    active_insert
    jmp     .fall_one
.fall_delay:
    mov     rdi, [cr_min_fall_delay]
    mov     rsi, [cr_max_fall_delay]
    call    rng_randint
    mov     [cr_fall_delay], rax
    mov     edi, 1
    mov     esi, 10
    call    rng_randint
    cmp     rax, 4
    jle     .fall_check
    inc     qword [cr_group_maxsize]
    xor     ecx, ecx
    mov     rax, [cr_min_fall_delay]
    dec     rax
    cmovl   rax, rcx
    mov     [cr_min_fall_delay], rax
    mov     rax, [cr_max_fall_delay]
    dec     rax
    cmovl   rax, rcx
    mov     [cr_max_fall_delay], rax
.fall_check:
    mov     rax, [cr_pending_pos]
    cmp     rax, [cr_pending_count]
    jb      .update
    call    active_empty
    test    eax, eax
    jz      .update
    mov     qword [cr_stage], CR_VACUUMING
    jmp     .update
.vacuuming:
    mov     rax, [cr_unvacuumed_pos]
    cmp     rax, [cr_unvacuumed_count]
    jae     .vacuum_check
    mov     edi, 3
    mov     esi, 10
    call    rng_randint
    mov     rbx, rax
.vacuum_one:
    test    rbx, rbx
    jle     .vacuum_check
    dec     rbx
    mov     rax, [cr_unvacuumed_pos]
    cmp     rax, [cr_unvacuumed_count]
    jae     .vacuum_one
    inc     qword [cr_unvacuumed_pos]
    mov     rcx, [cr_unvacuumed]
    mov     r12d, [rcx + rax * 4]
    mov     edi, r12d
    mov     esi, CR_P_TOP
    call    path_activate_name
    mov     edi, r12d
    call    active_insert
    jmp     .vacuum_one
.vacuum_check:
    call    active_empty
    test    eax, eax
    jz      .update
    mov     qword [cr_stage], CR_RESETTING
    jmp     .update
.resetting:
    cmp     byte [cr_reset], 0
    jne     .reset_check
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.reset_one:
    cmp     rbx, r13
    jae     .reset_done
    mov     edi, [r12 + rbx * 4]
    mov     esi, CR_P_INPUT
    call    path_activate_name
    mov     edi, [r12 + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .reset_one
.reset_done:
    mov     byte [cr_reset], 1
.reset_check:
    call    active_empty
    test    eax, eax
    jz      .update
    mov     qword [cr_stage], CR_COMPLETE
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
cr_fall_speed:      dq 0.65
cr_one:             dq 1.0
cr_weak_brightness: dq 0.65
cr_dust_brightness: dq 0.55

section .tstate
alignb 8
cr_spectrum:        resq 1
cr_map:             resq 1
cr_map_width:       resq 1
cr_dust_symbols:    resq 3
cr_symbol:          resq 1
cr_control:         resq 1
cr_stops:           resq 2
cr_steps:           resq 1
cr_key_fg:          resq 1
cr_key_bg:          resq 1
cr_weak_fg:         resq 1
cr_weak_bg:         resq 1
cr_dust_fg:         resq 1
cr_dust_bg:         resq 1
; gradient records: (length, spectrum[16])
cr_weaken_fg:       resq 17
cr_weaken_bg:       resq 17
cr_flash_fg:        resq 17
cr_flash_bg:        resq 17
cr_strengthen_fg:   resq 17
cr_strengthen_bg:   resq 17
cr_fall_name:       resd 1
cr_flash_name:      resd 1
cr_strengthen_name: resd 1
alignb 8
cr_pending:         resq 1
cr_pending_pos:     resq 1
cr_pending_count:   resq 1
cr_unvacuumed:      resq 1
cr_unvacuumed_pos:  resq 1
cr_unvacuumed_count: resq 1
cr_fall_delay:      resq 1
cr_max_fall_delay:  resq 1
cr_min_fall_delay:  resq 1
cr_group_maxsize:   resq 1
cr_stage:           resq 1
cr_reset:           resb 1
cr_key_valid:       resb 1
