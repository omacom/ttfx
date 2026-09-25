; effects/slide.asm - "Slide characters into view from outside the terminal"
; (src/effects/slide.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Slide).
;
; The effect draws nothing from the RNG and registers no events, so the
; order in which characters get their paths and scenes is free; it follows
; Rust's anyway. pending_groups is the group array (reversed in place where
; Rust reverses) walked by index; active_groups is a (cursor, remaining)
; array compacted in order like Vec::retain.

struc SLIDE
    .speed:             resq 1          ; f64
    .grouping:          resq 1          ; 0 row, 1 column, 2 diagonal
    .gap:               resq 1
    .reverse:           resq 1          ; bool
    .merge:             resq 1          ; bool
    .easing:            resq 1          ; easing id
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_frames:      resq 1          ; fits i32 (marshal checks)
    .final_direction:   resq 1
endstruc

%define SLD_ROW             0
%define SLD_COLUMN          1

; path names
%define SLD_INPUT_PATH      NAME_LITERAL + 0

section .text

; slide_build: Slide::build.
slide_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    sld_final_map
    ; the per-character gradient: with_steps([final stop 0, final fg], 10)
    lea     rdi, [sld_ten_steps]
    mov     ecx, 1
    mov     esi, 2
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [sld_pair_spectrum], rax
    mov     rax, [rbx + SLIDE.final_stops]
    mov     rax, [rax]
    mov     [sld_pair_stops], rax
    mov     qword [sld_last_fg], NONE
    mov     rax, [rbx + SLIDE.grouping]
    lea     rcx, [sld_groupings]
    movzx   esi, byte [rcx + rax]
    mov     edi, FILTER_INPUT
    call    get_characters_grouped
    mov     [sld_groups], rax
    mov     [sld_group_count], rdx
    ; every character: the "input_path" to its input coordinate
    xor     r12d, r12d
.path_group:
    cmp     r12, [sld_group_count]
    jae     .paths_done
    mov     r13, r12
    shl     r13, 4
    add     r13, [sld_groups]
    mov     r14, [r13 + 8]
    mov     r13, [r13]
.path_char:
    test    r14, r14
    jz      .path_next
    mov     ebp, [r13]
    mov     edi, ebp
    movsd   xmm0, [rbx + SLIDE.speed]
    mov     esi, [rbx + SLIDE.easing]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, SLD_INPUT_PATH
    call    path_new
    mov     r15d, eax
    mov     edi, ebp
    call    char_input_coord
    mov     edi, r15d
    mov     rsi, rax
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    add     r13, 4
    dec     r14
    jmp     .path_char
.path_next:
    inc     r12
    jmp     .path_group
.paths_done:
    xor     r12d, r12d
.group:
    cmp     r12, [sld_group_count]
    jae     .grouped
    call    sld_place_group
    inc     r12
    jmp     .group
.grouped:
    ; active_groups: at most one entry per group
    mov     rdi, [sld_group_count]
    shl     rdi, 4
    add     rdi, 16
    call    alloc
    mov     [sld_active], rax
    mov     qword [sld_active_count], 0
    mov     qword [sld_next_group], 0
    mov     qword [sld_gap_cur], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sld_place_group (r12 = group index, rbx = config): the build loop's body
; for one group - the starting coordinates, the gradient scenes, and the
; group reversed in place where Rust reverses it.
;
; Rust's row/column/diagonal branches reduce to one flag, flip = merge ?
; (index even) : reverse_direction:
;   row:      flip -> from canvas.right + 1 in order, else from left - 1 reversed
;   column:   flip -> from canvas.bottom - 1 in order, else from top + 1 reversed
;   diagonal: flip -> from above the first character reversed, else from
;             below the last character in order
sld_place_group:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rax, r12
    shl     rax, 4
    add     rax, [sld_groups]
    mov     r13, [rax]                  ; slots
    mov     r14, [rax + 8]              ; count
    ; flip -> ebp
    mov     ebp, [rbx + SLIDE.reverse]
    and     ebp, 1
    cmp     qword [rbx + SLIDE.merge], 0
    je      .flipped
    mov     ebp, r12d
    not     ebp
    and     ebp, 1
.flipped:
    xor     r15d, r15d                  ; reversed?
    mov     rax, [rbx + SLIDE.grouping]
    cmp     rax, SLD_ROW
    je      .row
    cmp     rax, SLD_COLUMN
    je      .column
    ; diagonal
    test    ebp, ebp
    jnz     .diag_top
    ; below the last character: (column - row, row - row) = (column - row, 0)
    mov     edi, [r13 + r14 * 4 - 4]
    call    char_input_coord
    mov     rcx, rax
    sar     rcx, 32                     ; row - (canvas.bottom - 1)
    sub     eax, ecx
    mov     eax, eax                    ; row 0
    jmp     .diag_set
.diag_top:
    ; above the first: + (canvas.top + 1 - row) on both axes
    mov     r15d, 1
    mov     edi, [r13]
    call    char_input_coord
    mov     rcx, rax
    sar     rcx, 32                     ; row
    mov     rdx, [canvas_top]
    inc     rdx
    sub     rdx, rcx                    ; distance_from_outside
    add     eax, edx                    ; column + distance
    add     ecx, edx                    ; row + distance
    shl     rcx, 32
    mov     eax, eax
    or      rax, rcx
.diag_set:
    mov     [rsp], rax
    xor     r12d, r12d
.diag_char:
    cmp     r12, r14
    jae     .scenes
    mov     edi, [r13 + r12 * 4]
    mov     rsi, [rsp]
    call    set_coordinate
    inc     r12
    jmp     .diag_char

.row:
    ; (start column, input row)
    xor     eax, eax                    ; canvas.left - 1
    test    ebp, ebp
    jnz     .row_right
    mov     r15d, 1
    jmp     .row_set
.row_right:
    mov     rax, [canvas_right]
    inc     eax
.row_set:
    mov     [rsp], rax
    xor     r12d, r12d
.row_char:
    cmp     r12, r14
    jae     .scenes
    mov     edi, [r13 + r12 * 4]
    call    char_input_coord
    shr     rax, 32
    shl     rax, 32
    mov     ecx, [rsp]
    or      rax, rcx
    mov     rsi, rax
    mov     edi, [r13 + r12 * 4]
    call    set_coordinate
    inc     r12
    jmp     .row_char

.column:
    ; (input column, start row)
    xor     eax, eax                    ; canvas.bottom - 1
    test    ebp, ebp
    jnz     .column_set
    mov     r15d, 1
    mov     rax, [canvas_top]
    inc     rax
.column_set:
    shl     rax, 32
    mov     [rsp], rax
    xor     r12d, r12d
.column_char:
    cmp     r12, r14
    jae     .scenes
    mov     edi, [r13 + r12 * 4]
    call    char_input_coord
    mov     eax, eax
    or      rax, [rsp]
    mov     rsi, rax
    mov     edi, [r13 + r12 * 4]
    call    set_coordinate
    inc     r12
    jmp     .column_char

.scenes:
    ; the gradient scenes, in the group's original order
    xor     r12d, r12d
.scene_char:
    cmp     r12, r14
    jae     .reverse
    mov     edi, [r13 + r12 * 4]
    call    sld_scene
    inc     r12
    jmp     .scene_char
.reverse:
    test    r15d, r15d
    jz      .out
    lea     rcx, [r13 + r14 * 4 - 4]
.swap:
    cmp     r13, rcx
    jae     .out
    mov     eax, [r13]
    mov     edx, [rcx]
    mov     [r13], edx
    mov     [rcx], eax
    add     r13, 4
    sub     rcx, 4
    jmp     .swap
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; sld_scene(edi=slot), rbx = config: the character's gradient scene
; (Gradient::with_steps([final stop 0, mapped fg], 10) applied to its
; symbol, or its input colors under dynamic handling), activated.
sld_scene:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebp, edi
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    mov     rax, [ch_sym]
    mov     rax, [rax + rbp * 8]
    mov     [sld_symbol], rax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    mov     edi, ebp
    call    char_input_coord
    mov     rcx, rax
    sar     rcx, 32
    sub     rcx, [text_bottom]
    imul    rcx, [sld_map_width]
    movsxd  rax, eax
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [sld_map]
    mov     rax, [rcx + rax * 8]
    cmp     rax, [sld_last_fg]
    je      .gradient
    mov     [sld_last_fg], rax
    mov     [sld_pair_stops + 8], rax
    lea     rdi, [sld_pair_stops]
    mov     esi, 2
    lea     rdx, [sld_ten_steps]
    mov     ecx, 1
    mov     r8, [sld_pair_spectrum]
    call    gradient_new
    mov     [sld_pair_len], rax
.gradient:
    push    0
    push    0
    mov     edi, r13d
    lea     rsi, [sld_symbol]
    mov     edx, 1
    mov     ecx, [rbx + SLIDE.final_frames]
    mov     r8, [sld_pair_spectrum]
    mov     r9d, [sld_pair_len]
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .activate
.dynamic:
    mov     rax, [ch_fg]
    mov     rcx, [rax + rbp * 8]
    mov     rax, [ch_bg]
    mov     r8, [rax + rbp * 8]
    mov     edi, r13d
    mov     rsi, [sld_symbol]
    mov     edx, [rbx + SLIDE.final_frames]
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

; sld_final_map (rbx = config): Gradient::new(final stops, final steps) and
; its coordinate mapping over the text rectangle.
sld_final_map:
    mov     rdi, [rbx + SLIDE.final_steps]
    mov     rcx, [rbx + SLIDE.final_step_count]
    mov     rsi, [rbx + SLIDE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [sld_spectrum], rax
    mov     rdi, [rbx + SLIDE.final_stops]
    mov     rsi, [rbx + SLIDE.final_stop_count]
    mov     rdx, [rbx + SLIDE.final_steps]
    mov     rcx, [rbx + SLIDE.final_step_count]
    mov     r8, [sld_spectrum]
    call    gradient_new
    mov     rdi, [sld_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [sld_map_width], rax
    sub     rsp, 8
    push    qword [rbx + SLIDE.final_direction]
    call    gradient_map
    add     rsp, 16
    mov     [sld_map], rax
    ret

; slide_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
slide_next_frame:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [effect_config]
    mov     rax, [sld_next_group]
    cmp     rax, [sld_group_count]
    jb      .run
    cmp     qword [sld_active_count], 0
    jne     .run
    call    active_empty
    test    eax, eax
    jnz     .finished
.run:
    mov     rax, [sld_next_group]
    cmp     rax, [sld_group_count]
    jae     .release
    mov     rcx, [sld_gap_cur]
    cmp     rcx, [rbx + SLIDE.gap]
    jne     .wait
    ; active_groups.push(pending_groups.remove(0))
    inc     qword [sld_next_group]
    shl     rax, 4
    add     rax, [sld_groups]
    mov     rcx, [sld_active_count]
    shl     rcx, 4
    add     rcx, [sld_active]
    mov     rdx, [rax]
    mov     [rcx], rdx
    mov     rdx, [rax + 8]
    mov     [rcx + 8], rdx
    inc     qword [sld_active_count]
    mov     qword [sld_gap_cur], 0
    jmp     .release
.wait:
    inc     qword [sld_gap_cur]
.release:
    ; each active group releases its next character; empty groups are
    ; dropped in place (retain)
    mov     r12, [sld_active]
    mov     r13, [sld_active_count]
    xor     r14d, r14d                  ; read index
    xor     r15d, r15d                  ; write index
.group:
    cmp     r14, r13
    jae     .released
    mov     rax, r14
    shl     rax, 4
    mov     rcx, [r12 + rax]            ; cursor
    mov     rdx, [r12 + rax + 8]        ; remaining (never 0 here)
    mov     ebx, [rcx]
    add     rcx, 4
    dec     rdx
    jz      .drop
    mov     rax, r15
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r15
.drop:
    mov     edi, ebx
    call    set_visible
    mov     edi, ebx
    mov     esi, SLD_INPUT_PATH
    call    path_activate_name
    mov     edi, ebx
    call    active_insert
    inc     r14
    jmp     .group
.released:
    mov     [sld_active_count], r15
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
sld_ten_steps:  dq 10
; CharacterGroup per SlideGrouping
sld_groupings:  db GROUP_ROW_TOP_TO_BOTTOM, GROUP_COLUMN_L2R, GROUP_DIAG_TL_TO_BR

section .tstate
alignb 8
sld_groups:             resq 1
sld_group_count:        resq 1
sld_next_group:         resq 1
sld_gap_cur:            resq 1
sld_active:             resq 1
sld_active_count:       resq 1
sld_spectrum:           resq 1
sld_map:                resq 1
sld_map_width:          resq 1
sld_pair_stops:         resq 2
sld_pair_spectrum:      resq 1
sld_pair_len:           resq 1
sld_last_fg:            resq 1
sld_symbol:             resq 1
