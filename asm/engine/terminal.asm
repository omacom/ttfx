; engine/terminal.asm - the input preprocessor, canvas layout and text
; anchoring of Terminal::new (src/engine/terminal.rs, input.rs, canvas.rs).
;
; Characters live in struct-of-arrays form, indexed by slot. A slot is
; allocated per parsed character in the order Rust pushes them to its arena,
; so ascending slot order equals ascending character_id order.
;
; This slice covers plain text: tabs, \r and \n. An escape sequence exits 3
; ("unsupported"), so harnesses can tell a gap from a mismatch.

%define CF_VISIBLE      1
%define CF_ORPHAN       2               ; overwritten by a later character
%define CF_INPUT        4               ; kept input character

section .text

; terminal_init: preprocess, lay out the canvas and anchor the text.
terminal_init:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    call    count_capacity
    call    alloc_characters
    call    preprocess
    call    compute_layout
    call    anchor_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; count_capacity: an upper bound on parsed characters (tabs expand to at most
; tab_width cells) and on rows.
count_capacity:
    mov     rsi, [input_ptr]
    mov     r9, rsi
    add     r9, [input_len]
    xor     r10d, r10d                  ; characters
    mov     r11d, 1                     ; rows
.loop:
    cmp     rsi, r9
    jae     .done
    call    utf8_decode
    add     rsi, rdx
    cmp     eax, 10
    je      .newline
    cmp     eax, 13
    je      .loop
    cmp     eax, 9
    je      .tab
    inc     r10
    jmp     .loop
.tab:
    add     r10, [cfg_tab_width]
    jmp     .loop
.newline:
    inc     r11
    jmp     .loop
.done:
    inc     r10
    mov     [char_capacity], r10
    mov     [row_capacity], r11
    ret

; alloc_characters: the SoA arrays, sized by char_capacity (+1 sentinel slot).
alloc_characters:
    push    rbx
    mov     rbx, [char_capacity]
    inc     rbx
    lea     rdi, [rbx * 8]
    call    alloc
    mov     [ch_sym], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_row], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_col], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_id], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_layer], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_handle], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [ch_scene], rax
    mov     rdi, rbx
    call    alloc
    mov     [ch_flags], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [cells], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [input_chars], rax
    mov     rbx, [row_capacity]
    inc     rbx
    lea     rdi, [rbx * 8]
    call    alloc
    mov     [row_start], rax
    lea     rdi, [rbx * 8]
    call    alloc
    mov     [row_len], rax
    lea     rdi, [rbx * 8]
    call    alloc
    mov     [line_len], rax
    pop     rbx
    ret

; new_char(rdi=packed symbol) -> eax = slot. Allocates the next character id.
new_char:
    mov     eax, [char_count]
    mov     rcx, [ch_sym]
    mov     [rcx + rax * 8], rdi
    mov     rcx, [ch_id]
    mov     edx, [next_character_id]
    mov     [rcx + rax * 4], edx
    inc     dword [next_character_id]
    mov     rcx, [ch_scene]
    mov     dword [rcx + rax * 4], NONE
    inc     dword [char_count]
    ret

; preprocess: the mini terminal emulator (input.rs preprocess), plain text.
; Registers: r12 = row, r13 = column, r14 = current row length,
; r15 = cells cursor for the current row, rbx = input cursor, rbp = input end.
preprocess:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [input_ptr]
    mov     rbp, rbx
    add     rbp, [input_len]
    xor     r12d, r12d
    xor     r13d, r13d
    xor     r14d, r14d
    mov     r15, [cells]
    mov     qword [max_row], 0
    mov     qword [max_col], 0
    mov     rax, [row_start]
    mov     qword [rax], 0
.loop:
    cmp     rbx, rbp
    jae     .end
    mov     rsi, rbx
    call    utf8_decode
    cmp     eax, 0x1b
    je      .escape
    cmp     eax, 10
    je      .newline
    cmp     eax, 13
    je      .return
    cmp     eax, 9
    je      .tab
    ; ordinary character: its UTF-8 bytes packed with the length
    mov     ecx, edx
    xor     edi, edi
.pack:
    dec     ecx
    shl     edi, 8
    movzx   eax, byte [rbx + rcx]
    or      edi, eax
    test    ecx, ecx
    jnz     .pack
    mov     eax, edx
    shl     rax, 32
    or      rdi, rax
    add     rbx, rdx
    call    put_char
    jmp     .loop
.tab:
    inc     rbx
    ; tab_width - (column % tab_width) spaces
    mov     rax, r13
    xor     edx, edx
    div     qword [cfg_tab_width]
    mov     rcx, [cfg_tab_width]
    sub     rcx, rdx
.tab_space:
    push    rcx
    mov     rdi, (1 << 32) | ' '
    call    put_char
    pop     rcx
    dec     rcx
    jnz     .tab_space
    jmp     .loop
.return:
    inc     rbx
    xor     r13d, r13d
    jmp     .loop
.newline:
    inc     rbx
    call    finish_row
    inc     r12
    xor     r13d, r13d
    cmp     r12, [max_row]
    jbe     .loop
    mov     [max_row], r12
    jmp     .loop
.end:
    call    finish_row
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    jmp     finish_lines
.escape:
    FAIL    msg_escape_unsupported

; put_char(rdi=packed symbol): write at (row r12, column r13), advance.
put_char:
    call    new_char                    ; eax = slot
    cmp     r13, r14
    jb      .overwrite
    mov     [r15 + r14 * 4], eax
    inc     r14
    jmp     .placed
.overwrite:
    mov     ecx, [r15 + r13 * 4]
    mov     rdx, [ch_flags]
    or      byte [rdx + rcx], CF_ORPHAN
    mov     [r15 + r13 * 4], eax
.placed:
    cmp     r12, [max_row]
    jbe     .col
    mov     [max_row], r12
.col:
    cmp     r13, [max_col]
    jbe     .advance
    mov     [max_col], r13
.advance:
    inc     r13
    ret

; finish_row: record the current row's length; the next row starts after it.
finish_row:
    mov     rax, [row_len]
    mov     [rax + r12 * 8], r14
    lea     r15, [r15 + r14 * 4]
    mov     rax, [row_start]
    mov     rcx, [rax + r12 * 8]
    add     rcx, r14
    mov     [rax + r12 * 8 + 8], rcx
    xor     r14d, r14d
    ret

; finish_lines: account the padding ids, trim trailing plain spaces and
; trailing empty lines, then assign bottom-up 1-based input coordinates.
finish_lines:
    push    rbx
    push    r12
    push    r13
    mov     r8, [row_len]
    mov     r9, [row_start]
    mov     r10, [line_len]
    mov     r11, [cells]
    ; padding: every missing cell of the (max_row+1) x (max_col+1) screen
    ; consumes an id, after all real characters
    xor     ebx, ebx
    xor     r12d, r12d                  ; last non-empty line + 1
.rows:
    cmp     rbx, [max_row]
    ja      .rows_done
    mov     rax, [max_col]
    inc     rax
    sub     rax, [r8 + rbx * 8]
    add     [next_character_id], eax
    ; trimmed length: drop trailing plain spaces
    mov     rcx, [r8 + rbx * 8]
    mov     rdx, [r9 + rbx * 8]
.trim:
    test    rcx, rcx
    jz      .trimmed
    lea     rax, [rdx + rcx - 1]
    mov     eax, [r11 + rax * 4]
    mov     rsi, [ch_sym]
    mov     rax, [rsi + rax * 8]
    mov     rsi, (1 << 32) | ' '
    cmp     rax, rsi
    jne     .trimmed
    dec     rcx
    jmp     .trim
.trimmed:
    mov     [r10 + rbx * 8], rcx
    test    rcx, rcx
    jz      .next_row
    lea     r12, [rbx + 1]
.next_row:
    inc     rbx
    jmp     .rows
.rows_done:
    mov     [line_count], r12
    mov     rax, [request]
    mov     [rax + RQ_LINE_COUNT], r12
    mov     rcx, [line_len]
    mov     [rax + RQ_LINE_LENGTHS], rcx
    test    r12, r12
    jz      .no_input_chars
    ; coordinates and the input character list, top row first
    xor     ebx, ebx
    xor     r13d, r13d                  ; input character count
.coord_rows:
    cmp     rbx, r12
    jae     .coords_done
    mov     rdx, [r9 + rbx * 8]
    mov     rcx, [r10 + rbx * 8]
    xor     esi, esi
.coord_cols:
    cmp     rsi, rcx
    jae     .coord_next_row
    lea     rax, [rdx + rsi]
    mov     eax, [r11 + rax * 4]        ; slot
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rax * 8]
    push    rdx
    mov     rdx, (1 << 32) | ' '
    cmp     rdi, rdx
    pop     rdx
    je      .coord_skip
    lea     edi, [esi + 1]
    mov     r8, [ch_col]
    mov     [r8 + rax * 4], edi
    mov     edi, r12d
    sub     edi, ebx
    mov     r8, [ch_row]
    mov     [r8 + rax * 4], edi
    mov     r8, [input_chars]
    mov     [r8 + r13 * 4], eax
    inc     r13
.coord_skip:
    inc     rsi
    jmp     .coord_cols
.coord_next_row:
    inc     rbx
    jmp     .coord_rows
.coords_done:
    mov     [input_count], r13
    pop     r13
    pop     r12
    pop     rbx
    ret
.no_input_chars:
    jmp     error_no_input_chars

error_no_input_chars:
    FAIL    msg_no_input_chars

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
    push    rcx
    mov     ecx, [r9 + rax * 4]
    add     ecx, edi
    mov     [r9 + rax * 4], ecx
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
    or      byte [r14 + rax], CF_INPUT
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

section .rodata
; Anchor enum order: n ne e se s sw w nw c.
; column group: 1 = S|N|C (centered), 2 = SE|E|NE (east), 0 = west
anchor_column_group:    db 1, 2, 2, 2, 1, 0, 0, 0, 1
; row group: 1 = W|E|C (centered), 2 = NW|N|NE (north), 0 = south
anchor_row_group:       db 2, 2, 1, 0, 0, 0, 1, 2, 1

STR msg_escape_unsupported, "internal: the asm engine was offered ANSI input"
STR msg_no_input_chars, "no input characters to anchor"
STR msg_all_outside, "all input characters fall outside the canvas after anchoring"


section .tstate
alignb 8
char_capacity:      resq 1
row_capacity:       resq 1
char_count:         resd 1
next_character_id:  resd 1
ch_sym:             resq 1
ch_row:             resq 1
ch_col:             resq 1
ch_id:              resq 1
ch_layer:           resq 1
ch_handle:          resq 1
ch_scene:           resq 1
ch_flags:           resq 1
cells:              resq 1
row_start:          resq 1
row_len:            resq 1
line_len:           resq 1
line_count:         resq 1
input_chars:        resq 1
input_count:        resq 1
max_row:            resq 1
max_col:            resq 1
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
