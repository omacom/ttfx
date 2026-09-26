; effects/pour.asm - "Pours the characters back and forth from the top,
; bottom, left, or right" (src/effects/pour.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Pour).
;
; Characters are built group by group in Rust's order, so the speed draws
; and the auto-numbered path and scene names line up. pending_groups is the
; group array walked by index: odd groups pour from their far end.

struc POUR
    .direction:         resq 1          ; PourDirection: up, down, left, right
    .speed:             resq 1          ; characters per pour
    .move_min:          resq 1          ; f64
    .move_max:          resq 1          ; f64
    .gap:               resq 1
    .starting_color:    resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_frames:      resq 1          ; fits i32 (marshal checks)
    .final_direction:   resq 1
    .easing:            resq 1          ; easing id
endstruc

%define POUR_UP             0
%define POUR_DOWN           1
%define POUR_LEFT           2
%define POUR_RIGHT          3

section .text

; pour_build: Pour::build.
pour_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    pour_final_map
    ; the per-character pour gradient: starting color -> the final color
    mov     rdi, [rbx + POUR.final_steps]
    mov     rcx, [rbx + POUR.final_step_count]
    mov     esi, 2
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [pour_pair_spectrum], rax
    mov     rax, [rbx + POUR.starting_color]
    mov     [pour_pair_stops], rax
    mov     qword [pour_last_fg], NONE
    ; groups: down pours rows bottom to top, up top to bottom, left
    ; columns left to right, right right to left
    mov     rax, [rbx + POUR.direction]
    lea     rcx, [pour_groupings]
    movzx   esi, byte [rcx + rax]
    mov     edi, FILTER_INPUT
    call    get_characters_grouped
    mov     [pour_groups], rax
    mov     [pour_group_count], rdx
    xor     r12d, r12d                  ; group index
.group:
    cmp     r12, [pour_group_count]
    jae     .grouped
    mov     r13, r12
    shl     r13, 4
    add     r13, [pour_groups]
    mov     r14, [r13 + 8]              ; count
    mov     r13, [r13]                  ; slots
.char:
    test    r14, r14
    jz      .next_group
    mov     edi, [r13]
    call    pour_character
    add     r13, 4
    dec     r14
    jmp     .char
.next_group:
    inc     r12
    jmp     .group
.grouped:
    ; current_group = pending_groups.remove(0)
    mov     qword [pour_next_group], 0
    mov     qword [pour_left], 0
    call    pour_take_group
    mov     qword [pour_gap_left], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; pour_character(edi=slot), rbx = config: hide it, move it to its pour
; start, give it a path to its input coordinate and its color scene.
pour_character:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebp, edi
    xor     esi, esi
    call    set_visibility
    mov     edi, ebp
    call    char_input_coord
    mov     r12, rax                    ; input coordinate
    mov     rcx, [rbx + POUR.direction]
    cmp     ecx, POUR_DOWN
    je      .down
    cmp     ecx, POUR_UP
    je      .up
    ; left / right keep the row and start at the right / left edge
    mov     rsi, rax
    shr     rsi, 32
    shl     rsi, 32
    mov     eax, 1                      ; canvas.left
    cmp     ecx, POUR_RIGHT
    je      .row_start
    mov     eax, [canvas_right]
.row_start:
    or      rsi, rax
    jmp     .start
.down:
    mov     rsi, [canvas_top]
    jmp     .column_start
.up:
    mov     esi, 1                      ; canvas.bottom
.column_start:
    shl     rsi, 32
    mov     eax, r12d
    or      rsi, rax
.start:
    mov     edi, ebp
    call    set_coordinate
    movsd   xmm0, [rbx + POUR.move_min]
    movsd   xmm1, [rbx + POUR.move_max]
    call    rng_uniform
    mov     edi, ebp
    mov     esi, [rbx + POUR.easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    mov     edi, eax
    mov     rsi, r12
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebp
    mov     esi, r13d
    call    path_activate
    mov     edi, ebp
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax                   ; scene
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; final fg from the coordinate map
    mov     rax, r12
    sar     rax, 32
    sub     rax, [text_bottom]
    imul    rax, [pour_map_width]
    movsxd  rcx, r12d
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [pour_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [pour_last_fg]
    je      .gradient
    mov     [pour_last_fg], rax
    mov     [pour_pair_stops + 8], rax
    lea     rdi, [pour_pair_stops]
    mov     esi, 2
    mov     rdx, [rbx + POUR.final_steps]
    mov     rcx, [rbx + POUR.final_step_count]
    mov     r8, [pour_pair_spectrum]
    call    gradient_new
    mov     [pour_pair_len], eax
.gradient:
    ; apply_gradient_to_symbols with one symbol and an fg gradient: one
    ; frame per spectrum color
    xor     r14d, r14d
    mov     rax, [ch_sym]
    mov     r15, [rax + rbp * 8]
.color:
    cmp     r14d, [pour_pair_len]
    jae     .activate
    mov     rcx, [pour_pair_spectrum]
    mov     rcx, [rcx + r14 * 8]
    mov     r8, NONE
    mov     rsi, r15
    mov     edi, r13d
    mov     edx, [rbx + POUR.final_frames]
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14d
    jmp     .color
.dynamic:
    ; with_steps([starting color, input fg/bg], 10) for each present color
    mov     rax, [ch_sym]
    mov     rax, [rax + rbp * 8]
    mov     [pour_symbol], rax
    mov     rax, [ch_fg]
    mov     rdi, [rax + rbp * 8]
    lea     rsi, [pour_fg_spectrum]
    call    pour_dynamic_gradient
    mov     r14, rax                    ; fg spectrum or 0
    mov     r15, rdx                    ; fg count
    mov     rax, [ch_bg]
    mov     rdi, [rax + rbp * 8]
    lea     rsi, [pour_bg_spectrum]
    call    pour_dynamic_gradient
    mov     rcx, r14
    or      rcx, rax
    jz      .plain
    push    rdx
    push    rax
    mov     edi, r13d
    lea     rsi, [pour_symbol]
    mov     edx, 1
    mov     ecx, [rbx + POUR.final_frames]
    mov     r8, r14
    mov     r9, r15
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.plain:
    mov     edi, r13d
    mov     rsi, [pour_symbol]
    mov     edx, [rbx + POUR.final_frames]
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.activate:
    mov     edi, ebp
    mov     esi, r13d
    call    scene_activate
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; pour_dynamic_gradient(rdi=color or NONE, rsi=spectrum out) -> rax =
; spectrum or 0, rdx = its length: Gradient::with_steps([starting color,
; color], 10) when the color is present. rbx = config.
pour_dynamic_gradient:
    xor     eax, eax
    xor     edx, edx
    cmp     rdi, NONE
    je      .absent
    push    rsi
    mov     rax, [rbx + POUR.starting_color]
    mov     [pour_pair_stops], rax
    mov     [pour_pair_stops + 8], rdi
    lea     rdi, [pour_pair_stops]
    mov     r8, rsi
    mov     esi, 2
    lea     rdx, [pour_ten_steps]
    mov     ecx, 1
    call    gradient_new
    mov     edx, eax
    pop     rax
.absent:
    ret

; pour_final_map (rbx = config): Gradient::new(final stops, final steps) and
; its coordinate mapping over the text rectangle.
pour_final_map:
    mov     rdi, [rbx + POUR.final_steps]
    mov     rcx, [rbx + POUR.final_step_count]
    mov     rsi, [rbx + POUR.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [pour_spectrum], rax
    mov     rdi, [rbx + POUR.final_stops]
    mov     rsi, [rbx + POUR.final_stop_count]
    mov     rdx, [rbx + POUR.final_steps]
    mov     rcx, [rbx + POUR.final_step_count]
    mov     r8, [pour_spectrum]
    call    gradient_new
    mov     rdi, [pour_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [pour_map_width], rax
    sub     rsp, 8
    push    qword [rbx + POUR.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     [pour_map], rax
    ret

; pour_take_group: current_group = pending_groups.remove(0), when a pending
; group is left. Even groups pour in order, odd ones reversed. Clobbers rax,
; rcx, rdx.
pour_take_group:
    mov     rax, [pour_next_group]
    cmp     rax, [pour_group_count]
    jae     .none
    inc     qword [pour_next_group]
    mov     rcx, rax
    shl     rcx, 4
    add     rcx, [pour_groups]
    mov     rdx, [rcx + 8]
    mov     [pour_left], rdx
    mov     rcx, [rcx]
    mov     qword [pour_stride], 4
    test    eax, 1
    jz      .set
    lea     rcx, [rcx + rdx * 4 - 4]
    mov     qword [pour_stride], -4
.set:
    mov     [pour_cursor], rcx
.none:
    ret

; pour_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
pour_next_frame:
    push    rbx
    push    r12
    push    r13
    mov     rax, [pour_next_group]
    cmp     rax, [pour_group_count]
    jb      .run
    cmp     qword [pour_left], 0
    jne     .run
    call    active_empty
    test    eax, eax
    jnz     .finished
.run:
    cmp     qword [pour_left], 0
    jne     .pour
    call    pour_take_group
    cmp     qword [pour_left], 0
    je      .update
.pour:
    mov     rax, [pour_gap_left]
    test    rax, rax
    jz      .release
    dec     rax
    mov     [pour_gap_left], rax
    jmp     .update
.release:
    ; pour_speed characters (fewer when the group runs out)
    mov     rbx, [effect_config]
    mov     r12, [rbx + POUR.speed]
.next:
    test    r12, r12
    jle     .released
    cmp     qword [pour_left], 0
    je      .released
    dec     r12
    dec     qword [pour_left]
    mov     rax, [pour_cursor]
    mov     r13d, [rax]
    add     rax, [pour_stride]
    mov     [pour_cursor], rax
    mov     edi, r13d
    call    set_visible
    mov     edi, r13d
    call    active_insert
    jmp     .next
.released:
    mov     rax, [rbx + POUR.gap]
    mov     [pour_gap_left], rax
.update:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
pour_ten_steps: dq 10
; CharacterGroup per PourDirection
pour_groupings: db GROUP_ROW_TOP_TO_BOTTOM, GROUP_ROW_BOTTOM_TO_TOP, GROUP_COLUMN_L2R, GROUP_COLUMN_R2L

section .tstate
alignb 8
pour_groups:            resq 1
pour_group_count:       resq 1
pour_next_group:        resq 1
pour_cursor:            resq 1
pour_stride:            resq 1
pour_left:              resq 1
pour_gap_left:          resq 1
pour_spectrum:          resq 1
pour_map:               resq 1
pour_map_width:         resq 1
pour_pair_stops:        resq 2
pour_pair_spectrum:     resq 1
pour_pair_len:          resq 1
pour_last_fg:           resq 1
pour_symbol:            resq 1
pour_fg_spectrum:       resq 16
pour_bg_spectrum:       resq 16
