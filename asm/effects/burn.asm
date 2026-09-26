; effects/burn.asm - "Burns vertically in the canvas" (src/effects/burn.rs).
;
; RNG order is BurnIterator.__init__'s: PrimsSimple's starting coord, the
; smoke pool's 2000 symbol draws, then build() runs PrimsSimple to
; completion. Each frame draws randint(2, 4) and every finished burn may
; draw random() and emit a smoke particle (one randint for its target).
;
; Each emission registers a fresh reclaim callback on the particle (its
; payload is the emission count), exactly like Rust's per-emission closure,
; so the particle's action list grows the same way.

struc BURN
    .starting_color:    resq 1
    .burn_colors:       resq 1          ; *const u64
    .burn_color_count:  resq 1
    .smoke_chance:      resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define BRN_BURN            NAME_LITERAL + 0
%define BRN_SMOKE           NAME_LITERAL + 1

%define BRN_CHAR_ORDER      9
%define BRN_SMOKE_SYMBOLS   6
%define BRN_SMOKE_LEN       10          ; 504F4F -> C7C7C7 in 9 steps
%define BRN_CHAR_LEN        9           ; fire end -> final color in 8 steps

section .text

; burn_build: BurnIterator.__init__ + build().
burn_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    brn_symbols
    mov     edi, 1
    call    ps_new
    ; the smoke pool: 2000 particles at (0, 0), at most 2000
    lea     rdi, [brn_smoke_stops]
    mov     esi, 2
    lea     rdx, [brn_nine]
    mov     ecx, 1
    lea     r8, [brn_smoke_spectrum]
    call    gradient_new
    lea     rdi, [brn_pool]
    lea     rsi, [brn_smoke_symbols]
    mov     edx, BRN_SMOKE_SYMBOLS
    mov     ecx, 2000
    xor     r8d, r8d
    call    pool_init
    lea     rax, [brn_init_smoke]
    mov     [brn_pool + POOL.initializer], rax
    lea     rdi, [brn_pool]
    mov     esi, 2000
    call    pool_preallocate
    ; build(): the final gradient mapping and the fire gradient
    call    brn_final_map
    lea     rdi, [brn_ten]
    mov     ecx, 1
    mov     rsi, [rbx + BURN.burn_color_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [brn_fire], rax
    mov     rdi, [rbx + BURN.burn_colors]
    mov     rsi, [rbx + BURN.burn_color_count]
    lea     rdx, [brn_ten]
    mov     ecx, 1
    mov     r8, [brn_fire]
    call    gradient_new
    mov     [brn_fire_len], rax
    mov     rcx, [brn_fire]
    mov     rax, [rcx + rax * 8 - 8]
    mov     [brn_pair_stops], rax       ; the fire gradient's last color
    call    ps_run
    mov     [brn_order], rax
    mov     [brn_order_count], rdx
    mov     qword [brn_order_head], 0
    ; every input character, top to bottom, left to right
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     r13d, r13d
.character:
    cmp     r13, r15
    jae     .built
    mov     edi, [r14 + r13 * 4]
    call    brn_character
    inc     r13
    jmp     .character
.built:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; brn_symbols: pack the burn and smoke symbol tables.
brn_symbols:
    push    rbx
    xor     ebx, ebx
.next:
    cmp     ebx, BRN_CHAR_ORDER + BRN_SMOKE_SYMBOLS
    jae     .done
    lea     rax, [brn_codepoints]
    mov     edi, [rax + rbx * 4]
    call    utf8_pack
    lea     rcx, [brn_char_order]
    mov     [rcx + rbx * 8], rax
    inc     ebx
    jmp     .next
.done:
    pop     rbx
    ret

; brn_character(edi=slot): the starting appearance, the burn scene, the
; final color scene and the two burn-complete events.
brn_character:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    call    set_visible
    mov     edi, ebx
    xor     esi, esi
    mov     rax, [effect_config]
    mov     rdx, [rax + BURN.starting_color]
    mov     rcx, NONE
    call    set_appearance
    ; the burn scene is the same for every character whose input colors
    ; don't enter it: later ones clone the first one's
    mov     rax, [brn_template]
    test    rax, rax
    jz      .burn_fresh
    cmp     qword [cfg_existing_colors], 0
    jne     .burn_clone
    mov     rcx, [ch_flags]
    test    word [rcx + rbx * 2], CF_PREEXISTING
    jnz     .burn_fresh
.burn_clone:
    mov     edi, ebx
    lea     esi, [eax - 1]
    mov     edx, BRN_BURN
    call    scene_copy
    jmp     .final_scene
.burn_fresh:
    mov     edi, ebx
    mov     esi, BRN_BURN
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    push    0
    push    0
    mov     edi, eax
    lea     rsi, [brn_char_order]
    mov     edx, BRN_CHAR_ORDER
    mov     ecx, 4
    mov     r8, [brn_fire]
    mov     r9, [brn_fire_len]
    call    scene_apply_gradient
    add     rsp, 16
    cmp     qword [brn_template], 0
    jne     .final_scene
    SCENE_PTR rax, rbp
    test    dword [rax + SC_FLAGS], SCF_PREEXISTING | SCF_PRE_BOLD
    jnz     .final_scene
    lea     eax, [ebp + 1]
    mov     [brn_template], rax
.final_scene:
    ; the final color scene takes the next auto id
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    SCENE_PTR rax, rbp
    mov     r15d, [rax + SC_NAME]
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; fire end -> the mapped final color, 8 steps, duration 4
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    sub     rax, [text_bottom]
    imul    rax, [brn_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbx * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [brn_map]
    mov     rax, [rcx + rax * 8]
    mov     [brn_pair_stops + 8], rax
    lea     rdi, [brn_pair_stops]
    mov     esi, 2
    lea     rdx, [brn_eight]
    mov     ecx, 1
    lea     r8, [brn_pair_spectrum]
    call    gradient_new
    mov     r12d, eax
    xor     r13d, r13d
.frame:
    cmp     r13d, r12d
    jae     .events
    mov     edi, ebp
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 4
    lea     rcx, [brn_pair_spectrum]
    mov     rcx, [rcx + r13 * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r13d
    jmp     .frame
.dynamic:
    ; fire end -> the input fg / bg, when present
    xor     r12d, r12d                  ; fg length
    xor     r13d, r13d                  ; bg length
    mov     rax, [ch_fg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dynamic_bg
    mov     [brn_pair_stops + 8], rax
    lea     rdi, [brn_pair_stops]
    mov     esi, 2
    lea     rdx, [brn_eight]
    mov     ecx, 1
    lea     r8, [brn_pair_spectrum]
    call    gradient_new
    mov     r12d, eax
.dynamic_bg:
    mov     rax, [ch_bg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .dynamic_apply
    mov     [brn_pair_stops + 8], rax
    lea     rdi, [brn_pair_stops]
    mov     esi, 2
    lea     rdx, [brn_eight]
    mov     ecx, 1
    lea     r8, [brn_bg_spectrum]
    call    gradient_new
    mov     r13d, eax
.dynamic_apply:
    mov     eax, r12d
    or      eax, r13d
    jz      .plain
    xor     r8d, r8d
    test    r12d, r12d
    jz      .no_fg
    lea     r8, [brn_pair_spectrum]
.no_fg:
    xor     eax, eax
    test    r13d, r13d
    jz      .no_bg
    lea     rax, [brn_bg_spectrum]
.no_bg:
    push    r13
    push    rax
    mov     edi, ebp
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rbx * 8]
    mov     edx, 1
    mov     ecx, 4
    mov     r9d, r12d
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .events
.plain:
    mov     edi, ebp
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 4
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.events:
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, BRN_BURN
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, r15d
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, BRN_BURN
    mov     r8d, ACT_CALLBACK
    lea     r9, [brn_emit_smoke]
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

; brn_final_map: Gradient::new(final stops, final steps) mapped over the
; text rectangle.
brn_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + BURN.final_steps]
    mov     rcx, [rbx + BURN.final_step_count]
    mov     rsi, [rbx + BURN.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [brn_final_spectrum], rax
    mov     rdi, [rbx + BURN.final_stops]
    mov     rsi, [rbx + BURN.final_stop_count]
    mov     rdx, [rbx + BURN.final_steps]
    mov     rcx, [rbx + BURN.final_step_count]
    mov     r8, [brn_final_spectrum]
    call    gradient_new
    mov     rdi, [brn_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [brn_map_width], rax
    push    qword [rbx + BURN.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [brn_map], rax
    pop     rbx
    ret

; ------------------------------------------------------------ smoke

; brn_init_smoke(edi=slot): initialize_smoke - a "smoke" scene fading
; 504F4F -> C7C7C7 over the particle's symbol, layer 2.
brn_init_smoke:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     esi, BRN_SMOKE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax
    ; the smoke gradient over the symbol: six symbols, one spectrum
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbx * 8]
    lea     rsi, [brn_smoke_spectrum]
    mov     edx, BRN_SMOKE_LEN
    mov     rcx, NONE
    xor     r8d, r8d
    call    visual_run
    mov     edi, r12d
    mov     rsi, rax
    mov     ecx, 10
    call    visual_frames
.layer:
    mov     edi, ebx
    mov     esi, 2
    call    set_layer
    pop     r13
    pop     r12
    pop     rbx
    ret

; brn_emit_smoke(edi=slot): the burn-complete callback, _emit_smoke at the
; character's input coordinate.
brn_emit_smoke:
    push    rbx
    mov     ebx, edi
    call    rng_random
    mov     rax, [effect_config]
    ucomisd xmm0, [rax + BURN.smoke_chance]
    ja      .done
    inc     qword [brn_emissions]
    mov     edi, ebx
    call    char_input_coord
    mov     [brn_origin], rax
    lea     rdi, [brn_pool]
    mov     rsi, rax
    xor     edx, edx
    mov     ecx, 1
    lea     r8, [brn_on_emit]
    mov     r9, [brn_emissions]
    call    pool_emit
.done:
    pop     rbx
    ret

; brn_on_emit(edi=particle, rsi=emission): on_emit_smoke - restart the
; smoke scene, rise to a random column near the origin above the canvas,
; and reclaim when the scene completes.
brn_on_emit:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    mov     esi, BRN_SMOKE
    call    scene_find
    mov     edi, eax
    call    scene_reset
    movsd   xmm0, [brn_half]
    mov     edi, ebx
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    movsxd  rdi, dword [brn_origin]
    lea     rsi, [rdi + 4]
    sub     rdi, 4
    call    rng_randint
    mov     esi, eax
    mov     rax, [canvas_top]
    inc     rax
    shl     rax, 32
    or      rsi, rax
    mov     edi, r13d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebx
    mov     esi, r13d
    call    path_activate
    mov     edi, ebx
    mov     esi, BRN_SMOKE
    call    scene_activate_name
    push    0
    push    r12
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, BRN_SMOKE
    mov     r8d, ACT_CALLBACK
    lea     r9, [brn_reclaim]
    call    event_register
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

; brn_reclaim(edi=particle): reclaim(hide=True, deactivate=True).
brn_reclaim:
    mov     esi, edi
    lea     rdi, [brn_pool]
    mov     edx, 1
    mov     ecx, 1
    jmp     pool_reclaim

; burn_next_frame -> eax = 1 for a frame, 0 when done.
burn_next_frame:
    push    rbx
    push    r12
    mov     rax, [brn_order_head]
    cmp     rax, [brn_order_count]
    jb      .frame
    call    active_empty
    test    eax, eax
    jnz     .finished
.frame:
    mov     edi, 2
    mov     esi, 4
    call    rng_randint
    mov     r12, rax
.ignite:
    test    r12, r12
    jz      .tick
    dec     r12
    mov     rax, [brn_order_head]
    cmp     rax, [brn_order_count]
    jae     .ignite
    inc     qword [brn_order_head]
    mov     rcx, [brn_order]
    mov     ebx, [rcx + rax * 4]
    ; _is_burnable: a visible symbol, or input colors unless ignored
    mov     rax, [ch_sym]
    mov     rcx, (1 << 32) | ' '
    cmp     [rax + rbx * 8], rcx
    jne     .burn
    cmp     qword [cfg_existing_colors], 2
    je      .ignite
    mov     rax, [ch_fg]
    cmp     qword [rax + rbx * 8], NONE
    jne     .burn
    mov     rax, [ch_bg]
    cmp     qword [rax + rbx * 8], NONE
    je      .ignite
.burn:
    mov     edi, ebx
    mov     esi, BRN_BURN
    call    scene_activate_name
    mov     edi, ebx
    call    active_insert
    jmp     .ignite
.tick:
    call    update
    mov     eax, 1
    pop     r12
    pop     rbx
    ret
.finished:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
brn_half:           dq 0.5
brn_nine:           dq 9
brn_ten:            dq 10
brn_eight:          dq 8
brn_smoke_stops:    dq 0x504F4F, 0xC7C7C7
; ' . ▖ ▙ █ ▜ ▀ ▝ .   then the smoke symbols . , ' ` # *
brn_codepoints:     dd "'", '.', 0x2596, 0x2599, 0x2588, 0x259C, 0x2580, 0x259D, '.'
                    dd '.', ',', "'", '`', '#', '*'

section .tstate
alignb 8
brn_template:       resq 1              ; the burn scene to clone, + 1 (0 = none yet)
brn_pool:           resb POOL_size
alignb 8
brn_char_order:     resq BRN_CHAR_ORDER
brn_smoke_symbols:  resq BRN_SMOKE_SYMBOLS
brn_smoke_spectrum: resq BRN_SMOKE_LEN + 2
brn_pair_stops:     resq 2
brn_pair_spectrum:  resq BRN_CHAR_LEN + 2
brn_bg_spectrum:    resq BRN_CHAR_LEN + 2
brn_fire:           resq 1
brn_fire_len:       resq 1
brn_final_spectrum: resq 1
brn_map:            resq 1
brn_map_width:      resq 1
brn_order:          resq 1
brn_order_count:    resq 1
brn_order_head:     resq 1
brn_origin:         resq 1
brn_emissions:      resq 1
