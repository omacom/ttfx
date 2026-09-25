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
; carry none. Header and bytes together are the interning key.
;
; Every pooled visual is readable for 128 bytes from its start (the pool keeps
; that much slack), so copies may overrun their length without leaving it.

%define VISUAL_MAX          128         ; longest visual the pool accepts
%define VISUAL_HEADER       32
%define POOL_RESERVE        (POOL_LIMIT + 4096)

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
    mov     ecx, 4096
    call    visual_table_alloc
    mov     rdi, NONE
    mov     rsi, NONE
    mov     rdx, (1 << 32) | ' '
    xor     ecx, ecx
    call    visual_make
    mov     [space_handle], eax
    ret

; visual_table_alloc(ecx=capacity): fresh zeroed table of ecx entries.
visual_table_alloc:
    push    rcx
    lea     rdi, [rcx * 4]
    call    alloc
    pop     rcx
    mov     [table_base], rax
    dec     ecx
    mov     [table_mask], ecx
    ret

; visual_hash(rdi=key, esi=key length) -> eax. Clobbers rcx, rdx.
visual_hash:
    mov     eax, esi
    lea     edx, [esi + 7]
    shr     edx, 3
    xor     ecx, ecx
.loop:
    crc32   rax, qword [rdi + rcx * 8]
    inc     ecx
    cmp     ecx, edx
    jb      .loop
    ret

; key_masks(esi=key length): k1/k2/k3 select the key's bytes in three zmm.
; Clobbers rax, rcx.
key_masks:
    mov     ecx, esi
    mov     rax, -1
    kmovq   k1, rax
    kmovq   k2, rax
    cmp     ecx, 128
    jae     .third
    kxorq   k3, k3, k3
    cmp     ecx, 64
    jae     .second
    bzhi    rax, rax, rcx
    kmovq   k1, rax
    kxorq   k2, k2, k2
    ret
.second:
    sub     ecx, 64
    bzhi    rax, rax, rcx
    kmovq   k2, rax
    ret
.third:
    sub     ecx, 128
    bzhi    rax, rax, rcx
    kmovq   k3, rax
    ret

; visual_intern(rdi=key: 32-byte header then the bytes, zero-padded to 192;
;               esi=byte length) -> eax = handle.
visual_intern:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r14, rdi
    mov     r12d, esi                   ; byte length
    lea     esi, [r12 + VISUAL_HEADER]
    call    visual_hash
    mov     ebx, eax
    lea     esi, [r12 + VISUAL_HEADER]
    call    key_masks
    vmovdqu64 zmm0, [r14]
    vmovdqu64 zmm1, [r14 + 64]
    vmovdqu64 zmm2, [r14 + 128]
    mov     r13, [table_base]
    mov     rdx, [pool_base]
.next:
    and     ebx, [table_mask]
    mov     eax, [r13 + rbx * 4]
    test    eax, eax
    jz      .insert
    mov     ecx, eax
    shr     ecx, HANDLE_LEN_SHIFT
    cmp     ecx, r12d
    jne     .skip
    mov     ecx, eax
    and     ecx, HANDLE_OFFSET_MASK
    sub     ecx, VISUAL_HEADER
    vpcmpb  k4{k1}, zmm0, [rdx + rcx], 4
    vpcmpb  k5{k2}, zmm1, [rdx + rcx + 64], 4
    vpcmpb  k6{k3}, zmm2, [rdx + rcx + 128], 4
    korq    k4, k4, k5
    kortestq k4, k6
    jz      .found
.skip:
    inc     ebx
    jmp     .next
.found:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret
.insert:
    mov     ecx, [pool_len]
    vmovdqu64 [rdx + rcx], zmm0
    vmovdqu64 [rdx + rcx + 64], zmm1
    vmovdqu64 [rdx + rcx + 128], zmm2
    lea     eax, [rcx + VISUAL_HEADER]
    mov     esi, r12d
    shl     esi, HANDLE_LEN_SHIFT
    or      eax, esi
    lea     ecx, [rcx + r12 + VISUAL_HEADER]
    cmp     ecx, POOL_LIMIT
    jae     .full
    mov     [pool_len], ecx
    mov     [r13 + rbx * 4], eax
    inc     dword [table_count]
    mov     ecx, [table_count]
    add     ecx, ecx
    cmp     ecx, [table_mask]
    jbe     .found
    push    rax
    call    visual_table_grow
    pop     rax
    jmp     .found
.full:
    lea     rdi, [msg_pool_full]
    mov     esi, msg_pool_full_len
    jmp     fatal

; visual_table_grow: double the table and reinsert every handle.
visual_table_grow:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 192
    mov     r12, [table_base]
    mov     r13d, [table_mask]
    inc     r13d                        ; old capacity
    lea     ecx, [r13 * 2]
    call    visual_table_alloc
    mov     r14, [table_base]
    xor     ebx, ebx
.each:
    cmp     ebx, r13d
    jae     .done
    mov     r15d, [r12 + rbx * 4]
    test    r15d, r15d
    jz      .skip
    ; rebuild the zero-padded key exactly as visual_intern hashed it
    mov     esi, r15d
    shr     esi, HANDLE_LEN_SHIFT
    add     esi, VISUAL_HEADER
    call    key_masks
    mov     ecx, r15d
    and     ecx, HANDLE_OFFSET_MASK
    sub     ecx, VISUAL_HEADER
    add     rcx, [pool_base]
    vmovdqu8 zmm0{k1}{z}, [rcx]
    vmovdqu8 zmm1{k2}{z}, [rcx + 64]
    vmovdqu8 zmm2{k3}{z}, [rcx + 128]
    vmovdqu64 [rsp], zmm0
    vmovdqu64 [rsp + 64], zmm1
    vmovdqu64 [rsp + 128], zmm2
    mov     rdi, rsp
    mov     esi, r15d
    shr     esi, HANDLE_LEN_SHIFT
    add     esi, VISUAL_HEADER
    call    visual_hash
.probe:
    and     eax, [table_mask]
    cmp     dword [r14 + rax * 4], 0
    je      .put
    inc     eax
    jmp     .probe
.put:
    mov     [r14 + rax * 4], r15d
.skip:
    inc     ebx
    jmp     .each
.done:
    add     rsp, 192
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret

; ------------------------------------------------------------ formatting

; visual_make(rdi=fg color or NONE, rsi=bg color or NONE, rdx=packed symbol,
;             ecx=ATTR_* bits) -> eax = handle.
; CharacterVisual::new + format_symbol_into: bold, italic, underline, blink,
; reverse, hidden, strike, fg, bg, symbol, then a reset only if anything
; preceded it. Colors are dropped from the bytes under --no-color
; (resolve_color_code) but kept in the header. Under --xterm-colors a color
; renders as its own code when it has one, else the nearest by hex_to_xterm.
; Clobbers rax, rcx, rdx, rsi, rdi, r8-r11, zmm0-zmm7, k1-k6.
visual_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 200
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15d, ecx
    vpxorq  zmm0, zmm0, zmm0
    vmovdqu64 [rsp], zmm0
    vmovdqu64 [rsp + 64], zmm0
    vmovdqu64 [rsp + 128], zmm0
    ; header
    mov     [rsp], r14
    mov     [rsp + 8], r12
    mov     [rsp + 16], r13
    mov     [rsp + 24], r15
    lea     rbx, [rsp + VISUAL_HEADER]  ; write cursor
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
    lea     rdx, [rsp + VISUAL_HEADER]
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
    lea     rdx, [rsp + VISUAL_HEADER]
    sub     rsi, rdx
    cmp     esi, VISUAL_MAX
    ja      .too_long
    mov     rdi, rsp
    call    visual_intern
    add     rsp, 200
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
