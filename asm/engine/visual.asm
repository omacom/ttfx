; engine/visual.asm - the visual pool (plan §7.5).
;
; A CharacterVisual is formatted once - SGR prefix, symbol, reset - and
; interned into a de-duplicated pool. A visual is then a u32 handle: the
; offset of its bytes (low 24 bits) and their length (high 8). The renderer
; never formats, allocates or refcounts; a cell is one bounded copy.
;
; Each pooled visual is preceded by a 32-byte header holding what the visual
; *is*, for effects that read it back (CharacterVisual.symbol, .colors):
;   -32 symbol (packed)   -24 fg color   -16 bg color   -8 attribute bits
; The colors are the logical ones even under --no-color, where the bytes
; carry none. The header is the interning key: it determines the bytes.
;
; Every pooled visual is readable for 128 bytes from its start (the pool keeps
; that much slack), so copies may overrun their length without leaving it.

%define VISUAL_MAX          128         ; longest visual the pool accepts
%define VISUAL_HEADER       32
%define POOL_RESERVE        (POOL_LIMIT + 4096)
%define VISUAL_TABLE_INITIAL (1 << 12)  ; entries; the arena is lazily committed

; header fields, relative to the visual's bytes
%define VH_SYMBOL           -32
%define VH_FG               -24
%define VH_BG               -16
%define VH_ATTRS            -8

; attribute bits (VisualParams / format_symbol_into order); dim is stored
; upstream but never emitted, so it has no bit
%define ATTR_BOLD           1
%define ATTR_ITALIC         2
%define ATTR_UNDERLINE      4
%define ATTR_BLINK          8
%define ATTR_REVERSE        16
%define ATTR_HIDDEN         32
%define ATTR_STRIKE         64

section .text

; visual_init: reserve the pool and table, and make the blank cell.
visual_init:
    mov     rdi, POOL_RESERVE
    call    reserve
    mov     [pool_base], rax
    mov     ecx, VISUAL_TABLE_INITIAL
    call    visual_table_alloc
    mov     rdi, NONE
    mov     rsi, NONE
    mov     rdx, (1 << 32) | ' '
    xor     ecx, ecx
    call    visual_make
    mov     [space_handle], eax
    ret

; visual_table_alloc(ecx=capacity): fresh zeroed table of ecx entries. An
; entry is the handle in the low half and its hash in the high half (0 =
; empty; handles are never 0), so probes and growth rarely touch the pool.
visual_table_alloc:
    push    rcx
    lea     rdi, [rcx * 8]
    call    alloc
    pop     rcx
    mov     [table_base], rax
    dec     ecx
    mov     [table_mask], ecx
    ret

; VISUAL_HASH sym, fg, bg, attrs, out, tmp: a 32-bit hash of a visual's
; header (four 64-bit registers, left intact) into the 64-bit register out.
; Only the table's probe order depends on it, never a handle, so any mix
; that is consistent within one build will do. Scalar, so every tier.
%macro VISUAL_HASH 6
    mov     %6, 0x9e3779b97f4a7c15
    mov     %5, %2
    imul    %5, %6
    xor     %5, %1
    ror     %5, 29
    add     %5, %3
    imul    %5, %6
    xor     %5, %4
    ror     %5, 31
    imul    %5, %6
    shr     %5, 32
%endmacro

; visual_make(rdi=fg color or NONE, rsi=bg color or NONE, rdx=packed symbol,
;             ecx=ATTR_* bits) -> eax = handle.
; CharacterVisual::new + format_symbol_into: bold, italic, underline, blink,
; reverse, hidden, strike, fg, bg, symbol, then a reset only if anything
; preceded it. Colors are dropped from the bytes under --no-color
; (resolve_color_code) but kept in the header. Under --xterm-colors a color
; renders as its own code when it has one, else the nearest by hex_to_xterm.
;
; The bytes are a function of the header (the color flags are fixed for a
; run), so the header alone is the interning key: a visual seen before is
; found without formatting it, and a new one is formatted straight into
; the pool. Handles are pool offsets in first-seen order, as before.
; Clobbers rax, rcx, rdx, rsi, rdi, r8-r11 (and zmm0-zmm7, k1-k2 when
; hex_to_xterm runs).
visual_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15d, ecx
    VISUAL_HASH r14, r12, r13, r15, rbp, rax
    mov     r10, [table_base]
    mov     r11, [pool_base]
    mov     r9d, [table_mask]
    mov     r8, rbp
    shl     r8, 32                      ; the entry's tag
    mov     edx, ebp                    ; probe index
.next:
    and     edx, r9d
    mov     rax, [r10 + rdx * 8]
    test    rax, rax
    jz      .new
    mov     rcx, rax
    xor     rcx, r8
    shr     rcx, 32
    jnz     .skip                       ; another hash
    mov     ecx, eax
    and     ecx, HANDLE_OFFSET_MASK
    cmp     r14, [r11 + rcx + VH_SYMBOL]
    jne     .skip
    cmp     r12, [r11 + rcx + VH_FG]
    jne     .skip
    cmp     r13, [r11 + rcx + VH_BG]
    jne     .skip
    cmp     r15, [r11 + rcx + VH_ATTRS]
    je      .found
.skip:
    inc     edx
    jmp     .next
.found:
    mov     eax, eax
    jmp     .done
.new:
    shl     rbp, 32
    or      rbp, rdx                    ; hash << 32 | slot
    ; format at the pool's end: the header, then the bytes. POOL_RESERVE's
    ; slack past POOL_LIMIT covers a visual written before the limit check.
    mov     ecx, [pool_len]
    lea     rbx, [r11 + rcx]
    mov     [rbx], r14
    mov     [rbx + 8], r12
    mov     [rbx + 16], r13
    mov     [rbx + 24], r15
    add     rbx, VISUAL_HEADER          ; write cursor
    cmp     byte [cfg_no_color], 0
    je      .attrs
    mov     r12, NONE
    mov     r13, NONE
.attrs:
    lea     r8, [sgr_attr_codes]
    xor     r9d, r9d
.attr:
    bt      r15d, r9d
    jnc     .attr_next
    mov     dword [rbx], 0x6d305b1b     ; "\x1b[0m", digit patched below
    mov     al, [r8 + r9]
    mov     [rbx + 2], al
    add     rbx, 4
.attr_next:
    inc     r9d
    cmp     r9d, 7
    jb      .attr
    cmp     r12, NONE
    je      .no_fg
    mov     rdi, r12
    mov     esi, '3'
    call    sgr_color
.no_fg:
    cmp     r13, NONE
    je      .no_bg
    mov     rdi, r13
    mov     esi, '4'
    call    sgr_color
.no_bg:
    mov     rax, r14
    shr     rax, 32
    movzx   ecx, al                     ; symbol byte length
    mov     [rbx], r14d
    mov     edx, [pool_len]
    add     rdx, [pool_base]
    lea     rdx, [rdx + VISUAL_HEADER]  ; the bytes' start
    mov     rdi, rbx
    sub     rdi, rdx                    ; prefix length
    add     rbx, rcx
    test    rdi, rdi
    jz      .plain
    mov     dword [rbx], 0x6d305b1b     ; "\x1b[0m"
    add     rbx, 4
.plain:
    mov     dword [rbx], 0              ; clear symbol bytes past its length
    mov     rsi, rbx
    sub     rsi, rdx                    ; byte length
    cmp     esi, VISUAL_MAX
    ja      .too_long
    mov     ecx, [pool_len]
    lea     eax, [rcx + VISUAL_HEADER]
    lea     ecx, [rcx + rsi + VISUAL_HEADER]
    cmp     ecx, POOL_LIMIT
    jae     .full
    mov     [pool_len], ecx
    shl     esi, HANDLE_LEN_SHIFT
    or      eax, esi
    mov     rcx, rbp
    shr     rcx, 32
    shl     rcx, 32
    or      rcx, rax
    mov     rdx, [table_base]
    mov     esi, ebp
    mov     [rdx + rsi * 8], rcx
    inc     dword [table_count]
    mov     ecx, [table_count]
    add     ecx, ecx
    cmp     ecx, [table_mask]
    jbe     .done
    push    rax
    push    rax
    call    visual_table_grow
    pop     rax
    pop     rax
.done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.too_long:
    lea     rdi, [msg_visual_long]
    mov     esi, msg_visual_long_len
    jmp     fatal
.full:
    lea     rdi, [msg_pool_full]
    mov     esi, msg_pool_full_len
    jmp     fatal

; visual_table_grow: double the table and reinsert every entry at its
; stored hash. Clobbers rax, rcx, rdx, rsi, rdi, r8-r11.
visual_table_grow:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, [table_base]
    mov     r13d, [table_mask]
    inc     r13d                        ; old capacity
    lea     ecx, [r13 * 2]
    call    visual_table_alloc
    mov     r14, [table_base]
    mov     r10d, [table_mask]
    xor     ebx, ebx
.each:
    cmp     ebx, r13d
    jae     .finish
    mov     r11, [r12 + rbx * 8]
    test    r11, r11
    jz      .skip
    mov     rax, r11
    shr     rax, 32
.probe:
    and     eax, r10d
    cmp     qword [r14 + rax * 8], 0
    je      .put
    inc     eax
    jmp     .probe
.put:
    mov     [r14 + rax * 8], r11
.skip:
    inc     ebx
    jmp     .each
.finish:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; visual_meta(eax=handle) -> rax = pointer to the visual's bytes; the header
; fields are at negative offsets (VH_*).
visual_meta:
    and     eax, HANDLE_OFFSET_MASK
    add     rax, [pool_base]
    ret

; sgr_color(rdi=color, esi='3' fg or '4' bg): append the SGR sequence at rbx:
; "\x1b[38;2;R;G;Bm", or "\x1b[38;5;Nm" under --xterm-colors.
sgr_color:
    cmp     byte [cfg_xterm_colors], 0
    je      sgr_rgb
    push    rsi
    bt      rdi, COLOR_XTERM_BIT
    jnc     .nearest
    mov     rax, rdi
    shr     rax, 32
    movzx   eax, al
    jmp     .code
.nearest:
    push    rbx
    call    hex_to_xterm
    pop     rbx
.code:
    pop     rsi
    mov     byte [rbx], 0x1b
    mov     byte [rbx + 1], '['
    mov     [rbx + 2], sil
    mov     dword [rbx + 3], 0x3b353b38 ; "8;5;"
    add     rbx, 7
    lea     r8, [dec3_table]
    mov     ecx, eax
    call    sgr_rgb.channel
    mov     byte [rbx], 'm'
    inc     rbx
    ret

; sgr_rgb(edi=rgb, esi='3' fg or '4' bg): append "\x1b[38;2;R;G;Bm" at rbx.
sgr_rgb:
    mov     byte [rbx], 0x1b
    mov     byte [rbx + 1], '['
    mov     [rbx + 2], sil
    mov     dword [rbx + 3], 0x3b323b38 ; "8;2;"
    add     rbx, 7
    lea     r8, [dec3_table]
    mov     ecx, edi
    shr     ecx, 16
    movzx   ecx, cl
    call    .channel
    mov     byte [rbx], ';'
    inc     rbx
    mov     ecx, edi
    shr     ecx, 8
    movzx   ecx, cl
    call    .channel
    mov     byte [rbx], ';'
    inc     rbx
    movzx   ecx, dil
    call    .channel
    mov     byte [rbx], 'm'
    inc     rbx
    ret
.channel:
    mov     eax, [r8 + rcx * 4]
    mov     [rbx], eax
    shr     eax, 24
    add     rbx, rax
    ret

section .rodata
sgr_attr_codes: db '1', '3', '4', '5', '7', '8', '9'

; dec3_table[n]: the decimal digits of n (1-3 bytes) with the count in byte 3.
align 4
dec3_table:
%assign n 0
%rep 256
  %if n >= 100
    db '0' + n / 100, '0' + (n / 10) % 10, '0' + n % 10, 3
  %elif n >= 10
    db '0' + n / 10, '0' + n % 10, 0, 2
  %else
    db '0' + n, 0, 0, 1
  %endif
  %assign n n + 1
%endrep

STR msg_pool_full, "ttfx: asm engine: visual pool exhausted", 10
STR msg_visual_long, "ttfx: asm engine: visual exceeds 128 bytes", 10

section .tstate
alignb 8
pool_base:      resq 1
pool_len:       resd 1
space_handle:   resd 1
table_base:     resq 1
table_mask:     resd 1
table_count:    resd 1
