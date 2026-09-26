; engine/render.asm - visibility and the frame renderer
; (terminal.rs update_render_cells + get_formatted_output_string).
;
; The cell grid keeps, per cell, the winning slot (maximum (layer,
; character_id), exactly Rust's painter order) and that winner's visual
; handle. Rust rebuilds it every frame; here it is maintained incrementally:
;
;   * a visual change writes through to the grid when its character owns the
;     cell (set_handle), which covers scene playback - the common case;
;   * a newly visible character is painted into its cell on the spot;
;   * movement, layer changes and hiding move the character between the
;     cells' occupant lists, and a cell whose owner left picks the best of the
;     rest (cell_rewin).
;
; Character ids ascend with slots (chars.asm), so the character_id tie-break
; compares slots.
;
; Emission: each row keeps its bytes (with its joining newline) in storage of
; its own, and a frame is handed to the kernel as one iovec per row. A row
; none of whose cells changed since the previous frame is not touched at all.
; A row with changed cells is rebuilt into its second buffer: the runs of
; unchanged BLOCK-cell blocks are copied from the previous bytes (each row records
; where every block's bytes start), and only the changed blocks are formatted
; from the handle grid.

%define EMPTY_SLOT      0xffffffff
; per-cell record (cell_rec): the occupant list's head, the owner (also in
; slot_grid, which SET_HANDLE reads) and the owner's layer, so a character
; competing for a cell reads one line
%define CR_HEAD         0
%define CR_OWNER        4
%define CR_LAYER        8
; cells per dirty block: 4 or 8
%ifndef BLOCK
%define BLOCK           4
%endif
%if BLOCK == 4
%define BLOCK_SHIFT     2
%else
%define BLOCK_SHIFT     3
%endif
%define OUTPUT_RESERVE  (1 << 36)
; POPCNT dst, scratch: dst = its own population count (SWAR below TIER 2).
; Clobbers scratch.
%macro POPCNT 2
%if TIER >= 2
    popcnt  %1, %1
%else
    mov     %2, %1
    shr     %2, 1
    and     %2, [pc_55]
    sub     %1, %2
    mov     %2, %1
    shr     %2, 2
    and     %1, [pc_33]
    and     %2, [pc_33]
    add     %1, %2
    mov     %2, %1
    shr     %2, 4
    add     %1, %2
    and     %1, [pc_0f]
    imul    %1, [pc_01]
    shr     %1, 56
%endif
%endmacro

; LD32 a, b, addr / ST32 addr, a, b: a 32-byte copy through ymm<a>, or
; xmm<a> and xmm<b> below TIER 3.
%macro LD32 3
%if TIER >= 3
    vmovdqu ymm%1, [%3]
%else
    movdqu  xmm%1, [%3]
    movdqu  xmm%2, [%3 + 16]
%endif
%endmacro
%macro ST32 3
%if TIER >= 3
    vmovdqu [%1], ymm%2
%else
    movdqu  [%1], xmm%2
    movdqu  [%1 + 16], xmm%3
%endif
%endmacro

; COPY128 dst, src: 128 bytes (a visual of any length). Clobbers xmm0-xmm7.
%macro COPY128 2
%if TIER >= 4
    vmovdqu64 zmm0, [%2]
    vmovdqu64 zmm1, [%2 + 64]
    vmovdqu64 [%1], zmm0
    vmovdqu64 [%1 + 64], zmm1
%else
    %assign %%i 0
    %rep 4
    LD32    0, 1, %2 + %%i
    ST32    %1 + %%i, 0, 1
    %assign %%i %%i + 32
    %endrep
%endif
%endmacro

; CELL_OF: eax = grid cell of slot edi's current coordinate, or NONE outside
; the visible window. Clobbers rcx, rdx.
%macro CELL_OF 0
    mov     rax, [ch_row]
    movsxd  rcx, dword [rax + rdi * 4]
    mov     rax, [ch_col]
    movsxd  rdx, dword [rax + rdi * 4]
    mov     rax, rcx
    add     rax, [co_rbase]
    cmp     rax, [co_rspan]
    ja      %%outside
    mov     rax, rdx
    add     rax, [co_cbase]
    cmp     rax, [co_cspan]
    ja      %%outside
    imul    rcx, [grid_width]
    add     rdx, [co_cell0]
    lea     rax, [rcx + rdx]
    jmp     %%done
%%outside:
    mov     eax, NONE
%%done:
%endmacro

section .rodata
align 8
pc_55:          dq 0x5555555555555555
pc_33:          dq 0x3333333333333333
pc_0f:          dq 0x0f0f0f0f0f0f0f0f
pc_01:          dq 0x0101010101010101

section .text

; render_init: grids for the visible window, the visible list, the output.
render_init:
    push    rbx
    mov     rax, [visible_right]
    xor     ecx, ecx
    test    rax, rax
    cmovs   rax, rcx
    mov     [grid_width], rax
    mov     rdx, [visible_top]
    test    rdx, rdx
    cmovs   rdx, rcx
    mov     [grid_height], rdx
    imul    rax, rdx
    mov     [grid_cells], rax
    ; cell_of: row + co_rbase and col + co_cbase are unsigned in-window
    ; indices, and the cell is row * width + col + co_cell0
    mov     rax, [row_offset]
    sub     rax, [visible_bottom]
    mov     rcx, [visible_top]
    sub     rcx, [visible_bottom]
    mov     rdx, 1 << 40                ; an empty window matches nothing
    xor     r8d, r8d
    test    rcx, rcx
    cmovs   rax, rdx
    cmovs   rcx, r8
    mov     [co_rbase], rax
    mov     [co_rspan], rcx
    mov     rax, [col_offset]
    sub     rax, [visible_left]
    mov     rcx, [visible_right]
    sub     rcx, [visible_left]
    test    rcx, rcx
    cmovs   rax, rdx
    cmovs   rcx, r8
    mov     [co_cbase], rax
    mov     [co_cspan], rcx
    mov     rax, [row_offset]
    dec     rax
    imul    rax, [grid_width]
    add     rax, [col_offset]
    dec     rax
    mov     [co_cell0], rax
    mov     rbx, [grid_cells]
    lea     rbx, [rbx * 4 + 64]
    mov     rdi, rbx
    call    alloc
    mov     [slot_grid], rax
    mov     rdi, rbx
    call    alloc
    mov     [handle_grid], rax
    mov     rdi, CHAR_LIMIT * 4
    call    reserve
    mov     [ch_cnext], rax
    mov     rdi, CHAR_LIMIT * 4
    call    reserve
    mov     [ch_cprev], rax
    mov     rdi, [grid_cells]
    shl     rdi, 4
    add     rdi, 64
    call    reserve
    mov     [cell_rec], rax
    mov     rdi, CHAR_LIMIT * 4
    call    reserve
    mov     [visible_list], rax
    mov     rdi, CHAR_LIMIT * 4
    call    reserve
    mov     [visible_pos], rax
    mov     rdi, OUTPUT_RESERVE
    call    reserve
    mov     [out_base], rax
    ; per-row storage, two buffers per row: width * VISUAL_MAX bytes +
    ; newline + copy slack
    mov     rax, [grid_width]
    shl     rax, 7
    add     rax, 256
    mov     [row_stride], rax
    imul    rax, [grid_height]
    lea     rdi, [rax * 2 + 4096]
    call    reserve
    mov     [row_store], rax
    ; and two arrays of BLOCK-cell block starts per row: blocks + 1 entries +
    ; slack
    mov     rax, [grid_width]
    add     rax, BLOCK - 1
    shr     rax, BLOCK_SHIFT
    mov     [row_blocks], rax
    lea     rcx, [rax * 3]
    mov     [full_blocks], rcx          ; 3/4 of the row's blocks, times 4
    lea     rax, [rax * 4 + 33 * 4 + 63]
    and     rax, -64
    mov     [offs_stride], rax
    imul    rax, [grid_height]
    lea     rdi, [rax * 2 + 4096]
    call    reserve
    mov     [row_offs], rax
    mov     rbx, [grid_height]
    lea     rdi, [rbx + 64]
    call    alloc
    mov     [row_sel], rax
    ; the rows' iovecs, top row first, and the frame's: one slot before
    ; the rows (prefix / header) and one after them (the dump's trailing
    ; newline)
    mov     rdi, rbx
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     [row_iov], rax
    mov     rdi, rbx
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     [frame_iov], rax
    mov     rdi, [grid_cells]
    add     rdi, 128
    call    alloc
    mov     [dirty_cells], rax
    mov     rdi, [grid_width]
    shr     rdi, 6
    add     rdi, 64
    call    alloc
    mov     [dirty_bits], rax
    mov     byte [grid_valid], 0
    pop     rbx
    ret

; cell_of(edi=slot) -> eax = grid cell of the character's current coordinate,
; or NONE outside the visible window. Clobbers rcx, rdx.
cell_of:
    CELL_OF
    ret

; paint(edi=slot, eax=cell): take the cell when empty or when this character
; outranks its owner on (layer, character_id). Clobbers rcx, rdx, rsi, r8.
paint:
    mov     r8, rax
    shl     r8, 4
    add     r8, [cell_rec]
; paint_rec: paint with r8 = the cell's record.
paint_rec:
    mov     rsi, [ch_layer]
    mov     ecx, [rsi + rdi * 4]
    mov     edx, [r8 + CR_OWNER]
    cmp     edx, EMPTY_SLOT
    je      .take
    cmp     ecx, [r8 + CR_LAYER]
    jg      .take
    jl      .keep
    cmp     edi, edx
    jbe     .keep
.take:
    mov     [r8 + CR_OWNER], edi
    mov     [r8 + CR_LAYER], ecx
    mov     rsi, [slot_grid]
    mov     [rsi + rax * 4], edi
    mov     rsi, [ch_handle]
    mov     ecx, [rsi + rdi * 4]
    mov     rsi, [handle_grid]
    mov     [rsi + rax * 4], ecx
    mov     rsi, [dirty_cells]
    mov     byte [rsi + rax], 1
.keep:
    ret

; cell_link(edi=slot, eax=cell): put a visible character into a cell's list
; and let it compete for the cell. Clobbers rcx, rdx, rsi, r8.
cell_link:
    mov     rcx, [ch_cell]
    mov     [rcx + rdi * 4], eax
    mov     r8, rax
    shl     r8, 4
    add     r8, [cell_rec]
    mov     edx, [r8 + CR_HEAD]
    mov     rcx, [ch_cnext]
    mov     [rcx + rdi * 4], edx
    mov     rcx, [ch_cprev]
    mov     dword [rcx + rdi * 4], NONE
    cmp     edx, NONE
    je      .head
    mov     [rcx + rdx * 4], edi
.head:
    mov     [r8 + CR_HEAD], edi
    jmp     paint_rec

; cell_unlink(edi=slot): take a character out of its cell; if it owned the
; cell, the best remaining character (or nobody) takes over.
; Clobbers rax, rcx, rdx, rsi, r8, r9.
cell_unlink:
    mov     rax, [ch_cell]
    mov     r9d, [rax + rdi * 4]
    cmp     r9d, NONE
    je      .done
    mov     dword [rax + rdi * 4], NONE
    mov     r8, r9
    shl     r8, 4
    add     r8, [cell_rec]
    mov     rcx, [ch_cnext]
    mov     edx, [rcx + rdi * 4]        ; next
    mov     rsi, [ch_cprev]
    mov     eax, [rsi + rdi * 4]        ; previous
    cmp     eax, NONE
    je      .was_head
    mov     [rcx + rax * 4], edx
    jmp     .fix_next
.was_head:
    mov     [r8 + CR_HEAD], edx
.fix_next:
    cmp     edx, NONE
    je      .owner
    mov     [rsi + rdx * 4], eax
.owner:
    cmp     [r8 + CR_OWNER], edi
    jne     .done
    mov     eax, r9d
    jmp     cell_rewin
.done:
    ret

; cell_rewin(eax=cell): the cell's owner is the best of its list, or nobody.
; Clobbers rcx, rdx, rsi, r8, r9.
cell_rewin:
    push    rbx
    mov     r9, rax
    shl     r9, 4
    add     r9, [cell_rec]
    mov     ecx, [r9 + CR_HEAD]         ; candidate
    mov     ebx, NONE                   ; best so far
    mov     rsi, [ch_layer]
    mov     r8, [ch_cnext]
.scan:
    cmp     ecx, NONE
    je      .chosen
    cmp     ebx, NONE
    je      .take
    mov     edx, [rsi + rcx * 4]
    cmp     edx, [rsi + rbx * 4]
    jg      .take
    jl      .next
    cmp     ecx, ebx
    jbe     .next
.take:
    mov     ebx, ecx
.next:
    mov     ecx, [r8 + rcx * 4]
    jmp     .scan
.chosen:
    mov     [r9 + CR_OWNER], ebx
    mov     rdx, [handle_grid]
    cmp     ebx, NONE
    je      .empty
    mov     ecx, [rsi + rbx * 4]
    mov     [r9 + CR_LAYER], ecx
    mov     rsi, [slot_grid]
    mov     [rsi + rax * 4], ebx
    mov     rsi, [ch_handle]
    mov     ecx, [rsi + rbx * 4]
    mov     [rdx + rax * 4], ecx
    jmp     .dirty
.empty:
    mov     rsi, [slot_grid]
    mov     dword [rsi + rax * 4], EMPTY_SLOT
    mov     ecx, [space_handle]
    mov     [rdx + rax * 4], ecx
.dirty:
    mov     rsi, [dirty_cells]
    mov     byte [rsi + rax], 1
    pop     rbx
    ret

; set_visibility(edi=slot, esi=visible): Terminal.set_character_visibility.
set_visibility:
    test    esi, esi
    jnz     set_visible
    ; hide: swap-remove from the visible list and leave the cell
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jz      .done
    and     word [rax + rdi * 2], ~CF_VISIBLE
    mov     rax, [visible_pos]
    mov     ecx, [rax + rdi * 4]        ; position of the hidden character
    dec     dword [visible_count]
    mov     edx, [visible_count]        ; last position
    mov     r8, [visible_list]
    mov     r9d, [r8 + rdx * 4]         ; the character moved into the hole
    mov     [r8 + rcx * 4], r9d
    mov     [rax + r9 * 4], ecx
    cmp     byte [grid_valid], 0
    je      .done
    jmp     cell_unlink
.done:
    ret

; set_visible(edi=slot): Terminal.set_character_visibility(id, true).
set_visible:
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jnz     .done
    or      word [rax + rdi * 2], CF_VISIBLE
    mov     ecx, [visible_count]
    mov     rax, [visible_list]
    mov     [rax + rcx * 4], edi
    mov     rax, [visible_pos]
    mov     [rax + rdi * 4], ecx
    inc     dword [visible_count]
    cmp     byte [grid_valid], 0
    je      .done
    CELL_OF
    cmp     eax, NONE
    je      .done
    jmp     cell_link
.done:
    ret

; coordinate_changed(edi=slot): the character's current coordinate changed;
; a visible character that changes cells leaves the old one and joins the
; new one.
coordinate_changed:
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jz      .done
    cmp     byte [grid_valid], 0
    je      .done
    CELL_OF
    mov     rcx, [ch_cell]
    cmp     [rcx + rdi * 4], eax
    je      .done
    ; the new cell's record is needed after the unlink: start its load now
    cmp     eax, NONE
    je      .unlink
    mov     rcx, rax
    shl     rcx, 4
    add     rcx, [cell_rec]
    prefetcht0 [rcx]
.unlink:
    push    rax
    call    cell_unlink
    pop     rax
    cmp     eax, NONE
    je      .done
    jmp     cell_link
.done:
    ret

; layer_changed(edi=slot): a visible character's layer changed; its cell
; picks its owner again.
layer_changed:
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jz      .done
    cmp     byte [grid_valid], 0
    je      .done
    mov     rax, [ch_cell]
    mov     eax, [rax + rdi * 4]
    cmp     eax, NONE
    je      .done
    jmp     cell_rewin
.done:
    ret

; set_handle(edi=slot, eax=handle): see SET_HANDLE in ttfx.inc.
set_handle:
    SET_HANDLE
    ret

; repaint: rebuild both grids from the visible list (update_render_cells).
repaint:
    push    rbx
    push    r12
    push    r13
    mov     rdx, [grid_cells]
    mov     rdi, [slot_grid]
    mov     eax, EMPTY_SLOT
    mov     rcx, rdx
    rep     stosd
    mov     rdi, [cell_rec]
    mov     rcx, rdx
    mov     rax, -1
.records:
    test    rcx, rcx
    jz      .handles
    mov     [rdi], rax                  ; no head, no owner
    mov     qword [rdi + 8], 0
    add     rdi, 16
    dec     rcx
    jmp     .records
.handles:
    mov     rdi, [handle_grid]
    mov     eax, [space_handle]
    mov     rcx, rdx
    rep     stosd
    mov     r12, [visible_list]
    mov     r13d, [visible_count]
    xor     ebx, ebx
.next:
    cmp     ebx, r13d
    jae     .done
    mov     edi, [r12 + rbx * 4]
    inc     ebx
    CELL_OF
    mov     rcx, [ch_cell]
    mov     [rcx + rdi * 4], eax
    cmp     eax, NONE
    je      .next
    call    cell_link
    jmp     .next
.done:
    mov     byte [grid_valid], 1
    mov     byte [all_dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

; row_dirty(rax=first cell of the row) -> rax = the number of the row's
; BLOCK-cell blocks with changed cells. When there are any, also writes the
; row's block bitmap to [dirty_bits] (one bit per block, plus a set bit at
; index row_blocks: a sentinel for the run scan) and clears the row's dirty
; bytes. r14 = width, nonzero. Clobbers rcx, rdx, rsi, r8, r9, r10, r11,
; vector registers.
;
; The last 64-byte chunk reads and clears past the row's end: that is the
; next row up in memory, which render_frame has already scanned (it goes
; from the highest row index down), or the zeroed slack after the grid.
row_dirty:
    mov     rcx, [dirty_cells]
    add     rcx, rax
    ; most rows are clean: a first pass only ORs the bytes together
    mov     rdx, rcx
    mov     r9, r14
%if TIER >= 4
    vpxord  zmm1, zmm1, zmm1
    vpxord  zmm0, zmm0, zmm0
.any:
    vporq   zmm0, zmm0, [rdx]
    add     rdx, 64
    sub     r9, 64
    ja      .any
    vptestmb k1, zmm0, zmm0
    kortestq k1, k1
    jz      .clean
%elif TIER >= 3
    vpxor   ymm2, ymm2, ymm2
    vpxor   ymm0, ymm0, ymm0
.any:
    vpor    ymm0, ymm0, [rdx]
    vpor    ymm0, ymm0, [rdx + 32]
    add     rdx, 64
    sub     r9, 64
    ja      .any
    vptest  ymm0, ymm0
    jz      .clean
%else
    pxor    xmm4, xmm4
    pxor    xmm0, xmm0
.any:
    movdqu  xmm1, [rdx]
    movdqu  xmm2, [rdx + 16]
    por     xmm0, xmm1
    por     xmm0, xmm2
    movdqu  xmm1, [rdx + 32]
    movdqu  xmm2, [rdx + 48]
    por     xmm0, xmm1
    por     xmm0, xmm2
    add     rdx, 64
    sub     r9, 64
    ja      .any
    pcmpeqb xmm0, xmm4
    pmovmskb eax, xmm0
    cmp     eax, 0xffff
    je      .clean
%endif
    ; 64 / BLOCK block bits per 64 cells, gathered into whole words in rax (narrow
    ; stores would stall the word loads of the run scan)
    mov     rsi, rcx
    mov     r8, [dirty_bits]
    mov     r9, r14
    xor     r10d, r10d
    xor     eax, eax
    xor     ecx, ecx
.chunk:
%if BLOCK == 8
%if TIER >= 4
    vmovdqu64 zmm0, [rsi]
    vptestmq k1, zmm0, zmm0
    kmovb   r11d, k1
    vmovdqu64 [rsi], zmm1
%elif TIER >= 3
    vpcmpeqq ymm0, ymm2, [rsi]
    vpcmpeqq ymm1, ymm2, [rsi + 32]
    vmovmskpd r11d, ymm0
    vmovmskpd edx, ymm1
    shl     edx, 4
    or      r11d, edx
    xor     r11d, 0xff
    vmovdqu [rsi], ymm2
    vmovdqu [rsi + 32], ymm2
%else
    xor     r11d, r11d
    %assign k 7
    %rep 8
    mov     rdx, [rsi + k * 8]
    neg     rdx                         ; CF = block k is dirty
    adc     r11d, r11d
    %assign k k - 1
    %endrep
    movdqu  [rsi], xmm4
    movdqu  [rsi + 16], xmm4
    movdqu  [rsi + 32], xmm4
    movdqu  [rsi + 48], xmm4
%endif
%else
%if TIER >= 4
    vmovdqu64 zmm0, [rsi]
    vptestmd k1, zmm0, zmm0
    kmovw   r11d, k1
    vmovdqu64 [rsi], zmm1
%elif TIER >= 3
    vpcmpeqd ymm0, ymm2, [rsi]
    vpcmpeqd ymm1, ymm2, [rsi + 32]
    vmovmskps r11d, ymm0
    vmovmskps edx, ymm1
    shl     edx, 8
    or      r11d, edx
    xor     r11d, 0xffff
    vmovdqu [rsi], ymm2
    vmovdqu [rsi + 32], ymm2
%else
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rsi + 16]
    movdqu  xmm2, [rsi + 32]
    movdqu  xmm3, [rsi + 48]
    pcmpeqd xmm0, xmm4
    pcmpeqd xmm1, xmm4
    pcmpeqd xmm2, xmm4
    pcmpeqd xmm3, xmm4
    movmskps r11d, xmm3
    shl     r11d, 4
    movmskps edx, xmm2
    or      r11d, edx
    shl     r11d, 4
    movmskps edx, xmm1
    or      r11d, edx
    shl     r11d, 4
    movmskps edx, xmm0
    or      r11d, edx
    xor     r11d, 0xffff
    movdqu  [rsi], xmm4
    movdqu  [rsi + 16], xmm4
    movdqu  [rsi + 32], xmm4
    movdqu  [rsi + 48], xmm4
%endif
%endif
    shl     r11, cl
    or      rax, r11
    add     ecx, 64 / BLOCK
    cmp     ecx, 64
    jb      .next
    mov     [r8], rax
    add     r8, 8
    POPCNT  rax, rdx
    add     r10, rax
    xor     eax, eax
    xor     ecx, ecx
.next:
    add     rsi, 64
    sub     r9, 64
    ja      .chunk
    mov     [r8], rax
    mov     qword [r8 + 8], 0
    POPCNT  rax, rdx
    add     r10, rax
    mov     r8, [dirty_bits]
    mov     rdx, [row_blocks]
    mov     ecx, edx
    shr     rdx, 6
    mov     r9d, 1
    shl     r9, cl
    or      [r8 + rdx * 8], r9
    mov     rax, r10
    ret
.clean:
    xor     eax, eax
    ret

; next_set(rax=block) -> rax = the first block >= rax whose dirty bit is set
; (row_blocks at the latest, through the sentinel). Clobbers rcx, rdx, r8.
next_set:
    mov     r8, [dirty_bits]
    mov     ecx, eax
    shr     rax, 6
    mov     rdx, -1
    shl     rdx, cl
    and     rdx, [r8 + rax * 8]
    jnz     .found
.word:
    inc     rax
    mov     rdx, [r8 + rax * 8]
    test    rdx, rdx
    jz      .word
.found:
    bsf     rdx, rdx
    shl     rax, 6
    add     rax, rdx
    ret

; next_clear(rax=block < row_blocks) -> rax = the first block >= rax whose
; dirty bit is clear, capped at row_blocks. Clobbers rcx, rdx, r8.
next_clear:
    mov     r8, [dirty_bits]
    mov     ecx, eax
    shr     rax, 6
    mov     rdx, -1
    shl     rdx, cl
    mov     rcx, [r8 + rax * 8]
    not     rcx
    and     rdx, rcx
    jnz     .found
.word:
    inc     rax
    mov     rdx, [r8 + rax * 8]
    not     rdx
    test    rdx, rdx
    jz      .word
.found:
    bsf     rdx, rdx
    shl     rax, 6
    add     rax, rdx
    mov     rcx, [row_blocks]
    cmp     rax, rcx
    cmova   rax, rcx
    ret

; row_buffers(rbp=row, ecx=0 current / 1 other) -> rax = bytes, rdx = block
; starts. Clobbers rcx.
row_buffers:
    mov     rax, [row_sel]
    movzx   eax, byte [rax + rbp]
    xor     ecx, eax
    lea     rcx, [rcx + rbp * 2]        ; buffer index
    mov     rax, [row_stride]
    imul    rax, rcx
    add     rax, [row_store]
    imul    rcx, [offs_stride]
    mov     rdx, [row_offs]
    add     rdx, rcx
    ret

; render_frame -> rax = frame length. The frame's rows are frame_iov[1] ..
; frame_iov[grid_height], top row first; frame_iov[0] and the entry after the
; rows are the caller's.
render_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     byte [grid_valid], 0
    jne     .rows
    call    repaint
.rows:
    mov     r13, [handle_grid]
    mov     r14, [grid_width]
    mov     rbp, [grid_height]
    mov     rbx, [pool_base]
    test    rbp, rbp
    jz      .done
.row:
    dec     rbp                         ; row index, counting down
    test    r14, r14
    jz      .scanned
    mov     rax, rbp
    imul    rax, r14
    call    row_dirty
    cmp     byte [all_dirty], 0
    jne     .full
    test    rax, rax
    jz      .next
    ; a mostly dirty row is cheaper to format whole
    lea     rax, [rax * 4]
    cmp     rax, [full_blocks]
    jae     .full
    call    row_rebuild
    jmp     .next
.scanned:
    cmp     byte [all_dirty], 0
    je      .next
.full:
    call    row_full
.next:
    test    rbp, rbp
    jnz     .row
    ; the rows' iovecs (writev_all consumes its array, so it gets a copy)
    mov     rsi, [row_iov]
    mov     rdi, [frame_iov]
    add     rdi, 16
    mov     rcx, [grid_height]
.iov:
    LD32    0, 1, rsi
    ST32    rdi, 0, 1
    add     rsi, 32
    add     rdi, 32
    sub     rcx, 2
    ja      .iov
.done:
    mov     byte [all_dirty], 0
    mov     rax, [frame_len]
%if TIER >= 3
    vzeroupper
%endif
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; row_end(rbp=row, rdi=end of the row's cells, rsi=block starts, r15 = the
; row's first byte): record the end of the cells, add the joining newline,
; and update the row's iovec and the frame length. Clobbers rax, rcx.
row_end:
    mov     rax, [row_blocks]
    mov     [rsi + rax * 4], edi
    ; every row but the bottom one carries the newline that joins it to the next
    test    rbp, rbp
    jz      .emitted
    mov     byte [rdi], 10
    inc     rdi
.emitted:
    sub     rdi, r15
    ; the top row's iovec comes first
    mov     rax, [grid_height]
    sub     rax, rbp
    shl     rax, 4
    add     rax, [row_iov]
    mov     [rax - 16], r15
    mov     rcx, rdi
    sub     rcx, [rax - 8]
    add     [frame_len], rcx
    mov     [rax - 8], rdi
    ret

; row_full(rbp=row): format every cell of the row into its current buffer.
; r13 = handle grid, r14 = width, rbx = pool base. Clobbers C but rbx, rbp,
; r12-r14.
row_full:
    push    r15
    xor     ecx, ecx
    call    row_buffers
    mov     r15, rax
    mov     rdi, rax
    mov     r9, rdx
    push    rdx
    mov     rsi, rbp
    imul    rsi, r14
    lea     rsi, [r13 + rsi * 4]        ; handles of this row
    lea     rdx, [rsi + r14 * 4]
    call    emit_blocks
    pop     rsi
    call    row_end
    pop     r15
    ret

; row_rebuild(rbp=row): rebuild a row with dirty blocks into its other
; buffer, which becomes current. Runs of clean blocks are copied from the old
; bytes, their starts shifted; dirty runs are formatted. r13 = handle grid,
; r14 = width, rbx = pool base, the row's bitmap in [dirty_bits].
; Clobbers C but rbx, rbp, r12-r14.
row_rebuild:
    push    r12
    push    r15
    sub     rsp, 24
    ; [rsp] = old bytes, [rsp + 8] = old block starts, [rsp + 16] = new ones
    xor     ecx, ecx
    call    row_buffers
    mov     [rsp], rax
    mov     [rsp + 8], rdx
    mov     ecx, 1
    call    row_buffers
    mov     r15, rax
    mov     [rsp + 16], rdx
    mov     rax, [row_sel]
    xor     byte [rax + rbp], 1
    mov     rdi, r15                    ; output
    xor     r12d, r12d                  ; block
.run:
    mov     rax, r12
    call    next_set
    cmp     rax, r12
    je      .dirty
    ; clean blocks r12 .. rax - 1: their bytes move as one piece
    mov     r10, [rsp + 8]
    mov     r11, [rsp + 16]
    mov     ecx, [r10 + r12 * 4]        ; start of the piece, old
    mov     edx, [r10 + rax * 4]        ; its end
    sub     edx, ecx                    ; its length
    mov     r8d, edi
    sub     r8d, ecx                    ; start shift (mod 2^32)
    ; the starts: new = old + shift, a vector at a time (runs over into the
    ; next dirty run's entries, which it rewrites, or the slack)
    lea     r9, [r12 * 4]
    lea     rsi, [rax * 4]
%if TIER >= 4
    vpbroadcastd zmm0, r8d
.starts:
    vpaddd  zmm1, zmm0, [r10 + r9]
    vmovdqu32 [r11 + r9], zmm1
    add     r9, 64
%elif TIER >= 3
    vmovd   xmm0, r8d
    vpbroadcastd ymm0, xmm0
.starts:
    vpaddd  ymm1, ymm0, [r10 + r9]
    vmovdqu [r11 + r9], ymm1
    add     r9, 32
%else
    movd    xmm0, r8d
    pshufd  xmm0, xmm0, 0
.starts:
    movdqu  xmm1, [r10 + r9]
    paddd   xmm1, xmm0
    movdqu  [r11 + r9], xmm1
    add     r9, 16
%endif
    cmp     r9, rsi
    jb      .starts
    ; the bytes (also running over by up to one vector)
    mov     r12, rax
    mov     rsi, [rsp]
    mov     eax, ecx
    sub     eax, esi                    ; offset of the piece in the old row
    add     rsi, rax
    mov     rcx, rdi
    add     rdi, rdx
    ; one unaligned vector, then aligned stores from the next line on
%if TIER >= 4
    vmovdqu64 zmm0, [rsi]
    vmovdqu64 [rcx], zmm0
%else
    LD32    0, 1, rsi
    LD32    2, 3, rsi + 32
    ST32    rcx, 0, 1
    ST32    rcx + 32, 2, 3
%endif
    mov     eax, ecx
    neg     eax
    and     eax, 63
    jnz     .align
    mov     eax, 64                     ; already aligned: the first line is done
.align:
    add     rsi, rax
    add     rcx, rax
    sub     rdx, rax
    jbe     .copied
.bytes:
%if TIER >= 4
    vmovdqu64 zmm0, [rsi]
    vmovdqa64 [rcx], zmm0
%else
    LD32    0, 1, rsi
    LD32    2, 3, rsi + 32
    ST32    rcx, 0, 1
    ST32    rcx + 32, 2, 3
%endif
    add     rsi, 64
    add     rcx, 64
    sub     rdx, 64
    ja      .bytes
.copied:
    cmp     r12, [row_blocks]
    jae     .end
.dirty:
    ; dirty blocks r12 .. next clear - 1
    mov     rax, r12
    call    next_clear
    mov     r9, [rsp + 16]
    lea     r9, [r9 + r12 * 4]
    mov     rcx, rbp
    imul    rcx, r14
    lea     rcx, [r13 + rcx * 4]        ; handles of this row
    lea     rdx, [rcx + r14 * 4]        ; their end
    shl     r12, BLOCK_SHIFT + 2
    lea     rsi, [rcx + r12]
    mov     r12, rax
    shl     rax, BLOCK_SHIFT + 2
    add     rax, rcx
    cmp     rax, rdx
    cmovb   rdx, rax
    call    emit_blocks
    cmp     r12, [row_blocks]
    jb      .run
.end:
    mov     rsi, [rsp + 16]
    call    row_end
    add     rsp, 24
    pop     r15
    pop     r12
    ret

; emit_blocks(rsi=first handle, at a block start, rdx=end, rdi=output,
; r9=the first block's start entry) -> rdi advanced. Each block's start (the
; low half of its output address) is stored at [r9], r9 advancing.
; rbx = pool base. Clobbers rax, rcx, rsi, r8, r9, r10, r11, vector
; registers.
emit_blocks:
    push    r12
    push    r13
.block:
    cmp     rsi, rdx
    jae     .done
    mov     [r9], edi
    add     r9, 4
    lea     r12, [rsi + BLOCK * 4]
    cmp     r12, rdx
    cmova   r12, rdx                    ; the block's end
.quad:
    ; four cells per iteration; one test covers all four lengths (< 32 bytes
    ; leaves bits 5-7 of every length clear, so their OR stays below 32)
    lea     r8, [rsi + 16]
    cmp     r8, r12
    ja      .cell
    mov     eax, [rsi]
    mov     ecx, [rsi + 4]
    mov     r8d, [rsi + 8]
    mov     r10d, [rsi + 12]
    mov     r11d, eax
    or      r11d, ecx
    or      r11d, r8d
    or      r11d, r10d
    test    r11d, 0xE0000000
    jnz     .cell
    add     rsi, 16
    mov     r11d, eax
    shr     r11d, HANDLE_LEN_SHIFT
    and     eax, HANDLE_OFFSET_MASK
    LD32    0, 1, rbx + rax
    mov     r13d, ecx
    shr     r13d, HANDLE_LEN_SHIFT
    and     ecx, HANDLE_OFFSET_MASK
    LD32    2, 3, rbx + rcx
    ST32    rdi, 0, 1
    add     rdi, r11
    mov     r11d, r8d
    shr     r11d, HANDLE_LEN_SHIFT
    and     r8d, HANDLE_OFFSET_MASK
    LD32    4, 5, rbx + r8
    ST32    rdi, 2, 3
    add     rdi, r13
    mov     r13d, r10d
    shr     r13d, HANDLE_LEN_SHIFT
    and     r10d, HANDLE_OFFSET_MASK
    LD32    6, 7, rbx + r10
    ST32    rdi, 4, 5
    add     rdi, r11
    ST32    rdi, 6, 7
    add     rdi, r13
    jmp     .quad
.cell:
    ; one cell at a time: block tails and visuals of 32 bytes or more
    cmp     rsi, r12
    jae     .block
    mov     eax, [rsi]
    add     rsi, 4
    mov     ecx, eax
    and     eax, HANDLE_OFFSET_MASK
    shr     ecx, HANDLE_LEN_SHIFT
    cmp     ecx, 32
    ja      .wide
    LD32    0, 1, rbx + rax
    ST32    rdi, 0, 1
    add     rdi, rcx
    jmp     .quad
.wide:
    COPY128 rdi, rbx + rax
    add     rdi, rcx
    jmp     .quad
.done:
    pop     r13
    pop     r12
    ret

section .tstate
alignb 8
grid_width:     resq 1
grid_height:    resq 1
grid_cells:     resq 1
slot_grid:      resq 1
handle_grid:    resq 1
visible_list:   resq 1
ch_cnext:       resq 1
ch_cprev:       resq 1
cell_rec:       resq 1
visible_pos:    resq 1
visible_count:  resd 1
grid_valid:     resb 1
all_dirty:      resb 1
alignb 8
co_rbase:       resq 1
co_rspan:       resq 1
co_cbase:       resq 1
co_cspan:       resq 1
co_cell0:       resq 1
out_base:       resq 1
row_store:      resq 1
row_stride:     resq 1
row_offs:       resq 1
offs_stride:    resq 1
row_sel:        resq 1
row_iov:        resq 1
frame_len:      resq 1
frame_iov:      resq 1
dirty_cells:    resq 1
dirty_bits:     resq 1
full_blocks:    resq 1
row_blocks:     resq 1
