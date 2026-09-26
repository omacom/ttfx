; effects/thunderstorm.asm - "Create a thunderstorm in the terminal"
; (src/effects/thunderstorm.rs).
;
; Two particle pools (rain, sparks) and a hand-managed stack of strike
; characters (available / pending / active lists). The storm budget reads
; clock_monotonic at exactly Rust's points: build, fade_complete and every
; storm frame. Characters are created, scenes built and RNG draws taken in
; Rust's order, so slots, ids and the random stream line up.
;
; Per-character words:
;   text characters:   ch_user0 = glow | fade << 32, ch_user1 = unfade | flash << 32
;   sparks:            ch_user0 = glow scene
;   strike characters: ch_user0 = flash scene, ch_user1 = strike symbol index

struc THUNDERSTORM
    .lightning_color:   resq 1
    .glowing_color:     resq 1
    .text_glow_time:    resq 1
    .rain_symbols:      resq 1          ; *const u64 packed symbols
    .rain_symbol_count: resq 1
    .spark_symbols:     resq 1
    .spark_symbol_count: resq 1
    .spark_glow_color:  resq 1
    .spark_glow_time:   resq 1
    .storm_time:        resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define TS_GLOW             NAME_LITERAL + 0
%define TS_FADE             NAME_LITERAL + 1
%define TS_UNFADE           NAME_LITERAL + 2
%define TS_FLASH            NAME_LITERAL + 3

%define TS_PRE_STORM        0
%define TS_WAITING          1
%define TS_STORM            2
%define TS_COMPLETE         3

%define TS_EASE_OUT_QUINT   14
%define TS_EASE_IN_CIRC     19

%define TS_LIST_LIMIT       (1 << 24)   ; entries per strike / glow list

; Gradient::with_steps lengths: two stops and 7 steps give 8 colors, the
; looped flash 15, the strike fade (6 steps) 7.
%define TS_GRAD             8
%define TS_FLASH_LEN        15
%define TS_STRIKE_FADE_LEN  7

section .text

; thunderstorm_build: Thunderstorm::new + build().
thunderstorm_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    ; the strike and glow lists share one reservation
    mov     rdi, TS_LIST_LIMIT * 4 * 4
    call    reserve
    mov     [ts_pending], rax
    add     rax, TS_LIST_LIMIT * 4
    mov     [ts_available], rax
    add     rax, TS_LIST_LIMIT * 4
    mov     [ts_active], rax
    add     rax, TS_LIST_LIMIT * 4
    mov     [ts_glow], rax
    mov     rbx, [effect_config]
    ; ParticlePool::new for rain (unbounded) and sparks (at most 2000); both
    ; emit with ParticleReset { clear_events, ..default }
    lea     rdi, [ts_rain_pool]
    mov     rsi, [rbx + THUNDERSTORM.rain_symbols]
    mov     rdx, [rbx + THUNDERSTORM.rain_symbol_count]
    mov     rcx, -1
    xor     r8d, r8d
    call    pool_init
    mov     qword [ts_rain_pool + POOL.reset], RESET_DEFAULT | RESET_CLEAR_EVENTS
    lea     rax, [ts_init_raindrop]
    mov     [ts_rain_pool + POOL.initializer], rax
    lea     rdi, [ts_spark_pool]
    mov     rsi, [rbx + THUNDERSTORM.spark_symbols]
    mov     rdx, [rbx + THUNDERSTORM.spark_symbol_count]
    mov     ecx, 2000
    xor     r8d, r8d
    call    pool_init
    mov     qword [ts_spark_pool + POOL.reset], RESET_DEFAULT | RESET_CLEAR_EVENTS
    lea     rax, [ts_init_spark]
    mov     [ts_spark_pool + POOL.initializer], rax
    ; __init__ preamble: rain, the spark gradient, sparks, the storm clock
    lea     rdi, [ts_rain_pool]
    mov     esi, 50
    call    pool_preallocate
    mov     rdi, [rbx + THUNDERSTORM.spark_glow_color]
    call    ts_background
    mov     rsi, rax
    lea     rdx, [ts_spark_spectrum]
    call    ts_gradient2
    mov     [ts_spark_len], eax
    lea     rdi, [ts_spark_pool]
    mov     esi, 200
    call    pool_preallocate
    call    clock_monotonic
    movsd   [ts_storm_start], xmm0
    ; build(): the final gradient mapping, 200 strike characters
    call    ts_final_color_map
    mov     edi, 200
    call    ts_build_strike_characters
    call    ts_strike_visuals
    ; scenes on the text characters
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [ts_text], rax
    mov     [ts_text_count], rdx
    xor     r12d, r12d
.text:
    cmp     r12, [ts_text_count]
    jae     .reference
    mov     rax, [ts_text]
    mov     edi, [rax + r12 * 4]
    call    ts_text_scenes
    inc     r12
    jmp     .text
.reference:
    ; the first character's fade completing starts the storm
    cmp     qword [ts_text_count], 0
    je      .built
    push    0
    push    0
    mov     rax, [ts_text]
    mov     edi, [rax]
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FADE
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_cb_fade_complete]
    call    event_register
    add     rsp, 16
.built:
    mov     rax, [ts_branch_default]
    mov     [ts_branch_chance], rax
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ts_background -> rax: TerminalConfig.terminal_background_color. Keeps rdi.
ts_background:
    mov     rax, [request]
    mov     rax, [rax + RQ_BACKGROUND]
    ret

; ts_gradient2(rdi=start, rsi=end, rdx=out) -> eax = length:
; Gradient::with_steps([start, end], 7, false).
ts_gradient2:
    mov     [ts_stops], rdi
    mov     [ts_stops + 8], rsi
    lea     rdi, [ts_stops]
    mov     esi, 2
    mov     r8, rdx
    lea     rdx, [ts_seven]
    mov     ecx, 1
    jmp     gradient_new

; ts_gradient_loop(rdi=start, rsi=end, rdx=out) -> eax = length:
; Gradient::with_steps([start, end], 7, true) - the stops go round.
ts_gradient_loop:
    mov     [ts_stops], rdi
    mov     [ts_stops + 8], rsi
    mov     [ts_stops + 16], rdi
    lea     rdi, [ts_stops]
    mov     esi, 3
    mov     r8, rdx
    lea     rdx, [ts_seven]
    mov     ecx, 1
    jmp     gradient_new

; ts_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
ts_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + THUNDERSTORM.final_steps]
    mov     rcx, [rbx + THUNDERSTORM.final_step_count]
    mov     rsi, [rbx + THUNDERSTORM.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [ts_final_spectrum], rax
    mov     rdi, [rbx + THUNDERSTORM.final_stops]
    mov     rsi, [rbx + THUNDERSTORM.final_stop_count]
    mov     rdx, [rbx + THUNDERSTORM.final_steps]
    mov     rcx, [rbx + THUNDERSTORM.final_step_count]
    mov     r8, [ts_final_spectrum]
    call    gradient_new
    mov     rdi, [ts_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [ts_final_width], rax
    push    qword [rbx + THUNDERSTORM.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [ts_final_map], rax
    pop     rbx
    ret

; ts_build_strike_characters(edi=count): build_strike_characters - "|"
; characters at (1, 1) pushed onto the available stack.
ts_build_strike_characters:
    push    rbx
    mov     ebx, edi
.next:
    test    ebx, ebx
    jz      .done
    mov     rdi, '|' | 1 << 32
    mov     rsi, 1 << 32 | 1
    call    add_character
    mov     rcx, [ts_available_count]
    mov     rdx, [ts_available]
    mov     [rdx + rcx * 4], eax
    inc     qword [ts_available_count]
    dec     ebx
    jmp     .next
.done:
    pop     rbx
    ret

; ts_strike_visuals: lightning_strike's flash and fade frames for each
; strike symbol. Their colors depend only on the config, so every strike
; shares them.
ts_strike_visuals:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, [effect_config]
    mov     rdi, [rbx + THUNDERSTORM.lightning_color]
    movsd   xmm0, [ts_bright]
    call    adjust_color_brightness
    mov     rsi, rax
    mov     rdi, [rbx + THUNDERSTORM.lightning_color]
    lea     rdx, [ts_strike_flash_colors]
    call    ts_gradient_loop
    ; Gradient::with_steps([lightning, background], 6, false)
    mov     rax, [rbx + THUNDERSTORM.lightning_color]
    mov     [ts_stops], rax
    call    ts_background
    mov     [ts_stops + 8], rax
    lea     rdi, [ts_stops]
    mov     esi, 2
    lea     rdx, [ts_six]
    mov     ecx, 1
    lea     r8, [ts_strike_fade_colors]
    call    gradient_new
    xor     r12d, r12d                  ; symbol index
.symbol:
    cmp     r12d, 3
    jae     .done
    xor     r13d, r13d
.flash:
    lea     rax, [ts_strike_flash_colors]
    mov     rdi, [rax + r13 * 8]
    mov     rsi, NONE
    lea     rax, [ts_strike_symbols]
    mov     rdx, [rax + r12 * 8]
    xor     ecx, ecx
    call    visual_make
    imul    ecx, r12d, TS_FLASH_LEN
    add     ecx, r13d
    lea     rdx, [ts_strike_flash_handles]
    mov     [rdx + rcx * 4], eax
    inc     r13d
    cmp     r13d, TS_FLASH_LEN
    jb      .flash
    xor     r13d, r13d
.fade:
    lea     rax, [ts_strike_fade_colors]
    mov     rdi, [rax + r13 * 8]
    mov     rsi, NONE
    lea     rax, [ts_strike_symbols]
    mov     rdx, [rax + r12 * 8]
    xor     ecx, ecx
    call    visual_make
    imul    ecx, r12d, TS_STRIKE_FADE_LEN
    add     ecx, r13d
    lea     rdx, [ts_strike_fade_handles]
    mov     [rdx + rcx * 4], eax
    inc     r13d
    cmp     r13d, TS_STRIKE_FADE_LEN
    jb      .fade
    inc     r12d
    jmp     .symbol
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_text_colors(rdi=visible fg, rsi=visible bg or NONE): the colors build()
; derives from a character's visible pair. Neighbors mostly share one, so
; the last result is kept.
ts_text_colors:
    cmp     byte [ts_tc_valid], 0
    je      .compute
    cmp     rdi, [ts_tc_fg]
    jne     .compute
    cmp     rsi, [ts_tc_bg]
    jne     .compute
    ret
.compute:
    push    rbx
    push    r12
    push    r13
    mov     byte [ts_tc_valid], 1
    mov     [ts_tc_fg], rdi
    mov     [ts_tc_bg], rsi
    mov     rbx, rdi
    mov     r12, rsi
    ; storm colors: _adjust_color_pair_brightness(visible, 0.5)
    movsd   xmm0, [ts_half]
    call    adjust_color_brightness
    mov     [ts_storm_fg], rax
    mov     rax, NONE
    cmp     r12, NONE
    je      .storm_bg
    mov     rdi, r12
    movsd   xmm0, [ts_half]
    call    adjust_color_brightness
.storm_bg:
    mov     [ts_storm_bg], rax
    lea     rdi, [ts_bg_storm]
    mov     ecx, 16
    rep     stosq
    ; glow: glowing text color -> storm fg
    mov     rdi, [effect_config]
    mov     rdi, [rdi + THUNDERSTORM.glowing_color]
    mov     rsi, [ts_storm_fg]
    lea     rdx, [ts_glow_colors]
    call    ts_gradient2
    ; fade: visible fg -> storm fg; unfade plays it backwards
    mov     rdi, rbx
    mov     rsi, [ts_storm_fg]
    lea     rdx, [ts_fade_colors]
    call    ts_gradient2
    lea     rsi, [ts_fade_colors]
    lea     rdi, [ts_unfade_colors]
    mov     ecx, TS_GRAD
.reverse:
    mov     rax, [rsi + rcx * 8 - 8]
    mov     [rdi], rax
    add     rdi, 8
    dec     ecx
    jnz     .reverse
    ; flash: storm fg -> visible fg at 1.7 brightness, looped
    mov     rdi, rbx
    movsd   xmm0, [ts_bright]
    call    adjust_color_brightness
    mov     rsi, rax
    mov     rdi, [ts_storm_fg]
    lea     rdx, [ts_flash_colors]
    call    ts_gradient_loop
    cmp     qword [cfg_existing_colors], 1
    jne     .done
    ; dynamic: the pair gradients of _add_color_pair_gradient_frames
    mov     rdi, [ts_storm_fg]
    mov     rsi, rbx
    lea     rdx, [ts_unfade_colors]
    call    ts_gradient2
    mov     rdi, r12
    mov     rsi, [ts_storm_bg]
    lea     rdx, [ts_fade_bg]
    call    ts_pair_steps
    mov     rdi, [ts_storm_bg]
    mov     rsi, r12
    lea     rdx, [ts_unfade_bg]
    call    ts_pair_steps
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_pair_steps(rdi=start or NONE, rsi=end or NONE, rdx=out): one channel of
; _add_color_pair_gradient_frames - the gradient when both colors exist,
; else the end color (or the start) repeated.
ts_pair_steps:
    cmp     rdi, NONE
    je      .fill
    cmp     rsi, NONE
    jne     ts_gradient2
.fill:
    mov     rax, rsi
    cmp     rax, NONE
    cmove   rax, rdi
    mov     rdi, rdx
    mov     ecx, TS_GRAD
    rep     stosq
    ret

; ts_add_frames(edi=scene, rsi=fg colors, rdx=bg colors, ecx=count,
;               r8d=duration): add_frame per color pair, with the symbol in
; [ts_symbol].
ts_add_frames:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     ebp, ecx
    mov     r14d, r8d
.next:
    test    ebp, ebp
    jz      .done
    mov     edi, ebx
    mov     rsi, [ts_symbol]
    mov     edx, r14d
    mov     rcx, [r12]
    mov     r8, [r13]
    xor     r9d, r9d
    call    scene_add_frame
    add     r12, 8
    add     r13, 8
    dec     ebp
    jmp     .next
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ts_add_frame(edi=scene, rsi=fg, rdx=bg, ecx=duration): one add_frame.
ts_add_frame:
    mov     r8, rdx
    mov     edx, ecx
    mov     rcx, rsi
    mov     rsi, [ts_symbol]
    xor     r9d, r9d
    jmp     scene_add_frame

; ts_new_scene(edi=slot, esi=name) -> eax: a plain named scene.
ts_new_scene:
    xor     edx, edx
    mov     ecx, NONE
    jmp     scene_new

; ts_text_scenes(edi=slot): build()'s glow, fade, unfade and flash scenes
; for one text character, then its visibility.
ts_text_scenes:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, edi
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [ts_symbol], rax
    mov     r15, [effect_config]
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic_colors
    ; visible = (final gradient color at the input coordinate, none)
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [ts_final_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [ts_final_map]
    mov     r13, [rcx + rax * 8]
    mov     r14, NONE
    jmp     .colors
.dynamic_colors:
    ; visible = (input fg or neutral gray, input bg)
    mov     rax, [ch_fg]
    mov     r13, [rax + r12 * 8]
    cmp     r13, NONE
    jne     .input_bg
    mov     r13d, 0x808080
.input_bg:
    mov     rax, [ch_bg]
    mov     r14, [rax + r12 * 8]
.colors:
    mov     rdi, r13
    mov     rsi, r14
    call    ts_text_colors
    ; glow: glowing -> storm over 8 frames of text_glow_time
    mov     edi, r12d
    mov     esi, TS_GLOW
    call    ts_new_scene
    mov     ebx, eax
    mov     rcx, [ch_user0]
    mov     [rcx + r12 * 8], eax
    mov     edi, ebx
    lea     rsi, [ts_glow_colors]
    lea     rdx, [ts_bg_storm]
    mov     ecx, TS_GRAD
    mov     r8, [r15 + THUNDERSTORM.text_glow_time]
    call    ts_add_frames
    cmp     qword [cfg_existing_colors], 1
    jne     .fade
    mov     edi, ebx
    mov     rsi, [ts_storm_fg]
    mov     rdx, [ts_storm_bg]
    mov     rcx, [r15 + THUNDERSTORM.text_glow_time]
    call    ts_add_frame
.fade:
    mov     edi, r12d
    mov     esi, TS_FADE
    call    ts_new_scene
    mov     ebx, eax
    mov     rcx, [ch_user0]
    mov     [rcx + r12 * 8 + 4], eax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic_fade
    mov     edi, ebx
    lea     rsi, [ts_fade_colors]
    lea     rdx, [ts_bg_none]
    mov     ecx, TS_GRAD
    mov     r8d, 12
    call    ts_add_frames
    jmp     .unfade
.dynamic_fade:
    ; range(7) of the pair gradient, then the storm colors
    mov     edi, ebx
    lea     rsi, [ts_fade_colors]
    lea     rdx, [ts_fade_bg]
    mov     ecx, 7
    mov     r8d, 12
    call    ts_add_frames
    mov     edi, ebx
    mov     rsi, [ts_storm_fg]
    mov     rdx, [ts_storm_bg]
    mov     ecx, 12
    call    ts_add_frame
.unfade:
    mov     edi, r12d
    mov     esi, TS_UNFADE
    call    ts_new_scene
    mov     ebx, eax
    mov     rcx, [ch_user1]
    mov     [rcx + r12 * 8], eax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic_unfade
    mov     edi, ebx
    lea     rsi, [ts_unfade_colors]
    lea     rdx, [ts_bg_none]
    mov     ecx, TS_GRAD
    mov     r8d, 12
    call    ts_add_frames
    jmp     .flash
.dynamic_unfade:
    mov     edi, ebx
    lea     rsi, [ts_unfade_colors]
    lea     rdx, [ts_unfade_bg]
    mov     ecx, 7
    mov     r8d, 12
    call    ts_add_frames
    mov     edi, ebx
    mov     rsi, r13
    mov     rdx, r14
    mov     ecx, 12
    call    ts_add_frame
    ; the restore colors (the input pair) when they differ from visible
    mov     rax, [ch_fg]
    mov     rsi, [rax + r12 * 8]
    mov     rax, [ch_bg]
    mov     rdx, [rax + r12 * 8]
    cmp     rsi, r13
    jne     .restore
    cmp     rdx, r14
    je      .flash
.restore:
    mov     edi, ebx
    mov     ecx, 12
    call    ts_add_frame
.flash:
    mov     edi, r12d
    mov     esi, TS_FLASH
    call    ts_new_scene
    mov     ebx, eax
    mov     rcx, [ch_user1]
    mov     [rcx + r12 * 8 + 4], eax
    mov     edi, ebx
    lea     rsi, [ts_flash_colors]
    lea     rdx, [ts_bg_storm]
    mov     ecx, TS_FLASH_LEN
    mov     r8d, 6
    call    ts_add_frames
    mov     edi, r12d
    call    set_visible
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ------------------------------------------------------------ particles

; ts_init_raindrop(edi=slot): initialize_raindrop - layer 1, the input
; symbol in aaaaff.
ts_init_raindrop:
    push    rbx
    mov     ebx, edi
    mov     esi, 1
    call    set_layer
    mov     edi, ebx
    xor     esi, esi
    mov     edx, 0xaaaaff
    mov     rcx, NONE
    call    set_appearance
    pop     rbx
    ret

; ts_init_spark(edi=slot): _build_spark_characters - layer 2 and an
; in_circ "glow" scene down the spark gradient.
ts_init_spark:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     esi, 2
    call    set_layer
    mov     edi, ebx
    mov     esi, TS_GLOW
    xor     edx, edx
    mov     ecx, TS_EASE_IN_CIRC
    call    scene_new
    mov     r12d, eax
    mov     rcx, [ch_user0]
    mov     [rcx + rbx * 8], eax
    xor     r13d, r13d
.frame:
    cmp     r13d, [ts_spark_len]
    jae     .done
    mov     edi, r12d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     rdx, [effect_config]
    mov     rdx, [rdx + THUNDERSTORM.spark_glow_time]
    lea     rcx, [ts_spark_spectrum]
    mov     rcx, [rcx + r13 * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r13d
    jmp     .frame
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_setup_raindrop(edi=slot): _setup_raindrop - a straight fall to row 0,
; reclaimed when the path completes.
ts_setup_raindrop:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    char_coord
    mov     r12, rax                    ; origin
    movsd   xmm0, [ts_half]
    movsd   xmm1, [ts_one_half]
    call    rng_uniform
    mov     edi, ebx
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    ; (origin.column + canvas.top + 1, canvas.bottom - 1)
    movsxd  rsi, r12d
    add     rsi, [canvas_top]
    inc     rsi
    mov     esi, esi
    mov     edi, r13d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    PATH_PTR rcx, r13
    mov     ecx, [rcx + PA_NAME]
    lea     rax, [ts_rain_pool]
    push    0
    push    rax
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_reclaim]
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    mov     esi, r13d
    call    path_activate
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_setup_sparks(edi=slot): _setup_sparks_for_impact - an out_quint bezier
; arc to the canvas bottom, the glow scene, reclaimed when the glow ends.
ts_setup_sparks:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    call    char_coord
    mov     r12, rax                    ; impact
    movsd   xmm0, [ts_spark_speed_low]
    movsd   xmm1, [ts_spark_speed_high]
    call    rng_uniform
    mov     edi, ebx
    mov     esi, TS_EASE_OUT_QUINT
    mov     rdx, NONE_I64
    mov     ecx, 30
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    ; offset = randint(4, 20) * choice([1, -1])
    mov     edi, 4
    mov     esi, 20
    call    rng_randint
    mov     r14, rax
    mov     edi, 2
    call    rng_below
    test    rax, rax
    jz      .positive
    neg     r14
.positive:
    movsxd  rax, r12d
    lea     r14, [rax + r14]            ; target column
    ; bezier column: impact - floor_div(impact - target, 2)
    mov     rcx, rax
    sub     rcx, r14
    sar     rcx, 1
    sub     rax, rcx
    mov     r15, rax
    mov     edi, 1
    mov     rsi, [canvas_top]
    call    rng_randint
    shl     rax, 32
    mov     ecx, r15d
    or      rax, rcx
    mov     [rsp], rax                  ; the control point
    mov     esi, r14d
    mov     rax, 1 << 32                ; canvas.bottom
    or      rsi, rax
    mov     edi, r13d
    lea     rdx, [rsp]
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    lea     rax, [ts_spark_pool]
    push    0
    push    rax
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_GLOW
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_reclaim]
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    mov     rax, [ch_user0]
    mov     esi, [rax + rbx * 8]
    call    scene_activate
    mov     edi, ebx
    mov     esi, r13d
    call    path_activate
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_reclaim(edi=slot, rsi=pool): the pools' reclaim_on_event callback.
ts_reclaim:
    mov     eax, edi
    mov     rdi, rsi
    mov     esi, eax
    mov     edx, 1
    mov     ecx, 1
    jmp     pool_reclaim

; ------------------------------------------------------------ callbacks

; fade_complete: the storm begins and its clock restarts.
ts_cb_fade_complete:
    mov     byte [ts_phase], TS_STORM
    call    clock_monotonic
    movsd   [ts_storm_start], xmm0
    ret

; hide_character
ts_cb_hide:
    xor     esi, esi
    jmp     set_visibility

; make_char_glow: the visible text character under the strike character
; starts glowing; it joins the active set on the next storm frame.
ts_cb_glow:
    push    rbx
    call    char_coord
    mov     rsi, rax
    call    char_at_input_coord
    cmp     eax, NONE
    je      .done
    mov     ebx, eax
    mov     rcx, [ch_flags]
    test    word [rcx + rbx * 2], CF_VISIBLE
    jz      .done
    mov     edi, ebx
    mov     rax, [ch_user0]
    mov     esi, [rax + rbx * 8]        ; glow
    call    scene_activate
    mov     rax, [ts_glow_count]
    mov     rcx, [ts_glow]
    mov     [rcx + rax * 4], ebx
    inc     qword [ts_glow_count]
.done:
    pop     rbx
    ret

; return_strike_to_pool
ts_cb_return_strike:
    mov     rax, [ts_available_count]
    mov     rcx, [ts_available]
    mov     [rcx + rax * 4], edi
    inc     qword [ts_available_count]
    ret

; set_strike_in_progress_false
ts_cb_strike_done:
    mov     byte [ts_strike_in_progress], 0
    ret

; ------------------------------------------------------------ the storm

; ts_setup_strike(edi=branch neighbor or NONE): setup_lightning_strike, with
; its recursive branching. Strike characters are all created with input
; symbol "|", so a branch's first step always takes the random-delta arm
; (the "/" and "\\" arms are unreachable upstream too).
ts_setup_strike:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     r14d, edi                   ; branch neighbor
    cmp     r14d, NONE
    je      .fresh
    call    char_coord
    movsxd  r12, eax                    ; column
    sar     rax, 32
    mov     r13, rax                    ; row
    jmp     .row
.fresh:
    mov     edi, 1
    mov     rsi, [canvas_right]
    call    rng_randint
    mov     r12, rax
    mov     r13, [canvas_top]
.row:
    cmp     r13, 1                      ; canvas.bottom
    jl      .done
    cmp     qword [ts_available_count], 0
    jne     .symbol
    mov     edi, 20
    call    ts_build_strike_characters
.symbol:
    cmp     r14d, NONE
    je      .choose
    ; delta = choice([-1, 1]); "\\" when it is 1, else "/"
    mov     edi, 2
    call    rng_below
    lea     rcx, [rax * 2 - 1]
    add     r12, rcx
    xor     ebp, ebp                    ; "\\"
    test    rax, rax
    jnz     .place
    mov     ebp, 1                      ; "/"
    jmp     .place
.choose:
    mov     edi, 3
    call    rng_below                   ; choice(["\\", "/", "|"])
    mov     ebp, eax
.place:
    ; get_next_strike_char: pop, clear its scenes and events
    mov     rax, [ts_available_count]
    dec     rax
    mov     [ts_available_count], rax
    mov     rcx, [ts_available]
    mov     ebx, [rcx + rax * 4]
    mov     edi, ebx
    call    scenes_release
    mov     edi, ebx
    call    events_release
    mov     esi, r12d
    mov     rax, r13
    shl     rax, 32
    or      rsi, rax
    mov     edi, ebx
    call    set_coordinate
    mov     rax, [ch_user1]
    mov     [rax + rbx * 8], rbp
    lea     rax, [ts_strike_symbols]
    mov     rsi, [rax + rbp * 8]
    mov     rdx, [effect_config]
    mov     rdx, [rdx + THUNDERSTORM.lightning_color]
    mov     rcx, NONE
    mov     edi, ebx
    call    set_appearance
    dec     r13
    cmp     ebp, 0
    jne     .slash
    inc     r12
    jmp     .pending
.slash:
    cmp     ebp, 1
    jne     .pending
    dec     r12
.pending:
    mov     rax, [ts_pending_count]
    mov     rcx, [ts_pending]
    mov     [rcx + rax * 4], ebx
    inc     qword [ts_pending_count]
    ; random() is always drawn; a branch never branches at its first step
    call    rng_random
    movsd   xmm1, [ts_branch_chance]
    ucomisd xmm1, xmm0
    jbe     .next
    cmp     r14d, NONE
    jne     .next
    subsd   xmm1, [ts_branch_step]
    movsd   [ts_branch_chance], xmm1
    mov     edi, ebx
    call    ts_setup_strike
.next:
    mov     r14d, NONE
    jmp     .row
.done:
    mov     rax, [ts_branch_default]
    mov     [ts_branch_chance], rax
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ts_lightning_strike: lightning_strike - lay out the bolt, give each of its
; characters flash (eased by a fresh random curve) and fade scenes, and ease
; the text's flash scenes by the same curve.
ts_lightning_strike:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     qword [ts_pending_head], 0
    mov     qword [ts_pending_count], 0
    mov     edi, NONE
    call    ts_setup_strike
    movsd   xmm0, [ts_ease_y2_low]
    movsd   xmm1, [ts_ease_y2_high]
    call    rng_uniform
    movapd  xmm3, xmm0
    xorpd   xmm0, xmm0
    movsd   xmm1, [ts_ease_y1]
    movsd   xmm2, [ts_one]
    call    bezier_new
    mov     [ts_flash_ease], eax
    push    0
    push    0
    mov     r12, [ts_pending_head]
.strike:
    cmp     r12, [ts_pending_count]
    jae     .text
    mov     rax, [ts_pending]
    mov     ebx, [rax + r12 * 4]
    mov     rax, [ch_user1]
    mov     rbp, [rax + rbx * 8]        ; symbol index
    mov     edi, ebx
    mov     esi, TS_FLASH
    xor     edx, edx
    mov     ecx, [ts_flash_ease]
    call    scene_new
    mov     r13d, eax
    mov     rcx, [ch_user0]
    mov     [rcx + rbx * 8], eax
    imul    r14d, ebp, TS_FLASH_LEN
.flash_frame:
    mov     edi, r13d
    lea     rax, [ts_strike_flash_handles]
    mov     esi, [rax + r14 * 4]
    mov     edx, 6
    call    scene_add_frame_visual
    inc     r14d
    imul    eax, ebp, TS_FLASH_LEN
    add     eax, TS_FLASH_LEN
    cmp     r14d, eax
    jb      .flash_frame
    mov     edi, ebx
    mov     esi, TS_FADE
    call    ts_new_scene
    mov     r13d, eax
    imul    r14d, ebp, TS_STRIKE_FADE_LEN
.fade_frame:
    mov     edi, r13d
    lea     rax, [ts_strike_fade_handles]
    mov     esi, [rax + r14 * 4]
    mov     edx, 2
    call    scene_add_frame_visual
    inc     r14d
    imul    eax, ebp, TS_STRIKE_FADE_LEN
    add     eax, TS_STRIKE_FADE_LEN
    cmp     r14d, eax
    jb      .fade_frame
    mov     edi, ebx
    mov     esi, 1
    call    set_layer
    ; flash -> fade; fade -> hide, glow, return to the pool
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FLASH
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, TS_FADE
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FADE
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_cb_hide]
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FADE
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_cb_glow]
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FADE
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_cb_return_strike]
    call    event_register
    inc     r12
    jmp     .strike
.text:
    add     rsp, 16
    ; every text flash scene takes the new curve
    mov     edx, [ts_flash_ease]
    xor     ecx, ecx
.ease:
    cmp     rcx, [ts_text_count]
    jae     .done
    mov     rax, [ts_text]
    mov     eax, [rax + rcx * 4]
    mov     rsi, [ch_user1]
    mov     eax, [rsi + rax * 8 + 4]    ; flash
    SCENE_PTR r8, rax
    mov     edi, [r8 + SC_OWNER]
    call    doze_wake                   ; update.asm: its playback changes
    mov     [r8 + SC_EASE], edx
    or      dword [r8 + SC_FLAGS], SCF_EASED
    inc     rcx
    jmp     .ease
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ts_step_strike: step_lightning_strike - reveal 1-3 bolt characters every
; other frame; after the last, sparks fly and everything flashes.
ts_step_strike:
    mov     rax, [ts_progression_delay]
    test    rax, rax
    jz      .go
    dec     rax
    mov     [ts_progression_delay], rax
    ret
.go:
    mov     rax, [ts_pending_head]
    cmp     rax, [ts_pending_count]
    jb      .reveal
    ret
.reveal:
    push    rbx
    push    rbp
    push    r12
    mov     edi, 1
    mov     esi, 3
    call    rng_randint
    mov     rbp, rax                    ; batch
.batch:
    test    rbp, rbp
    jz      .done
    dec     rbp
    mov     rax, [ts_pending_head]
    cmp     rax, [ts_pending_count]
    jae     .done
    mov     rcx, [ts_pending]
    mov     ebx, [rcx + rax * 4]
    inc     rax
    mov     [ts_pending_head], rax
    mov     rax, [ts_active_count]
    mov     rcx, [ts_active]
    mov     [rcx + rax * 4], ebx
    inc     qword [ts_active_count]
    mov     edi, ebx
    call    set_visible
    mov     qword [ts_progression_delay], 1
    mov     rax, [ts_pending_head]
    cmp     rax, [ts_pending_count]
    jb      .batch
    ; the last strike character: sparks at the impact
    mov     edi, 12
    mov     esi, 18
    call    rng_randint
    mov     r12, rax
.spark:
    test    r12, r12
    jz      .sparked
    mov     rax, [ts_active_count]
    mov     rcx, [ts_active]
    mov     edi, [rcx + rax * 4 - 4]
    call    char_coord
    lea     rdi, [ts_spark_pool]
    mov     rsi, rax
    xor     edx, edx
    mov     ecx, 1
    lea     r8, [ts_setup_sparks]
    xor     r9d, r9d
    call    pool_emit
    dec     r12
    jmp     .spark
.sparked:
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, TS_FADE
    mov     r8d, ACT_CALLBACK
    lea     r9, [ts_cb_strike_done]
    call    event_register
    add     rsp, 16
    ; flash the bolt, then the text
    xor     r12d, r12d
.bolt:
    cmp     r12, [ts_active_count]
    jae     .bolt_done
    mov     rax, [ts_active]
    mov     edi, [rax + r12 * 4]
    mov     rax, [ch_user0]
    mov     esi, [rax + rdi * 8]        ; flash
    push    rdi
    call    scene_activate
    pop     rdi
    call    active_insert
    inc     r12
    jmp     .bolt
.bolt_done:
    mov     qword [ts_active_count], 0
    mov     qword [ts_pending_head], 0
    mov     qword [ts_pending_count], 0
    mov     esi, 4 + 8                  ; ch_user1 high: flash
    call    ts_activate_text
    jmp     .batch
.done:
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ts_activate_text(esi=byte offset of the scene in ch_user0/1): activate
; that scene on every text character (top to bottom, left to right) and make
; each active. Offsets: 0 glow, 4 fade, 8 unfade, 12 flash.
ts_activate_text:
    push    rbx
    push    r12
    push    r13
    mov     r13d, esi
    mov     rbx, [ch_user0]
    cmp     r13d, 8
    jb      .words
    mov     rbx, [ch_user1]
    sub     r13d, 8
.words:
    xor     r12d, r12d
.next:
    cmp     r12, [ts_text_count]
    jae     .done
    mov     rax, [ts_text]
    mov     edi, [rax + r12 * 4]
    lea     rax, [rbx + rdi * 8]
    mov     esi, [rax + r13]
    push    rdi
    call    scene_activate
    pop     rdi
    call    active_insert
    inc     r12
    jmp     .next
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ts_rain: rain - every few frames, 1-6 raindrops from above the canvas.
ts_rain:
    mov     rax, [ts_delay]
    test    rax, rax
    jz      .spawn
    dec     rax
    mov     [ts_delay], rax
    ret
.spawn:
    push    rbx
    mov     edi, 1
    mov     esi, 6
    call    rng_randint
    mov     rbx, rax
.drop:
    test    rbx, rbx
    jz      .done
    mov     edi, 1
    sub     rdi, [canvas_top]
    mov     rsi, [canvas_right]
    call    rng_randint
    ; origin (spawn_column - 1, canvas.top + 1)
    dec     eax
    mov     esi, eax
    mov     rax, [canvas_top]
    inc     rax
    shl     rax, 32
    or      rsi, rax
    lea     rdi, [ts_rain_pool]
    xor     edx, edx
    mov     ecx, 1
    lea     r8, [ts_setup_raindrop]
    xor     r9d, r9d
    call    pool_emit
    dec     rbx
    jmp     .drop
.done:
    mov     edi, 1
    mov     esi, 7
    call    rng_randint
    mov     [ts_delay], rax
    pop     rbx
    ret

; thunderstorm_next_frame -> eax = 1 for a frame, 0 when done.
thunderstorm_next_frame:
    push    rbx
    cmp     byte [ts_phase], TS_COMPLETE
    jne     .phase
    call    active_empty
    test    eax, eax
    jnz     .finished
.phase:
    movzx   eax, byte [ts_phase]
    cmp     eax, TS_PRE_STORM
    je      .pre_storm
    cmp     eax, TS_STORM
    je      .storm
    jmp     .update
.pre_storm:
    ; pre_storm_text_fade
    mov     esi, 4                      ; fade
    call    ts_activate_text
    mov     byte [ts_phase], TS_WAITING
    jmp     .update
.storm:
    call    ts_rain
    cmp     byte [ts_strike_in_progress], 0
    jne     .stepping
    call    rng_random
    movsd   xmm1, [ts_strike_chance]
    ucomisd xmm1, xmm0
    jbe     .stepping
    mov     byte [ts_strike_in_progress], 1
    call    ts_lightning_strike
.stepping:
    cmp     byte [ts_strike_in_progress], 0
    je      .glowing
    call    ts_step_strike
.glowing:
    xor     ebx, ebx
.glow:
    cmp     rbx, [ts_glow_count]
    jae     .glowed
    mov     rax, [ts_glow]
    mov     edi, [rax + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .glow
.glowed:
    mov     qword [ts_glow_count], 0
    call    clock_monotonic
    subsd   xmm0, [ts_storm_start]
    mov     rax, [effect_config]
    cvtsi2sd xmm1, qword [rax + THUNDERSTORM.storm_time]
    ucomisd xmm0, xmm1
    jb      .update
    cmp     byte [ts_strike_in_progress], 0
    jne     .update
    ; post_storm_text_fade_in
    mov     esi, 8                      ; unfade
    call    ts_activate_text
    mov     byte [ts_phase], TS_COMPLETE
.update:
    call    update
    mov     eax, 1
    pop     rbx
    ret
.finished:
    xor     eax, eax
    pop     rbx
    ret

section .rodata
align 8
ts_seven:           dq 7
ts_six:             dq 6
ts_half:            dq 0.5
ts_one_half:        dq 1.5
ts_one:             dq 1.0
ts_bright:          dq 1.7
ts_spark_speed_low: dq 0.1
ts_spark_speed_high: dq 0.25
ts_ease_y1:         dq 1.6
ts_ease_y2_low:     dq -0.6
ts_ease_y2_high:    dq 0.4
ts_strike_chance:   dq 0.008
ts_branch_default:  dq 0.05
ts_branch_step:     dq 0.01
; the strike symbols, in setup_lightning_strike's choice order
ts_strike_symbols:  dq '\' | 1 << 32, '/' | 1 << 32, '|' | 1 << 32
ts_bg_none:         times 16 dq NONE

section .tstate
alignb 8
ts_rain_pool:       resb POOL_size
alignb 8
ts_spark_pool:      resb POOL_size
alignb 8
ts_pending:         resq 1          ; u32 lists (see thunderstorm_build)
ts_pending_head:    resq 1
ts_pending_count:   resq 1
ts_available:       resq 1
ts_available_count: resq 1
ts_active:          resq 1
ts_active_count:    resq 1
ts_glow:            resq 1
ts_glow_count:      resq 1
ts_text:            resq 1
ts_text_count:      resq 1
ts_delay:           resq 1
ts_progression_delay: resq 1
ts_branch_chance:   resq 1
ts_storm_start:     resq 1
ts_final_spectrum:  resq 1
ts_final_map:       resq 1
ts_final_width:     resq 1
ts_symbol:          resq 1
ts_stops:           resq 3
ts_spark_spectrum:  resq 16
ts_spark_len:       resd 1
ts_flash_ease:      resd 1
ts_strike_flash_colors: resq 16
ts_strike_fade_colors:  resq 16
ts_strike_flash_handles: resd 3 * TS_FLASH_LEN
ts_strike_fade_handles:  resd 3 * TS_STRIKE_FADE_LEN
alignb 8
ts_tc_fg:           resq 1
ts_tc_bg:           resq 1
ts_storm_fg:        resq 1
ts_storm_bg:        resq 1
ts_bg_storm:        resq 16
ts_glow_colors:     resq 16
ts_fade_colors:     resq 16
ts_unfade_colors:   resq 16
ts_flash_colors:    resq 16
ts_fade_bg:         resq 16
ts_unfade_bg:       resq 16
ts_tc_valid:        resb 1
ts_phase:           resb 1
ts_strike_in_progress: resb 1
