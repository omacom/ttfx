; effects/orbittingvolley.asm - "Four launchers orbit the canvas, firing
; volleys of characters towards their input coordinates"
; (src/effects/orbittingvolley.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Orbittingvolley).
;
; The effect draws no random numbers. The main (top) launcher rides the
; "perimeter" path along the top row; the other three are placed from its
; progress each frame. Launcher.magazine is a cursor into the flattened
; center-to-outside order: launcher i owns positions i, i + 4, i + 8, ...
; and remove(0) advances its cursor by 4.

struc ORBITTINGVOLLEY
    .top_symbol:        resq 1
    .right_symbol:      resq 1
    .bottom_symbol:     resq 1
    .left_symbol:       resq 1
    .launcher_speed:    resq 1          ; f64
    .character_speed:   resq 1          ; f64
    .volley_size:       resq 1          ; f64
    .launch_delay:      resq 1
    .character_easing:  resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; path names: "input_path", "perimeter"
%define OV_INPUT            NAME_LITERAL + 0
%define OV_PERIMETER        NAME_LITERAL + 1

section .text

; orbittingvolley_build: OrbittingVolley::build.
orbittingvolley_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    ov_color_maps
    mov     r13, [effect_config]
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r15
    jae     .launchers
    mov     r12d, [r14 + rbx * 4]
    ; the "input_path" home, layer 1
    movsd   xmm0, [r13 + ORBITTINGVOLLEY.character_speed]
    mov     edi, r12d
    mov     esi, [r13 + ORBITTINGVOLLEY.character_easing]
    mov     edx, 1
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, OV_INPUT
    call    path_new
    mov     ebp, eax
    mov     edi, r12d
    call    char_input_coord
    mov     edi, ebp
    mov     rsi, rax
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; PathComplete("input_path") -> SetLayer(0)
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, OV_INPUT
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    add     rsp, 16
    ; the final colors: the input colors under dynamic handling, else the
    ; final gradient at the input coordinate
    cmp     qword [cfg_existing_colors], 1
    jne     .final
    mov     rax, [ch_fg]
    mov     rdx, [rax + r12 * 8]
    mov     rax, [ch_bg]
    mov     rcx, [rax + r12 * 8]
    jmp     .appearance
.final:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [ov_final_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [ov_final_map]
    mov     rdx, [rcx + rax * 8]
    mov     rcx, NONE
.appearance:
    mov     edi, r12d
    xor     esi, esi
    call    set_appearance
    inc     rbx
    jmp     .char
.launchers:
    ; top-left, top-right, bottom-right, bottom-left, each on layer 2
    xor     ebx, ebx
.launcher:
    cmp     ebx, 4
    jae     .main
    mov     rdi, [r13 + ORBITTINGVOLLEY.top_symbol + rbx * 8]
    call    ov_corner
    mov     rsi, rax
    call    add_character
    mov     r12d, eax
    lea     rcx, [ov_launchers]
    mov     [rcx + rbx * 4], eax
    mov     edi, r12d
    mov     esi, 2
    call    set_layer
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
    inc     ebx
    jmp     .launcher
.main:
    mov     r12d, [ov_launchers]
    mov     edi, r12d
    xor     esi, esi
    mov     rdx, [ov_last_color]
    mov     rcx, NONE
    call    set_appearance
    ; Launcher.build_paths: the main launcher starts at waypoints[0], so the
    ; rotation is the identity
    movsd   xmm0, [r13 + ORBITTINGVOLLEY.launcher_speed]
    mov     edi, r12d
    mov     esi, NONE
    mov     edx, 2
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, OV_PERIMETER
    call    path_new
    mov     [ov_perimeter], eax
    mov     edi, eax
    mov     rsi, [canvas_top]
    shl     rsi, 32
    or      rsi, 1
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, [ov_perimeter]
    mov     rsi, [canvas_top]
    shl     rsi, 32
    mov     eax, [canvas_right]
    or      rsi, rax
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, r12d
    mov     esi, [ov_perimeter]
    call    path_activate
    ; the magazines: center to outside, dealt round robin
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_CENTER_TO_OUTSIDE
    call    get_characters_grouped
    mov     r14, rax
    mov     r15, rdx
    xor     ecx, ecx
    xor     edi, edi
.sum:
    cmp     rcx, r15
    jae     .flatten
    mov     rax, rcx
    shl     rax, 4
    add     rdi, [r14 + rax + 8]
    inc     rcx
    jmp     .sum
.flatten:
    mov     [ov_sorted_count], rdi
    shl     rdi, 2
    add     rdi, 4
    call    alloc
    mov     [ov_sorted], rax
    mov     rdi, rax
    xor     ecx, ecx
.group:
    cmp     rcx, r15
    jae     .dealt
    mov     rax, rcx
    shl     rax, 4
    mov     rsi, [r14 + rax]
    mov     rdx, [r14 + rax + 8]
    xor     r8d, r8d
.member:
    cmp     r8, rdx
    jae     .next_group
    mov     eax, [rsi + r8 * 4]
    mov     [rdi], eax
    add     rdi, 4
    inc     r8
    jmp     .member
.next_group:
    inc     rcx
    jmp     .group
.dealt:
    lea     rax, [ov_cursor]
    mov     qword [rax], 0
    mov     qword [rax + 8], 1
    mov     qword [rax + 16], 2
    mov     qword [rax + 24], 3
    ; characters per volley: max(int(volley_size * len(input) / 4), 1)
    cvtsi2sd xmm0, qword [input_count]
    movsd   xmm1, [r13 + ORBITTINGVOLLEY.volley_size]
    mulsd   xmm1, xmm0
    divsd   xmm1, [ov_four]
    cvttsd2si rax, xmm1
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [ov_volley], rax
    mov     qword [ov_delay], 0
    mov     byte [ov_complete], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ov_corner(ebx=launcher index) -> rax = its packed corner coordinate:
; (left, top), (right, top), (right, bottom), (left, bottom). Keeps rdi.
ov_corner:
    mov     rax, 1                      ; row = bottom
    cmp     ebx, 2
    jae     .row
    mov     rax, [canvas_top]
.row:
    shl     rax, 32
    mov     ecx, 1                      ; column = left
    cmp     ebx, 1
    je      .right
    cmp     ebx, 2
    jne     .column
.right:
    mov     ecx, [canvas_right]
.column:
    or      rax, rcx
    ret

; ov_color_maps: Gradient::new(final stops, steps), its coordinate maps over
; the text rectangle and over the canvas, and the spectrum's last color.
ov_color_maps:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 8
    mov     rbx, [effect_config]
    mov     rdi, [rbx + ORBITTINGVOLLEY.final_steps]
    mov     rcx, [rbx + ORBITTINGVOLLEY.final_step_count]
    mov     rsi, [rbx + ORBITTINGVOLLEY.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + ORBITTINGVOLLEY.final_stops]
    mov     rsi, [rbx + ORBITTINGVOLLEY.final_stop_count]
    mov     rdx, [rbx + ORBITTINGVOLLEY.final_steps]
    mov     rcx, [rbx + ORBITTINGVOLLEY.final_step_count]
    mov     r8, r12
    call    gradient_new
    mov     r13d, eax
    mov     rax, [r12 + r13 * 8 - 8]
    mov     [ov_last_color], rax
    ; over the text
    mov     rdi, r12
    mov     esi, r13d
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [ov_final_width], rax
    push    qword [rbx + ORBITTINGVOLLEY.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [ov_final_map], rax
    ; over the canvas (for the launchers)
    mov     rdi, r12
    mov     esi, r13d
    mov     edx, 1
    mov     rcx, [canvas_top]
    mov     r8d, 1
    mov     r9, [canvas_right]
    push    qword [rbx + ORBITTINGVOLLEY.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [ov_launcher_map], rax
    add     rsp, 8
    pop     r13
    pop     r12
    pop     rbx
    ret

; ov_launcher_color(edi=slot) -> rax = launcher_gradient_coordinate_map at
; the character's current coordinate.
ov_launcher_color:
    mov     rax, [ch_row]
    movsxd  rax, dword [rax + rdi * 4]
    dec     rax
    imul    rax, [canvas_right]
    mov     rcx, [ch_col]
    movsxd  rcx, dword [rcx + rdi * 4]
    add     rax, rcx
    dec     rax
    mov     rcx, [ov_launcher_map]
    mov     rax, [rcx + rax * 8]
    ret

; ov_set_child(ebx=child launcher index):
; OrbittingVolleyIterator._set_launcher_coordinates(parent 0, child).
ov_set_child:
    push    r12
    push    r13
    push    r14
    lea     rax, [ov_launchers]
    mov     r12d, [rax + rbx * 4]       ; child
    mov     edi, r12d
    call    char_input_coord
    ; parent_progress = main column / canvas right
    mov     edx, [ov_launchers]
    mov     rcx, [ch_col]
    movsxd  rdx, dword [rcx + rdx * 4]
    cvtsi2sd xmm2, rdx
    cvtsi2sd xmm0, qword [canvas_right]
    divsd   xmm2, xmm0
    mov     r13, [canvas_top]
    mov     r14, [canvas_right]
    ; (right, top)
    mov     rcx, r13
    shl     rcx, 32
    or      rcx, r14
    cmp     rax, rcx
    jne     .bottom_right
    cvtsi2sd xmm0, r13
    mulsd   xmm0, xmm2
    cvttsd2si rcx, xmm0
    mov     rsi, r13
    sub     rsi, rcx                    ; top - int(top * progress)
    mov     ecx, 1
    cmp     rsi, 1
    cmovl   rsi, rcx
    shl     rsi, 32
    or      rsi, r14
    jmp     .move
.bottom_right:
    mov     rcx, 1 << 32
    or      rcx, r14
    cmp     rax, rcx
    jne     .bottom_left
    cvtsi2sd xmm0, r14
    mulsd   xmm0, xmm2
    cvttsd2si rcx, xmm0
    mov     rsi, r14
    sub     rsi, rcx                    ; right - int(right * progress)
    mov     ecx, 1
    cmp     rsi, 1
    cmovl   rsi, rcx
    mov     esi, esi
    mov     rcx, 1 << 32
    or      rsi, rcx
    jmp     .move
.bottom_left:
    mov     rcx, (1 << 32) | 1
    cmp     rax, rcx
    jne     .color
    cvtsi2sd xmm0, r13
    mulsd   xmm0, xmm2
    cvttsd2si rsi, xmm0
    inc     rsi                         ; bottom + int(top * progress)
    cmp     rsi, r13
    cmovg   rsi, r13
    shl     rsi, 32
    or      rsi, 1
.move:
    mov     edi, r12d
    call    set_coordinate
.color:
    mov     edi, r12d
    call    ov_launcher_color
    mov     rdx, rax
    mov     edi, r12d
    xor     esi, esi
    mov     rcx, NONE
    call    set_appearance
    pop     r14
    pop     r13
    pop     r12
    ret

; ov_launch(ebx=launcher index): Launcher.launch, then the character joins
; the active set.
ov_launch:
    push    r12
    lea     rcx, [ov_cursor]
    mov     rax, [rcx + rbx * 8]
    cmp     rax, [ov_sorted_count]
    jae     .empty
    add     qword [rcx + rbx * 8], 4
    mov     rcx, [ov_sorted]
    mov     r12d, [rcx + rax * 4]
    lea     rax, [ov_launchers]
    mov     edi, [rax + rbx * 4]
    call    char_coord
    mov     edi, r12d
    mov     rsi, rax
    call    set_coordinate
    mov     edi, r12d
    mov     esi, OV_INPUT
    call    path_activate_name
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
.empty:
    pop     r12
    ret

; orbittingvolley_next_frame -> eax = 1 for a frame, 0 when done.
orbittingvolley_next_frame:
    push    rbx
    push    r12
    push    r13
    ; any magazine left, or anything besides one launcher still active
    lea     rcx, [ov_cursor]
    mov     rdx, [ov_sorted_count]
    xor     eax, eax
.magazines:
    cmp     [rcx + rax * 8], rdx
    jb      .running
    inc     eax
    cmp     eax, 4
    jb      .magazines
    call    active_count
    cmp     rax, 1
    ja      .running
    cmp     byte [ov_complete], 0
    jne     .done
    mov     byte [ov_complete], 1
    xor     ebx, ebx
.hide:
    lea     rax, [ov_launchers]
    mov     edi, [rax + rbx * 4]
    xor     esi, esi
    call    set_visibility
    inc     ebx
    cmp     ebx, 4
    jb      .hide
    jmp     .frame
.running:
    mov     r12d, [ov_launchers]
    mov     rax, [ch_path]
    cmp     dword [rax + r12 * 4], NONE
    jne     .main_color
    ; the perimeter run ended: back to its first waypoint and go again
    mov     rsi, [canvas_top]
    shl     rsi, 32
    or      rsi, 1
    mov     edi, r12d
    call    set_coordinate
    mov     edi, r12d
    mov     esi, [ov_perimeter]
    call    path_activate
    mov     edi, r12d
    call    active_insert
.main_color:
    mov     edi, r12d
    call    ov_launcher_color
    mov     rdx, rax
    mov     edi, r12d
    xor     esi, esi                    ; top_launcher_symbol is its symbol
    mov     rcx, NONE
    call    set_appearance
    mov     ebx, 1
.children:
    call    ov_set_child
    inc     ebx
    cmp     ebx, 4
    jb      .children
    cmp     qword [ov_delay], 0
    jne     .wait
    xor     ebx, ebx
.volley:
    mov     r13, [ov_volley]
.shot:
    lea     rcx, [ov_cursor]
    mov     rax, [rcx + rbx * 8]
    cmp     rax, [ov_sorted_count]
    jae     .next_launcher              ; the rest of the volley is empty
    call    ov_launch
    dec     r13
    jnz     .shot
.next_launcher:
    inc     ebx
    cmp     ebx, 4
    jb      .volley
    mov     rax, [effect_config]
    mov     rax, [rax + ORBITTINGVOLLEY.launch_delay]
    mov     [ov_delay], rax
    jmp     .update
.wait:
    dec     qword [ov_delay]
.update:
    call    update
.frame:
    mov     eax, 1
    pop     r13
    pop     r12
    pop     rbx
    ret
.done:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
ov_four:        dq 4.0

section .tstate
alignb 8
ov_final_map:       resq 1
ov_final_width:     resq 1
ov_launcher_map:    resq 1
ov_last_color:      resq 1
ov_sorted:          resq 1
ov_sorted_count:    resq 1
ov_cursor:          resq 4
ov_volley:          resq 1
ov_delay:           resq 1
ov_launchers:       resd 4
ov_perimeter:       resd 1
ov_complete:        resb 1
