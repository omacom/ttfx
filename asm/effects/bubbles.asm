; effects/bubbles.asm - "Characters are formed into bubbles that float down
; and pop into position" (src/effects/bubbles.rs).
;
; Config (src/asm/effects.rs, the Bubbles arm). --movement-easing is parsed
; but never read upstream, so it is not passed.
;
; A bubble is a run of characters (rows bottom to top) around an invisible
; anchor character whose path carries it to the floor; every move places the
; characters on a circle around the anchor. The rainbow sheen scene is made
; looping up front: Rust sets is_looping right after activating it, and
; activation does not read the flag.

struc BUBBLES
    .rainbow:           resq 1
    .colors:            resq 1          ; *const u64 bubble colors
    .color_count:       resq 1
    .pop_color:         resq 1
    .speed:             resq 1          ; f64 bubble speed
    .delay:             resq 1
    .pop_condition:     resq 1          ; 0 row, 1 bottom, 2 anywhere
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; BubblesIterator.Bubble
struc BUB
    .chars:     resq 1                  ; *u32 slots (a slice of the row list)
    .n:         resq 1
    .radius:    resq 1
    .lowest:    resq 1                  ; lowest_row
    .anchor:    resd 1
    .landed:    resd 1
    .trig:      resq 1                  ; radius * (cos, sin) per point, or 0
endstruc

%define BUB_POP_ROW         0
%define BUB_POP_ANYWHERE    2

; scene names
%define BUB_SCN_POP1        NAME_LITERAL + 0
; path names
%define BUB_PATH_FINAL      NAME_LITERAL + 0
%define BUB_PATH_POP_OUT    NAME_LITERAL + 1

%define BUB_EASE_OUT_EXPO   17
%define BUB_EASE_IN_OUT_EXPO 18

section .text

; bubbles_build: Bubbles::new (the rainbow gradient) + Bubbles::build.
bubbles_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    lea     rdi, [bub_rainbow_stops]
    mov     esi, 7
    lea     rdx, [bub_five_steps]
    mov     ecx, 1
    lea     r8, [bub_rainbow]
    call    gradient_new
    mov     [bub_rainbow_len], rax
    call    bub_final_map
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [bub_dynamic], al
    ; every input character: layer, pop scenes, final scene and path
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     r14d, r14d
.setup:
    cmp     r14, r13
    jae     .rows
    mov     edi, [r12 + r14 * 4]
    call    bub_setup_char
    inc     r14
    jmp     .setup
.rows:
    ; unbubbled_chars: the row groups, bottom to top, flattened
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_ROW_BOTTOM_TO_TOP
    call    get_characters_grouped
    mov     r12, rax
    mov     r13, rdx
    xor     r14d, r14d                  ; total
    xor     ecx, ecx
.sum:
    cmp     rcx, r13
    jae     .summed
    mov     rax, rcx
    shl     rax, 4
    add     r14, [r12 + rax + 8]
    inc     rcx
    jmp     .sum
.summed:
    lea     rdi, [r14 * 4 + 64]
    call    alloc
    mov     r15, rax                    ; the flat list
    xor     ebx, ebx                    ; group
    xor     ebp, ebp                    ; position in the flat list
.group:
    cmp     rbx, r13
    jae     .flat
    mov     rax, rbx
    shl     rax, 4
    mov     rsi, [r12 + rax]
    mov     rcx, [r12 + rax + 8]
.copy:
    test    rcx, rcx
    jz      .next_group
    mov     edx, [rsi]
    mov     [r15 + rbp * 4], edx
    add     rsi, 4
    inc     rbp
    dec     rcx
    jmp     .copy
.next_group:
    inc     rbx
    jmp     .group
.flat:
    lea     rdi, [r14 + 1]
    imul    rdi, rdi, BUB_size
    call    alloc
    mov     [bub_list], rax
    lea     rdi, [r14 * 8 + 64]
    call    alloc
    mov     [bub_anim], rax
    ; take bubbles off the front until nothing is left
    xor     ebx, ebx                    ; taken
.bubble:
    mov     r12, r14
    sub     r12, rbx                    ; remaining
    jz      .state
    cmp     r12, 5
    jb      .take
    mov     rsi, r12
    mov     eax, 20
    cmp     rsi, rax
    cmova   rsi, rax
    mov     edi, 5
    call    rng_randint
    mov     r12, rax
.take:
    mov     edi, 1
    mov     rsi, [canvas_right]
    call    rng_randint
    mov     rdx, [canvas_top]
    add     rdx, 10
    shl     rdx, 32
    mov     eax, eax
    or      rdx, rax                    ; bubble_origin
    lea     rdi, [r15 + rbx * 4]
    mov     rsi, r12
    call    bub_make
    add     rbx, r12
    jmp     .bubble
.state:
    mov     qword [bub_next], 0
    mov     qword [bub_anim_count], 0
    mov     qword [bub_steps], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bub_setup_char(edi=slot): the per-character part of Bubbles::build.
bub_setup_char:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     esi, 1
    call    set_layer
    mov     edi, ebx
    mov     esi, BUB_SCN_POP1
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax                   ; pop_1
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax                   ; pop_2
    mov     rax, [effect_config]
    mov     rcx, [rax + BUBBLES.pop_color]
    mov     edi, r12d
    mov     rsi, [bub_sym_star]
    mov     edx, 9
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     rax, [effect_config]
    mov     rcx, [rax + BUBBLES.pop_color]
    mov     edi, r13d
    mov     rsi, [bub_sym_tick]
    mov     edx, 9
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax                   ; final scene
    mov     rax, [ch_sym]
    mov     rax, [rax + rbx * 8]
    mov     [bub_sym], rax
    cmp     byte [bub_dynamic], 0
    je      .mapped
    ; dynamic: pop color -> the input colors, whichever exist
    xor     ebp, ebp                    ; fg spectrum
    xor     r15d, r15d                  ; bg spectrum
    mov     rax, [ch_fg]
    mov     rsi, [rax + rbx * 8]
    cmp     rsi, NONE
    je      .bg
    lea     rdi, [bub_fg_spectrum]
    call    bub_pop_gradient
    mov     [bub_fg_len], rax
    lea     rbp, [bub_fg_spectrum]
.bg:
    mov     rax, [ch_bg]
    mov     rsi, [rax + rbx * 8]
    cmp     rsi, NONE
    je      .dynamic_frames
    lea     rdi, [bub_bg_spectrum]
    call    bub_pop_gradient
    mov     [bub_bg_len], rax
    lea     r15, [bub_bg_spectrum]
.dynamic_frames:
    mov     rax, rbp
    or      rax, r15
    jnz     .dynamic_gradient
    mov     edi, r14d
    mov     rsi, [bub_sym]
    mov     edx, 6
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .events
.dynamic_gradient:
    push    qword [bub_bg_len]
    push    r15
    mov     edi, r14d
    lea     rsi, [bub_sym]
    mov     edx, 1
    mov     ecx, 6
    mov     r8, rbp
    mov     r9, [bub_fg_len]
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .events
.mapped:
    mov     edi, ebx
    call    bub_final_color
    mov     rsi, rax
    lea     rdi, [bub_fg_spectrum]
    call    bub_pop_gradient
    push    0
    push    0
    mov     edi, r14d
    lea     rsi, [bub_sym]
    mov     edx, 1
    mov     ecx, 6
    lea     r8, [bub_fg_spectrum]
    mov     r9, rax
    call    scene_apply_gradient
    add     rsp, 16
.events:
    ; pop_1 complete -> pop_2, pop_2 complete -> final
    SCENE_PTR rax, r12
    mov     ecx, [rax + SC_NAME]
    SCENE_PTR rax, r13
    mov     r9d, [rax + SC_NAME]
    SCENE_PTR rax, r14
    mov     ebp, [rax + SC_NAME]
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     r8d, ACT_ACTIVATE_SCENE
    call    event_register
    SCENE_PTR rax, r13
    mov     ecx, [rax + SC_NAME]
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, ebp
    call    event_register
    add     rsp, 16
    ; the final path home, then layer 0
    mov     edi, ebx
    movsd   xmm0, [bub_speed_pop]
    mov     esi, BUB_EASE_IN_OUT_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, BUB_PATH_FINAL
    call    path_new
    mov     ebp, eax
    mov     edi, ebx
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, BUB_PATH_FINAL
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
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

; bub_pop_gradient(rdi=spectrum out, rsi=color) -> rax = length:
; Gradient::with_steps([pop_color, color], 8).
bub_pop_gradient:
    mov     rax, [effect_config]
    mov     rax, [rax + BUBBLES.pop_color]
    mov     [bub_pair_stops], rax
    mov     [bub_pair_stops + 8], rsi
    mov     r8, rdi
    lea     rdi, [bub_pair_stops]
    mov     esi, 2
    lea     rdx, [bub_eight_steps]
    mov     ecx, 1
    call    gradient_new
    mov     eax, eax
    ret

; bub_final_color(edi=slot) -> rax: character_final_color_map, the final
; gradient at the input coordinate.
bub_final_color:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    sub     rax, [text_bottom]
    imul    rax, [bub_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rdi * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [bub_final_map_ptr]
    mov     rax, [rcx + rax * 8]
    ret

; bub_final_map: Gradient::new(final stops, final steps) and its coordinate
; mapping over the text rectangle.
bub_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + BUBBLES.final_steps]
    mov     rcx, [rbx + BUBBLES.final_step_count]
    mov     rsi, [rbx + BUBBLES.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [bub_final_spectrum], rax
    mov     rdi, [rbx + BUBBLES.final_stops]
    mov     rsi, [rbx + BUBBLES.final_stop_count]
    mov     rdx, [rbx + BUBBLES.final_steps]
    mov     rcx, [rbx + BUBBLES.final_step_count]
    mov     r8, [bub_final_spectrum]
    call    gradient_new
    mov     rdi, [bub_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [bub_final_map_width], rax
    push    qword [rbx + BUBBLES.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [bub_final_map_ptr], rax
    pop     rbx
    ret

; bub_make(rdi=chars, rsi=count, rdx=origin): Bubble.__init__ with
; make_waypoints and make_gradients; appends the bubble to bub_list.
bub_make:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     rbx, [bub_count]
    imul    rbx, rbx, BUB_size
    add     rbx, [bub_list]
    inc     qword [bub_count]
    mov     [rbx + BUB.chars], r12
    mov     [rbx + BUB.n], r13
    mov     rax, r13
    xor     edx, edx
    mov     ecx, 5
    div     rcx
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [rbx + BUB.radius], rax
    mov     rdi, [bub_sym_space]
    mov     rsi, r14
    call    add_character
    mov     [rbx + BUB.anchor], eax
    ; lowest_row: the bubble's lowest input row, or the canvas bottom
    mov     qword [rbx + BUB.lowest], 1
    mov     rax, [effect_config]
    cmp     qword [rax + BUBBLES.pop_condition], BUB_POP_ROW
    jne     .coords
    mov     rdx, [ch_irow]
    mov     rax, 0x7fffffffffffffff
    xor     ecx, ecx
.min_row:
    cmp     rcx, r13
    jae     .lowest
    mov     esi, [r12 + rcx * 4]
    movsxd  rsi, dword [rdx + rsi * 4]
    cmp     rsi, rax
    cmovl   rax, rsi
    inc     rcx
    jmp     .min_row
.lowest:
    mov     [rbx + BUB.lowest], rax
.coords:
    mov     rdi, rbx
    call    bub_set_coords
    mov     dword [rbx + BUB.landed], 0
    ; make_waypoints: the anchor floats to a random column on the floor
    mov     edi, 1
    mov     rsi, [canvas_right]
    call    rng_randint
    mov     r14, [rbx + BUB.lowest]
    shl     r14, 32
    mov     eax, eax
    or      r14, rax
    mov     edi, [rbx + BUB.anchor]
    mov     rax, [effect_config]
    movsd   xmm0, [rax + BUBBLES.speed]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax
    mov     edi, eax
    mov     rsi, r14
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, [rbx + BUB.anchor]
    mov     esi, ebp
    call    path_activate
    ; make_gradients
    mov     rax, [effect_config]
    cmp     qword [rax + BUBBLES.rainbow], 0
    jne     .rainbow
    mov     rdi, [rax + BUBBLES.color_count]
    call    rng_below
    mov     rcx, [effect_config]
    mov     rcx, [rcx + BUBBLES.colors]
    mov     r14, [rcx + rax * 8]        ; bubble_color
    xor     r15d, r15d
.plain:
    cmp     r15, r13
    jae     .done
    mov     ebp, [r12 + r15 * 4]
    inc     r15
    mov     edi, ebp
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp], eax
    mov     edi, eax
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     rcx, r14
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, ebp
    mov     esi, [rsp]
    call    scene_activate
    jmp     .plain
.rainbow:
    ; frame j of character k is spectrum[(rot + j) % len], where rot sums
    ; the growing offsets (the list is rotated by each one in turn)
    mov     qword [bub_rot], 0
    xor     r14d, r14d                  ; gradient_offset
    xor     r15d, r15d
.sheen:
    cmp     r15, r13
    jae     .done
    mov     ebp, [r12 + r15 * 4]
    inc     r15
    mov     edi, ebp
    mov     esi, AUTO
    mov     edx, SCF_LOOPING
    mov     ecx, NONE
    call    scene_new
    mov     [rsp], eax
    xor     ebx, ebx                    ; j (the bubble record is done)
.step:
    cmp     rbx, [bub_rainbow_len]
    jae     .rotate
    mov     rax, [bub_rot]
    add     rax, rbx
    xor     edx, edx
    div     qword [bub_rainbow_len]
    lea     rax, [bub_rainbow]
    mov     rcx, [rax + rdx * 8]
    mov     edi, [rsp]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 4
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     rbx
    jmp     .step
.rotate:
    lea     rax, [r14 + 2]
    xor     edx, edx
    div     qword [bub_rainbow_len]
    mov     r14, rdx
    mov     rax, [bub_rot]
    add     rax, r14
    xor     edx, edx
    div     qword [bub_rainbow_len]
    mov     [bub_rot], rdx
    mov     edi, ebp
    mov     esi, [rsp]
    call    scene_activate
    jmp     .sheen
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bub_set_coords(rdi=bubble): Bubble.set_character_coordinates:
; find_coords_on_circle(anchor, radius, n, false). Its trig does not depend
; on the anchor, so radius * cos and radius * sin of each point's angle are
; made once per bubble (the same sincos of the same angles) and each move
; only adds the anchor and rounds, in Rust's order.
bub_set_coords:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    sub     rsp, 16                     ; [rsp] origin column, [rsp+8] row (f64)
    mov     rbx, rdi
    cmp     qword [rbx + BUB.radius], 0
    je      .moved                      ; no points at all
    mov     r12, [rbx + BUB.trig]
    test    r12, r12
    jnz     .placed
    call    bub_trig
    mov     r12, rax
.placed:
    mov     edi, [rbx + BUB.anchor]
    call    char_coord
    movsxd  rcx, eax
    cvtsi2sd xmm0, rcx
    movsd   [rsp], xmm0
    sar     rax, 32
    cvtsi2sd xmm0, rax
    movsd   [rsp + 8], xmm0
    xor     ebp, ebp
.char:
    cmp     rbp, [rbx + BUB.n]
    jae     .moved
    ; x = column + radius * cos; x += x - column; y = row + radius * sin
    mov     rax, rbp
    shl     rax, 4
    movsd   xmm0, [r12 + rax]
    addsd   xmm0, [rsp]
    movapd  xmm1, xmm0
    subsd   xmm1, [rsp]
    addsd   xmm0, xmm1
    ROUND_HALF_EVEN
    mov     r13d, eax
    mov     rax, rbp
    shl     rax, 4
    movsd   xmm0, [r12 + rax + 8]
    addsd   xmm0, [rsp + 8]
    ROUND_HALF_EVEN
    mov     r14, rax
    shl     rax, 32
    or      r13, rax
    mov     rax, [rbx + BUB.chars]
    mov     edi, [rax + rbp * 4]
    mov     rsi, r13
    call    set_coordinate
    movsxd  rax, r14d
    cmp     rax, [rbx + BUB.lowest]
    jne     .next
    mov     dword [rbx + BUB.landed], 1
.next:
    inc     rbp
    jmp     .char
.moved:
    mov     rax, [effect_config]
    cmp     qword [rax + BUBBLES.pop_condition], BUB_POP_ANYWHERE
    jne     .done
    call    rng_random
    movsd   xmm1, [bub_pop_chance]
    ucomisd xmm1, xmm0
    jbe     .done
    mov     dword [rbx + BUB.landed], 1
.done:
    add     rsp, 16
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bub_trig(rbx=bubble) -> rax = n (radius * cos(a_i), radius * sin(a_i))
; pairs, a_i = (2 pi / n) * i as find_coords_on_circle computes them; kept
; in BUB.trig. Clobbers C except rbx, rbp, r12-r15.
bub_trig:
    push    r12
    push    r13
    push    r14
    sub     rsp, 32
    mov     rdi, [rbx + BUB.n]
    shl     rdi, 4
    add     rdi, 16
    call    alloc
    mov     r12, rax
    mov     [rbx + BUB.trig], rax
    mov     r13, [rbx + BUB.n]
    test    r13, r13
    jle     .done
    cvtsi2sd xmm1, r13
    movsd   xmm0, [bub_two_pi]
    divsd   xmm0, xmm1
    movsd   [rsp + 16], xmm0            ; angle_step
    cvtsi2sd xmm0, qword [rbx + BUB.radius]
    movsd   [rsp + 24], xmm0
    xor     r14d, r14d
.point:
    cmp     r14, r13
    jge     .done
    cvtsi2sd xmm0, r14
    mulsd   xmm0, [rsp + 16]            ; angle
    lea     rdi, [rsp]
    lea     rsi, [rsp + 8]
    CCALL   sincos
    movsd   xmm0, [rsp + 8]
    mulsd   xmm0, [rsp + 24]            ; radius * cos
    movsd   [r12], xmm0
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rsp + 24]            ; radius * sin
    movsd   [r12 + 8], xmm0
    add     r12, 16
    inc     r14
    jmp     .point
.done:
    mov     rax, [rbx + BUB.trig]
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    ret

; bub_pop(rdi=bubble): Bubble.pop - each character (zipped with the unique
; points of a wider circle) gets a pop_out path that hands over to "final",
; then all of them start pop_1 and pop_out and join the active set.
bub_pop:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx + BUB.anchor]
    call    char_coord
    mov     rdi, rax
    mov     rsi, [rbx + BUB.radius]
    add     rsi, 3
    mov     rdx, [rbx + BUB.n]
    mov     ecx, 1
    call    find_coords_on_circle
    mov     r12, rax
    mov     r13, rdx
    cmp     r13, [rbx + BUB.n]
    cmova   r13, [rbx + BUB.n]
    xor     r14d, r14d
.path:
    cmp     r14, r13
    jae     .activate
    mov     rax, [rbx + BUB.chars]
    mov     ebp, [rax + r14 * 4]
    mov     edi, ebp
    movsd   xmm0, [bub_speed_pop]
    mov     esi, BUB_EASE_OUT_EXPO
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, BUB_PATH_POP_OUT
    call    path_new
    mov     edi, eax
    mov     rsi, [r12 + r14 * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    push    0
    push    0
    mov     edi, ebp
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, BUB_PATH_POP_OUT
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, BUB_PATH_FINAL
    call    event_register
    add     rsp, 16
    inc     r14
    jmp     .path
.activate:
    xor     r14d, r14d
.char:
    cmp     r14, [rbx + BUB.n]
    jae     .insert
    mov     rax, [rbx + BUB.chars]
    mov     ebp, [rax + r14 * 4]
    mov     edi, ebp
    mov     esi, BUB_SCN_POP1
    call    scene_activate_name
    mov     edi, ebp
    mov     esi, BUB_PATH_POP_OUT
    call    path_activate_name
    inc     r14
    jmp     .char
.insert:
    xor     r14d, r14d
.active:
    cmp     r14, [rbx + BUB.n]
    jae     .done
    mov     rax, [rbx + BUB.chars]
    mov     edi, [rax + r14 * 4]
    call    active_insert
    inc     r14
    jmp     .active
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; bub_move(rdi=bubble): Bubble.move.
bub_move:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     edi, [rbx + BUB.anchor]
    call    motion_move
    mov     rdi, rbx
    call    bub_set_coords
    xor     r12d, r12d
    mov     r13, [rbx + BUB.chars]
.char:
    cmp     r12, [rbx + BUB.n]
    jae     .done
    mov     edi, [r13 + r12 * 4]
    call    step_animation
    inc     r12
    jmp     .char
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; bubbles_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
bubbles_next_frame:
    push    rbx
    push    rbp
    push    r12
    cmp     qword [bub_anim_count], 0
    jne     .frame
    mov     rax, [bub_next]
    cmp     rax, [bub_count]
    jb      .frame
    call    active_empty
    test    eax, eax
    jz      .frame
    xor     eax, eax
    pop     r12
    pop     rbp
    pop     rbx
    ret
.frame:
    ; release the next bubble every bubble_delay steps
    mov     rbx, [bub_next]
    cmp     rbx, [bub_count]
    jae     .count
    mov     rax, [effect_config]
    mov     rax, [rax + BUBBLES.delay]
    cmp     [bub_steps], rax
    jl      .count
    imul    rbx, rbx, BUB_size
    add     rbx, [bub_list]
    inc     qword [bub_next]
    xor     r12d, r12d
.show:
    cmp     r12, [rbx + BUB.n]
    jae     .shown
    mov     rax, [rbx + BUB.chars]
    mov     edi, [rax + r12 * 4]
    call    set_visible
    inc     r12
    jmp     .show
.shown:
    mov     rax, [bub_anim]
    mov     rcx, [bub_anim_count]
    mov     [rax + rcx * 8], rbx
    inc     qword [bub_anim_count]
    mov     qword [bub_steps], 0
.count:
    inc     qword [bub_steps]
    ; landed bubbles pop
    xor     r12d, r12d
.landed:
    cmp     r12, [bub_anim_count]
    jae     .retain
    mov     rax, [bub_anim]
    mov     rdi, [rax + r12 * 8]
    inc     r12
    cmp     dword [rdi + BUB.landed], 0
    je      .landed
    call    bub_pop
    jmp     .landed
.retain:
    xor     r12d, r12d                  ; read
    xor     ebp, ebp                    ; write
    mov     rax, [bub_anim]
.keep:
    cmp     r12, [bub_anim_count]
    jae     .kept
    mov     rdi, [rax + r12 * 8]
    inc     r12
    cmp     dword [rdi + BUB.landed], 0
    jne     .keep
    mov     [rax + rbp * 8], rdi
    inc     rbp
    jmp     .keep
.kept:
    mov     [bub_anim_count], rbp
    ; the rest float on
    xor     r12d, r12d
.move:
    cmp     r12, [bub_anim_count]
    jae     .update
    mov     rax, [bub_anim]
    mov     rdi, [rax + r12 * 8]
    inc     r12
    call    bub_move
    jmp     .move
.update:
    call    update
    mov     eax, 1
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
bub_two_pi:     dq 0x401921FB54442D18   ; 2 * pi
align 8
bub_rainbow_stops:  dq 0xe81416, 0xffa500, 0xfaeb36, 0x79c314, 0x487de7, 0x4b369d, 0x70369d
bub_five_steps:     dq 5
bub_eight_steps:    dq 8
bub_speed_pop:      dq 0.3
bub_pop_chance:     dq 0.002
bub_sym_star:       dq 0x10000002a      ; "*"
bub_sym_tick:       dq 0x100000027      ; "'"
bub_sym_space:      dq 0x100000020      ; " "

section .tstate
alignb 8
bub_rainbow:            resq 64
bub_rainbow_len:        resq 1
bub_rot:                resq 1
bub_final_spectrum:     resq 1
bub_final_map_ptr:      resq 1
bub_final_map_width:    resq 1
bub_pair_stops:         resq 2
bub_fg_spectrum:        resq 16
bub_bg_spectrum:        resq 16
bub_fg_len:             resq 1
bub_bg_len:             resq 1
bub_sym:                resq 1
bub_list:               resq 1
bub_count:              resq 1
bub_next:               resq 1
bub_anim:               resq 1
bub_anim_count:         resq 1
bub_steps:              resq 1
bub_dynamic:            resb 1
