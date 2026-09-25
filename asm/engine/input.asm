; engine/input.asm - Terminal._preprocess_input_data (src/engine/input.rs):
; the mini terminal emulator that turns input text into rows of characters.
;
; The input walks codepoint by codepoint (one codepoint is one cell,
; faithfully), tracking the SGR color state and the cursor. Characters land in
; a screen map keyed by (row, column); a later write to a cell orphans the
; character that was there. Which malformed sequences are errors and which
; SGR parameters are silently ignored follows input.rs exactly, error text
; included.
;
; Slots are allocated per parsed character in Rust's arena order. The
; padding characters Rust builds for empty screen cells are never referenced,
; so only their ids are consumed.

%define SCREEN_EMPTY        0xffffffff

section .text

; input_init: parse the input into rows of character slots.
input_init:
    call    count_capacity
    call    screen_init
    call    preprocess
    call    build_lines
    jmp     finish_lines

; count_capacity: an upper bound on parsed characters (tabs expand to at most
; tab_width cells).
count_capacity:
    mov     rsi, [input_ptr]
    mov     r9, rsi
    add     r9, [input_len]
    xor     r10d, r10d
.loop:
    cmp     rsi, r9
    jae     .done
    call    utf8_decode
    add     rsi, rdx
    cmp     eax, 9
    je      .tab
    inc     r10
    jmp     .loop
.tab:
    add     r10, [cfg_tab_width]
    jmp     .loop
.done:
    add     r10, 2
    mov     [char_capacity], r10
    ret

; screen_init: an open-addressing map (row << 32 | column) -> slot, sized
; for every parsed character at half load.
screen_init:
    mov     rax, [char_capacity]
    add     rax, rax
    lzcnt   rcx, rax
    mov     eax, 1
    neg     cl
    add     cl, 64
    shl     rax, cl                     ; next power of two >= 2 * capacity
    mov     [screen_mask], rax
    dec     qword [screen_mask]
    mov     rdi, rax
    shl     rdi, 4                      ; 16 bytes: key, slot
    call    reserve
    mov     [screen], rax
    ret

; screen_slot(rdi=key) -> rax = pointer to the entry for key (empty or found).
screen_slot:
    mov     rax, rdi
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    shr     rax, 32
    mov     rdx, [screen]
.probe:
    and     rax, [screen_mask]
    mov     rcx, rax
    shl     rcx, 4
    add     rcx, rdx
    cmp     dword [rcx + 8], 0
    je      .found                      ; empty (slots are stored + 1)
    cmp     [rcx], rdi
    je      .found
    inc     rax
    jmp     .probe
.found:
    mov     rax, rcx
    ret

; preprocess: the emulator loop.
; rbx = input cursor, rbp = input end, r12 = row, r13 = column.
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
    mov     qword [max_row], 0
    mov     qword [max_col], 0
    mov     qword [sgr_fg], NONE
    mov     qword [sgr_bg], NONE
    mov     byte [sgr_bold], 0
    mov     qword [sgr_standard], NONE
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
    ; ordinary character: its packed UTF-8 bytes
    mov     edi, eax
    push    rdx
    call    utf8_pack
    pop     rdx
    add     rbx, rdx
    mov     rdi, rax
    call    put_char
    jmp     .loop
.tab:
    inc     rbx
    mov     rax, r13
    xor     edx, edx
    div     qword [cfg_tab_width]
    mov     r14, [cfg_tab_width]
    sub     r14, rdx
.tab_space:
    mov     rdi, (1 << 32) | ' '
    call    put_char
    dec     r14
    jnz     .tab_space
    jmp     .loop
.return:
    inc     rbx
    xor     r13d, r13d
    jmp     .loop
.newline:
    inc     rbx
    inc     r12
    xor     r13d, r13d
    cmp     r12, [max_row]
    jbe     .loop
    mov     [max_row], r12
    jmp     .loop
.escape:
    call    escape_sequence
    jmp     .loop
.end:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; put_char(rdi=packed symbol): build_character with the current SGR state at
; (row r12, column r13), then advance.
put_char:
    push    rdi
    mov     rdi, r12
    shl     rdi, 32
    or      rdi, r13
    call    screen_slot
    mov     r15, rax
    pop     rdi
    call    build_character             ; eax = slot
    ; the cell's previous character, if any, is orphaned
    mov     ecx, [r15 + 8]
    test    ecx, ecx
    jz      .store
    dec     ecx
    mov     rdx, [ch_flags]
    or      word [rdx + rcx * 2], CF_ORPHAN
.store:
    mov     rcx, r12
    shl     rcx, 32
    or      rcx, r13
    mov     [r15], rcx
    inc     eax
    mov     [r15 + 8], eax
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

; build_character(rdi=packed symbol) -> eax = slot. Captures the active
; colors (counting their frequency at creation, fg first), bold, and under
; --existing-color-handling always shows the input colors at once.
build_character:
    push    rbx
    xor     esi, esi
    xor     edx, edx
    call    new_char
    mov     ebx, eax
    mov     rcx, [ch_flags]
    or      word [rcx + rbx * 2], CF_PREEXISTING
    cmp     byte [sgr_bold], 0
    je      .fg
    or      word [rcx + rbx * 2], CF_BOLD
.fg:
    mov     rdi, [sgr_fg]
    cmp     rdi, NONE
    je      .bg
    mov     rax, [ch_fg]
    mov     [rax + rbx * 8], rdi
    call    count_input_color
.bg:
    mov     rdi, [sgr_bg]
    cmp     rdi, NONE
    je      .always
    mov     rax, [ch_bg]
    mov     [rax + rbx * 8], rdi
    call    count_input_color
.always:
    cmp     qword [cfg_existing_colors], 0
    jne     .done
    mov     edi, ebx
    call    reset_appearance            ; set_appearance(input symbol, uses=true)
.done:
    mov     eax, ebx
    pop     rbx
    ret

; count_input_color(rdi=color): _input_colors_frequency, insertion ordered.
; Colors are equal by their constructor argument; for input colors that is
; exactly the u64 value (xterm codes carry their code, 24-bit ones none).
count_input_color:
    mov     rax, [color_freq]
    test    rax, rax
    jnz     .search
    push    rdi
    mov     edi, 4096 * 16
    call    alloc
    mov     [color_freq], rax
    pop     rdi
.search:
    mov     rcx, [color_freq_count]
    xor     edx, edx
.next:
    cmp     rdx, rcx
    jae     .new
    mov     r8, rdx
    shl     r8, 4
    cmp     [rax + r8], rdi
    je      .found
    inc     rdx
    jmp     .next
.found:
    inc     qword [rax + r8 + 8]
    ret
.new:
    cmp     rcx, 4096
    jae     .full
    mov     r8, rcx
    shl     r8, 4
    mov     [rax + r8], rdi
    mov     qword [rax + r8 + 8], 1
    inc     qword [color_freq_count]
    ret
.full:
    lea     rdi, [msg_too_many_colors]
    mov     esi, msg_too_many_colors_len
    jmp     fatal

; ------------------------------------------------------------ escapes

; escape_sequence: rbx at an ESC. match_escape_sequence's alternation (OSC,
; CSI, then ESC + any character but newline), then SGR, the four supported
; private modes, or cursor movement. Advances rbx past the sequence.
escape_sequence:
    lea     rsi, [rbx + 1]
    cmp     rsi, rbp
    jae     .lone_escape
    cmp     byte [rsi], ']'
    jne     .csi
    ; OSC: the first BEL after "ESC ]" ends it ...
    lea     rcx, [rbx + 2]
.bel:
    cmp     rcx, rbp
    jae     .no_bel
    cmp     byte [rcx], 7
    je      .osc_bel
    inc     rcx
    jmp     .bel
.osc_bel:
    lea     rdx, [rcx + 1]
    jmp     unsupported_sequence
.no_bel:
    ; ... else the rightmost "ESC \" at or after the run start
    mov     rcx, rbp
.st:
    lea     rax, [rbx + 4]
    cmp     rcx, rax
    jb      .csi
    cmp     byte [rcx - 2], 0x1b
    jne     .st_next
    cmp     byte [rcx - 1], '\'
    jne     .st_next
    mov     rdx, rcx
    jmp     unsupported_sequence
.st_next:
    dec     rcx
    jmp     .st
.csi:
    cmp     byte [rsi], '['
    jne     .any
    lea     rcx, [rbx + 2]
.params:
    cmp     rcx, rbp
    jae     .any
    movzx   eax, byte [rcx]
    sub     eax, 0x30
    cmp     eax, 0x0f
    ja      .inter
    inc     rcx
    jmp     .params
.inter:
    mov     r8, rcx                     ; end of the parameters
.inter_next:
    cmp     rcx, rbp
    jae     .any
    movzx   eax, byte [rcx]
    sub     eax, 0x20
    cmp     eax, 0x0f
    ja      .final
    inc     rcx
    jmp     .inter_next
.final:
    movzx   eax, byte [rcx]
    sub     eax, 0x40
    cmp     eax, 0x3e
    ja      .any
    lea     rdx, [rcx + 1]              ; end of the sequence
    jmp     csi_sequence
.any:
    ; ESC and any one character but a newline
    cmp     byte [rsi], 10
    je      .lone_escape
    push    rsi
    call    utf8_decode
    pop     rsi
    lea     rdx, [rsi + rdx]
    ; "ESC [" alone is not a well-formed CSI sequence either
    jmp     unsupported_sequence
.lone_escape:
    lea     rdx, [rbx + 1]
    jmp     unsupported_sequence

; unsupported_sequence(rbx=start, rdx=end): UnsupportedAnsiSequence(bytes).
unsupported_sequence:
    mov     rax, [request]
    mov     [rax + RQ_ERROR_PTR], rbx
    sub     rdx, rbx
    mov     [rax + RQ_ERROR_LEN], rdx
    mov     qword [rax + RQ_ERROR_KIND], ERR_ANSI
    mov     rsp, [fail_rsp]
    mov     eax, OUT_ERROR
    jmp     ttfx_asm_run.return

; csi_sequence(rbx=ESC, r8=end of parameters, rcx=final byte, rdx=end).
csi_sequence:
    push    rdx
    push    rcx
    push    r8
    cmp     byte [rcx], 'm'
    je      .sgr
    ; the four supported private modes (cursor show/hide, autowrap on/off)
    ; are ignored: exactly ESC [ ? 2 5 h|l or ESC [ ? 7 h|l
    mov     rax, rdx
    sub     rax, rbx
    cmp     rax, 6
    je      .private25
    cmp     rax, 5
    jne     .cursor
    cmp     dword [rbx], 0x373f5b1b     ; ESC [ ? 7
    jne     .cursor
    movzx   eax, byte [rbx + 4]
    jmp     .private_final
.private25:
    cmp     dword [rbx], 0x323f5b1b     ; ESC [ ? 2
    jne     .cursor
    cmp     byte [rbx + 4], '5'
    jne     .cursor
    movzx   eax, byte [rbx + 5]
.private_final:
    cmp     eax, 'h'
    je      .ignored
    cmp     eax, 'l'
    je      .ignored
    jmp     .cursor
.ignored:
    pop     r8
    pop     rcx
    pop     rbx                         ; continue after the sequence
    ret
.sgr:
    call    parse_parameters            ; errors on anything but digits/;
    call    apply_sgr
    pop     r8
    pop     rcx
    pop     rbx
    ret
.cursor:
    ; intermediates or a private marker make it unsupported
    mov     r8, [rsp]
    mov     rcx, [rsp + 8]
    cmp     r8, rcx
    jne     .unsupported
    cmp     byte [rbx + 2], '?'
    je      .unsupported
    call    parse_parameters
    mov     rcx, [rsp + 8]
    movzx   eax, byte [rcx]
    call    apply_cursor
    jc      .unsupported
    pop     r8
    pop     rcx
    pop     rbx
    ret
.unsupported:
    mov     rdx, [rsp + 16]
    jmp     unsupported_sequence

; parse_parameters(rbx=ESC, r8=end of parameters) -> params[]/param_count.
; parse_csi_parameters: only digits and ';' (else UnsupportedAnsiSequence
; of "ESC [ <parameters>"); empty fields are 0.
parse_parameters:
    lea     rsi, [rbx + 2]
    mov     qword [param_count], 0
    cmp     rsi, r8
    je      .done
    xor     eax, eax                    ; current value
.char:
    cmp     rsi, r8
    jae     .last
    movzx   ecx, byte [rsi]
    cmp     ecx, ';'
    je      .field
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .bad
    imul    rax, rax, 10
    add     rax, rcx
    inc     rsi
    jmp     .char
.field:
    call    .push
    xor     eax, eax
    inc     rsi
    jmp     .char
.last:
    call    .push
.done:
    ret
.push:
    mov     rcx, [param_count]
    cmp     rcx, 256
    jae     .too_many
    lea     rdx, [params]
    mov     [rdx + rcx * 8], rax
    inc     qword [param_count]
    ret
.too_many:
    lea     rdi, [msg_too_many_params]
    mov     esi, msg_too_many_params_len
    jmp     fatal
.bad:
    add     rsp, 8                      ; leave parse_parameters' frame ...
    mov     rdx, r8                     ; ... reporting "ESC [ <parameters>"
    jmp     unsupported_sequence

; apply_sgr(rbx=ESC, [rsp+16]=end) - Preprocessor.apply_sgr_sequence.
apply_sgr:
    push    r12
    push    r13
    cmp     qword [param_count], 0
    jne     .loop_start
    mov     qword [params], 0
    mov     qword [param_count], 1
.loop_start:
    xor     r12d, r12d                  ; idx
.next:
    cmp     r12, [param_count]
    jae     .done
    lea     rax, [params]
    mov     r13, [rax + r12 * 8]
    test    r13, r13
    jz      .reset
    cmp     r13, 1
    je      .bold
    cmp     r13, 22
    je      .unbold
    cmp     r13, 39
    je      .fg_reset
    cmp     r13, 49
    je      .bg_reset
    lea     rax, [r13 - 30]
    cmp     rax, 7
    jbe     .fg_standard
    lea     rax, [r13 - 90]
    cmp     rax, 7
    jbe     .fg_bright
    lea     rax, [r13 - 40]
    cmp     rax, 7
    jbe     .bg_standard
    lea     rax, [r13 - 100]
    cmp     rax, 7
    jbe     .bg_bright
    cmp     r13, 38
    je      .extended
    cmp     r13, 48
    je      .extended
    jmp     .advance                    ; anything else is silently ignored
.reset:
    mov     qword [sgr_fg], NONE
    mov     qword [sgr_bg], NONE
    mov     byte [sgr_bold], 0
    mov     qword [sgr_standard], NONE
    jmp     .advance
.bold:
    mov     byte [sgr_bold], 1
    mov     rax, [sgr_standard]
    cmp     rax, NONE
    je      .advance
    sub     rax, 30 - 8
    call    xterm_input_color
    mov     [sgr_fg], rax
    jmp     .advance
.unbold:
    mov     byte [sgr_bold], 0
    mov     rax, [sgr_standard]
    cmp     rax, NONE
    je      .advance
    sub     rax, 30
    call    xterm_input_color
    mov     [sgr_fg], rax
    jmp     .advance
.fg_reset:
    mov     qword [sgr_fg], NONE
    mov     qword [sgr_standard], NONE
    jmp     .advance
.bg_reset:
    mov     qword [sgr_bg], NONE
    jmp     .advance
.fg_standard:
    cmp     byte [sgr_bold], 0
    je      .fg_plain
    add     rax, 8
.fg_plain:
    call    xterm_input_color
    mov     [sgr_fg], rax
    mov     [sgr_standard], r13
    jmp     .advance
.fg_bright:
    add     rax, 8
    call    xterm_input_color
    mov     [sgr_fg], rax
    mov     qword [sgr_standard], NONE
    jmp     .advance
.bg_standard:
    call    xterm_input_color
    mov     [sgr_bg], rax
    jmp     .advance
.bg_bright:
    add     rax, 8
    call    xterm_input_color
    mov     [sgr_bg], rax
    jmp     .advance
.extended:
    ; 38/48 ; 5 ; code  or  38/48 ; 2 ; r ; g ; b
    lea     rax, [r12 + 1]
    cmp     rax, [param_count]
    jae     .unsupported
    lea     rcx, [params]
    mov     rax, [rcx + r12 * 8 + 8]
    cmp     rax, 5
    je      .indexed
    cmp     rax, 2
    je      .truecolor
    jmp     .unsupported
.indexed:
    lea     rax, [r12 + 2]
    cmp     rax, [param_count]
    jae     .unsupported
    mov     rax, [rcx + r12 * 8 + 16]
    call    xterm_input_color
    add     r12, 2
    jmp     .store_extended
.truecolor:
    lea     rax, [r12 + 4]
    cmp     rax, [param_count]
    jae     .unsupported
    lea     rdi, [rcx + r12 * 8 + 16]
    call    hex_input_color
    add     r12, 4
.store_extended:
    cmp     r13, 38
    jne     .store_bg
    mov     [sgr_fg], rax
    mov     qword [sgr_standard], NONE
    jmp     .advance
.store_bg:
    mov     [sgr_bg], rax
.advance:
    inc     r12
    jmp     .next
.done:
    pop     r13
    pop     r12
    ret
.unsupported:
    ; UnsupportedAnsiSequence(the whole sequence): its end is csi_sequence's
    ; saved rdx, past our two pushes and the return address
    mov     rdx, [rsp + 16 + 8 + 16]
    jmp     unsupported_sequence

; xterm_input_color(rax=code) -> rax = Color::from_xterm(code); codes outside
; 0..=255 are an error ("invalid xterm color code in input: N").
xterm_input_color:
    cmp     rax, 255
    ja      .bad
    mov     rcx, rax
    lea     rdx, [xterm_rgb]
    mov     eax, [rdx + rcx * 4]
    shl     rcx, 32
    or      rax, rcx
    bts     rax, COLOR_XTERM_BIT
    ret
.bad:
    mov     rsi, rax
    lea     rdi, [msg_bad_xterm_code]
    mov     edx, msg_bad_xterm_code_len
    jmp     fail_with_number

; hex_input_color(rdi=three params) -> rax. The 24-bit path formats each
; channel as {:02X} and parses the result with Color::from_hex, faithfully:
; channels over 255 widen the hex string; 7 digits still parse (first six
; used), anything else is an invalid color.
hex_input_color:
    xor     eax, eax                    ; digits so far
    xor     edx, edx                    ; first six digits as a number
    xor     r9d, r9d                    ; channel
.channel:
    cmp     r9d, 3
    jae     .check
    mov     r10, [rdi + r9 * 8]
    ; digits of the channel in hex, at least two
    mov     rcx, r10
    mov     r11d, 1
.width:
    shr     rcx, 4
    jz      .widthed
    inc     r11d
    jmp     .width
.widthed:
    cmp     r11d, 2
    jae     .emit
    mov     r11d, 2
.emit:
    ; append r11 digits of r10, most significant first
    lea     ecx, [r11 * 4 - 4]
.digit:
    mov     r8, r10
    shr     r8, cl
    and     r8d, 15
    cmp     eax, 6
    jae     .skip
    shl     rdx, 4
    or      rdx, r8
.skip:
    inc     eax
    sub     ecx, 4
    jns     .digit
    inc     r9d
    jmp     .channel
.check:
    cmp     eax, 6
    je      .ok
    cmp     eax, 7
    je      .ok
    lea     rdi, [msg_invalid_color]
    mov     esi, msg_invalid_color_len
    jmp     engine_fail
.ok:
    mov     rax, rdx
    ret

; apply_cursor(eax=final byte) -> CF set when the final is unsupported.
; apply_cursor_sequence, clamping the cursor at 0 and extending max_row/col.
apply_cursor:
    ; default_parameter: the first parameter or 1, at least 1
    mov     ecx, 1
    cmp     qword [param_count], 0
    je      .default
    mov     rcx, [params]
    cmp     rcx, 1
    jge     .default
    mov     ecx, 1
.default:
    cmp     eax, 'A'
    je      .up
    cmp     eax, 'B'
    je      .down
    cmp     eax, 'C'
    je      .right
    cmp     eax, 'D'
    je      .left
    cmp     eax, 'E'
    je      .next_line
    cmp     eax, 'F'
    je      .previous_line
    cmp     eax, 'G'
    je      .column
    cmp     eax, 'H'
    je      .position
    cmp     eax, 'f'
    je      .position
    stc
    ret
.up:
    sub     r12, rcx
    jmp     .clamp
.down:
    add     r12, rcx
    jmp     .clamp
.right:
    add     r13, rcx
    jmp     .clamp
.left:
    sub     r13, rcx
    jmp     .clamp
.next_line:
    add     r12, rcx
    xor     r13d, r13d
    jmp     .clamp
.previous_line:
    sub     r12, rcx
    xor     r13d, r13d
    jmp     .clamp
.column:
    lea     r13, [rcx - 1]
    jmp     .clamp
.position:
    lea     r12, [rcx - 1]
    xor     r13d, r13d
    cmp     qword [param_count], 2
    jb      .clamp
    mov     rax, [params + 8]
    test    rax, rax
    jz      .clamp
    lea     r13, [rax - 1]
.clamp:
    xor     eax, eax
    test    r12, r12
    cmovs   r12, rax
    test    r13, r13
    cmovs   r13, rax
    cmp     r12, [max_row]
    jbe     .max_col
    mov     [max_row], r12
.max_col:
    cmp     r13, [max_col]
    jbe     .ok
    mov     [max_col], r13
.ok:
    clc
    ret

; ------------------------------------------------------------ lines

; build_lines: every screen cell of (max_row + 1) x (max_col + 1), row-major:
; the character written there, or padding (an id, but no slot).
build_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, [max_row]
    inc     rbx
    lea     rdi, [rbx * 8 + 64]
    call    alloc
    mov     [row_start], rax
    lea     rdi, [rbx * 8 + 64]
    call    alloc
    mov     [row_len], rax
    lea     rdi, [rbx * 8 + 64]
    call    alloc
    mov     [line_len], rax
    mov     r14, [max_col]
    inc     r14                         ; row width
    mov     rdi, rbx
    imul    rdi, r14
    lea     rdi, [rdi * 4 + 64]
    call    reserve
    mov     [cells], rax
    xor     r12d, r12d                  ; row
.row:
    cmp     r12, rbx
    jae     .done
    mov     rax, r12
    imul    rax, r14
    mov     rcx, [row_start]
    mov     [rcx + r12 * 8], rax
    mov     rcx, [row_len]
    mov     [rcx + r12 * 8], r14
    xor     r13d, r13d                  ; column
.column:
    cmp     r13, r14
    jae     .next_row
    mov     rdi, r12
    shl     rdi, 32
    or      rdi, r13
    call    screen_slot
    mov     ecx, [rax + 8]
    dec     ecx                         ; NONE for padding
    cmp     ecx, NONE
    jne     .cell
    inc     dword [next_character_id]   ; padding consumes an id
.cell:
    mov     rax, r12
    imul    rax, r14
    add     rax, r13
    mov     rdx, [cells]
    mov     [rdx + rax * 4], ecx
    inc     r13
    jmp     .column
.next_row:
    inc     r12
    jmp     .row
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; is_plain_space(ecx=slot or NONE) -> ZF set for padding or an uncolored " ".
is_plain_space:
    cmp     ecx, NONE
    je      .yes
    mov     rax, [ch_sym]
    mov     rax, [rax + rcx * 8]
    mov     rdx, (1 << 32) | ' '
    cmp     rax, rdx
    jne     .no
    mov     rax, [ch_fg]
    cmp     qword [rax + rcx * 8], NONE
    jne     .no
    mov     rax, [ch_bg]
    cmp     qword [rax + rcx * 8], NONE
.no:
    ret
.yes:
    cmp     ecx, ecx
    ret

; finish_lines: trim trailing plain spaces and trailing empty lines, assign
; bottom-up 1-based input coordinates, and collect the input characters
; (anything but a plain space). With nothing left, the fallback character
; carries the end-of-input SGR state, faithfully.
finish_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r13, [max_row]
    inc     r13                         ; rows
    xor     ebx, ebx
    xor     r12d, r12d                  ; last non-empty row + 1
.rows:
    cmp     rbx, r13
    jae     .rows_done
    mov     rax, [row_len]
    mov     r14, [rax + rbx * 8]
    mov     rax, [row_start]
    mov     r8, [rax + rbx * 8]
.trim:
    test    r14, r14
    jz      .trimmed
    lea     rax, [r8 + r14 - 1]
    mov     rdx, [cells]
    mov     ecx, [rdx + rax * 4]
    call    is_plain_space
    jne     .trimmed
    dec     r14
    jmp     .trim
.trimmed:
    mov     rax, [line_len]
    mov     [rax + rbx * 8], r14
    test    r14, r14
    jz      .next_row
    lea     r12, [rbx + 1]
.next_row:
    inc     rbx
    jmp     .rows
.rows_done:
    test    r12, r12
    jnz     .have_lines
    ; no lines: one space with the end-of-input state
    mov     rdi, (1 << 32) | ' '
    call    build_character
    mov     rdx, [cells]
    mov     [rdx], eax
    mov     rax, [row_start]
    mov     qword [rax], 0
    mov     rax, [line_len]
    mov     qword [rax], 1
    mov     r12d, 1
.have_lines:
    mov     [line_count], r12
    mov     rax, [request]
    mov     [rax + RQ_LINE_COUNT], r12
    mov     rcx, [line_len]
    mov     [rax + RQ_LINE_LENGTHS], rcx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; wrapped_line_count(rdi=width) -> rax: formatted rows after wrapping every
; line at width (wrapped_line_count / wrap_lines): a line longer than the
; width splits into width-sized pieces; an empty line stays one row.
wrapped_line_count:
    xor     eax, eax
    xor     ecx, ecx
.line:
    cmp     rcx, [line_count]
    jae     .done
    mov     rdx, [line_len]
    mov     rdx, [rdx + rcx * 8]
.split:
    cmp     rdx, rdi
    jle     .last
    inc     rax
    sub     rdx, rdi
    jmp     .split
.last:
    inc     rax
    inc     rcx
    jmp     .line
.done:
    ret

; assign_coordinates: Terminal._setup_input_characters - wrap the lines at
; the canvas width under --wrap-text, give every character of the formatted
; lines a bottom-up 1-based input coordinate, and collect the input
; characters (anything but a plain space), top row first.
assign_coordinates:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    ; the formatted height
    mov     r15, [line_count]
    cmp     byte [cfg_wrap_text], 0
    je      .height
    mov     rdi, [canvas_right]
    call    wrapped_line_count
    mov     r15, rax
.height:
    mov     edi, [char_count]
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     [input_chars], rax
    xor     r14d, r14d                  ; input count
    xor     r12d, r12d                  ; formatted row index
    xor     ebx, ebx                    ; line
.line:
    cmp     rbx, [line_count]
    jae     .collected
    mov     rax, [row_start]
    mov     rbp, [rax + rbx * 8]        ; first cell of the line
    mov     rax, [line_len]
    mov     r13, [rax + rbx * 8]        ; cells left in the line
.piece:
    ; one formatted row: the whole rest, or a width-sized piece of it
    mov     r9, r13
    cmp     byte [cfg_wrap_text], 0
    je      .row
    cmp     r13, [canvas_right]
    jle     .row
    mov     r9, [canvas_right]
.row:
    xor     esi, esi
.cell:
    cmp     rsi, r9
    jae     .row_done
    lea     rax, [rbp + rsi]
    mov     rdx, [cells]
    mov     ecx, [rdx + rax * 4]
    push    rsi
    push    r9
    call    is_plain_space
    pop     r9
    pop     rsi
    je      .skip
    lea     edi, [esi + 1]
    mov     rax, [ch_col]
    mov     [rax + rcx * 4], edi
    mov     rax, [ch_icol]
    mov     [rax + rcx * 4], edi
    mov     edi, r15d
    sub     edi, r12d
    mov     rax, [ch_row]
    mov     [rax + rcx * 4], edi
    mov     rax, [ch_irow]
    mov     [rax + rcx * 4], edi
    mov     rax, [input_chars]
    mov     [rax + r14 * 4], ecx
    inc     r14
.skip:
    inc     rsi
    jmp     .cell
.row_done:
    inc     r12
    add     rbp, r9
    sub     r13, r9
    jnz     .piece                      ; more of this line to wrap
    inc     rbx
    jmp     .line
.collected:
    mov     [input_count], r14
    ; preexisting_colors_present: any input character with a color
    xor     ebx, ebx
.present:
    cmp     rbx, r14
    jae     .done
    mov     rax, [input_chars]
    mov     ecx, [rax + rbx * 4]
    mov     rax, [ch_fg]
    cmp     qword [rax + rcx * 8], NONE
    jne     .colored
    mov     rax, [ch_bg]
    cmp     qword [rax + rcx * 8], NONE
    jne     .colored
    inc     rbx
    jmp     .present
.colored:
    mov     byte [preexisting_colors_present], 1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

error_no_input_chars:
    FAIL    msg_no_input_chars

; get_input_colors(edi=COLOR_SORT_*) -> rax = u64 colors, rdx = count.
; Terminal.get_input_colors: most/least frequent first (stable, so ties keep
; insertion order), or shuffled with the engine RNG.
%define COLOR_SORT_LEAST_TO_MOST    0
%define COLOR_SORT_MOST_TO_LEAST    1
%define COLOR_SORT_RANDOM           2
get_input_colors:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, [color_freq_count]
    ; (count key, color) pairs; most-to-least sorts by the negated count
    mov     rdi, r12
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     r13, rax
    xor     ecx, ecx
.pair:
    cmp     rcx, r12
    jae     .sort
    mov     rdx, rcx
    shl     rdx, 4
    add     rdx, [color_freq]
    mov     rax, [rdx + 8]              ; count
    cmp     ebx, COLOR_SORT_MOST_TO_LEAST
    jne     .key
    neg     rax
.key:
    mov     r8, 0x8000000000000000
    add     rax, r8
    mov     r8, rcx
    shl     r8, 4
    mov     [r13 + r8], rax
    mov     rax, [rdx]
    mov     [r13 + r8 + 8], rax
    inc     rcx
    jmp     .pair
.sort:
    cmp     ebx, COLOR_SORT_RANDOM
    je      .colors
    mov     rdi, r13
    mov     rsi, r12
    call    sort_pairs
.colors:
    lea     rdi, [r12 * 8 + 64]
    call    alloc
    xor     ecx, ecx
.copy:
    cmp     rcx, r12
    jae     .shuffle
    mov     rdx, rcx
    shl     rdx, 4
    mov     rdx, [r13 + rdx + 8]
    mov     [rax + rcx * 8], rdx
    inc     rcx
    jmp     .copy
.shuffle:
    cmp     ebx, COLOR_SORT_RANDOM
    jne     .done
    push    rax
    mov     rdi, rax
    mov     rsi, r12
    call    rng_shuffle64
    pop     rax
.done:
    mov     rdx, r12
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
STR msg_no_input_chars, "no input characters to anchor"
STR msg_bad_xterm_code, "invalid xterm color code in input: "
STR msg_invalid_color, "Invalid color value. Color must be an XTerm-256 color code or an RGB hex color string. Example: 255 or 'ffffff' or '#ffffff'"
STR msg_too_many_colors, "ttfx: asm engine: too many distinct input colors", 10
STR msg_too_many_params, "ttfx: asm engine: too many SGR parameters", 10

section .tstate
alignb 8
char_capacity:      resq 1
cells:              resq 1
row_start:          resq 1
row_len:            resq 1
line_len:           resq 1
line_count:         resq 1
input_chars:        resq 1
input_count:        resq 1
max_row:            resq 1
max_col:            resq 1
screen:             resq 1
screen_mask:        resq 1
sgr_fg:             resq 1
sgr_bg:             resq 1
sgr_standard:       resq 1
color_freq:         resq 1
color_freq_count:   resq 1
param_count:        resq 1
params:             resq 256
sgr_bold:           resb 1
preexisting_colors_present: resb 1
