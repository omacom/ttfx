; effects/blackhole.asm - "Characters are consumed by a black hole and
; explode outwards" (src/effects/blackhole.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Blackhole):
;
; Everything is created in exactly Rust's order, so every RNG draw and every
; auto-numbered scene and path name lines up. The starfield's visuals (7
; symbols x 7 colors, each with its 12-frame fade) are made once and reused.

struc BLACKHOLE
    .blackhole_color:   resq 1
    .star_colors:       resq 1          ; *const u64
    .star_count:        resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define STAR_SYMBOLS        7
%define STARFIELD_COLORS    7           ; with_steps(#4a4a4d -> #ffffff, 6)
%define FADE_FRAMES         12          ; 11 fade colors, then " "

; phases
%define PH_FORMING          0
%define PH_CONSUMING        1
%define PH_COLLAPSING       2
%define PH_EXPLODING        3
%define PH_COMPLETE         4

; path names
%define P_BLACKHOLE         NAME_LITERAL + 0
%define P_ROTATION          NAME_LITERAL + 1
%define P_SINGULARITY       NAME_LITERAL + 2
; scene names
%define S_BLACKHOLE         NAME_LITERAL + 0

%define EASE_IN_OUT_SINE    3
%define EASE_IN_CUBIC       7
%define EASE_IN_EXPO        16
%define EASE_OUT_EXPO       17

; bh_pack_center -> rax = canvas.center (packed). Clobbers rcx.
%macro BH_CENTER 0
    mov     rax, [center_row]
    shl     rax, 32
    mov     ecx, [center_col]
    or      rax, rcx
%endmacro

section .text

; blackhole_build: BlackholeIterator.__init__ + build().
blackhole_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    ; blackhole_radius = max(min(round(width * 0.3), round(height * 0.2)), 3)
    cvtsi2sd xmm0, qword [canvas_right]
    mulsd   xmm0, [bh_point3]
    call    round_half_even
    mov     rbx, rax
    cvtsi2sd xmm0, qword [canvas_top]
    mulsd   xmm0, [bh_point2]
    call    round_half_even
    cmp     rax, rbx
    cmovg   rax, rbx
    mov     ecx, 3
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [bh_radius], rax
    call    bh_final_color_map
    ; ctx.preexisting_colors_present
    mov     r12, [input_chars]
    mov     r13, [input_count]
    xor     ebx, ebx
.present:
    cmp     rbx, r13
    jae     .prepare
    mov     edi, [r12 + rbx * 4]
    mov     rax, [ch_fg]
    mov     rcx, [ch_bg]
    mov     rax, [rax + rdi * 8]
    and     rax, [rcx + rdi * 8]
    inc     rbx
    cmp     rax, NONE
    je      .present
    mov     byte [bh_preexisting], 1
.prepare:
    call    bh_prepare
    ; formation_delay = max(100 // len(blackhole_chars), 6)
    mov     eax, 100
    xor     edx, edx
    div     qword [bh_count]
    mov     ecx, 6
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [bh_formation_delay], rax
    mov     [bh_f_delay], rax
    mov     qword [bh_phase], PH_FORMING
    mov     qword [bh_form_pos], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bh_make_visuals: the symbol tables, the starfield spectrum, each starfield
; color's fade to black, and every starfield visual.
bh_make_visuals:
    push    rbx
    push    rbp
    push    r12
    xor     ebx, ebx
.symbols:
    lea     rax, [bh_star_codes]
    mov     edi, [rax + rbx * 4]
    call    utf8_pack
    lea     rcx, [bh_symbols]
    mov     [rcx + rbx * 8], rax
    lea     rax, [bh_unstable_codes]
    mov     edi, [rax + rbx * 4]
    call    utf8_pack
    lea     rcx, [bh_unstable]
    mov     [rcx + rbx * 8], rax
    inc     ebx
    cmp     ebx, STAR_SYMBOLS
    jb      .symbols
    mov     edi, ' '
    call    utf8_pack
    mov     [bh_space], rax
    ; starfield_colors = Gradient::with_steps([#4a4a4d, #ffffff], 6)
    mov     qword [bh_pair], 0x4a4a4d
    mov     qword [bh_pair + 8], 0xffffff
    lea     rdi, [bh_pair]
    mov     esi, 2
    lea     rdx, [bh_six]
    mov     ecx, 1
    lea     r8, [bh_starfield]
    call    gradient_new
    ; gradient_map[c] = Gradient::with_steps([starfield[c], #000000], 10)
    xor     ebx, ebx
.fades:
    lea     rax, [bh_starfield]
    mov     rax, [rax + rbx * 8]
    mov     [bh_pair], rax
    mov     qword [bh_pair + 8], 0
    lea     rdi, [bh_pair]
    mov     esi, 2
    lea     rdx, [bh_ten_steps]
    mov     ecx, 1
    imul    r8, rbx, 16 * 8
    lea     rax, [bh_fades]
    add     r8, rax
    call    gradient_new
    inc     ebx
    cmp     ebx, STARFIELD_COLORS
    jb      .fades
    ; visuals: index = symbol * 7 + color
    xor     ebx, ebx
.visual:
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, STARFIELD_COLORS
    div     ecx                         ; eax = symbol, edx = color
    mov     r12d, eax
    mov     ebp, edx
    lea     rax, [bh_starfield]
    mov     rdi, [rax + rbp * 8]
    mov     rsi, NONE
    lea     rax, [bh_symbols]
    mov     rdx, [rax + r12 * 8]
    xor     ecx, ecx
    call    visual_make
    lea     rcx, [bh_star_vis]
    mov     [rcx + rbx * 4], eax
    ; the consumed scene's frames: the color's fade, then " "
    shl     ebp, 4                      ; fade row (16 colors)
    shl     r12d, 8                     ; symbol * 256 | fade index << 4 | k
    or      r12d, ebp
.fade_frame:
    mov     eax, r12d
    and     eax, 15
    cmp     eax, FADE_FRAMES - 1
    je      .space
    mov     ecx, r12d
    and     ecx, 0xff
    lea     rax, [bh_fades]
    mov     rdi, [rax + rcx * 8]
    mov     rsi, NONE
    mov     ecx, r12d
    shr     ecx, 8
    lea     rax, [bh_symbols]
    mov     rdx, [rax + rcx * 8]
    xor     ecx, ecx
    call    visual_make
    imul    ecx, ebx, FADE_FRAMES
    mov     edx, r12d
    and     edx, 15
    add     ecx, edx
    lea     rdx, [bh_fade_vis]
    mov     [rdx + rcx * 4], eax
    inc     r12d
    jmp     .fade_frame
.space:
    mov     rdi, NONE
    mov     rsi, NONE
    mov     rdx, [bh_space]
    xor     ecx, ecx
    call    visual_make
    imul    ecx, ebx, FADE_FRAMES
    add     ecx, FADE_FRAMES - 1
    lea     rdx, [bh_fade_vis]
    mov     [rdx + rcx * 4], eax
    inc     ebx
    cmp     ebx, STAR_SYMBOLS * STARFIELD_COLORS
    jb      .visual
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bh_prepare: BlackholeIterator.prepare_blackhole.
bh_prepare:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    bh_make_visuals
    ; available_chars = input_characters; take radius * 3 at random
    mov     rdi, [input_count]
    lea     rdi, [rdi * 4 + 4]
    call    alloc
    mov     r12, rax                    ; available
    mov     rdi, rax
    mov     rsi, [input_chars]
    mov     rcx, [input_count]
    rep     movsd
    mov     rdi, [input_count]
    lea     rdi, [rdi * 4 + 4]
    call    alloc
    mov     [bh_chars], rax
    mov     rdi, [input_count]
    lea     rdi, [rdi * 4 + 4]
    call    alloc
    mov     [bh_consume], rax
    mov     r13, [input_count]          ; available count
    imul    r14, [bh_radius], 3
.take:
    cmp     [bh_count], r14
    jge     .taken
    test    r13, r13
    jz      .taken
    xor     edi, edi
    mov     rsi, r13
    call    rng_randrange
    mov     ecx, [r12 + rax * 4]
    mov     rdx, [bh_chars]
    mov     rsi, [bh_count]
    mov     [rdx + rsi * 4], ecx
    inc     qword [bh_count]
    ; available.remove(index)
    lea     rdi, [r12 + rax * 4]
    lea     rsi, [rdi + 4]
    lea     rcx, [r13 - 1]
    sub     rcx, rax
    rep     movsd
    dec     r13
    jmp     .take
.taken:
    ; membership bitmap over slots
    mov     edi, [char_count]
    add     rdi, 63
    shr     rdi, 6
    lea     rdi, [rdi * 8 + 8]
    call    alloc
    mov     [bh_bits], rax
    xor     ecx, ecx
.bits:
    cmp     rcx, [bh_count]
    jae     .ring
    mov     rdx, [bh_chars]
    mov     edx, [rdx + rcx * 4]
    bts     [rax], rdx
    inc     rcx
    jmp     .bits
.ring:
    BH_CENTER
    mov     rdi, rax
    mov     rsi, [bh_radius]
    mov     rdx, [bh_count]
    mov     ecx, 1
    call    find_coords_on_circle
    cmp     rdx, [bh_count]
    jb      .short_ring
    mov     r14, rax                    ; ring positions
    mov     r15, [bh_count]
    xor     ebx, ebx
.ring_char:
    cmp     rbx, r15
    jae     .starfield
    mov     rax, [bh_chars]
    mov     r12d, [rax + rbx * 4]
    ; "blackhole": 0.7, in_out_sine, to the ring position
    mov     edi, r12d
    movsd   xmm0, [bh_speed_form]
    mov     esi, EASE_IN_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, P_BLACKHOLE
    call    path_new
    mov     edi, eax
    mov     rsi, [r14 + rbx * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; "blackhole" scene: "*" in the blackhole color
    mov     edi, r12d
    mov     esi, S_BLACKHOLE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     edi, eax
    mov     rsi, [bh_symbols]           ; "*"
    mov     edx, 1
    mov     rcx, [effect_config]
    mov     rcx, [rcx + BLACKHOLE.blackhole_color]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, P_BLACKHOLE
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    add     rsp, 16
    ; "blackhole_rotation": 0.45, looping, the ring from this position on
    mov     edi, r12d
    movsd   xmm0, [bh_speed_rotate]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    mov     r8d, 1
    mov     r9d, P_ROTATION
    call    path_new
    mov     ebp, eax
    xor     r13d, r13d
.rotation:
    cmp     r13, r15
    jae     .ring_next
    lea     rax, [rbx + r13]
    cmp     rax, r15
    jb      .index
    sub     rax, r15
.index:
    mov     edi, ebp
    mov     rsi, [r14 + rax * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    inc     r13
    jmp     .rotation
.ring_next:
    inc     rbx
    jmp     .ring_char
.starfield:
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     ebx, ebx
.star:
    cmp     rbx, r15
    jae     .shuffle
    mov     r12d, [r14 + rbx * 4]
    mov     edi, r12d
    call    set_visible
    mov     edi, STAR_SYMBOLS
    call    rng_below
    imul    ebp, eax, STARFIELD_COLORS
    mov     edi, STARFIELD_COLORS
    call    rng_below
    add     ebp, eax                    ; symbol * 7 + color
    ; starting scene: the star
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    mov     edi, eax
    lea     rax, [bh_star_vis]
    mov     esi, [rax + rbp * 4]
    mov     edx, 1
    call    scene_add_frame_visual
    mov     edi, r12d
    mov     esi, r13d
    call    scene_activate
    mov     rax, [bh_bits]
    bt      [rax], r12
    jc      .star_next
    ; outside the blackhole: a random starfield position, then the singularity
    xor     edi, edi
    xor     esi, esi
    call    canvas_random_coord
    mov     [rsp], rax
    movsd   xmm0, [bh_speed_min]
    movsd   xmm1, [bh_speed_max]
    call    rng_uniform
    movsd   [rsp + 8], xmm0
    mov     edi, r12d
    mov     rsi, [rsp]
    call    set_coordinate
    mov     edi, r12d
    movsd   xmm0, [rsp + 8]
    mov     esi, EASE_IN_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, P_SINGULARITY
    call    path_new
    mov     r13d, eax
    BH_CENTER
    mov     rsi, rax
    mov     edi, r13d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; consumed scene: the fade to black and " ", synced to distance
    mov     edi, r12d
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    imul    ebp, ebp, FADE_FRAMES
    mov     [rsp + 16], rbp
.consumed_frame:
    mov     edi, r13d
    lea     rax, [bh_fade_vis]
    mov     esi, [rax + rbp * 4]
    mov     edx, 1
    call    scene_add_frame_visual
    inc     ebp
    mov     eax, ebp
    sub     rax, [rsp + 16]
    cmp     eax, FADE_FRAMES
    jb      .consumed_frame
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, P_SINGULARITY
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 2
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, P_SINGULARITY
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9, r13
    shl     r9, SCENE_SHIFT
    add     r9, [scenes]
    mov     r9d, [r9 + SC_NAME]
    call    event_register
    add     rsp, 16
    mov     rax, [bh_consume]
    mov     rcx, [bh_consume_count]
    mov     [rax + rcx * 4], r12d
    inc     qword [bh_consume_count]
.star_next:
    inc     rbx
    jmp     .star
.shuffle:
    mov     rdi, [bh_consume]
    mov     rsi, [bh_consume_count]
    call    rng_shuffle32
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.short_ring:
    lea     rdi, [msg_bh_ring]
    mov     esi, msg_bh_ring_len
    jmp     fatal

; bh_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
bh_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + BLACKHOLE.final_steps]
    mov     rcx, [rbx + BLACKHOLE.final_step_count]
    mov     rsi, [rbx + BLACKHOLE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [bh_final_spectrum], rax
    mov     rdi, [rbx + BLACKHOLE.final_stops]
    mov     rsi, [rbx + BLACKHOLE.final_stop_count]
    mov     rdx, [rbx + BLACKHOLE.final_steps]
    mov     rcx, [rbx + BLACKHOLE.final_step_count]
    mov     r8, [bh_final_spectrum]
    call    gradient_new
    mov     rdi, [bh_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [bh_final_map_width], rax
    push    qword [rbx + BLACKHOLE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [bh_final_map], rax
    pop     rbx
    ret

; bh_path_name(eax=path index) -> eax = its name.
bh_path_name:
    shl     rax, 7                      ; PATH_SIZE
    add     rax, [paths]
    mov     eax, [rax + PA_NAME]
    ret

; bh_scene_name(eax=scene index) -> eax = its name.
bh_scene_name:
    shl     rax, SCENE_SHIFT
    add     rax, [scenes]
    mov     eax, [rax + SC_NAME]
    ret

; blackhole_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
blackhole_next_frame:
    push    rbx
    push    r12
    push    r13
    mov     rax, [bh_phase]
    cmp     rax, PH_COMPLETE
    jne     .phase
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .update
.phase:
    cmp     rax, PH_FORMING
    je      .forming
    cmp     rax, PH_CONSUMING
    je      .consuming
    cmp     rax, PH_COLLAPSING
    je      .collapsing
    ; exploding: once every blackhole character has stopped moving and animating
    xor     ebx, ebx
.settled:
    cmp     rbx, [bh_count]
    jae     .explode
    mov     rax, [bh_chars]
    mov     edi, [rax + rbx * 4]
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    jne     .update
    mov     rax, [ch_scene]
    cmp     dword [rax + rdi * 4], NONE
    jne     .update
    inc     rbx
    jmp     .settled
.explode:
    call    bh_explode
    mov     qword [bh_phase], PH_COMPLETE
    jmp     .update
.collapsing:
    call    bh_collapse
    mov     qword [bh_phase], PH_EXPLODING
    jmp     .update
.forming:
    mov     rbx, [bh_form_pos]
    cmp     rbx, [bh_count]
    jae     .formed
    cmp     qword [bh_f_delay], 0
    je      .next_char
    dec     qword [bh_f_delay]
    jmp     .update
.next_char:
    inc     qword [bh_form_pos]
    mov     rax, [bh_chars]
    mov     r12d, [rax + rbx * 4]
    mov     edi, r12d
    mov     esi, P_BLACKHOLE
    call    path_activate_name
    mov     edi, r12d
    mov     esi, S_BLACKHOLE
    call    scene_activate_name
    mov     edi, r12d
    call    active_insert
    mov     rax, [bh_formation_delay]
    mov     [bh_f_delay], rax
    jmp     .update
.formed:
    call    active_empty
    test    eax, eax
    jz      .update
    ; rotate_blackhole
    xor     ebx, ebx
.rotate:
    cmp     rbx, [bh_count]
    jae     .rotating
    mov     rax, [bh_chars]
    mov     r12d, [rax + rbx * 4]
    mov     edi, r12d
    mov     esi, P_ROTATION
    call    path_activate_name
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .rotate
.rotating:
    mov     qword [bh_phase], PH_CONSUMING
    jmp     .update
.consuming:
    mov     r13, [bh_consume_count]
    test    r13, r13
    jz      .check_consumed
    xor     ebx, ebx
.consume:
    cmp     rbx, r13
    jae     .consumed
    mov     rax, [bh_consume]
    mov     r12d, [rax + rbx * 4]
    mov     edi, r12d
    mov     esi, P_SINGULARITY
    call    path_activate_name
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .consume
.consumed:
    mov     qword [bh_consume_count], 0
    jmp     .update
.check_consumed:
    ; every active character belongs to the blackhole
    mov     ecx, [char_count]
    add     rcx, 63
    shr     rcx, 6
    mov     rax, [active_bits]
    mov     rdx, [bh_bits]
    xor     ebx, ebx
.word:
    cmp     rbx, rcx
    jae     .collapse_next
    mov     r8, [rdx + rbx * 8]
%if TIER >= 3
    andn    r8, r8, [rax + rbx * 8]
%else
    not     r8
    and     r8, [rax + rbx * 8]
%endif
    jnz     .update
    inc     rbx
    jmp     .word
.collapse_next:
    mov     qword [bh_phase], PH_COLLAPSING
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

; bh_collapse: BlackholeIterator.collapse_blackhole.
bh_collapse:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    BH_CENTER
    mov     rdi, rax
    mov     rsi, [bh_radius]
    add     rsi, 3
    mov     rdx, [bh_count]
    mov     ecx, 1
    call    find_coords_on_circle
    cmp     rdx, [bh_count]
    jb      .short_ring
    mov     r14, rax
    xor     ebx, ebx
.char:
    cmp     rbx, [bh_count]
    jae     .done
    mov     rax, [bh_chars]
    mov     r12d, [rax + rbx * 4]
    ; expand to the wider ring, then collapse to the center
    mov     edi, r12d
    movsd   xmm0, [bh_speed_expand]
    mov     esi, EASE_IN_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax
    mov     edi, eax
    mov     rsi, [r14 + rbx * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, r12d
    movsd   xmm0, [bh_speed_collapse]
    mov     esi, EASE_IN_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    BH_CENTER
    mov     rsi, rax
    mov     edi, r13d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     eax, r13d
    call    bh_path_name
    mov     r15d, eax                   ; collapse path name
    push    0
    push    0
    mov     eax, ebp
    call    bh_path_name
    mov     ecx, eax
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, r15d
    call    event_register
    add     rsp, 16
    test    rbx, rbx
    jnz     .activate
    ; the point character: 3 x 7 unstable symbols in random star colors
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp], rax
    mov     dword [rsp + 8], 0
.point_frame:
    mov     rax, [effect_config]
    mov     rdi, [rax + BLACKHOLE.star_count]
    call    rng_below
    mov     rcx, [effect_config]
    mov     rcx, [rcx + BLACKHOLE.star_colors]
    mov     rcx, [rcx + rax * 8]
    mov     eax, [rsp + 8]
    xor     edx, edx
    mov     esi, STAR_SYMBOLS
    div     esi
    lea     rax, [bh_unstable]
    mov     rsi, [rax + rdx * 8]
    mov     edi, [rsp]
    mov     edx, 3
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     dword [rsp + 8]
    cmp     dword [rsp + 8], 3 * STAR_SYMBOLS
    jb      .point_frame
    push    0
    push    0
    mov     eax, [rsp + 16]
    call    bh_scene_name
    mov     r9d, eax
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, r15d
    mov     r8d, ACT_ACTIVATE_SCENE
    call    event_register
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, r15d
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 3
    call    event_register
    add     rsp, 16
.activate:
    mov     edi, r12d
    mov     esi, ebp
    call    path_activate
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .char
.done:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.short_ring:
    lea     rdi, [msg_bh_ring]
    mov     esi, msg_bh_ring_len
    jmp     fatal

; bh_explode: BlackholeIterator.explode_singularity.
;
; find_coords_on_circle(input_coord, 3, 5) is the same five offsets for
; every integer origin: none of them is near a rounding boundary (the
; doubled x offsets are 6, +-1.854, +-4.854 and the y offsets 0, +-2.853,
; +-1.763), so they are computed once around (0, 0).
bh_explode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    ; [rsp] nearby coord, [rsp+8] star color, [rsp+16] explode scene,
    ; [rsp+24] cooling scene, [rsp+32] input symbol, [rsp+40] input coord,
    ; [rsp+48] input path
    xor     edi, edi
    mov     esi, 3
    mov     edx, 5
    mov     ecx, 1
    call    find_coords_on_circle
    cmp     rdx, 5
    jb      .short_ring
    mov     rsi, rax
    lea     rdi, [bh_offsets]
    mov     ecx, 5
    rep     movsq
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r15
    jae     .done
    mov     r12d, [r14 + rbx * 4]
    mov     edi, r12d
    call    char_input_coord
    mov     [rsp + 40], rax
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [rsp + 32], rax
    ; nearby: one of the five circle points, speed randint(3, 4) / 10
    xor     edi, edi
    mov     esi, 5
    call    rng_randrange
    lea     rcx, [bh_offsets]
    mov     rcx, [rcx + rax * 8]
    mov     rax, [rsp + 40]
    mov     rdx, rax
    shr     rdx, 32
    mov     rsi, rcx
    shr     rsi, 32
    add     edx, esi                    ; row
    add     eax, ecx                    ; column
    shl     rdx, 32
    or      rax, rdx
    mov     [rsp], rax
    mov     edi, 3
    mov     esi, 4
    call    rng_randint
    cvtsi2sd xmm0, rax
    divsd   xmm0, [bh_ten]
    mov     edi, r12d
    mov     esi, EASE_OUT_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax
    mov     edi, eax
    mov     rsi, [rsp]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; back home: speed randint(4, 6) / 100
    mov     edi, 4
    mov     esi, 6
    call    rng_randint
    cvtsi2sd xmm0, rax
    divsd   xmm0, [bh_hundred]
    mov     edi, r12d
    mov     esi, EASE_IN_CUBIC
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     [rsp + 48], rax             ; input path
    mov     edi, eax
    mov     rsi, [rsp + 40]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, 6
    call    rng_below
    lea     rcx, [bh_explode_colors]
    mov     rax, [rcx + rax * 8]
    mov     [rsp + 8], rax
    ; explode scene: the input symbol in the star color
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + 16], rax
    mov     edi, eax
    mov     rsi, [rsp + 32]
    mov     edx, 1
    mov     rcx, [rsp + 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r12d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + 24], rax
    ; cooling scene
    cmp     qword [cfg_existing_colors], 1
    jne     .final
    cmp     byte [bh_preexisting], 0
    je      .final
    call    bh_cool_dynamic
    jmp     .events
.final:
    ; star color -> final gradient color in 10 steps, 20 ticks each
    mov     rax, [rsp + 8]
    mov     [bh_pair], rax
    mov     rax, [rsp + 40]
    mov     rdx, rax
    sar     rdx, 32
    sub     rdx, [text_bottom]
    imul    rdx, [bh_final_map_width]
    movsxd  rax, eax
    add     rax, rdx
    sub     rax, [text_left]
    mov     rcx, [bh_final_map]
    mov     rax, [rcx + rax * 8]
    mov     [bh_pair + 8], rax
    lea     rdi, [bh_pair]
    mov     esi, 2
    lea     rdx, [bh_ten_steps]
    mov     ecx, 1
    lea     r8, [bh_pair_spectrum]
    call    gradient_new
    mov     r13d, eax
    push    r13
    xor     r13d, r13d
.cool_frame:
    cmp     r13d, [rsp]
    jae     .cooled
    mov     edi, [rsp + 8 + 24]
    mov     rsi, [rsp + 8 + 32]
    mov     edx, 20
    lea     rax, [bh_pair_spectrum]
    mov     rcx, [rax + r13 * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r13d
    jmp     .cool_frame
.cooled:
    pop     rax
.events:
    ; nearby complete -> the input path and the cooling scene
    push    0
    push    0
    mov     eax, ebp
    call    bh_path_name
    mov     r13d, eax                   ; nearby path name
    mov     eax, [rsp + 16 + 48]
    call    bh_path_name
    mov     r9d, eax
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, r13d
    mov     r8d, ACT_ACTIVATE_PATH
    call    event_register
    mov     eax, [rsp + 16 + 24]
    call    bh_scene_name
    mov     r9d, eax
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, r13d
    mov     r8d, ACT_ACTIVATE_SCENE
    call    event_register
    add     rsp, 16
    mov     edi, r12d
    mov     esi, [rsp + 16]
    call    scene_activate
    mov     edi, r12d
    mov     esi, ebp
    call    path_activate
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .char
.done:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.short_ring:
    lea     rdi, [msg_bh_ring]
    mov     esi, msg_bh_ring_len
    jmp     fatal

; bh_cool_dynamic(r12d=slot; bh_explode's frame at [rsp+8]): the cooling
; scene under --existing-color-handling dynamic with input colors present -
; the input colors as is, or gradients from the star color to them.
bh_cool_dynamic:
    push    rbx
    push    rbp
    ; bh_explode's locals are now at [rsp + 24]
    mov     rax, [ch_fg]
    mov     rbx, [rax + r12 * 8]        ; input fg
    mov     rax, [ch_bg]
    mov     rbp, [rax + r12 * 8]        ; input bg
    cmp     rbx, NONE
    jne     .gradients
    cmp     rbp, NONE
    jne     .gradients
    mov     edi, [rsp + 24 + 24]
    mov     rsi, [rsp + 24 + 32]
    mov     edx, 1
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    pop     rbp
    pop     rbx
    ret
.gradients:
    xor     eax, eax
    mov     [bh_fg_len], rax
    mov     [bh_bg_len], rax
    cmp     rbx, NONE
    je      .bg
    mov     rax, [rsp + 24 + 8]
    mov     [bh_pair], rax
    mov     [bh_pair + 8], rbx
    lea     rdi, [bh_pair]
    mov     esi, 2
    lea     rdx, [bh_ten_steps]
    mov     ecx, 1
    lea     r8, [bh_pair_spectrum]
    call    gradient_new
    mov     [bh_fg_len], rax
.bg:
    cmp     rbp, NONE
    je      .apply
    mov     rax, [rsp + 24 + 8]
    mov     [bh_pair], rax
    mov     [bh_pair + 8], rbp
    lea     rdi, [bh_pair]
    mov     esi, 2
    lea     rdx, [bh_ten_steps]
    mov     ecx, 1
    lea     r8, [bh_bg_spectrum]
    call    gradient_new
    mov     [bh_bg_len], rax
.apply:
    mov     edi, [rsp + 24 + 24]
    lea     rsi, [rsp + 24 + 32]        ; [input symbol]
    mov     edx, 1
    mov     ecx, 20
    xor     r8d, r8d
    xor     r9d, r9d
    cmp     rbx, NONE
    je      .no_fg
    lea     r8, [bh_pair_spectrum]
    mov     r9d, [bh_fg_len]
.no_fg:
    xor     eax, eax
    xor     r10d, r10d
    cmp     rbp, NONE
    je      .no_bg
    lea     rax, [bh_bg_spectrum]
    mov     r10d, [bh_bg_len]
.no_bg:
    push    r10
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
bh_point3:          dq 0.3
bh_point2:          dq 0.2
bh_speed_form:      dq 0.7
bh_speed_rotate:    dq 0.45
bh_speed_min:       dq 0.17
bh_speed_max:       dq 0.30
bh_speed_expand:    dq 0.2
bh_speed_collapse:  dq 0.3
bh_ten:             dq 10.0
bh_hundred:         dq 100.0
bh_six:             dq 6
bh_ten_steps:       dq 10
bh_explode_colors:  dq 0xffcc0d, 0xff7326, 0xff194d, 0xbf2669, 0x702a8c, 0x049dbf
; * ' ` ¤ • ° ·
bh_star_codes:      dd '*', 0x27, 0x60, 0xa4, 0x2022, 0xb0, 0xb7
; ◦ ◎ ◉ ● ◉ ◎ ◦
bh_unstable_codes:  dd 0x25e6, 0x25ce, 0x25c9, 0x25cf, 0x25c9, 0x25ce, 0x25e6
STR msg_bh_ring, "ttfx: asm engine: blackhole ring has too few positions", 10

section .tstate
alignb 8
bh_radius:          resq 1
bh_chars:           resq 1          ; u32 slots, in selection order
bh_count:           resq 1
bh_bits:            resq 1          ; membership bitmap over slots
bh_consume:         resq 1          ; u32 slots awaiting consumption
bh_consume_count:   resq 1
bh_formation_delay: resq 1
bh_f_delay:         resq 1
bh_form_pos:        resq 1
bh_phase:           resq 1
bh_final_spectrum:  resq 1
bh_final_map:       resq 1
bh_final_map_width: resq 1
bh_symbols:         resq STAR_SYMBOLS
bh_unstable:        resq STAR_SYMBOLS
bh_space:           resq 1
bh_starfield:       resq 8
bh_fades:           resq STARFIELD_COLORS * 16
bh_offsets:         resq 5
bh_pair:            resq 2
bh_pair_spectrum:   resq 16
bh_bg_spectrum:     resq 16
bh_fg_len:          resq 1
bh_bg_len:          resq 1
bh_star_vis:        resd STAR_SYMBOLS * STARFIELD_COLORS
bh_fade_vis:        resd STAR_SYMBOLS * STARFIELD_COLORS * FADE_FRAMES
bh_preexisting:     resb 1