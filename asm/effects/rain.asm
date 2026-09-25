; effects/rain.asm - "Rain characters from the top of the canvas"
; (src/effects/rain.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Rain):
;
; Every character gets its scenes, path and event in Rust's order, so every
; RNG draw lines up. group_by_row is the TopToBottomLeftToRight character list
; walked backwards one row at a time: Rust's stable sort by ascending row keeps
; each row's left-to-right order, and the BTreeMap pops the lowest row first.

struc RAIN
    .colors:            resq 1          ; *const u64
    .color_count:       resq 1
    .speed_min:         resq 1          ; f64
    .speed_max:         resq 1          ; f64
    .symbols:           resq 1          ; *const u64 (packed)
    .symbol_count:      resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
    .easing:            resq 1
endstruc

; A fresh character's auto ids: its first scene is "0", its second "1", its
; first path "0". Naming them explicitly is the same as AUTO here.
%define RAIN_SCENE          0
%define RAIN_FADE           1
%define RAIN_PATH           0

section .text

; rain_build: Rain::build.
rain_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    ; memo of (rain color, rain symbol) -> handle
    mov     rdi, [rbx + RAIN.color_count]
    imul    rdi, [rbx + RAIN.symbol_count]
    shl     rdi, 2
    call    alloc
    mov     [rain_memo], rax
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [rain_dynamic], al
    jz      .characters                 ; dynamic ignores the final gradient
    call    rain_final_color_map
.characters:
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [rain_chars], rax
    mov     [rain_group_end], rdx
    mov     r12, rax
    mov     r13, rdx
    lea     rdi, [rdx * 4 + 4]
    call    alloc
    mov     [rain_pending], rax
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .built
    mov     r14d, [r12 + rbx * 4]       ; slot
    ; raindrop_color = choice(rain_colors)
    mov     rax, [effect_config]
    mov     rdi, [rax + RAIN.color_count]
    call    rng_below
    mov     r15d, eax
    mov     edi, r14d
    mov     esi, RAIN_SCENE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    ; rain_symbol = choice(rain_symbols); one frame of duration 1
    mov     rax, [effect_config]
    mov     rdi, [rax + RAIN.symbol_count]
    call    rng_below
    mov     esi, eax
    mov     eax, r15d
    call    rain_memo_visual
    mov     esi, eax
    mov     edi, ebp
    mov     edx, 1
    call    scene_add_frame_visual
    mov     [rsp], ebp                  ; rain scene
    mov     edi, r14d
    mov     esi, RAIN_FADE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     edi, eax
    mov     esi, r14d
    mov     edx, r15d
    call    rain_fade_scene
    mov     edi, r14d
    mov     esi, [rsp]
    call    scene_activate
    ; speed = uniform(movement_speed); start at the top of the canvas
    mov     rax, [effect_config]
    movsd   xmm0, [rax + RAIN.speed_min]
    movsd   xmm1, [rax + RAIN.speed_max]
    call    rng_uniform
    movsd   [rsp], xmm0
    mov     rsi, [canvas_top]
    shl     rsi, 32
    mov     rax, [ch_icol]
    mov     eax, [rax + r14 * 4]
    or      rsi, rax
    mov     edi, r14d
    call    set_coordinate
    mov     edi, r14d
    movsd   xmm0, [rsp]
    mov     rax, [effect_config]
    mov     esi, [rax + RAIN.easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, RAIN_PATH
    call    path_new
    mov     ebp, eax
    mov     edi, r14d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; PathComplete(input path) -> ActivateScene(fade)
    push    0
    push    0
    mov     edi, r14d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, RAIN_PATH
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, RAIN_FADE
    call    event_register
    add     rsp, 16
    mov     edi, r14d
    mov     esi, ebp
    call    path_activate
    inc     rbx
    jmp     .char
.built:
    mov     qword [rain_pending_len], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rain_fade_scene(edi=fade scene, esi=slot, edx=raindrop color index): the
; fade from the raindrop color to the final colors over the input symbol, 3
; ticks per color.
rain_fade_scene:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13d, esi
    mov     rax, [effect_config]
    mov     rax, [rax + RAIN.colors]
    mov     r14, [rax + rdx * 8]        ; raindrop color
    cmp     byte [rain_dynamic], 0
    jne     .dynamic
    ; with_steps([raindrop, final_gradient_mapping[input_coord]], 7)
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r13 * 4]
    sub     rax, [text_bottom]
    imul    rax, [rain_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r13 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [rain_map]
    mov     rbx, [rcx + rax * 8]
    mov     rbp, NONE
    jmp     .gradients
.dynamic:
    mov     rax, [ch_fg]
    mov     rbx, [rax + r13 * 8]
    mov     rax, [ch_bg]
    mov     rbp, [rax + r13 * 8]
    mov     rax, rbx
    and     rax, rbp
    cmp     rax, NONE
    jne     .gradients
    ; neither input color: the input symbol with no colors
    mov     edi, r12d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r13 * 8]
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .done
.gradients:
    cmp     rbx, NONE
    je      .bg
    mov     [rain_pair], r14
    mov     [rain_pair + 8], rbx
    lea     rdi, [rain_pair]
    mov     esi, 2
    lea     rdx, [rain_seven]
    mov     ecx, 1
    lea     r8, [rain_fg_spectrum]
    call    gradient_new
    mov     [rain_fg_len], rax
.bg:
    cmp     rbp, NONE
    je      .apply
    mov     [rain_pair], r14
    mov     [rain_pair + 8], rbp
    lea     rdi, [rain_pair]
    mov     esi, 2
    lea     rdx, [rain_seven]
    mov     ecx, 1
    lea     r8, [rain_bg_spectrum]
    call    gradient_new
    mov     [rain_bg_len], rax
.apply:
    mov     rax, [ch_sym]
    lea     rsi, [rax + r13 * 8]        ; [input symbol]
    mov     edi, r12d
    mov     edx, 1
    mov     ecx, 3
    xor     r8d, r8d
    xor     r9d, r9d
    cmp     rbx, NONE
    je      .no_fg
    lea     r8, [rain_fg_spectrum]
    mov     r9, [rain_fg_len]
.no_fg:
    xor     eax, eax
    xor     r10d, r10d
    cmp     rbp, NONE
    je      .no_bg
    lea     rax, [rain_bg_spectrum]
    mov     r10, [rain_bg_len]
.no_bg:
    push    r10
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rain_memo_visual(eax=color index, esi=symbol index) -> eax = handle.
rain_memo_visual:
    push    rbx
    mov     rcx, [effect_config]
    mov     ebx, [rcx + RAIN.symbol_count]
    imul    ebx, eax
    add     ebx, esi
    mov     rdx, [rain_memo]
    mov     edx, [rdx + rbx * 4]
    test    edx, edx
    jnz     .hit
    mov     rdx, [rcx + RAIN.colors]
    mov     rdi, [rdx + rax * 8]
    mov     rdx, [rcx + RAIN.symbols]
    mov     rdx, [rdx + rsi * 8]
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     rcx, [rain_memo]
    mov     [rcx + rbx * 4], eax
    mov     edx, eax
.hit:
    mov     eax, edx
    pop     rbx
    ret

; rain_final_color_map: Gradient::new(final stops, final steps) and
; build_coordinate_color_mapping over the text rectangle.
rain_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + RAIN.final_steps]
    mov     rcx, [rbx + RAIN.final_step_count]
    mov     rsi, [rbx + RAIN.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [rain_spectrum], rax
    mov     rdi, [rbx + RAIN.final_stops]
    mov     rsi, [rbx + RAIN.final_stop_count]
    mov     rdx, [rbx + RAIN.final_steps]
    mov     rcx, [rbx + RAIN.final_step_count]
    mov     r8, [rain_spectrum]
    call    gradient_new
    mov     rdi, [rain_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [rain_map_width], rax
    push    qword [rbx + RAIN.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [rain_map], rax
    pop     rbx
    ret

; rain_next_frame -> eax = 1 for a frame, 0 when done. Rain::next_frame.
rain_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [rain_pending_len], 0
    jne     .release
    cmp     qword [rain_group_end], 0
    jne     .next_row
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .tick
.next_row:
    ; pending_chars.extend(group_by_row.pop_first())
    mov     rdx, [rain_chars]
    mov     rcx, [rain_group_end]
    mov     r8, [ch_irow]
    mov     eax, [rdx + rcx * 4 - 4]
    mov     r9d, [r8 + rax * 4]         ; the lowest remaining row
    lea     rax, [rcx - 1]
.row_start:
    test    rax, rax
    jz      .copy
    mov     r10d, [rdx + rax * 4 - 4]
    cmp     [r8 + r10 * 4], r9d
    jne     .copy
    dec     rax
    jmp     .row_start
.copy:
    mov     [rain_group_end], rax
    sub     rcx, rax
    mov     [rain_pending_len], rcx
    lea     rsi, [rdx + rax * 4]
    mov     rdi, [rain_pending]
    rep     movsd
.release:
    mov     edi, 1
    mov     esi, 2
    call    rng_randint
    mov     r12, rax
.drop:
    test    r12, r12
    jz      .tick
    dec     r12
    mov     r13, [rain_pending_len]
    test    r13, r13
    jz      .tick
    xor     edi, edi
    lea     rsi, [r13 - 1]
    call    rng_randint
    ; pending_chars.remove(index)
    mov     rdi, [rain_pending]
    lea     rdi, [rdi + rax * 4]
    mov     ebx, [rdi]
    lea     rsi, [rdi + 4]
    lea     rcx, [r13 - 1]
    sub     rcx, rax
    rep     movsd
    dec     qword [rain_pending_len]
    mov     edi, ebx
    call    set_visible
    mov     edi, ebx
    call    active_insert
    jmp     .drop
.tick:
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
rain_seven:         dq 7

section .tstate
alignb 8
rain_memo:          resq 1
rain_spectrum:      resq 1
rain_map:           resq 1
rain_map_width:     resq 1
rain_chars:         resq 1          ; TopToBottomLeftToRight input characters
rain_group_end:     resq 1          ; rows not yet pending: rain_chars[..end]
rain_pending:       resq 1
rain_pending_len:   resq 1
rain_fg_len:        resq 1
rain_bg_len:        resq 1
rain_pair:          resq 2
rain_fg_spectrum:   resq 16
rain_bg_spectrum:   resq 16
rain_dynamic:       resb 1
