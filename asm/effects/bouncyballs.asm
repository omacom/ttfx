; effects/bouncyballs.asm - "Characters are bouncy balls falling from the top
; of the canvas" (src/effects/bouncyballs.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Bouncyballs):
;
; Every character gets, in Rust's order: two RNG choices (ball color, ball
; symbol), a one-frame ball scene, a final scene fading from the ball color
; to its final color, a drop row from rng.uniform, and a one-waypoint path
; back to its input coordinate whose completion activates the final scene.
;
; group_by_row (a BTreeMap over input rows, in input order within a row) is
; the input order read backwards by row runs: get_characters with
; TopToBottomLeftToRight is the input order, whose rows never increase.

struc BOUNCYBALLS
    .ball_colors:       resq 1          ; *const u64
    .ball_color_count:  resq 1
    .ball_symbols:      resq 1          ; *const u64 (packed symbols)
    .ball_symbol_count: resq 1
    .ball_delay:        resq 1
    .movement_speed:    resq 1          ; f64
    .movement_easing:   resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define BB_DYNAMIC          1           ; cfg_existing_colors: dynamic

; build loop locals
%define L_BALL              0           ; ball scene
%define L_FINAL             8           ; final scene
%define L_COLOR             16          ; ball color
%define L_FG                24          ; input fg (dynamic)
%define L_BG                32          ; input bg (dynamic)
%define L_FG_LEN            40
%define L_BG_LEN            48
%define L_LEN               56          ; final spectrum length
%define L_SIZE              72

section .text

; bouncyballs_build: BouncyBalls::build.
bouncyballs_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, L_SIZE
    call    bb_final_color_map
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    mov     [bb_order], rax
    mov     [bb_group_end], rdx
    lea     rdi, [rdx * 4 + 4]
    call    alloc
    mov     [bb_pending], rax
    mov     qword [bb_pending_count], 0
    mov     r15, [effect_config]
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .check_order
    mov     r14d, [r12 + rbx * 4]
    ; final color: final_gradient_mapping[input_coord]
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r14 * 4]
    sub     rax, [text_bottom]
    imul    rax, [bb_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r14 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [bb_final_map]
    mov     rax, [rcx + rax * 8]
    mov     [bb_pair + 8], rax
    ; color = choice(ball_colors), symbol = choice(ball_symbols)
    mov     rdi, [r15 + BOUNCYBALLS.ball_color_count]
    call    rng_below
    mov     rcx, [r15 + BOUNCYBALLS.ball_colors]
    mov     rax, [rcx + rax * 8]
    mov     [rsp + L_COLOR], rax
    mov     rdi, [r15 + BOUNCYBALLS.ball_symbol_count]
    call    rng_below
    mov     rcx, [r15 + BOUNCYBALLS.ball_symbols]
    mov     rbp, [rcx + rax * 8]
    ; ball scene: the symbol in the ball color for one frame
    mov     edi, r14d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + L_BALL], rax
    mov     edi, eax
    mov     rsi, rbp
    mov     edx, 1
    mov     rcx, [rsp + L_COLOR]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    ; final scene
    mov     edi, r14d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + L_FINAL], rax
    cmp     qword [cfg_existing_colors], BB_DYNAMIC
    je      .dynamic
    ; with_steps([color, final color], 10), the input symbol for 6 frames each
    mov     rax, [rsp + L_COLOR]
    mov     [bb_pair], rax
    lea     rdi, [bb_pair]
    mov     esi, 2
    lea     rdx, [bb_ten_steps]
    mov     ecx, 1
    lea     r8, [bb_fg_spectrum]
    call    gradient_new
    mov     [rsp + L_LEN], rax
    xor     ebp, ebp
.final_frame:
    cmp     rbp, [rsp + L_LEN]
    jae     .drop
    mov     edi, [rsp + L_FINAL]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r14 * 8]
    mov     edx, 6
    lea     rax, [bb_fg_spectrum]
    mov     rcx, [rax + rbp * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    jmp     .final_frame
.drop:
    ; drop row: int(canvas.top * uniform(1.0, 1.5))
    movsd   xmm0, [bb_one]
    movsd   xmm1, [bb_one_half]
    call    rng_uniform
    cvtsi2sd xmm1, qword [canvas_top]
    mulsd   xmm0, xmm1
    call    f64_to_i64
    mov     rsi, rax
    shl     rsi, 32
    mov     rax, [ch_icol]
    mov     eax, [rax + r14 * 4]
    or      rsi, rax
    mov     edi, r14d
    call    set_coordinate
    ; the path to the input coordinate
    mov     edi, r14d
    movsd   xmm0, [r15 + BOUNCYBALLS.movement_speed]
    mov     esi, [r15 + BOUNCYBALLS.movement_easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
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
    mov     edi, r14d
    mov     esi, ebp
    call    path_activate
    mov     edi, r14d
    mov     esi, [rsp + L_BALL]
    call    scene_activate
    ; PathComplete(path) -> ActivateScene(final)
    PATH_PTR rcx, rbp
    mov     ecx, [rcx + PA_NAME]
    mov     eax, [rsp + L_FINAL]
    SCENE_PTR r9, rax
    mov     r9d, [r9 + SC_NAME]
    push    0
    push    0
    mov     edi, r14d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     r8d, ACT_ACTIVATE_SCENE
    call    event_register
    add     rsp, 16
    inc     rbx
    jmp     .char
.dynamic:
    call    bb_final_dynamic
    jmp     .drop
.check_order:
    ; input rows never increase, so row runs read backwards are the groups
    mov     ebx, 1
.order:
    cmp     rbx, r13
    jae     .built
    mov     rcx, [ch_irow]
    mov     eax, [r12 + rbx * 4 - 4]
    mov     edx, [r12 + rbx * 4]
    mov     eax, [rcx + rax * 4]
    cmp     eax, [rcx + rdx * 4]
    jl      .unordered
    inc     rbx
    jmp     .order
.built:
    mov     qword [bb_delay], 0
    add     rsp, L_SIZE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.unordered:
    lea     rdi, [msg_bb_order]
    mov     esi, msg_bb_order_len
    jmp     fatal

; bb_final_dynamic(r14d=slot; the build's locals at [rsp+8]): the final
; scene under --existing-color-handling dynamic - gradients from the ball
; color to the input colors, or the input symbol with no colors.
bb_final_dynamic:
    mov     rax, [ch_fg]
    mov     rax, [rax + r14 * 8]
    mov     [rsp + 8 + L_FG], rax
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + r14 * 8]
    mov     [rsp + 8 + L_BG], rcx
    and     rax, rcx
    cmp     rax, NONE
    jne     .gradients
    mov     edi, [rsp + 8 + L_FINAL]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r14 * 8]
    mov     edx, 6
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    jmp     scene_add_frame
.gradients:
    xor     eax, eax
    mov     [rsp + 8 + L_FG_LEN], rax
    mov     [rsp + 8 + L_BG_LEN], rax
    cmp     qword [rsp + 8 + L_FG], NONE
    je      .bg
    mov     rax, [rsp + 8 + L_COLOR]
    mov     [bb_pair], rax
    mov     rax, [rsp + 8 + L_FG]
    mov     [bb_pair + 8], rax
    lea     rdi, [bb_pair]
    mov     esi, 2
    lea     rdx, [bb_ten_steps]
    mov     ecx, 1
    lea     r8, [bb_fg_spectrum]
    call    gradient_new
    mov     [rsp + 8 + L_FG_LEN], rax
.bg:
    cmp     qword [rsp + 8 + L_BG], NONE
    je      .apply
    mov     rax, [rsp + 8 + L_COLOR]
    mov     [bb_pair], rax
    mov     rax, [rsp + 8 + L_BG]
    mov     [bb_pair + 8], rax
    lea     rdi, [bb_pair]
    mov     esi, 2
    lea     rdx, [bb_ten_steps]
    mov     ecx, 1
    lea     r8, [bb_bg_spectrum]
    call    gradient_new
    mov     [rsp + 8 + L_BG_LEN], rax
.apply:
    mov     rax, [ch_sym]
    mov     rax, [rax + r14 * 8]
    mov     [bb_symbol], rax
    mov     edi, [rsp + 8 + L_FINAL]
    lea     rsi, [bb_symbol]
    mov     edx, 1
    mov     ecx, 6
    xor     r8d, r8d
    xor     r9d, r9d
    cmp     qword [rsp + 8 + L_FG], NONE
    je      .no_fg
    lea     r8, [bb_fg_spectrum]
    mov     r9, [rsp + 8 + L_FG_LEN]
.no_fg:
    xor     eax, eax
    xor     r10d, r10d
    cmp     qword [rsp + 8 + L_BG], NONE
    je      .no_bg
    lea     rax, [bb_bg_spectrum]
    mov     r10, [rsp + 8 + L_BG_LEN]
.no_bg:
    push    r10
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
    ret

; bb_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
bb_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + BOUNCYBALLS.final_steps]
    mov     rcx, [rbx + BOUNCYBALLS.final_step_count]
    mov     rsi, [rbx + BOUNCYBALLS.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [bb_final_spectrum], rax
    mov     rdi, [rbx + BOUNCYBALLS.final_stops]
    mov     rsi, [rbx + BOUNCYBALLS.final_stop_count]
    mov     rdx, [rbx + BOUNCYBALLS.final_steps]
    mov     rcx, [rbx + BOUNCYBALLS.final_step_count]
    mov     r8, [bb_final_spectrum]
    call    gradient_new
    mov     rdi, [bb_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [bb_final_map_width], rax
    push    qword [rbx + BOUNCYBALLS.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [bb_final_map], rax
    pop     rbx
    ret

; bouncyballs_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
bouncyballs_next_frame:
    push    rbx
    push    r12
    push    r13
    cmp     qword [bb_pending_count], 0
    jne     .drop
    cmp     qword [bb_group_end], 0
    jne     .next_group
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .update
.next_group:
    ; pending = group_by_row.remove(min row): the last row run of the order
    mov     rdx, [bb_order]
    mov     rcx, [ch_irow]
    mov     rbx, [bb_group_end]
    mov     eax, [rdx + rbx * 4 - 4]
    mov     r8d, [rcx + rax * 4]        ; the group's row
    lea     r12, [rbx - 1]
.run:
    test    r12, r12
    jz      .take
    mov     eax, [rdx + r12 * 4 - 4]
    cmp     [rcx + rax * 4], r8d
    jne     .take
    dec     r12
    jmp     .run
.take:
    mov     [bb_group_end], r12
    lea     rsi, [rdx + r12 * 4]
    mov     rdi, [bb_pending]
    mov     rcx, rbx
    sub     rcx, r12
    mov     [bb_pending_count], rcx
    rep     movsd
.drop:
    cmp     qword [bb_delay], 0
    je      .release
    dec     qword [bb_delay]
    jmp     .update
.release:
    mov     edi, 2
    mov     esi, 6
    call    rng_randint
    mov     r13, rax
.ball:
    test    r13, r13
    jz      .released
    dec     r13
    mov     rsi, [bb_pending_count]
    test    rsi, rsi
    jz      .released
    xor     edi, edi
    dec     rsi
    call    rng_randint
    ; pending.remove(index)
    mov     rdi, [bb_pending]
    lea     rdi, [rdi + rax * 4]
    mov     r12d, [rdi]
    lea     rsi, [rdi + 4]
    mov     rcx, [bb_pending_count]
    dec     rcx
    mov     [bb_pending_count], rcx
    sub     rcx, rax
    rep     movsd
    mov     edi, r12d
    call    set_visible
    mov     edi, r12d
    call    active_insert
    jmp     .ball
.released:
    mov     rax, [effect_config]
    mov     rax, [rax + BOUNCYBALLS.ball_delay]
    mov     [bb_delay], rax
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
bb_one:             dq 1.0
bb_one_half:        dq 1.5
bb_ten_steps:       dq 10
STR msg_bb_order, "ttfx: asm engine: bouncyballs input rows out of order", 10

section .tstate
alignb 8
bb_order:           resq 1          ; u32 slots, input order
bb_group_end:       resq 1          ; groups left: bb_order[..end]
bb_pending:         resq 1          ; u32 slots
bb_pending_count:   resq 1
bb_delay:           resq 1
bb_final_spectrum:  resq 1
bb_final_map:       resq 1
bb_final_map_width: resq 1
bb_symbol:          resq 1
bb_pair:            resq 2
bb_fg_spectrum:     resq 16
bb_bg_spectrum:     resq 16
