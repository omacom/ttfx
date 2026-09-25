; utils/hexterm.asm - xterm-256 <-> RGB (src/utils/hexterm.rs).
;
; hex_to_xterm is the minimum mean absolute channel difference over codes
; 0..=255 in order, first minimum winning. The scan compares integer sums,
; which orders exactly like upstream's sum / 3. Sixteen codes per step with
; AVX-512; results are memoized per RGB value.

%define XTERM_MEMO_BYTES    (2 << 24)   ; u16 per RGB value: code + 1, 0 = unknown

section .text

; hex_to_xterm(edi=0xRRGGBB) -> eax = xterm code. Clobbers rcx, rdx, rsi,
; r8, zmm0-zmm7, k1-k2.
hex_to_xterm:
    mov     rax, [xterm_memo]
    test    rax, rax
    jnz     .memo
    push    rdi
    mov     rdi, XTERM_MEMO_BYTES
    call    reserve
    mov     [xterm_memo], rax
    pop     rdi
.memo:
    mov     edx, edi
    and     edx, 0xffffff
    movzx   ecx, word [rax + rdx * 2]
    test    ecx, ecx
    jz      .scan
    lea     eax, [rcx - 1]
    ret
.scan:
    push    rdx
    ; broadcast the query's channels
    mov     ecx, edi
    shr     ecx, 16
    and     ecx, 0xff
    vpbroadcastd zmm0, ecx              ; r
    mov     ecx, edi
    shr     ecx, 8
    and     ecx, 0xff
    vpbroadcastd zmm1, ecx              ; g
    mov     ecx, edi
    and     ecx, 0xff
    vpbroadcastd zmm2, ecx              ; b
    vpbroadcastd zmm7, [xterm_byte_mask]
    mov     esi, 0x7fffffff
    vpbroadcastd zmm6, esi              ; running minimum
    lea     rsi, [xterm_rgb]
    lea     r8, [xterm_diffs]
    xor     ecx, ecx
.block:
    vmovdqu32 zmm3, [rsi + rcx * 4]
    vpsrld  zmm4, zmm3, 16
    vpandd  zmm4, zmm4, zmm7
    vpsubd  zmm4, zmm4, zmm0
    vpabsd  zmm4, zmm4
    vpsrld  zmm5, zmm3, 8
    vpandd  zmm5, zmm5, zmm7
    vpsubd  zmm5, zmm5, zmm1
    vpabsd  zmm5, zmm5
    vpaddd  zmm4, zmm4, zmm5
    vpandd  zmm5, zmm3, zmm7
    vpsubd  zmm5, zmm5, zmm2
    vpabsd  zmm5, zmm5
    vpaddd  zmm4, zmm4, zmm5            ; channel differences of 16 codes
    vmovdqu32 [r8 + rcx * 4], zmm4
    vpminud zmm6, zmm6, zmm4
    add     ecx, 16
    cmp     ecx, 256
    jb      .block
    ; reduce the minimum across lanes
    vextracti64x4 ymm3, zmm6, 1
    vpminud ymm6, ymm6, ymm3
    vextracti128 xmm3, ymm6, 1
    vpminud xmm6, xmm6, xmm3
    vpshufd xmm3, xmm6, 0x4e
    vpminud xmm6, xmm6, xmm3
    vpshufd xmm3, xmm6, 0xb1
    vpminud xmm6, xmm6, xmm3
    vpbroadcastd zmm6, xmm6
    ; first code whose difference equals the minimum
    xor     ecx, ecx
    lea     rsi, [xterm_diffs]
.find:
    vpcmpeqd k1, zmm6, [rsi + rcx * 4]
    kmovw   eax, k1
    test    eax, eax
    jnz     .found
    add     ecx, 16
    jmp     .find
.found:
    tzcnt   eax, eax
    add     eax, ecx
    pop     rdx
    mov     rcx, [xterm_memo]
    lea     esi, [rax + 1]
    mov     [rcx + rdx * 2], si
    vzeroupper
    ret

section .rodata
align 64
xterm_byte_mask: dd 0xff
align 64
; xterm code -> 0xRRGGBB, generated from src/utils/hexterm_table.rs
xterm_rgb:
    dd 0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0
    dd 0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff
    dd 0x000000, 0x00005f, 0x000087, 0x0000af, 0x0000d7, 0x0000ff, 0x005f00, 0x005f5f
    dd 0x005f87, 0x005faf, 0x005fd7, 0x005fff, 0x008700, 0x00875f, 0x008787, 0x0087af
    dd 0x0087d7, 0x0087ff, 0x00af00, 0x00af5f, 0x00af87, 0x00afaf, 0x00afd7, 0x00afff
    dd 0x00d700, 0x00d75f, 0x00d787, 0x00d7af, 0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f
    dd 0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff, 0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af
    dd 0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f, 0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff
    dd 0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af, 0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f
    dd 0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff, 0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af
    dd 0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f, 0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff
    dd 0x870000, 0x87005f, 0x870087, 0x8700af, 0x8700d7, 0x8700ff, 0x875f00, 0x875f5f
    dd 0x875f87, 0x875faf, 0x875fd7, 0x875fff, 0x878700, 0x87875f, 0x878787, 0x8787af
    dd 0x8787d7, 0x8787ff, 0x87af00, 0x87af5f, 0x87af87, 0x87afaf, 0x87afd7, 0x87afff
    dd 0x87d700, 0x87d75f, 0x87d787, 0x87d7af, 0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f
    dd 0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff, 0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af
    dd 0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f, 0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff
    dd 0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af, 0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f
    dd 0xafaf87, 0xafafaf, 0xafafd7, 0xafafff, 0xafd700, 0xafd75f, 0xafd787, 0xafd7af
    dd 0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f, 0xafff87, 0xafffaf, 0xafffd7, 0xafffff
    dd 0xd70000, 0xd7005f, 0xd70087, 0xd700af, 0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f
    dd 0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff, 0xd78700, 0xd7875f, 0xd78787, 0xd787af
    dd 0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f, 0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff
    dd 0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af, 0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f
    dd 0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff, 0xff0000, 0xff005f, 0xff0087, 0xff00af
    dd 0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f, 0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff
    dd 0xff8700, 0xff875f, 0xff8787, 0xff87af, 0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f
    dd 0xffaf87, 0xffafaf, 0xffafd7, 0xffafff, 0xffd700, 0xffd75f, 0xffd787, 0xffd7af
    dd 0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f, 0xffff87, 0xffffaf, 0xffffd7, 0xffffff
    dd 0x080808, 0x121212, 0x1c1c1c, 0x262626, 0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e
    dd 0x585858, 0x626262, 0x6c6c6c, 0x767676, 0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e
    dd 0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6, 0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee

section .tstate
alignb 64
xterm_diffs:    resd 256
xterm_memo:     resq 1
