; engine/input.asm - Terminal._preprocess_input_data (src/engine/input.rs):
; the mini terminal emulator that turns input text into rows of characters.
;
; This version covers plain text: tabs, \r and \n. Rust declines input
; containing ESC until the ANSI part is ported.

section .text

; input_init: parse the input into lines of character slots.
input_init:
    call    count_capacity
    call    alloc_rows
    jmp     preprocess

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

; alloc_rows: scratch arrays for parsing, sized by count_capacity.
alloc_rows:
    push    rbx
    mov     rbx, [char_capacity]
    inc     rbx
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
    xor     esi, esi
    xor     edx, edx
    call    new_char                    ; eax = slot
    mov     rcx, [ch_flags]
    or      word [rcx + rax * 2], CF_PREEXISTING
    cmp     r13, r14
    jb      .overwrite
    mov     [r15 + r14 * 4], eax
    inc     r14
    jmp     .placed
.overwrite:
    mov     ecx, [r15 + r13 * 4]
    mov     rdx, [ch_flags]
    or      word [rdx + rcx * 2], CF_ORPHAN
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
    mov     r8, [ch_icol]
    mov     [r8 + rax * 4], edi
    mov     edi, r12d
    sub     edi, ebx
    mov     r8, [ch_row]
    mov     [r8 + rax * 4], edi
    mov     r8, [ch_irow]
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


section .rodata
STR msg_escape_unsupported, "internal: the asm engine was offered ANSI input"
STR msg_no_input_chars, "no input characters to anchor"

section .tstate
alignb 8
char_capacity:      resq 1
row_capacity:       resq 1
cells:              resq 1
row_start:          resq 1
row_len:            resq 1
line_len:           resq 1
line_count:         resq 1
input_chars:        resq 1
input_count:        resq 1
max_row:            resq 1
max_col:            resq 1
