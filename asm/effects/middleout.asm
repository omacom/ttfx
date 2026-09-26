; effects/middleout.asm - "Text expands in a single row or column in the
; middle of the canvas then out" (src/effects/middleout.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Middleout).
;
; The effect draws no random numbers. Every character starts at the canvas
; center in the starting color, rides an auto-named path to the center line,
; and once all have settled, the "full" path home and the "full" scene fading
; to its final color, in ascending slot order (the canonical set order).

struc MIDDLEOUT
    .starting_color:    resq 1
    .expand_direction:  resq 1          ; 0 vertical, 1 horizontal
    .center_speed:      resq 1          ; f64
    .full_speed:        resq 1          ; f64
    .center_easing:     resq 1
    .full_easing:       resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; names: path "full", waypoint "full", scene "full"
%define MO_FULL             NAME_LITERAL + 0

section .text

; middleout_build: MiddleoutIterator.__init__ + build().
middleout_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    mo_final_color_map
    mov     qword [mo_last_final], NONE
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    mov     r13, [effect_config]
    xor     ebx, ebx
.char:
    cmp     rbx, r15
    jae     .done
    mov     r12d, [r14 + rbx * 4]
    mov     edi, r12d
    call    char_input_coord
    mov     [rsp], rax                  ; input coord
    ; motion.set_coordinate(canvas.center)
    mov     rsi, [center_row]
    shl     rsi, 32
    mov     eax, [center_col]
    or      rsi, rax
    mov     edi, r12d
    call    set_coordinate
    ; the center path (auto id) to the center line
    movsd   xmm0, [r13 + MIDDLEOUT.center_speed]
    mov     edi, r12d
    mov     esi, [r13 + MIDDLEOUT.center_easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     ebp, eax                    ; center path
    mov     rsi, [rsp]
    cmp     qword [r13 + MIDDLEOUT.expand_direction], 0
    jne     .horizontal
    ; vertical: (input column, center_row)
    mov     eax, esi
    mov     rsi, [center_row]
    shl     rsi, 32
    or      rsi, rax
    jmp     .waypoint
.horizontal:
    ; horizontal: (center_column, input row)
    mov     rax, 0xffffffff00000000
    and     rsi, rax
    mov     eax, [center_col]
    or      rsi, rax
.waypoint:
    mov     edi, ebp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; the "full" path home
    movsd   xmm0, [r13 + MIDDLEOUT.full_speed]
    mov     edi, r12d
    mov     esi, [r13 + MIDDLEOUT.full_easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, MO_FULL
    call    path_new
    mov     edi, eax
    mov     rsi, [rsp]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, MO_FULL
    call    path_new_waypoint
    ; the "full" scene
    mov     edi, r12d
    mov     esi, MO_FULL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + 8], rax              ; scene
    cmp     qword [cfg_existing_colors], 1
    jne     .final
    call    mo_scene_dynamic
    jmp     .appearance
.final:
    ; starting color -> final gradient color in 10 steps, 6 ticks each
    mov     rax, [rsp]
    mov     rdx, rax
    sar     rdx, 32
    sub     rdx, [text_bottom]
    imul    rdx, [mo_final_map_width]
    movsxd  rax, eax
    add     rax, rdx
    sub     rax, [text_left]
    mov     rcx, [mo_final_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [mo_last_final]
    je      .apply
    mov     [mo_last_final], rax
    mov     [mo_pair + 8], rax
    mov     rax, [r13 + MIDDLEOUT.starting_color]
    mov     [mo_pair], rax
    lea     rdi, [mo_pair]
    mov     esi, 2
    lea     rdx, [mo_ten_steps]
    mov     ecx, 1
    lea     r8, [mo_fg_spectrum]
    call    gradient_new
    mov     [mo_fg_len], rax
.apply:
    ; apply_gradient_to_symbols([input symbol], 6, fg spectrum): a frame per
    ; color, the visuals shared by symbol and final color
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + r12 * 8]
    lea     rsi, [mo_fg_spectrum]
    mov     rdx, [mo_fg_len]
    mov     rcx, NONE
    mov     r8, [mo_last_final]
    call    visual_run
    mov     edi, [rsp + 8]
    mov     rsi, rax
    mov     ecx, 6
    call    visual_frames
.appearance:
    mov     edi, r12d
    mov     esi, ebp
    call    path_activate
    mov     edi, r12d
    xor     esi, esi
    mov     rdx, [r13 + MIDDLEOUT.starting_color]
    mov     rcx, NONE
    call    set_appearance
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
    inc     rbx
    jmp     .char
.done:
    mov     byte [mo_phase], 0
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; mo_scene_dynamic(r12d=slot, r13=config; the build frame at [rsp+8]):
; the "full" scene under --existing-color-handling dynamic - gradients from
; the starting color to the input colors, or one colorless frame.
mo_scene_dynamic:
    push    rbx
    push    rbp
    ; the build frame is now at [rsp + 24]
    mov     rax, [ch_fg]
    mov     rbx, [rax + r12 * 8]        ; input fg
    mov     rax, [ch_bg]
    mov     rbp, [rax + r12 * 8]        ; input bg
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [rsp + 24 + 16], rax        ; [input symbol]
    cmp     rbx, NONE
    jne     .gradients
    cmp     rbp, NONE
    jne     .gradients
    mov     edi, [rsp + 24 + 8]
    mov     rsi, rax
    mov     edx, 6
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    pop     rbp
    pop     rbx
    ret
.gradients:
    mov     rax, [r13 + MIDDLEOUT.starting_color]
    mov     [mo_pair], rax
    cmp     rbx, NONE
    je      .bg
    mov     [mo_pair + 8], rbx
    lea     rdi, [mo_pair]
    mov     esi, 2
    lea     rdx, [mo_ten_steps]
    mov     ecx, 1
    lea     r8, [mo_fg_spectrum]
    call    gradient_new
    mov     [mo_fg_len], rax
.bg:
    cmp     rbp, NONE
    je      .apply
    mov     [mo_pair + 8], rbp
    lea     rdi, [mo_pair]
    mov     esi, 2
    lea     rdx, [mo_ten_steps]
    mov     ecx, 1
    lea     r8, [mo_bg_spectrum]
    call    gradient_new
    mov     [mo_bg_len], rax
.apply:
    ; the fg spectrum no longer matches mo_last_final
    mov     qword [mo_last_final], NONE
    mov     edi, [rsp + 24 + 8]
    lea     rsi, [rsp + 24 + 16]
    mov     edx, 1
    mov     ecx, 6
    xor     r8d, r8d
    xor     r9d, r9d
    cmp     rbx, NONE
    je      .no_fg
    lea     r8, [mo_fg_spectrum]
    mov     r9d, [mo_fg_len]
.no_fg:
    xor     eax, eax
    xor     r10d, r10d
    cmp     rbp, NONE
    je      .no_bg
    lea     rax, [mo_bg_spectrum]
    mov     r10d, [mo_bg_len]
.no_bg:
    push    r10
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
    pop     rbp
    pop     rbx
    ret

; mo_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
mo_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + MIDDLEOUT.final_steps]
    mov     rcx, [rbx + MIDDLEOUT.final_step_count]
    mov     rsi, [rbx + MIDDLEOUT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [mo_final_spectrum], rax
    mov     rdi, [rbx + MIDDLEOUT.final_stops]
    mov     rsi, [rbx + MIDDLEOUT.final_stop_count]
    mov     rdx, [rbx + MIDDLEOUT.final_steps]
    mov     rcx, [rbx + MIDDLEOUT.final_step_count]
    mov     r8, [mo_final_spectrum]
    call    gradient_new
    mov     rdi, [mo_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [mo_final_map_width], rax
    push    qword [rbx + MIDDLEOUT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [mo_final_map], rax
    pop     rbx
    ret

; middleout_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
middleout_next_frame:
    push    rbx
    cmp     byte [mo_phase], 0
    jne     .tick
    call    active_empty
    test    eax, eax
    jz      .tick
    ; the center line has settled: every character goes home, ascending
    mov     byte [mo_phase], 1
    xor     ebx, ebx
.full:
    cmp     rbx, [input_count]
    jae     .tick
    mov     rax, [input_chars]
    mov     edi, [rax + rbx * 4]
    push    rdi
    call    active_insert
    mov     edi, [rsp]
    mov     esi, MO_FULL
    call    path_activate_name
    pop     rdi
    mov     esi, MO_FULL
    call    scene_activate_name
    inc     rbx
    jmp     .full
.tick:
    call    active_empty
    test    eax, eax
    jnz     .finished
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
mo_ten_steps:       dq 10

section .tstate
alignb 8
mo_final_spectrum:  resq 1
mo_final_map:       resq 1
mo_final_map_width: resq 1
mo_last_final:      resq 1
mo_pair:            resq 2
mo_fg_spectrum:     resq 16
mo_bg_spectrum:     resq 16
mo_fg_len:          resq 1
mo_bg_len:          resq 1
mo_phase:           resb 1
