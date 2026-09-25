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
;   * anything that can change a cell's winner some other way (movement,
;     layer changes, hiding) marks the grid stale, and the next frame repaints
;     from scratch.
;
; Emission streams the handle grid: per cell one load from the pool, one
; store, and an advance by the visual's true length. Each row keeps its bytes
; (with its joining newline) in storage of its own, and a frame is handed to
; the kernel as one iovec per row. A row none of whose cells changed since
; the previous frame is not touched at all - most rows of most frames.

%define EMPTY_SLOT      0xffffffff
%define OUTPUT_RESERVE  (1 << 36)

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
    lea     rbx, [rax * 4 + 64]
    mov     rdi, rbx
    call    alloc
    mov     [slot_grid], rax
    mov     rdi, rbx
    call    alloc
    mov     [handle_grid], rax
    mov     rbx, [char_capacity]
    inc     rbx
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [visible_list], rax
    lea     rdi, [rbx * 4]
    call    alloc
    mov     [visible_pos], rax
    lea     rdi, [rbx * 4 + 64]
    call    alloc
    mov     [ch_cell], rax
    ; every character starts outside the grid
    mov     rdi, rax
    lea     rcx, [rbx + 15]
    shr     rcx, 4
    vpternlogd zmm0, zmm0, zmm0, 0xff
.none:
    vmovdqu32 [rdi], zmm0
    add     rdi, 64
    dec     rcx
    jnz     .none
    vzeroupper
    mov     rdi, OUTPUT_RESERVE
    call    reserve
    mov     [out_base], rax
    ; per-row storage: width * VISUAL_MAX bytes + newline + copy slack
    mov     rax, [grid_width]
    shl     rax, 7
    add     rax, 256
    mov     [row_stride], rax
    imul    rax, [grid_height]
    lea     rdi, [rax + 4096]
    call    reserve
    mov     [row_store], rax
    mov     rbx, [grid_height]
    lea     rdi, [rbx * 8 + 64]
    call    alloc
    mov     [row_bytes], rax
    ; the frame's iovecs: one slot before the rows (prefix / header) and one
    ; after them (the dump's trailing newline)
    mov     rdi, rbx
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     [frame_iov], rax
    mov     rdi, [grid_cells]
    add     rdi, 128
    call    alloc
    mov     [dirty_cells], rax
    mov     byte [grid_valid], 0
    pop     rbx
    ret

; cell_of(edi=slot) -> eax = grid cell of the character's current coordinate,
; or NONE outside the visible window. Clobbers rcx, rdx.
cell_of:
    mov     rax, [ch_row]
    movsxd  rcx, dword [rax + rdi * 4]
    add     rcx, [row_offset]
    mov     rax, [ch_col]
    movsxd  rdx, dword [rax + rdi * 4]
    add     rdx, [col_offset]
    cmp     rcx, [visible_bottom]
    jl      .outside
    cmp     rcx, [visible_top]
    jg      .outside
    cmp     rdx, [visible_left]
    jl      .outside
    cmp     rdx, [visible_right]
    jg      .outside
    dec     rcx
    imul    rcx, [grid_width]
    lea     rax, [rcx + rdx - 1]
    ret
.outside:
    mov     eax, NONE
    ret

; paint(edi=slot, eax=cell): take the cell when empty or when this character
; outranks its owner on (layer, character_id). Clobbers rcx, rdx, rsi, r8.
paint:
    mov     r8, [slot_grid]
    mov     edx, [r8 + rax * 4]
    cmp     edx, EMPTY_SLOT
    je      .take
    mov     rsi, [ch_layer]
    mov     ecx, [rsi + rdi * 4]
    cmp     ecx, [rsi + rdx * 4]
    jg      .take
    jl      .keep
    mov     rsi, [ch_id]
    mov     ecx, [rsi + rdi * 4]
    cmp     ecx, [rsi + rdx * 4]
    jbe     .keep
.take:
    mov     [r8 + rax * 4], edi
    mov     rsi, [ch_handle]
    mov     ecx, [rsi + rdi * 4]
    mov     rsi, [handle_grid]
    mov     [rsi + rax * 4], ecx
    mov     rsi, [dirty_cells]
    mov     byte [rsi + rax], 1
.keep:
    ret

; set_visible(edi=slot): Terminal.set_character_visibility(id, true).
set_visible:
    mov     rax, [ch_flags]
    test    byte [rax + rdi], CF_VISIBLE
    jnz     .done
    or      byte [rax + rdi], CF_VISIBLE
    mov     ecx, [visible_count]
    mov     rax, [visible_list]
    mov     [rax + rcx * 4], edi
    mov     rax, [visible_pos]
    mov     [rax + rdi * 4], ecx
    inc     dword [visible_count]
    cmp     byte [grid_valid], 0
    je      .done
    call    cell_of
    mov     rcx, [ch_cell]
    mov     [rcx + rdi * 4], eax
    cmp     eax, NONE
    je      .done
    jmp     paint
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
    mov     rcx, [grid_cells]
    add     rcx, 15
    shr     rcx, 4
    mov     rax, [slot_grid]
    mov     rdx, [handle_grid]
    vpternlogd zmm0, zmm0, zmm0, 0xff
    vpbroadcastd zmm1, [space_handle]
.clear:
    test    rcx, rcx
    jz      .paint
    vmovdqu32 [rax], zmm0
    vmovdqu32 [rdx], zmm1
    add     rax, 64
    add     rdx, 64
    dec     rcx
    jmp     .clear
.paint:
    vzeroupper
    mov     r12, [visible_list]
    mov     r13d, [visible_count]
    xor     ebx, ebx
.next:
    cmp     ebx, r13d
    jae     .done
    mov     edi, [r12 + rbx * 4]
    inc     ebx
    call    cell_of
    mov     rcx, [ch_cell]
    mov     [rcx + rdi * 4], eax
    cmp     eax, NONE
    je      .next
    call    paint
    jmp     .next
.done:
    mov     byte [grid_valid], 1
    mov     byte [all_dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

; row_dirty(rsi=row's handles) -> ZF clear when any of the row's cells
; changed; the row's dirty bytes are cleared. r13 = handle grid, r14 = width.
; Clobbers rax, rcx, r8, r9.
row_dirty:
    mov     rax, rsi
    sub     rax, r13
    shr     rax, 2
    add     rax, [dirty_cells]          ; first dirty byte of the row
    mov     rcx, r14
    kxorq   k2, k2, k2
    vpxorq  zmm1, zmm1, zmm1
.chunk:
    cmp     rcx, 64
    jb      .tail
    vmovdqu8 zmm0, [rax]
    vptestmb k1, zmm0, zmm0
    korq    k2, k2, k1
    vmovdqu8 [rax], zmm1
    add     rax, 64
    sub     rcx, 64
    jmp     .chunk
.tail:
    test    rcx, rcx
    jz      .result
    mov     r8, -1
    bzhi    r8, r8, rcx
    kmovq   k3, r8
    vmovdqu8 zmm0{k3}{z}, [rax]
    vptestmb k1, zmm0, zmm0
    korq    k2, k2, k1
    vmovdqu8 [rax]{k3}, zmm1
.result:
    kortestq k2, k2
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
    mov     r12, [frame_iov]
    add     r12, 16                     ; first row's iovec
    xor     r15d, r15d                  ; frame length
    test    rbp, rbp
    jz      .done
    dec     rbp                         ; row index, counting down
.row:
    mov     rsi, rbp
    imul    rsi, r14
    lea     rsi, [r13 + rsi * 4]        ; handles of this row
    lea     rdx, [rsi + r14 * 4]        ; end of row
    call    row_dirty
    jnz     .emit
    cmp     byte [all_dirty], 0
    je      .keep
.emit:
    mov     rdi, rbp
    imul    rdi, [row_stride]
    add     rdi, [row_store]
    push    rdi
    call    emit_row
    ; every row but the bottom one carries the newline that joins it to the next
    test    rbp, rbp
    jz      .emitted
    mov     byte [rdi], 10
    inc     rdi
.emitted:
    pop     rax
    sub     rdi, rax
    mov     rcx, [row_bytes]
    mov     [rcx + rbp * 8], rdi
.keep:
    mov     rax, rbp
    imul    rax, [row_stride]
    add     rax, [row_store]
    mov     rcx, [row_bytes]
    mov     rcx, [rcx + rbp * 8]
    mov     [r12], rax
    mov     [r12 + 8], rcx
    add     r12, 16
    add     r15, rcx
    test    rbp, rbp
    jz      .done
    dec     rbp
    jmp     .row
.done:
    mov     byte [all_dirty], 0
    mov     rax, r15
    vzeroupper
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; emit_row(rsi=first handle, rdx=end, rdi=output) -> rdi advanced.
; rbx = pool base. Clobbers rax, rcx, rsi, r8, r9, r10, r11 (saved here).
emit_row:
    push    r10
    push    r11
.quad:
    ; four cells per iteration; one test covers all four lengths (< 32 bytes
    ; leaves bits 5-7 of every length clear, so their OR stays below 32)
    lea     r8, [rsi + 16]
    cmp     r8, rdx
    ja      .cell
    mov     eax, [rsi]
    mov     ecx, [rsi + 4]
    mov     r8d, [rsi + 8]
    mov     r9d, [rsi + 12]
    mov     r10d, eax
    or      r10d, ecx
    or      r10d, r8d
    or      r10d, r9d
    test    r10d, 0xE0000000
    jnz     .cell
    add     rsi, 16
    rorx    r10d, eax, HANDLE_LEN_SHIFT
    and     eax, HANDLE_OFFSET_MASK
    movzx   r10d, r10b
    vmovdqu ymm0, [rbx + rax]
    rorx    r11d, ecx, HANDLE_LEN_SHIFT
    and     ecx, HANDLE_OFFSET_MASK
    movzx   r11d, r11b
    vmovdqu ymm1, [rbx + rcx]
    vmovdqu [rdi], ymm0
    add     rdi, r10
    rorx    r10d, r8d, HANDLE_LEN_SHIFT
    and     r8d, HANDLE_OFFSET_MASK
    movzx   r10d, r10b
    vmovdqu ymm2, [rbx + r8]
    vmovdqu [rdi], ymm1
    add     rdi, r11
    rorx    r11d, r9d, HANDLE_LEN_SHIFT
    and     r9d, HANDLE_OFFSET_MASK
    movzx   r11d, r11b
    vmovdqu ymm3, [rbx + r9]
    vmovdqu [rdi], ymm2
    add     rdi, r10
    vmovdqu [rdi], ymm3
    add     rdi, r11
    jmp     .quad
.cell:
    ; one cell at a time: row tails and visuals of 32 bytes or more
    cmp     rsi, rdx
    jae     .done
    mov     eax, [rsi]
    add     rsi, 4
    mov     ecx, eax
    and     eax, HANDLE_OFFSET_MASK
    shr     ecx, HANDLE_LEN_SHIFT
    cmp     ecx, 32
    ja      .wide
    vmovdqu ymm0, [rbx + rax]
    vmovdqu [rdi], ymm0
    add     rdi, rcx
    jmp     .quad
.wide:
    vmovdqu64 zmm0, [rbx + rax]
    vmovdqu64 [rdi], zmm0
    vmovdqu64 zmm0, [rbx + rax + 64]
    vmovdqu64 [rdi + 64], zmm0
    add     rdi, rcx
    jmp     .quad
.done:
    pop     r11
    pop     r10
    ret

section .tstate
alignb 8
grid_width:     resq 1
grid_height:    resq 1
grid_cells:     resq 1
slot_grid:      resq 1
handle_grid:    resq 1
visible_list:   resq 1
visible_pos:    resq 1
ch_cell:        resq 1
visible_count:  resd 1
grid_valid:     resb 1
all_dirty:      resb 1
alignb 8
out_base:       resq 1
row_store:      resq 1
row_stride:     resq 1
row_bytes:      resq 1
frame_iov:      resq 1
dirty_cells:    resq 1
