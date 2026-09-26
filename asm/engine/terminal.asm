; engine/terminal.asm - canvas layout, text anchoring, fill characters,
; neighbors and character queries of Terminal (src/engine/terminal.rs,
; canvas.rs).

section .text

; terminal_init: preprocess, lay out the canvas and anchor the text.
terminal_init:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    call    input_init
    call    compute_layout
    call    assign_coordinates
    call    anchor_text
    call    build_coord_map
    call    make_fill_characters
    call    setup_neighbors
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; floor_div2(rax) -> rax = rax // 2 (Python floor division).
floor_div2:
    sar     rax, 1
    ret

; compute_layout: canvas dimensions, canvas offsets and the visible window.
compute_layout:
    push    rbx
    ; input width = longest trimmed line; input height = line count
    mov     rcx, [line_count]
    mov     rsi, [line_len]
    xor     eax, eax
    xor     edx, edx
.widest:
    cmp     rdx, rcx
    jae     .width
    cmp     rax, [rsi + rdx * 8]
    cmovl   rax, [rsi + rdx * 8]
    inc     rdx
    jmp     .widest
.width:
    mov     rbx, [cfg_canvas_width]
    test    rbx, rbx
    jg      .width_done
    jz      .width_term
    mov     rbx, rax
    cmp     byte [cfg_ignore_dims], 0
    jne     .width_done
    cmp     rbx, [term_width]
    cmovg   rbx, [term_width]
    jmp     .width_done
.width_term:
    mov     rbx, [term_width]
.width_done:
    mov     [canvas_right], rbx
    mov     rax, [cfg_canvas_height]
    test    rax, rax
    jg      .height_done
    jz      .height_term
    mov     rax, [line_count]
    cmp     byte [cfg_ignore_dims], 0
    jne     .height_done
    cmp     byte [cfg_wrap_text], 0
    je      .clip_height
    mov     rdi, rbx                    ; wrapped at the canvas width
    call    wrapped_line_count
.clip_height:
    cmp     rax, [term_height]
    cmovg   rax, [term_height]
    jmp     .height_done
.height_term:
    mov     rax, [term_height]
.height_done:
    mov     [canvas_top], rax
    ; canvas center (Canvas::new)
    mov     rdi, rax
    call    center_of
    mov     [center_row], rax
    mov     rdi, [canvas_right]
    call    center_of
    mov     [center_col], rax
    ; offsets
    xor     r8d, r8d                    ; column offset
    xor     r9d, r9d                    ; row offset
    mov     r10, [term_width]
    mov     r11, [term_height]
    cmp     byte [cfg_ignore_dims], 0
    je      .offsets
    mov     r10, [canvas_right]
    mov     r11, [canvas_top]
    jmp     .visible
.offsets:
    mov     rcx, [cfg_anchor_canvas]
    lea     rdx, [anchor_column_group]
    movzx   edx, byte [rdx + rcx]
    cmp     edx, 1
    jne     .col_east
    mov     rax, r10
    sar     rax, 1
    mov     r8, [canvas_right]
    sar     r8, 1
    sub     rax, r8
    mov     r8, rax
    jmp     .rows
.col_east:
    cmp     edx, 2
    jne     .rows
    mov     r8, r10
    sub     r8, [canvas_right]
.rows:
    lea     rdx, [anchor_row_group]
    movzx   edx, byte [rdx + rcx]
    cmp     edx, 1
    jne     .row_north
    mov     rax, r11
    sar     rax, 1
    mov     r9, [canvas_top]
    sar     r9, 1
    sub     rax, r9
    mov     r9, rax
    jmp     .visible
.row_north:
    cmp     edx, 2
    jne     .visible
    mov     r9, r11
    sub     r9, [canvas_top]
.visible:
    mov     [col_offset], r8
    mov     [row_offset], r9
    mov     rax, [canvas_top]
    add     rax, r9
    cmp     rax, r11
    cmovg   rax, r11
    mov     [visible_top], rax
    lea     rax, [r9 + 1]
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [visible_bottom], rax
    mov     rax, [canvas_right]
    add     rax, r8
    cmp     rax, r10
    cmovg   rax, r10
    mov     [visible_right], rax
    lea     rax, [r8 + 1]
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [visible_left], rax
    pop     rbx
    ret

; center_of(rdi=extent) -> rax: max(extent // 2, 1), +1 when odd and > 1.
center_of:
    mov     rax, rdi
    sar     rax, 1
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    test    dil, 1
    jz      .done
    cmp     rdi, 1
    jle     .done
    inc     rax
.done:
    ret

; anchor_text: Canvas::anchor_text over the input characters (in place).
anchor_text:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, [input_chars]
    mov     r13, [input_count]
    test    r13, r13
    jz      error_no_input_chars
    mov     r8, [ch_col]
    mov     r9, [ch_row]
    ; input extents: max column, max row
    xor     ecx, ecx
    mov     r10d, 0x80000000
    mov     r11d, 0x80000000
.extent:
    cmp     rcx, r13
    jae     .extent_done
    mov     eax, [r12 + rcx * 4]
    mov     edx, [r8 + rax * 4]
    cmp     edx, r10d
    cmovg   r10d, edx
    mov     edx, [r9 + rax * 4]
    cmp     edx, r11d
    cmovg   r11d, edx
    inc     rcx
    jmp     .extent
.extent_done:
    movsxd  r10, r10d                   ; input_width
    movsxd  r11, r11d                   ; input_height
    mov     rcx, [cfg_anchor_text]
    xor     esi, esi                    ; column delta
    xor     edi, edi                    ; row delta
    cmp     r10, [canvas_right]
    je      .row_delta
    lea     rdx, [anchor_column_group]
    movzx   edx, byte [rdx + rcx]
    cmp     edx, 1
    jne     .col_east
    mov     rax, r10
    sar     rax, 1
    mov     rsi, [center_col]
    sub     rsi, rax
    jmp     .row_delta
.col_east:
    cmp     edx, 2
    jne     .row_delta
    mov     rsi, [canvas_right]
    sub     rsi, r10
.row_delta:
    cmp     r11, [canvas_top]
    je      .apply
    lea     rdx, [anchor_row_group]
    movzx   edx, byte [rdx + rcx]
    cmp     edx, 1
    jne     .row_north
    mov     rax, r11
    sar     rax, 1
    mov     rdi, [center_row]
    sub     rdi, rax
    jmp     .apply
.row_north:
    cmp     edx, 2
    jne     .apply
    mov     rdi, [canvas_top]
    sub     rdi, r11
.apply:
    ; shift, then keep the in-canvas characters (order preserved)
    xor     ecx, ecx
    xor     ebx, ebx                    ; kept count
    mov     r10d, 0x7fffffff            ; text_left
    mov     r11d, 0x80000000            ; text_right
    mov     qword [text_top], -2147483648
    mov     qword [text_bottom], 2147483647
.shift:
    cmp     rcx, r13
    jae     .shifted
    mov     eax, [r12 + rcx * 4]
    mov     edx, [r8 + rax * 4]
    add     edx, esi
    mov     [r8 + rax * 4], edx
    mov     r14, [ch_icol]
    mov     [r14 + rax * 4], edx
    push    rcx
    mov     ecx, [r9 + rax * 4]
    add     ecx, edi
    mov     [r9 + rax * 4], ecx
    mov     r14, [ch_irow]
    mov     [r14 + rax * 4], ecx
    ; in canvas: 1 <= column <= right, 1 <= row <= top
    cmp     edx, 1
    jl      .drop
    movsxd  rdx, edx
    cmp     rdx, [canvas_right]
    jg      .drop
    cmp     ecx, 1
    jl      .drop
    movsxd  rcx, ecx
    cmp     rcx, [canvas_top]
    jg      .drop
    mov     [r12 + rbx * 4], eax
    inc     rbx
    mov     r14, [ch_flags]
    or      word [r14 + rax * 2], CF_INPUT
    cmp     edx, r10d
    cmovl   r10d, edx
    cmp     edx, r11d
    cmovg   r11d, edx
    cmp     rcx, [text_top]
    jle     .not_top
    mov     [text_top], rcx
.not_top:
    cmp     rcx, [text_bottom]
    jge     .drop
    mov     [text_bottom], rcx
.drop:
    pop     rcx
    inc     rcx
    jmp     .shift
.shifted:
    test    rbx, rbx
    jz      .all_outside
    mov     [input_count], rbx
    movsxd  r10, r10d
    movsxd  r11, r11d
    mov     [text_left], r10
    mov     [text_right], r11
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.all_outside:
    FAIL    msg_all_outside

; build_coord_map: character_by_input_coord as a canvas-sized grid of slots
; (NONE where empty), seeded with the kept input characters; plus the text
; center.
build_coord_map:
    push    rbx
    mov     rax, [canvas_top]
    imul    rax, [canvas_right]
    mov     [coord_map_cells], rax
    lea     rdi, [rax * 4 + 64]
    call    reserve
    mov     [coord_map], rax
    ; fill with NONE
    mov     rdi, rax
    mov     rcx, [coord_map_cells]
    mov     eax, NONE
    rep     stosd
    xor     ebx, ebx
.each:
    cmp     rbx, [input_count]
    jae     .center
    mov     rax, [input_chars]
    mov     edi, [rax + rbx * 4]
    call    char_input_coord
    mov     rsi, rax
    call    coord_map_index
    mov     rcx, [coord_map]
    mov     [rcx + rax * 4], edi
    inc     rbx
    jmp     .each
.center:
    mov     rax, [text_top]
    sub     rax, [text_bottom]
    sar     rax, 1
    add     rax, [text_bottom]
    mov     [text_center_row], rax
    mov     rax, [text_right]
    sub     rax, [text_left]
    sar     rax, 1
    add     rax, [text_left]
    mov     [text_center_col], rax
    pop     rbx
    ret

; coord_map_index(rsi=coord inside the canvas) -> rax = grid index.
coord_map_index:
    mov     rax, rsi
    sar     rax, 32
    dec     rax
    imul    rax, [canvas_right]
    movsxd  rcx, esi
    lea     rax, [rax + rcx - 1]
    ret

; char_at_input_coord(rsi=coord) -> eax = slot or NONE
; (Terminal.get_character_by_input_coord).
char_at_input_coord:
    mov     rax, rsi
    sar     rax, 32
    cmp     rax, 1
    jl      .none
    cmp     rax, [canvas_top]
    jg      .none
    movsxd  rcx, esi
    cmp     rcx, 1
    jl      .none
    cmp     rcx, [canvas_right]
    jg      .none
    call    coord_map_index
    mov     rcx, [coord_map]
    mov     eax, [rcx + rax * 4]
    ret
.none:
    mov     eax, NONE
    ret

; make_fill_characters: Terminal._make_fill_characters - row-major from
; (1, 1), a space for every unoccupied canvas cell, split inner/outer by the
; text box.
make_fill_characters:
    push    rbx
    push    r12
    push    r13
    mov     rdi, [coord_map_cells]
    lea     rdi, [rdi * 4 + 64]
    call    reserve
    mov     [inner_fill_chars], rax
    mov     rdi, [coord_map_cells]
    lea     rdi, [rdi * 4 + 64]
    call    reserve
    mov     [outer_fill_chars], rax
    mov     edi, [char_count]
    mov     rsi, [coord_map_cells]
    sub     rsi, [input_count]          ; the fill characters to come
    call    populate_chars
    mov     r12, 1                      ; row
.row:
    cmp     r12, [canvas_top]
    jg      .done
    mov     r13, 1                      ; column
.column:
    cmp     r13, [canvas_right]
    jg      .next_row
    mov     rsi, r12
    shl     rsi, 32
    or      rsi, r13
    call    coord_map_index
    mov     rbx, rax
    mov     rcx, [coord_map]
    cmp     dword [rcx + rbx * 4], NONE
    jne     .next
    mov     rdi, (1 << 32) | ' '
    mov     esi, r13d
    mov     edx, r12d
    call    new_char
    mov     rcx, [coord_map]
    mov     [rcx + rbx * 4], eax
    ; inner when inside the text box
    mov     edx, CF_FILL_OUTER
    cmp     r13, [text_left]
    jl      .flag
    cmp     r13, [text_right]
    jg      .flag
    cmp     r12, [text_bottom]
    jl      .flag
    cmp     r12, [text_top]
    jg      .flag
    mov     edx, CF_FILL_INNER
.flag:
    mov     rcx, [ch_flags]
    or      [rcx + rax * 2], dx
    cmp     edx, CF_FILL_INNER
    jne     .outer
    mov     ecx, [inner_fill_count]
    mov     rdx, [inner_fill_chars]
    mov     [rdx + rcx * 4], eax
    inc     dword [inner_fill_count]
    jmp     .next
.outer:
    mov     ecx, [outer_fill_count]
    mov     rdx, [outer_fill_chars]
    mov     [rdx + rcx * 4], eax
    inc     dword [outer_fill_count]
.next:
    inc     r13
    jmp     .column
.next_row:
    inc     r12
    jmp     .row
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; setup_neighbors: north/east/south/west of every mapped character, straight
; from the grid (every cell holds a character once the fill is made).
setup_neighbors:
    push    rbx
    mov     r8, [coord_map]
    mov     r9, [canvas_right]          ; row stride
    mov     r10, [ch_nbr]
    mov     r11, [canvas_top]
    mov     rbx, r9
    shl     rbx, 2                      ; stride in bytes
    mov     edx, 1                      ; row
.row:
    cmp     rdx, r11
    jg      .done
    mov     esi, 1                      ; column
.column:
    cmp     rsi, r9
    jg      .next_row
    mov     ecx, [r8]                   ; this character
    shl     rcx, 4
    add     rcx, r10
    mov     eax, NONE                   ; north: row + 1
    cmp     rdx, r11
    jge     .north
    mov     eax, [r8 + rbx]
.north:
    mov     [rcx + NBR_NORTH], eax
    mov     eax, NONE                   ; east: column + 1
    cmp     rsi, r9
    jge     .east
    mov     eax, [r8 + 4]
.east:
    mov     [rcx + NBR_EAST], eax
    mov     eax, NONE                   ; south: row - 1
    cmp     rdx, 1
    jle     .south
    mov     rax, r8
    sub     rax, rbx
    mov     eax, [rax]
.south:
    mov     [rcx + NBR_SOUTH], eax
    mov     eax, NONE                   ; west: column - 1
    cmp     rsi, 1
    jle     .west
    mov     eax, [r8 - 4]
.west:
    mov     [rcx + NBR_WEST], eax
    add     r8, 4
    inc     rsi
    jmp     .column
.next_row:
    inc     rdx
    jmp     .row
.done:
    pop     rbx
    ret

; ---------------------------------------------------------------- queries

%define FILTER_INPUT        1
%define FILTER_INNER_FILL   2
%define FILTER_OUTER_FILL   4
%define FILTER_ADDED        8

; CharacterSort order
%define SORT_RANDOM                 0
%define SORT_TOP_TO_BOTTOM_L2R      1
%define SORT_BOTTOM_TO_TOP_R2L      2
%define SORT_BOTTOM_TO_TOP_L2R      3
%define SORT_TOP_TO_BOTTOM_R2L      4
%define SORT_OUTSIDE_ROW_TO_MIDDLE  5
%define SORT_MIDDLE_ROW_TO_OUTSIDE  6

; CharacterGroup order
%define GROUP_COLUMN_L2R            0
%define GROUP_COLUMN_R2L            1
%define GROUP_ROW_TOP_TO_BOTTOM     2
%define GROUP_ROW_BOTTOM_TO_TOP     3
%define GROUP_DIAG_BL_TO_TR         4
%define GROUP_DIAG_TR_TO_BL         5
%define GROUP_DIAG_TL_TO_BR         6
%define GROUP_DIAG_BR_TO_TL         7
%define GROUP_CENTER_TO_OUTSIDE     8
%define GROUP_OUTSIDE_TO_CENTER     9

; collect_characters(edi=FILTER_* bits) -> rax = u32 slot array, rdx = count.
; Input characters, inner fill, outer fill, added - in that order.
collect_characters:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     rdi, [input_count]
    mov     eax, [inner_fill_count]
    add     rdi, rax
    mov     eax, [outer_fill_count]
    add     rdi, rax
    mov     eax, [added_count]
    add     rdi, rax
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     r12, rax
    xor     r13d, r13d
    test    ebx, FILTER_INPUT
    jz      .inner
    mov     rsi, [input_chars]
    mov     rcx, [input_count]
    call    .append
.inner:
    test    ebx, FILTER_INNER_FILL
    jz      .outer
    mov     rsi, [inner_fill_chars]
    mov     ecx, [inner_fill_count]
    call    .append
.outer:
    test    ebx, FILTER_OUTER_FILL
    jz      .added
    mov     rsi, [outer_fill_chars]
    mov     ecx, [outer_fill_count]
    call    .append
.added:
    test    ebx, FILTER_ADDED
    jz      .done
    mov     rsi, [added_chars]
    mov     ecx, [added_count]
    call    .append
.done:
    mov     rax, r12
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret
.append:
    lea     rdi, [r12 + r13 * 4]
    add     r13, rcx
    rep     movsd
    ret

; key_row_desc_col(edi=slot) -> rax: (-row, column) as an unsigned-ordered key
; over input coordinates. key_row_col: (row, column).
key_row_desc_col:
    mov     rax, [ch_irow]
    mov     eax, [rax + rdi * 4]
    neg     eax
    jmp     key_with_column
key_row_col:
    mov     rax, [ch_irow]
    mov     eax, [rax + rdi * 4]
key_with_column:
    add     eax, 0x80000000
    shl     rax, 32
    mov     rcx, [ch_icol]
    mov     ecx, [rcx + rdi * 4]
    add     ecx, 0x80000000
    or      rax, rcx
    ret

; sort_slots_by(rdi=u32 slots, rsi=count, rdx=key function) - stable sort by
; the 64-bit unsigned key the function computes for each slot.
sort_slots_by:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    cmp     r13, 1
    jbe     .done
    ; pairs of (key, slot)
    mov     rdi, r13
    shl     rdi, 4
    call    alloc
    mov     r15, rax
    xor     ebx, ebx
.keys:
    cmp     rbx, r13
    jae     .sort
    mov     edi, [r12 + rbx * 4]
    call    r14
    mov     rcx, rbx
    shl     rcx, 4
    mov     [r15 + rcx], rax
    mov     edi, [r12 + rbx * 4]
    mov     [r15 + rcx + 8], rdi
    inc     rbx
    jmp     .keys
.sort:
    mov     rdi, r15
    mov     rsi, r13
    call    sort_pairs
    xor     ebx, ebx
.back:
    cmp     rbx, r13
    jae     .done
    mov     rcx, rbx
    shl     rcx, 4
    mov     eax, [r15 + rcx + 8]
    mov     [r12 + rbx * 4], eax
    inc     rbx
    jmp     .back
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; sort_pairs(rdi=pairs of (u64 key, u64 value), rsi=count): stable merge sort
; by key (unsigned), bottom-up with one scratch buffer.
sort_pairs:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi                    ; source
    mov     [sort_pairs_origin], rdi
    mov     r13, rsi                    ; count
    mov     rdi, rsi
    shl     rdi, 4
    call    alloc
    mov     r14, rax                    ; destination
    mov     rbp, 1                      ; run width
.pass:
    cmp     rbp, r13
    jae     .finished
    xor     ebx, ebx                    ; left start
.merge:
    cmp     rbx, r13
    jae     .swap
    lea     r8, [rbx + rbp]             ; middle
    cmp     r8, r13
    cmova   r8, r13
    lea     r9, [r8 + rbp]              ; end
    cmp     r9, r13
    cmova   r9, r13
    mov     r10, rbx                    ; i (left)
    mov     r11, r8                     ; j (right)
    mov     r15, rbx                    ; k (out)
.pick:
    cmp     r15, r9
    jae     .merged
    cmp     r10, r8
    jae     .take_right
    cmp     r11, r9
    jae     .take_left
    mov     rax, r10
    shl     rax, 4
    mov     rcx, r11
    shl     rcx, 4
    mov     rdx, [r12 + rcx]
    cmp     rdx, [r12 + rax]
    jb      .take_right                 ; strictly smaller right wins; ties keep left
.take_left:
    mov     rax, r10
    inc     r10
    jmp     .put
.take_right:
    mov     rax, r11
    inc     r11
.put:
    shl     rax, 4
    mov     rcx, r15
    shl     rcx, 4
%if TIER >= 3
    vmovdqu xmm0, [r12 + rax]
    vmovdqu [r14 + rcx], xmm0
%else
    movdqu  xmm0, [r12 + rax]
    movdqu  [r14 + rcx], xmm0
%endif
    inc     r15
    jmp     .pick
.merged:
    mov     rbx, r9
    jmp     .merge
.swap:
    xchg    r12, r14
    add     rbp, rbp
    jmp     .pass
.finished:
    ; the sorted data is in r12; copy it back if that is the scratch buffer
    mov     rsi, r12
    mov     rdi, [sort_pairs_origin]
    cmp     rsi, rdi
    je      .done
    mov     rcx, r13
    shl     rcx, 4
    rep     movsb
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; get_characters(edi=FILTER_* bits, esi=SORT_*) -> rax = slots, rdx = count.
; Terminal.get_characters; the random sort shuffles with the engine RNG.
get_characters:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    call    collect_characters
    mov     r12, rax
    mov     r13, rdx
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [key_row_desc_col]
    call    sort_slots_stable
    cmp     ebx, SORT_RANDOM
    je      .random
    cmp     ebx, SORT_BOTTOM_TO_TOP_R2L
    je      .reverse
    cmp     ebx, SORT_BOTTOM_TO_TOP_L2R
    je      .row_col
    cmp     ebx, SORT_TOP_TO_BOTTOM_R2L
    je      .row_col_reversed
    cmp     ebx, SORT_OUTSIDE_ROW_TO_MIDDLE
    je      .interleave
    cmp     ebx, SORT_MIDDLE_ROW_TO_OUTSIDE
    je      .interleave_reversed
    jmp     .done
.random:
    mov     rdi, r12
    mov     rsi, r13
    call    rng_shuffle32
    jmp     .done
.row_col:
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [key_row_col]
    call    sort_slots_stable
    jmp     .done
.row_col_reversed:
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [key_row_col]
    call    sort_slots_stable
.reverse:
    mov     rdi, r12
    mov     rsi, r13
    call    reverse_u32
    jmp     .done
.interleave:
    call    .alternate
    jmp     .done
.interleave_reversed:
    call    .alternate
    jmp     .reverse
.done:
    mov     rax, r12
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret
.alternate:
    ; alternately pop the front and the back (outside rows first)
    lea     rdi, [r13 * 4 + 64]
    call    alloc
    xor     ecx, ecx                    ; front
    lea     rdx, [r13 - 1]              ; back
    xor     r8d, r8d                    ; out index
.alt_next:
    cmp     r8, r13
    jae     .alt_done
    mov     r9d, [r12 + rcx * 4]
    inc     rcx
    mov     [rax + r8 * 4], r9d
    inc     r8
    cmp     r8, r13
    jae     .alt_done
    mov     r9d, [r12 + rdx * 4]
    dec     rdx
    mov     [rax + r8 * 4], r9d
    inc     r8
    jmp     .alt_next
.alt_done:
    mov     r12, rax
    ret

sort_slots_stable equ sort_slots_by

; reverse_u32(rdi=array, rsi=count)
reverse_u32:
    lea     rsi, [rdi + rsi * 4 - 4]
.loop:
    cmp     rdi, rsi
    jae     .done
    mov     eax, [rdi]
    mov     ecx, [rsi]
    mov     [rdi], ecx
    mov     [rsi], eax
    add     rdi, 4
    sub     rsi, 4
    jmp     .loop
.done:
    ret

; get_characters_grouped(edi=FILTER_* bits, esi=GROUP_*) -> rax = groups,
; rdx = group count. Each group is 16 bytes: (u32 slot array, count).
; Terminal.get_characters_grouped: characters in (row, column) order, then
; bucketed by the grouping key (keys outside the canvas range dropped, empty
; buckets skipped), buckets in ascending key order, reversed for the
; opposite direction.
get_characters_grouped:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, esi
    call    collect_characters
    mov     r12, rax
    mov     r13, rdx
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [key_row_col]
    call    sort_slots_stable
    ; key function and inclusive range per grouping
    mov     eax, ebx
    shr     eax, 1                      ; 0 column, 1 row, 2 diag, 3 anti, 4 center
    mov     [group_kind], eax
    ; (key, slot) pairs for the kept characters, stable-sorted by key
    mov     rdi, r13
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     r14, rax
    xor     r15d, r15d                  ; kept
    xor     ebp, ebp
.key:
    cmp     rbp, r13
    jae     .keyed
    mov     edi, [r12 + rbp * 4]
    call    group_key                   ; rax = key (i64), ZF set when out of range
    jz      .skip
    mov     rcx, r15
    shl     rcx, 4
    mov     rdx, 0x8000000000000000
    add     rax, rdx                    ; unsigned order
    mov     [r14 + rcx], rax
    mov     edi, [r12 + rbp * 4]
    mov     [r14 + rcx + 8], rdi
    inc     r15
.skip:
    inc     rbp
    jmp     .key
.keyed:
    mov     rdi, r14
    mov     rsi, r15
    call    sort_pairs
    ; runs of equal keys become groups; members go to one slot array
    lea     rdi, [r15 * 4 + 64]
    call    alloc
    mov     r12, rax                    ; members
    mov     rdi, r15
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     r13, rax                    ; groups
    xor     ebp, ebp                    ; group count
    xor     ecx, ecx
.member:
    cmp     rcx, r15
    jae     .grouped
    mov     rdx, rcx
    shl     rdx, 4
    mov     eax, [r14 + rdx + 8]
    mov     [r12 + rcx * 4], eax
    ; a new group when the key differs from the previous one
    test    rcx, rcx
    jz      .new_group
    mov     rax, [r14 + rdx]
    cmp     rax, [r14 + rdx - 16]
    je      .same_group
.new_group:
    mov     rax, rbp
    shl     rax, 4
    lea     rdx, [r12 + rcx * 4]
    mov     [r13 + rax], rdx
    mov     qword [r13 + rax + 8], 0
    inc     rbp
.same_group:
    mov     rax, rbp
    dec     rax
    shl     rax, 4
    inc     qword [r13 + rax + 8]
    inc     rcx
    jmp     .member
.grouped:
    ; column right-to-left, row top-to-bottom, and the diagonal/center
    ; variants listed second run their buckets in reverse
    mov     eax, (1 << GROUP_COLUMN_R2L) | (1 << GROUP_ROW_TOP_TO_BOTTOM) | (1 << GROUP_DIAG_TR_TO_BL) | (1 << GROUP_DIAG_BR_TO_TL) | (1 << GROUP_OUTSIDE_TO_CENTER)
    bt      eax, ebx
    jnc     .result
.reverse:
    ; reverse the order of the 16-byte group records
    mov     rdi, r13
    mov     rsi, rbp
    shl     rsi, 4
    lea     rsi, [r13 + rsi - 16]
.rev:
    cmp     rdi, rsi
    jae     .result
%if TIER >= 3
    vmovdqu xmm0, [rdi]
    vmovdqu xmm1, [rsi]
    vmovdqu [rdi], xmm1
    vmovdqu [rsi], xmm0
%else
    movdqu  xmm0, [rdi]
    movdqu  xmm1, [rsi]
    movdqu  [rdi], xmm1
    movdqu  [rsi], xmm0
%endif
    add     rdi, 16
    sub     rsi, 16
    jmp     .rev
.result:
    mov     rax, r13
    mov     rdx, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; group_key(edi=slot) -> rax = the grouping key of [group_kind]; ZF set
; when it falls outside ordered_buckets' range (the character is dropped).
group_key:
    mov     rax, [ch_irow]
    movsxd  r8, dword [rax + rdi * 4]   ; row
    mov     rax, [ch_icol]
    movsxd  r9, dword [rax + rdi * 4]   ; column
    mov     eax, [group_kind]
    cmp     eax, 1
    je      .row
    cmp     eax, 2
    je      .diagonal
    cmp     eax, 3
    je      .anti
    cmp     eax, 4
    je      .center
    ; column in [0, right]
    mov     rax, r9
    xor     ecx, ecx
    mov     rdx, [canvas_right]
    jmp     .range
.row:
    mov     rax, r8
    xor     ecx, ecx
    mov     rdx, [canvas_top]
    jmp     .range
.diagonal:
    lea     rax, [r8 + r9]
    xor     ecx, ecx
    mov     rdx, [canvas_top]
    add     rdx, [canvas_right]
    jmp     .range
.anti:
    mov     rax, r9
    sub     rax, r8                     ; column - row
    mov     rcx, 1
    sub     rcx, [canvas_top]           ; left - top
    mov     rdx, [canvas_right]
    dec     rdx                         ; right - bottom
    jmp     .range
.center:
    ; Manhattan distance from the text center; every character is kept
    mov     rax, r9
    sub     rax, [text_center_col]
    mov     rcx, rax
    neg     rcx
    cmovns  rax, rcx
    mov     rdx, r8
    sub     rdx, [text_center_row]
    mov     rcx, rdx
    neg     rcx
    cmovns  rdx, rcx
    add     rax, rdx
    or      ecx, 1                      ; ZF clear
    ret
.range:
    cmp     rax, rcx
    jl      .out
    cmp     rax, rdx
    jg      .out
    or      ecx, 1
    test    ecx, ecx                    ; ZF clear
    ret
.out:
    xor     ecx, ecx                    ; ZF set
    ret

; ---------------------------------------------------------------- canvas

; canvas_random_column(edi=within text) -> rax  (Canvas.random_column)
canvas_random_column:
    test    edi, edi
    jz      .canvas
    mov     rdi, [text_left]
    mov     rsi, [text_right]
    jmp     rng_randint
.canvas:
    mov     edi, 1
    mov     rsi, [canvas_right]
    jmp     rng_randint

; canvas_random_row(edi=within text) -> rax  (Canvas.random_row)
canvas_random_row:
    test    edi, edi
    jz      .canvas
    mov     rdi, [text_bottom]
    mov     rsi, [text_top]
    jmp     rng_randint
.canvas:
    mov     edi, 1
    mov     rsi, [canvas_top]
    jmp     rng_randint

; canvas_random_coord(edi=outside scope, esi=within text) -> rax = coord.
; Canvas.random_coord, with its exact draw order: above, below, left, right
; are built (four draws), then one is chosen.
canvas_random_coord:
    push    rbx
    push    r12
    sub     rsp, 32
    test    edi, edi
    jz      .inside
    xor     edi, edi
    call    canvas_random_column
    mov     rcx, [canvas_top]
    inc     rcx
    shl     rcx, 32
    mov     eax, eax
    or      rax, rcx
    mov     [rsp], rax                  ; above
    xor     edi, edi
    call    canvas_random_column
    mov     rcx, 0                      ; bottom - 1
    shl     rcx, 32
    mov     eax, eax
    or      rax, rcx
    mov     [rsp + 8], rax              ; below
    xor     edi, edi
    call    canvas_random_row
    shl     rax, 32
    mov     ecx, 0                      ; left - 1
    or      rax, rcx
    mov     [rsp + 16], rax             ; left
    xor     edi, edi
    call    canvas_random_row
    shl     rax, 32
    mov     rcx, [canvas_right]
    inc     rcx
    mov     ecx, ecx
    or      rax, rcx
    mov     [rsp + 24], rax             ; right
    mov     edi, 4
    call    rng_below
    mov     rax, [rsp + rax * 8]
    jmp     .done
.inside:
    mov     ebx, esi
    mov     edi, esi
    call    canvas_random_column
    mov     r12, rax
    mov     edi, ebx
    call    canvas_random_row
    shl     rax, 32
    mov     r12d, r12d
    or      rax, r12
.done:
    add     rsp, 32
    pop     r12
    pop     rbx
    ret

; coord_in_canvas(rsi=coord) -> eax = 1 inside [1, right] x [1, top].
coord_in_canvas:
    mov     rax, rsi
    sar     rax, 32
    cmp     rax, 1
    jl      .no
    cmp     rax, [canvas_top]
    jg      .no
    movsxd  rax, esi
    cmp     rax, 1
    jl      .no
    cmp     rax, [canvas_right]
    jg      .no
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

section .rodata
; Anchor enum order: n ne e se s sw w nw c.
; column group: 1 = S|N|C (centered), 2 = SE|E|NE (east), 0 = west
anchor_column_group:    db 1, 2, 2, 2, 1, 0, 0, 0, 1
; row group: 1 = W|E|C (centered), 2 = NW|N|NE (north), 0 = south
anchor_row_group:       db 2, 2, 1, 0, 0, 0, 1, 2, 1

STR msg_all_outside, "all input characters fall outside the canvas after anchoring"


section .tstate
alignb 8
term_width:         resq 1
term_height:        resq 1
canvas_top:         resq 1
canvas_right:       resq 1
center_row:         resq 1
center_col:         resq 1
col_offset:         resq 1
row_offset:         resq 1
visible_top:        resq 1
visible_bottom:     resq 1
visible_right:      resq 1
visible_left:       resq 1
text_top:           resq 1
text_bottom:        resq 1
text_left:          resq 1
text_right:         resq 1
text_center_row:    resq 1
text_center_col:    resq 1
coord_map:          resq 1
coord_map_cells:    resq 1
inner_fill_chars:   resq 1
outer_fill_chars:   resq 1
inner_fill_count:   resd 1
outer_fill_count:   resd 1
group_kind:         resd 1
sort_pairs_origin:  resq 1
