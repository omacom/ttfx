; effects/laseretch.asm - "A laser etches characters onto the terminal"
; (src/effects/laseretch.rs).
;
; build() makes every character's spawn scene, then (for the "algorithm"
; pattern) runs RecursiveBacktracker from a random text coordinate; its link
; order is the etch order. A character-group pattern etches nothing (the
; upstream dead branch Rust reproduces). The laser follows: the spark pool
; (2000 particles, each reclaimed when its spark scene completes; particles
; the pool creates later never are, as in Rust) and one beam character per
; canvas row up the diagonal from (0, 0).

struc LASERETCH
    .group_pattern:     resq 1          ; 1 = a CharacterGroup, 0 = algorithm
    .etch_speed:        resq 1
    .etch_delay:        resq 1
    .cool_stops:        resq 1          ; *const u64
    .cool_stop_count:   resq 1
    .laser_stops:       resq 1
    .laser_stop_count:  resq 1
    .spark_stops:       resq 1
    .spark_stop_count:  resq 1
    .spark_cooling:     resq 1
    .final_stops:       resq 1
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define LE_SPAWN            NAME_LITERAL + 0
%define LE_SPARK            NAME_LITERAL + 1
%define LE_LASER            NAME_LITERAL + 2

%define LE_OUT_SINE         2
%define LE_COOL_MAX         64          ; cool/cooldown spectrum entries

section .text

; laseretch_build: LaserEtchIterator.build + __init__'s tail.
laseretch_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    le_final_map
    ; cool gradient stops: the cool stops, then the mapped color
    mov     rax, [rbx + LASERETCH.cool_stop_count]
    inc     rax
    mov     [le_cool_stop_count], rax
    lea     rdi, [rax * 8]
    call    alloc
    mov     [le_cool_stops], rax
    mov     rdi, rax
    mov     rsi, [rbx + LASERETCH.cool_stops]
    mov     rcx, [rbx + LASERETCH.cool_stop_count]
    rep     movsq
    lea     rdi, [le_eight]
    mov     ecx, 1
    mov     rsi, [le_cool_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [le_cool], rax
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r14, rax
    mov     r15, rdx
    xor     r13d, r13d
.character:
    cmp     r13, r15
    jae     .etch_order
    mov     edi, [r14 + r13 * 4]
    call    le_character
    inc     r13
    jmp     .character
.etch_order:
    cmp     qword [rbx + LASERETCH.group_pattern], 0
    jne     .laser
    mov     edi, 1
    call    rb_new
    call    rb_run
    mov     [le_pending], rax
    mov     [le_pending_count], rdx
.laser:
    mov     qword [le_pending_head], 0
    mov     qword [le_delay], 0
    call    le_make_laser
    xor     r12d, r12d
.beam:
    cmp     r12, [le_beam_count]
    jae     .built
    mov     rax, [le_beam]
    mov     edi, [rax + r12 * 4]
    call    active_insert
    inc     r12
    jmp     .beam
.built:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; le_character(edi=slot): the spawn scene ("^", the cool gradient, and the
; dynamic tail), activated.
le_character:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     rbp, [effect_config]
    ; final colors: r12 fg, r13 bg
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     r12, [rax + rbx * 8]
    mov     rax, [ch_bg]
    mov     r13, [rax + rbx * 8]
    ; cool = Gradient(cool stops, steps=8)
    mov     rdi, [rbp + LASERETCH.cool_stops]
    mov     rsi, [rbp + LASERETCH.cool_stop_count]
    jmp     .cool
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbx * 4]
    sub     rax, [text_bottom]
    imul    rax, [le_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbx * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [le_map]
    mov     r12, [rcx + rax * 8]
    mov     r13, NONE
    mov     rdi, [le_cool_stops]
    mov     rsi, [le_cool_stop_count]
    mov     [rdi + rsi * 8 - 8], r12
.cool:
    lea     rdx, [le_eight]
    mov     ecx, 1
    mov     r8, [le_cool]
    call    gradient_new
    mov     r14d, eax                   ; cool length
    mov     edi, ebx
    mov     esi, LE_SPAWN
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     edi, r15d
    mov     rsi, (1 << 32) | '^'
    mov     edx, 3
    mov     ecx, 0xffe680
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    xor     ebp, ebp
.cool_frame:
    cmp     ebp, r14d
    jae     .tail
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 3
    mov     rcx, [le_cool]
    mov     rcx, [rcx + rbp * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    jmp     .cool_frame
.tail:
    cmp     qword [cfg_existing_colors], 1
    jne     .activate
    mov     rax, [le_cool]
    mov     rax, [rax + r14 * 8 - 8]
    mov     [le_pair_stops], rax        ; the cool gradient's last color
    mov     rax, r12
    and     rax, r13
    cmp     rax, NONE
    je      .white
    ; fg / bg gradients from the cool end to the input colors
    xor     r14d, r14d                  ; fg length
    xor     ebp, ebp                    ; bg length
    cmp     r12, NONE
    je      .tail_bg
    mov     [le_pair_stops + 8], r12
    lea     rdi, [le_pair_stops]
    mov     esi, 2
    lea     rdx, [le_eight]
    mov     ecx, 1
    lea     r8, [le_fg_spectrum]
    call    gradient_new
    mov     r14d, eax
.tail_bg:
    cmp     r13, NONE
    je      .tail_apply
    mov     [le_pair_stops + 8], r13
    lea     rdi, [le_pair_stops]
    mov     esi, 2
    lea     rdx, [le_eight]
    mov     ecx, 1
    lea     r8, [le_bg_spectrum]
    call    gradient_new
    mov     ebp, eax
.tail_apply:
    xor     r8d, r8d
    test    r14d, r14d
    jz      .no_fg
    lea     r8, [le_fg_spectrum]
.no_fg:
    xor     eax, eax
    test    ebp, ebp
    jz      .no_bg
    lea     rax, [le_bg_spectrum]
.no_bg:
    push    rbp
    push    rax
    mov     edi, r15d
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rbx * 8]
    mov     edx, 1
    mov     ecx, 3
    mov     r9d, r14d
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.white:
    ; no input colors: cool end -> white, then a colorless frame
    mov     qword [le_pair_stops + 8], 0xffffff
    lea     rdi, [le_pair_stops]
    mov     esi, 2
    lea     rdx, [le_eight]
    mov     ecx, 1
    lea     r8, [le_fg_spectrum]
    call    gradient_new
    push    0
    push    0
    mov     edi, r15d
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rbx * 8]
    mov     edx, 1
    mov     ecx, 3
    lea     r8, [le_fg_spectrum]
    mov     r9d, eax
    call    scene_apply_gradient
    add     rsp, 16
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.activate:
    mov     edi, ebx
    mov     esi, r15d
    call    scene_activate
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; le_final_map: Gradient::new(final stops, final steps) mapped over the text
; rectangle.
le_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + LASERETCH.final_steps]
    mov     rcx, [rbx + LASERETCH.final_step_count]
    mov     rsi, [rbx + LASERETCH.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [le_final_spectrum], rax
    mov     rdi, [rbx + LASERETCH.final_stops]
    mov     rsi, [rbx + LASERETCH.final_stop_count]
    mov     rdx, [rbx + LASERETCH.final_steps]
    mov     rcx, [rbx + LASERETCH.final_step_count]
    mov     r8, [le_final_spectrum]
    call    gradient_new
    mov     rdi, [le_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [le_map_width], rax
    push    qword [rbx + LASERETCH.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [le_map], rax
    pop     rbx
    ret

; ------------------------------------------------------------ the laser

; le_make_laser: Laser.__init__ + _make_sparks_pool.
le_make_laser:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    ; the looped laser gradient: the stops plus the first again, 6 steps
    mov     rax, [rbx + LASERETCH.laser_stop_count]
    lea     rdi, [rax * 8 + 8]
    call    alloc
    mov     r12, rax
    mov     rdi, rax
    mov     rsi, [rbx + LASERETCH.laser_stops]
    mov     rcx, [rbx + LASERETCH.laser_stop_count]
    rep     movsq
    mov     rax, [rbx + LASERETCH.laser_stops]
    mov     rax, [rax]
    mov     [rdi], rax
    mov     r13, [rbx + LASERETCH.laser_stop_count]
    cmp     r13, 1
    je      .one_stop                   ; a single stop is not looped
    inc     r13
.one_stop:
    lea     rdi, [le_six]
    mov     ecx, 1
    mov     rsi, r13
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [le_laser], rax
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [le_six]
    mov     ecx, 1
    mov     r8, [le_laser]
    call    gradient_new
    mov     [le_laser_len], rax
    ; the spark gradient, steps (3, 8)
    lea     rdi, [le_three_eight]
    mov     ecx, 2
    mov     rsi, [rbx + LASERETCH.spark_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [le_spark], rax
    mov     rdi, [rbx + LASERETCH.spark_stops]
    mov     rsi, [rbx + LASERETCH.spark_stop_count]
    lea     rdx, [le_three_eight]
    mov     ecx, 2
    mov     r8, [le_spark]
    call    gradient_new
    mov     [le_spark_len], rax
    ; the spark pool: unbounded, 2000 preallocated, reclaimed on "spark"
    lea     rax, [le_spark_symbols]
    mov     rcx, (1 << 32) | '.'
    mov     [rax], rcx
    mov     rcx, (1 << 32) | ','
    mov     [rax + 8], rcx
    mov     rcx, (1 << 32) | '*'
    mov     [rax + 16], rcx
    lea     rdi, [le_pool]
    lea     rsi, [le_spark_symbols]
    mov     edx, 3
    mov     rcx, -1
    xor     r8d, r8d
    call    pool_init
    lea     rax, [le_init_spark]
    mov     [le_pool + POOL.initializer], rax
    lea     rdi, [le_pool]
    mov     esi, 2000
    call    pool_preallocate
    xor     r12d, r12d
.reclaim:
    cmp     r12, [le_pool + POOL.particle_count]
    jae     .beam
    push    0
    push    0
    mov     rax, [le_pool + POOL.particles]
    mov     edi, [rax + r12 * 4]
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, LE_SPARK
    mov     r8d, ACT_CALLBACK
    lea     r9, [le_reclaim]
    call    event_register
    add     rsp, 16
    inc     r12
    jmp     .reclaim
.beam:
    ; one beam character per row 0..=canvas.top up the diagonal
    mov     rdi, [canvas_top]
    lea     rdi, [rdi * 4 + 68]
    call    alloc
    mov     [le_beam], rax
    xor     r12d, r12d                  ; row = column
.beam_char:
    cmp     r12, [canvas_top]
    jg      .done
    mov     rdi, (1 << 32) | '/'
    mov     rax, (1 << 32) | '*'
    test    r12, r12
    cmovz   rdi, rax
    mov     rsi, r12
    shl     rsi, 32
    mov     eax, r12d
    or      rsi, rax
    call    add_character
    mov     ebx, eax
    mov     rcx, [le_beam]
    mov     [rcx + r12 * 4], eax
    inc     qword [le_beam_count]
    mov     edi, ebx
    mov     esi, 2
    call    set_layer
    mov     edi, ebx
    call    set_visible
    ; the looping laser scene, its gradient rotated left once per character
    mov     edi, ebx
    mov     esi, LE_LASER
    mov     edx, SCF_LOOPING
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    xor     r14d, r14d
.laser_frame:
    cmp     r14, [le_laser_len]
    jae     .laser_done
    lea     rax, [r12 + r14]
    xor     edx, edx
    div     qword [le_laser_len]
    mov     rcx, [le_laser]
    mov     rcx, [rcx + rdx * 8]
    mov     edi, r13d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 3
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14
    jmp     .laser_frame
.laser_done:
    mov     edi, ebx
    mov     esi, r13d
    call    scene_activate
    inc     r12
    jmp     .beam_char
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; le_init_spark(edi=slot): initialize_spark - layer 2 and the "spark"
; cooling scene.
le_init_spark:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     esi, 2
    call    set_layer
    mov     edi, ebx
    mov     esi, LE_SPARK
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax
    xor     r13d, r13d
.frame:
    cmp     r13, [le_spark_len]
    jae     .done
    mov     edi, r12d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     rdx, [effect_config]
    mov     rdx, [rdx + LASERETCH.spark_cooling]
    mov     rcx, [le_spark]
    mov     rcx, [rcx + r13 * 8]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r13
    jmp     .frame
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; le_reclaim(edi=spark): sparks_pool.reclaim(spark, hide=True,
; deactivate=True).
le_reclaim:
    mov     esi, edi
    lea     rdi, [le_pool]
    mov     edx, 1
    mov     ecx, 1
    jmp     pool_reclaim

; le_reposition(rdi=target coord): Laser.reposition - the beam up the
; diagonal from the target, then one spark.
le_reposition:
    push    rbx
    push    r12
    push    r13
    mov     [le_position], rdi
    mov     r12, rdi
    xor     ebx, ebx
.move:
    cmp     rbx, [le_beam_count]
    jae     .spark
    mov     rax, [le_beam]
    mov     edi, [rax + rbx * 4]
    mov     rsi, r12
    call    set_coordinate
    mov     rax, (1 << 32) | 1
    add     r12, rax                    ; row + 1, column + 1 (the column
    inc     rbx                         ; is positive: no carry)
    jmp     .move
.spark:
    ; emit_sparks(1)
    lea     rdi, [le_pool]
    mov     rsi, [le_position]
    xor     edx, edx
    mov     ecx, 1
    lea     r8, [le_setup_spark]
    xor     r9d, r9d
    call    pool_emit
    pop     r13
    pop     r12
    pop     rbx
    ret

; le_setup_spark(edi=spark): setup_spark_path - an out_sine bezier fall to
; the canvas bottom from the laser position, and the spark scene.
le_setup_spark:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     rsi, [le_position]
    call    set_coordinate
    movsd   xmm0, [le_spark_speed]
    mov     edi, ebx
    mov     esi, LE_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r13d, eax
    movsxd  rdi, dword [le_position]
    lea     rsi, [rdi + 20]
    sub     rdi, 20
    call    rng_randint
    mov     r12d, eax                   ; fall column
    mov     rdi, -10
    mov     esi, 20
    call    rng_randint
    mov     rcx, [le_position]
    sar     rcx, 32
    add     rax, rcx
    shl     rax, 32
    or      rax, r12
    mov     [rsp], rax                  ; control (fall column, row + offset)
    mov     rsi, 1 << 32                ; canvas.bottom
    or      rsi, r12
    mov     edi, r13d
    lea     rdx, [rsp]
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebx
    mov     esi, r13d
    call    path_activate
    mov     edi, ebx
    mov     esi, LE_SPARK
    call    scene_activate_name
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

; le_pop -> eax = the next pending character, or ZF set when none.
le_pop:
    mov     rax, [le_pending_head]
    cmp     rax, [le_pending_count]
    jae     .none
    inc     qword [le_pending_head]
    mov     rcx, [le_pending]
    mov     eax, [rcx + rax * 4]
    or      ecx, 1                      ; ZF clear
    ret
.none:
    xor     ecx, ecx                    ; ZF set
    ret

; laseretch_next_frame -> eax = 1 for a frame, 0 when done.
laseretch_next_frame:
    push    rbx
    push    r12
    push    r13
    mov     rax, [le_pending_head]
    cmp     rax, [le_pending_count]
    jb      .frame
    call    active_empty
    test    eax, eax
    jnz     .finished
.frame:
    cmp     qword [le_delay], 0
    jne     .wait
    mov     rax, [effect_config]
    mov     r12, [rax + LASERETCH.etch_speed]
.etch:
    test    r12, r12
    jz      .etched
    dec     r12
    call    le_pop
    jz      .etched
    mov     ebx, eax
.skip_blank:
    ; spaces without input colors are passed over
    mov     rax, [ch_sym]
    mov     rcx, (1 << 32) | ' '
    cmp     [rax + rbx * 8], rcx
    jne     .etch_char
    mov     rax, [ch_fg]
    cmp     qword [rax + rbx * 8], NONE
    jne     .etch_char
    mov     rax, [ch_bg]
    cmp     qword [rax + rbx * 8], NONE
    jne     .etch_char
    call    le_pop
    jz      .etch_char
    mov     ebx, eax
    jmp     .skip_blank
.etch_char:
    mov     edi, ebx
    call    set_visible
    mov     edi, ebx
    call    active_insert
    mov     edi, ebx
    call    char_input_coord
    mov     rdi, rax
    call    le_reposition
    jmp     .etch
.etched:
    mov     rax, [effect_config]
    mov     rax, [rax + LASERETCH.etch_delay]
    mov     [le_delay], rax
    jmp     .beam
.wait:
    dec     qword [le_delay]
.beam:
    xor     ebx, ebx
    mov     rax, [le_pending_head]
    cmp     rax, [le_pending_count]
    jae     .disable
.keep:
    cmp     rbx, [le_beam_count]
    jae     .tick
    mov     rax, [le_beam]
    mov     edi, [rax + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .keep
.disable:
    cmp     rbx, [le_beam_count]
    jae     .tick
    mov     rax, [le_beam]
    mov     edi, [rax + rbx * 4]
    xor     esi, esi
    call    set_visibility
    inc     rbx
    jmp     .disable
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
le_spark_speed:     dq 0.3
le_six:             dq 6
le_eight:           dq 8
le_three_eight:     dq 3, 8

section .tstate
alignb 8
le_pool:            resb POOL_size
alignb 8
le_spark_symbols:   resq 3
le_pair_stops:      resq 2
le_fg_spectrum:     resq 16
le_bg_spectrum:     resq 16
le_cool_stops:      resq 1
le_cool_stop_count: resq 1
le_cool:            resq 1
le_final_spectrum:  resq 1
le_map:             resq 1
le_map_width:       resq 1
le_laser:           resq 1
le_laser_len:       resq 1
le_spark:           resq 1
le_spark_len:       resq 1
le_beam:            resq 1
le_beam_count:      resq 1
le_pending:         resq 1
le_pending_count:   resq 1
le_pending_head:    resq 1
le_delay:           resq 1
le_position:        resq 1
