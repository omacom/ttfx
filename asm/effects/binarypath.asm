; effects/binarypath.asm - src/effects/binarypath.rs.
struc BINARYPATH
    .stops: resq 1
    .stop_count: resq 1
    .steps: resq 1
    .step_count: resq 1
    .direction: resq 1
    .colors: resq 1
    .color_count: resq 1
    .speed: resq 1
    .active: resq 1
endstruc

; Bits are contiguous arena slots. Pending and active vectors contain pointers
; to these records; removals preserve Rust's Vec order.
struc BP_REP
    .source: resd 1
    .first: resd 1
    .count: resd 1
    .emitted: resd 1
    .coord: resq 1
endstruc
%define BP_COLLAPSE (NAME_LITERAL + 0)
%define BP_BRIGHTEN (NAME_LITERAL + 1)

section .text
; BinaryPath::build. Clobbers C.
binarypath_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_DIAG_TR_TO_BL
    call    get_characters_grouped
    mov     [bp_groups], rax
    mov     [bp_group_count], rdx
    call    bp_color_map
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [bp_chars], rax
    mov     [bp_count], rdx
    mov     [bp_pending_count], rdx
    imul    rdi, rdx, BP_REP_size
    call    alloc
    mov     [bp_reps], rax
    mov     rdi, [bp_count]
    shl     rdi, 3
    call    alloc
    mov     [bp_pending], rax
    mov     rdi, [bp_count]
    shl     rdi, 3
    call    alloc
    mov     [bp_active], rax
    mov     rdi, [canvas_right]
    add     rdi, [canvas_top]
    add     rdi, 5
    shl     rdi, 3
    call    alloc
    mov     [bp_coords], rax
    xor     ebx, ebx
.add_rep:
    cmp     rbx, [bp_count]
    jae     .paths
    imul    rbp, rbx, BP_REP_size
    add     rbp, [bp_reps]
    mov     rax, [bp_pending]
    mov     [rax + rbx*8], rbp
    mov     rax, [bp_chars]
    mov     edi, [rax + rbx*4]
    mov     [rbp + BP_REP.source], edi
    call    char_input_coord
    mov     [rbp + BP_REP.coord], rax
    mov     edi, [rbp + BP_REP.source]
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rdi*8]
    call    utf8_decode
    mov     r12d, eax
    or      eax, 0x80                    ; minimum width 8, including U+0000
    bsr     r13d, eax
    lea     eax, [r13 + 1]
    mov     [rbp + BP_REP.count], eax
.bits:
    mov     ecx, r13d
    mov     edi, r12d
    shr     edi, cl
    and     edi, 1
    add     edi, '0'
    bts     rdi, 32
    xor     esi, esi
    call    add_character
    mov     ecx, [rbp + BP_REP.count]
    dec     ecx
    cmp     ecx, r13d
    jne     .next_bit
    mov     [rbp + BP_REP.first], eax
.next_bit:
    dec     r13d
    jns     .bits
    inc     rbx
    jmp     .add_rep
.paths:
    xor     ebx, ebx
.rep_path:
    cmp     rbx, [bp_count]
    jae     .scenes
    imul    rbp, rbx, BP_REP_size
    add     rbp, [bp_reps]
    call    bp_make_coords
    xor     r12d, r12d
.bit_path:
    cmp     r12d, [rbp + BP_REP.count]
    jae     .next_rep
    mov     r13d, [rbp + BP_REP.first]
    add     r13d, r12d
    mov     edi, r13d
    mov     rax, [bp_coords]
    mov     rsi, [rax]
    call    set_coordinate
    mov     edi, r13d
    mov     rax, [effect_config]
    movsd   xmm0, [rax + BINARYPATH.speed]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r14d, eax
    xor     r15d, r15d
.waypoint:
    mov     rax, [bp_coords]
    mov     rsi, [rax + r15*8]
    mov     edi, r14d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    inc     r15
    cmp     r15, [bp_coord_count]
    jb      .waypoint
    mov     edi, r13d
    mov     esi, r14d
    call    path_activate
    mov     edi, r13d
    mov     esi, 1
    call    set_layer
    mov     rax, [effect_config]
    mov     rdi, [rax + BINARYPATH.color_count]
    call    rng_below
    mov     rcx, [effect_config]
    mov     rcx, [rcx + BINARYPATH.colors]
    mov     r15, [rcx + rax*8]
    mov     edi, r13d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    mov     edi, eax
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r13*8]
    mov     edx, 1
    mov     rcx, r15
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r13d
    mov     esi, r14d
    call    scene_activate
    inc     r12d
    jmp     .bit_path
.next_rep:
    inc     rbx
    jmp     .rep_path
.scenes:
    xor     ebx, ebx
.scene:
    cmp     rbx, [bp_count]
    jae     .done
    mov     rax, [bp_chars]
    mov     edi, [rax + rbx*4]
    call    bp_make_scenes
    inc     rbx
    jmp     .scene
.done:
    cvtsi2sd xmm0, qword [bp_count]
    mov     rax, [effect_config]
    mulsd   xmm0, [rax + BINARYPATH.active]
    call    f64_to_i64
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [bp_max_active], rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; The alternating row/column walk in BinaryPath::build, including the two
; duplicate terminal waypoints. rbp = representation; preserves callee saves.
bp_make_coords:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, 1
    xor     esi, esi
    call    canvas_random_coord
    mov     r12, rax
    mov     rax, [bp_coords]
    mov     [rax], r12
    mov     r13d, 1
    mov     edi, 2
    call    rng_below
    mov     r14d, eax
    cvtsi2sd xmm0, qword [canvas_right]
    mulsd   xmm0, [bp_fifth]
    call    f64_to_i64
    mov     ecx, 10
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     r15, rax
.walk:
    cmp     r12, [rbp + BP_REP.coord]
    je      .finish
    test    r14d, r14d
    jnz     .column
    mov     rax, r12
    sar     rax, 32
    movsxd  rsi, dword [rbp + BP_REP.coord + 4]
    sub     rsi, rax
    jz      .direct
    mov     ebx, 1
    jns     .row_positive
    neg     rsi
    neg     rbx
.row_positive:
    cmp     rsi, r15
    cmovg   rsi, r15
    mov     edi, 1
    call    rng_randint
    imul    rax, rbx
    shl     rax, 32
    add     r12, rax
    mov     r14d, 1
    jmp     .append
.column:
    movsxd  rax, r12d
    movsxd  rsi, dword [rbp + BP_REP.coord]
    sub     rsi, rax
    jz      .direct
    mov     ebx, 1
    jns     .col_positive
    neg     rsi
    neg     rbx
.col_positive:
    mov     eax, 4
    cmp     rsi, rax
    cmovg   rsi, rax
    mov     edi, 1
    call    rng_randint
    imul    rax, rbx
    mov     ecx, r12d
    add     ecx, eax
    shr     r12, 32
    shl     r12, 32
    or      r12, rcx
    xor     r14d, r14d
    jmp     .append
.direct:
    mov     r12, [rbp + BP_REP.coord]
.append:
    mov     rax, [bp_coords]
    mov     [rax + r13*8], r12
    inc     r13
    jmp     .walk
.finish:
    mov     rax, [bp_coords]
    mov     [rax + r13*8], r12
    mov     [rax + r13*8 + 8], r12
    add     r13, 2
    mov     [bp_coord_count], r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Gradient::new + build_coordinate_color_mapping.
bp_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + BINARYPATH.steps]
    mov     rcx, [rbx + BINARYPATH.step_count]
    mov     rsi, [rbx + BINARYPATH.stop_count]
    call    gradient_capacity
    lea     rdi, [rax*8]
    call    alloc
    mov     r8, rax
    mov     rdi, [rbx + BINARYPATH.stops]
    mov     rsi, [rbx + BINARYPATH.stop_count]
    mov     rdx, [rbx + BINARYPATH.steps]
    mov     rcx, [rbx + BINARYPATH.step_count]
    push    rax
    call    gradient_new
    pop     rdi
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [bp_map_width], rax
    push    qword [rbx + BINARYPATH.direction]
    call    gradient_map
    add     rsp, 8
    mov     [bp_map], rax
    pop     rbx
    ret

; Build collapse/brighten scenes, including Dynamic foreground/background.
; edi = source. Clobbers C.
bp_make_scenes:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     rax, [ch_sym]
    mov     rax, [rax + r12*8]
    mov     [bp_symbol], rax
    mov     r13, NONE
    mov     r14, NONE
    cmp     qword [cfg_existing_colors], 1
    jne     .mapped
    mov     rax, [ch_fg]
    mov     r13, [rax + r12*8]
    mov     rax, [ch_bg]
    mov     r14, [rax + r12*8]
    jmp     .colors
.mapped:
    call    char_input_coord
    mov     rcx, rax
    sar     rax, 32
    sub     rax, [text_bottom]
    imul    rax, [bp_map_width]
    mov     ecx, ecx
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [bp_map]
    mov     r13, [rcx + rax*8]
.colors:
    mov     [bp_final_fg], r13
    mov     [bp_final_bg], r14
    mov     rdi, r13
    call    bp_dim
    mov     [bp_dim_fg], rax
    mov     rdi, r14
    call    bp_dim
    mov     [bp_dim_bg], rax
    xor     ebx, ebx
.scene:
    mov     edi, r12d
    lea     esi, [BP_COLLAPSE + rbx]
    xor     edx, edx
    mov     ecx, 4                      ; InQuad
    test    ebx, ebx
    jz      .new
    mov     ecx, NONE
.new:
    call    scene_new
    mov     ebp, eax
    mov     r13d, 7
    mov     r14d, 3
    mov     rdi, 0xffffff
    mov     rsi, [bp_dim_fg]
    lea     r8, [bp_fg_spectrum]
    test    ebx, ebx
    jz      .fg
    mov     r13d, 10
    mov     r14d, 2
    mov     rdi, [bp_dim_fg]
    mov     rsi, [bp_final_fg]
.fg:
    call    bp_pair_gradient
    mov     r15d, eax
    mov     rdi, 0xffffff
    mov     rsi, [bp_dim_bg]
    lea     r8, [bp_bg_spectrum]
    test    ebx, ebx
    jz      .bg
    mov     rdi, [bp_dim_bg]
    mov     rsi, [bp_final_bg]
.bg:
    call    bp_pair_gradient
    mov     r9d, r15d
    lea     r8, [bp_fg_spectrum]
    mov     edx, 1
    lea     rsi, [bp_symbol]
    mov     edi, ebp
    mov     ecx, r14d
    test    eax, eax
    jnz     .gradient
    test    r15d, r15d
    jnz     .gradient
    mov     rsi, [bp_symbol]
    mov     edx, r14d
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .next
.gradient:
    push    rax
    lea     rax, [bp_bg_spectrum]
    push    rax
    call    scene_apply_gradient
    add     rsp, 16
.next:
    inc     ebx
    cmp     ebx, 2
    jb      .scene
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

bp_dim:
    mov     rax, rdi
    cmp     rdi, NONE
    je      .done
    movsd   xmm0, [bp_half]
    jmp     adjust_color_brightness
.done:
    ret

; rdi/start, rsi/end, r13/steps, r8/output. Absent end -> empty gradient.
bp_pair_gradient:
    xor     eax, eax
    cmp     rsi, NONE
    je      .done
    mov     [bp_pair], rdi
    mov     [bp_pair + 8], rsi
    mov     [bp_steps], r13
    lea     rdi, [bp_pair]
    mov     esi, 2
    lea     rdx, [bp_steps]
    mov     ecx, 1
    jmp     gradient_new
.done:
    ret

; BinaryPath::next_frame. Clobbers C.
binarypath_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    cmp     byte [bp_complete], 0
    je      .run
    call    active_empty
    test    eax, eax
    jz      .run
    xor     eax, eax
    cmp     byte [bp_last], 0
    jne     .out
    mov     byte [bp_last], 1
    jmp     .frame
.run:
    cmp     byte [bp_wipe], 0
    jne     .wipe
.select:
    mov     rax, [bp_active_count]
    cmp     rax, [bp_max_active]
    jae     .travel
    mov     rdi, [bp_pending_count]
    test    rdi, rdi
    jz      .travel
    call    rng_below
    mov     rsi, [bp_pending]
    mov     rdx, [rsi + rax*8]
    mov     rcx, [bp_active_count]
    mov     rdi, [bp_active]
    mov     [rdi + rcx*8], rdx
    inc     qword [bp_active_count]
    dec     qword [bp_pending_count]
    mov     rcx, [bp_pending_count]
    sub     rcx, rax
    lea     rdi, [rsi + rax*8]
    lea     rsi, [rdi + 8]
    rep     movsq
    jmp     .select
.travel:
    xor     ebx, ebx
    xor     r12d, r12d                  ; retained count
.rep:
    cmp     rbx, [bp_active_count]
    jae     .traveled
    mov     rax, [bp_active]
    mov     rbp, [rax + rbx*8]
    mov     eax, [rbp + BP_REP.emitted]
    cmp     eax, [rbp + BP_REP.count]
    jae     .check
    add     eax, [rbp + BP_REP.first]
    mov     r13d, eax
    inc     dword [rbp + BP_REP.emitted]
    mov     edi, r13d
    call    active_insert
    mov     edi, r13d
    call    set_visible
    jmp     .retain
.check:
    xor     r13d, r13d
.bit:
    mov     edi, [rbp + BP_REP.first]
    add     edi, r13d
    call    char_coord
    cmp     rax, [rbp + BP_REP.coord]
    jne     .retain
    inc     r13d
    cmp     r13d, [rbp + BP_REP.count]
    jb      .bit
    xor     r13d, r13d
.hide:
    mov     edi, [rbp + BP_REP.first]
    add     edi, r13d
    xor     esi, esi
    call    set_visibility
    inc     r13d
    cmp     r13d, [rbp + BP_REP.count]
    jb      .hide
    mov     edi, [rbp + BP_REP.source]
    call    set_visible
    mov     edi, [rbp + BP_REP.source]
    mov     esi, BP_COLLAPSE
    call    scene_activate_name
    mov     edi, [rbp + BP_REP.source]
    call    active_insert
    jmp     .next
.retain:
    mov     rax, [bp_active]
    mov     [rax + r12*8], rbp
    inc     r12
.next:
    inc     rbx
    jmp     .rep
.traveled:
    mov     [bp_active_count], r12
    call    active_empty
    test    eax, eax
    jz      .tick
    mov     byte [bp_wipe], 1
.wipe:
    mov     ebx, 2
.group:
    mov     rax, [bp_group_pos]
    cmp     rax, [bp_group_count]
    jae     .complete
    inc     qword [bp_group_pos]
    shl     rax, 4
    add     rax, [bp_groups]
    mov     rbp, [rax]
    mov     r12, [rax + 8]
    xor     r13d, r13d
.char:
    cmp     r13, r12
    jae     .next_group
    mov     r14d, [rbp + r13*4]
    mov     edi, r14d
    mov     esi, BP_BRIGHTEN
    call    scene_activate_name
    mov     edi, r14d
    call    set_visible
    mov     edi, r14d
    call    active_insert
    inc     r13
    jmp     .char
.complete:
    mov     byte [bp_complete], 1
.next_group:
    dec     ebx
    jnz     .group
.tick:
    call    update
.frame:
    mov     eax, 1
.out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
bp_fifth: dq 0.2
bp_half: dq 0.5

section .tstate
alignb 8
bp_groups: resq 1
bp_group_count: resq 1
bp_group_pos: resq 1
bp_chars: resq 1
bp_count: resq 1
bp_reps: resq 1
bp_pending: resq 1
bp_pending_count: resq 1
bp_active: resq 1
bp_active_count: resq 1
bp_max_active: resq 1
bp_coords: resq 1
bp_coord_count: resq 1
bp_map: resq 1
bp_map_width: resq 1
bp_symbol: resq 1
bp_final_fg: resq 1
bp_final_bg: resq 1
bp_dim_fg: resq 1
bp_dim_bg: resq 1
bp_pair: resq 2
bp_steps: resq 1
bp_fg_spectrum: resq 11
bp_bg_spectrum: resq 11
bp_complete: resb 1
bp_last: resb 1
bp_wipe: resb 1
