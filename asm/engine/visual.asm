; engine/visual.asm - the visual pool (plan §7.5).
;
; A CharacterVisual is fully described by the bytes it renders to: SGR prefix,
; symbol, reset. Those bytes are formatted once and interned into a
; de-duplicated pool; a visual is then a u32 handle (offset | len << 24). The
; renderer never formats, allocates or refcounts: a cell is one bounded copy.
;
; Every pooled visual is readable for 128 bytes from its start (the pool keeps
; that much slack), so copies may overrun their length without leaving it.

%define VISUAL_MAX          128         ; longest visual the pool accepts
%define POOL_RESERVE        (POOL_LIMIT + 4096)

section .text

; visual_init: reserve the pool, seed it with the blank cell, size the table.
visual_init:
    mov     rdi, POOL_RESERVE
    call    reserve
    mov     [pool_base], rax
    mov     byte [rax], ' '
    mov     dword [pool_len], 1
    mov     dword [space_handle], 0 | (1 << HANDLE_LEN_SHIFT)
    mov     ecx, 4096
    jmp     visual_table_alloc

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

; visual_hash(zmm0, zmm1 = 128 zero-padded bytes, esi=len) -> eax.
visual_hash:
    sub     rsp, 128
    vmovdqu64 [rsp], zmm0
    vmovdqu64 [rsp + 64], zmm1
    mov     eax, esi
    lea     edx, [esi + 7]
    shr     edx, 3                      ; qwords holding the visual
    xor     ecx, ecx
.loop:
    crc32   rax, qword [rsp + rcx * 8]
    inc     ecx
    cmp     ecx, edx
    jb      .loop
    add     rsp, 128
    ret

; visual_intern(rdi=ptr to 128 zero-padded bytes, esi=len) -> eax = handle.
visual_intern:
    push    rbx
    push    r12
    push    r13
    vmovdqu64 zmm0, [rdi]
    vmovdqu64 zmm1, [rdi + 64]
    mov     r12d, esi
    call    visual_hash
    mov     r13, [table_base]
    mov     ebx, eax
    ; kmask for the compare: low len bits across 128 bytes (k1 = low 64, k2 = high)
    mov     rax, -1
    mov     ecx, r12d
    cmp     ecx, 64
    jae     .full_low
    bzhi    rax, rax, rcx
    kmovq   k1, rax
    kxorq   k2, k2, k2
    jmp     .probe
.full_low:
    kmovq   k1, rax
    sub     ecx, 64
    bzhi    rax, rax, rcx
    kmovq   k2, rax
.probe:
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
    vpcmpb  k3{k1}, zmm0, [rdx + rcx], 4        ; not-equal bytes, low half
    vpcmpb  k4{k2}, zmm1, [rdx + rcx + 64], 4   ; high half
    kortestq k3, k4
    jz      .found
.skip:
    inc     ebx
    jmp     .next
.found:
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret
.insert:
    mov     ecx, [pool_len]
    vmovdqu64 [rdx + rcx], zmm0
    vmovdqu64 [rdx + rcx + 64], zmm1
    mov     eax, r12d
    shl     eax, HANDLE_LEN_SHIFT
    or      eax, ecx
    add     ecx, r12d
    cmp     ecx, POOL_LIMIT
    jae     .full
    mov     [pool_len], ecx
    mov     [r13 + rbx * 4], eax
    inc     dword [table_count]
    mov     ecx, [table_count]
    add     ecx, ecx
    mov     edx, [table_mask]
    cmp     ecx, edx
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
    mov     eax, [r12 + rbx * 4]
    test    eax, eax
    jz      .skip
    push    rax
    mov     ecx, eax
    and     ecx, HANDLE_OFFSET_MASK
    mov     esi, eax
    shr     esi, HANDLE_LEN_SHIFT
    mov     rdx, [pool_base]
    ; rebuild the zero-padded key exactly as visual_intern hashed it
    mov     rax, -1
    cmp     esi, 64
    jae     .wide
    bzhi    rax, rax, rsi
    kmovq   k1, rax
    vmovdqu8 zmm0{k1}{z}, [rdx + rcx]
    vpxorq  zmm1, zmm1, zmm1
    jmp     .hash
.wide:
    vmovdqu8 zmm0, [rdx + rcx]
    mov     edi, esi
    sub     edi, 64
    bzhi    rax, rax, rdi
    kmovq   k1, rax
    vmovdqu8 zmm1{k1}{z}, [rdx + rcx + 64]
.hash:
    call    visual_hash
    pop     rdx
.probe:
    and     eax, [table_mask]
    cmp     dword [r14 + rax * 4], 0
    je      .put
    inc     eax
    jmp     .probe
.put:
    mov     [r14 + rax * 4], edx
.skip:
    inc     ebx
    jmp     .each
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret

; ------------------------------------------------------------ formatting

; visual_make(rdi=fg color or NONE, rsi=bg color or NONE, rdx=packed symbol,
;             ecx=attribute bits) -> eax = handle. Colors use the u64 format
; of ttfx.inc; under --xterm-colors they emit 8-bit codes (the color's own
; code when it has one, else the nearest by hex_to_xterm).
; CharacterVisual.format_symbol_into: bold, italic, underline, blink, reverse,
; hidden, strike, fg, bg, symbol, then a reset only if anything preceded it.
; `dim` is stored upstream but never emitted, so it has no bit here.
; Colors are dropped entirely under --no-color (resolve_color_code).
visual_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 136
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    vpxorq  zmm0, zmm0, zmm0
    vmovdqu64 [rsp], zmm0
    vmovdqu64 [rsp + 64], zmm0
    mov     rbx, rsp                    ; write cursor
    cmp     byte [cfg_no_color], 0
    je      .attrs
    mov     r12, NONE
    mov     r13, NONE
.attrs:
    lea     r8, [sgr_attr_codes]
    xor     r9d, r9d
.attr:
    bt      ecx, r9d
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
    mov     rdx, rbx
    sub     rdx, rsp                    ; prefix length
    add     rbx, rcx
    test    rdx, rdx
    jz      .plain
    mov     dword [rbx], 0x6d305b1b     ; "\x1b[0m"
    add     rbx, 4
.plain:
    ; clear any symbol bytes past its length (the dword store wrote 4)
    mov     rdx, rbx
    sub     rdx, rsp
    mov     dword [rbx], 0
    mov     esi, edx
    cmp     esi, VISUAL_MAX
    ja      .too_long
    mov     rdi, rsp
    call    visual_intern
    add     rsp, 136
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.too_long:
    lea     rdi, [msg_visual_long]
    mov     esi, msg_visual_long_len
    jmp     fatal

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

STR msg_pool_full, "ttfx: visual pool exhausted", 10
STR msg_visual_long, "ttfx: visual exceeds 128 bytes", 10

section .tstate
pool_base:      resq 1
pool_len:       resd 1
space_handle:   resd 1
table_base:     resq 1
table_mask:     resd 1
table_count:    resd 1
