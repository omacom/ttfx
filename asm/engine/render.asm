; engine/render.asm - visibility and the frame renderer
; (terminal.rs update_render_cells + get_formatted_output_string).
;
; The cell grid keeps, per cell, the winning slot (maximum (layer,
; character_id), exactly Rust's painter order) and that winner's visual
; handle. Rust rebuilds it every frame; here it is maintained incrementally,
; by the renderer alone. The effect's side (set_visibility,
; coordinate_changed, layer_changed, SET_HANDLE) only appends records to the
; frame's change log (ttfx.inc), and the renderer replays the log before it
; formats the frame (render_apply):
;
;   * a visual change reaches the grid when its character owns the cell;
;   * a character entering a cell competes for it on the spot;
;   * movement, layer changes and hiding move the character between the
;     cells' occupant lists, and a cell whose owner left picks the best of the
;     rest (cell_rewin) once the log is replayed.
;
; Replaying the log in order gives the grid a direct update would, since the
; winner of a cell depends only on its occupants. That lets the renderer run
; on a thread of its own (the frame ring, below). Nothing outside this file
; reads the grid.
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
; an owner to be chosen again once the frame's log is replayed
%define PENDING_SLOT    0xfffffffe
; per-cell record (cell_rec, 8 bytes): the occupant list's head and the
; owner's layer; the owner itself is in [owner_grid], a dense array that
; the common visual change checks alone
%define CR_HEAD         0
%define CR_LAYER        4
; the renderer's per-character pairs (8 bytes per slot)
%define RL_NEXT         0               ; [rs_link]: the cell's next occupant
%define RL_LAYER        4
%define RC_PREV         0               ; [rs_cell]: its previous occupant
%define RC_CELL         4               ; cell + 1, 0 = none
; spins before an idle renderer sleeps
%define RENDER_SPIN     256
; cells per dirty block (one emission quad)
%define BLOCK           4
%define BLOCK_SHIFT     2
; a clean gap of fewer blocks than this between dirty runs is formatted
; along with them: a copy has a fixed cost of several blocks' formatting
%define MIN_GAP         4
; cells per dirty chunk (the coarse summary of dirty_cells)
%define CHUNK_SHIFT     6
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

; MARK_DIRTY cell, scratch: the cell changed; so did its CHUNK-cell chunk,
; which render_frame checks before it scans a row's cells. cell is a 64-bit
; register; both are clobbered.
%macro MARK_DIRTY 2
    mov     %2, [dirty_cells]
    mov     byte [%2 + %1], 1
    shr     %1, CHUNK_SHIFT
    add     %1, [dirty_chunks]
    mov     byte [%1], 1
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
    mov     rdi, [grid_cells]
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     [handle_grid], rax
    mov     rdi, CHAR_LIMIT * 8
    call    reserve_small
    mov     [rs_link], rax
    mov     rdi, CHAR_LIMIT * 8
    call    reserve_small
    mov     [rs_cell], rax
    mov     rdi, [grid_cells]
    lea     rdi, [rdi * 8 + 64]
    call    reserve
    mov     [cell_rec], rax
    mov     rdi, [grid_cells]
    lea     rdi, [rdi * 4 + 64]
    call    reserve
    mov     [owner_grid], rax
    ; the empty grid: no occupants, no owners, blank cells, all to be drawn
    mov     rdi, [cell_rec]
    mov     rcx, [grid_cells]
    mov     rax, NONE
.records:
    test    rcx, rcx
    jz      .owners
    mov     [rdi + CR_HEAD], eax
    add     rdi, 8
    dec     rcx
    jmp     .records
.owners:
    mov     rdi, [owner_grid]
    mov     rcx, [grid_cells]
    rep     stosd
    mov     rdi, [handle_grid]
    mov     eax, [space_handle]
    mov     rcx, [grid_cells]
    rep     stosd
    mov     byte [all_dirty], 1
    ; the change logs, one per ring entry, and the first one open
    mov     rdi, FRAME_RING << LOG_SHIFT
    call    reserve_small               ; touched a stretch per entry
    mov     [log_ptr], rax
    lea     rcx, [ring]
    xor     edx, edx
.logs:
    mov     [rcx + FS_LOG], rax
    add     rax, 1 << LOG_SHIFT
    add     rcx, FS_SIZE
    inc     edx
    cmp     edx, FRAME_RING
    jb      .logs
    mov     rdi, OUTPUT_RESERVE
    call    reserve_small
    mov     [out_base], rax
    ; each ring entry's pending bytes (a frame's prefix) get an equal share
    lea     rcx, [ring]
    xor     edx, edx
.prefixes:
    mov     [rcx + FS_PREFIX], rax
    mov     rdi, OUTPUT_RESERVE / FRAME_RING
    add     rax, rdi
    add     rcx, FS_SIZE
    inc     edx
    cmp     edx, FRAME_RING
    jb      .prefixes
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
    lea     rdi, [rbx + 2]
    shl     rdi, 4
    call    alloc
    mov     [frame_iov], rax
    add     rax, 16
    mov     [row_iov], rax
    lea     rdi, [rbx + 2]
    shl     rdi, 4
    call    alloc
    mov     [iov_scratch], rax
    mov     rdi, [grid_cells]
    add     rdi, 128
    call    alloc
    mov     [dirty_cells], rax
    mov     rdi, [grid_cells]
    shr     rdi, CHUNK_SHIFT
    add     rdi, 64
    call    alloc
    mov     [dirty_chunks], rax
    mov     rdi, [grid_height]
    add     rdi, 64
    call    alloc
    mov     [dirty_rows], rax
    mov     rdi, [grid_cells]
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     [pending_cells], rax
    mov     rdi, [grid_width]
    shr     rdi, 6
    add     rdi, 64
    call    alloc
    mov     [dirty_bits], rax
    pop     rbx
    ret

; cell_of(edi=slot) -> eax = grid cell of the character's current coordinate,
; or NONE outside the visible window. Clobbers rcx, rdx.
cell_of:
    CELL_OF
    ret

; ------------------------------------------------------------ the main side
; These run with the effect: they keep ch_cell and append to the frame's
; change log (ttfx.inc), and never touch the grid itself.

; LOG_REC op, value register: append (slot edi | op, value). Clobbers rcx, rdx.
%macro LOG_REC 2
    mov     rcx, [log_ptr]
    mov     edx, edi
    or      edx, %1
    mov     [rcx], edx
    mov     [rcx + 4], %2
    add     rcx, 8
    mov     [log_ptr], rcx
%endmacro

; set_visibility(edi=slot, esi=visible): Terminal.set_character_visibility.
set_visibility:
    test    esi, esi
    jnz     set_visible
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jz      .done
    and     word [rax + rdi * 2], ~CF_VISIBLE
    mov     rax, [ch_cell]
    cmp     dword [rax + rdi * 4], NONE
    je      .done
    mov     dword [rax + rdi * 4], NONE
    mov     eax, NONE
    LOG_REC LOG_MOVE, eax
.done:
    ret

; set_visible(edi=slot): Terminal.set_character_visibility(id, true).
set_visible:
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jnz     .done
    or      word [rax + rdi * 2], CF_VISIBLE
    CELL_OF
    cmp     eax, NONE
    jne     enter_cell
.done:
    ret

; enter_cell(edi=slot, eax=cell): a character without a cell takes one. The
; renderer learns its visual and layer first. Clobbers rcx, rdx.
enter_cell:
    mov     rcx, [ch_cell]
    mov     [rcx + rdi * 4], eax
    mov     rcx, [log_ptr]
    cmp     byte [log_handles], 0
    je      .unlogged
    mov     rdx, [ch_handle]
    mov     edx, [rdx + rdi * 4]
    mov     [rcx], edi                  ; LOG_HANDLE
    mov     [rcx + 4], edx
    mov     rdx, [ch_layer]
    mov     edx, [rdx + rdi * 4]
    mov     [rcx + 12], edx
    mov     edx, edi
    or      edx, LOG_LAYER
    mov     [rcx + 8], edx
    xor     edx, LOG_LAYER | LOG_MOVE
    mov     [rcx + 16], edx
    mov     [rcx + 20], eax
    add     rcx, 24
    mov     [log_ptr], rcx
    ret
.unlogged:
    ; the renderer reads the visual from ch_handle
    mov     rdx, [ch_layer]
    mov     edx, [rdx + rdi * 4]
    mov     [rcx + 4], edx
    mov     edx, edi
    or      edx, LOG_LAYER
    mov     [rcx], edx
    xor     edx, LOG_LAYER | LOG_MOVE
    mov     [rcx + 8], edx
    mov     [rcx + 12], eax
    add     rcx, 16
    mov     [log_ptr], rcx
    ret

; handle_direct(edi=slot, eax=handle, ecx=its cell): SET_HANDLE without a
; render thread: the cell shows the visual at once when the character owns
; it. The grid is only the renderer's between frames, and one whose move is
; still in the log settles when the log is replayed. Clobbers rcx.
handle_direct:
    push    rdx
    mov     rdx, [owner_grid]
    cmp     [rdx + rcx * 4], edi
    jne     .done
    mov     rdx, [handle_grid]
    cmp     [rdx + rcx * 4], eax
    je      .done
    mov     [rdx + rcx * 4], eax
    MARK_DIRTY rcx, rdx
.done:
    pop     rdx
    ret

; coordinate_changed(edi=slot, rsi=its new coordinate, packed): the
; character's current coordinate changed (set_coordinate); a visible
; character that changes cells logs the move. Clobbers rax, rcx, rdx.
coordinate_changed:
    mov     rax, [ch_flags]
    test    word [rax + rdi * 2], CF_VISIBLE
    jz      .done
    ; the cell, as CELL_OF
    mov     rcx, rsi
    sar     rcx, 32
    movsxd  rdx, esi
    mov     rax, rcx
    add     rax, [co_rbase]
    cmp     rax, [co_rspan]
    ja      .outside
    mov     rax, rdx
    add     rax, [co_cbase]
    cmp     rax, [co_cspan]
    ja      .outside
    imul    rcx, [grid_width]
    add     rdx, [co_cell0]
    lea     rax, [rcx + rdx]
    jmp     .cell
.outside:
    mov     eax, NONE
.cell:
    mov     rcx, [ch_cell]
    mov     edx, [rcx + rdi * 4]
    cmp     edx, eax
    je      .done
    cmp     edx, NONE
    je      enter_cell
    mov     [rcx + rdi * 4], eax
    LOG_REC LOG_MOVE, eax
.done:
    ret

; layer_changed(edi=slot): the character's layer changed. Clobbers rax, rcx,
; rdx.
layer_changed:
    mov     rax, [ch_cell]
    cmp     dword [rax + rdi * 4], NONE
    je      .done
    mov     rax, [ch_layer]
    mov     eax, [rax + rdi * 4]
    LOG_REC LOG_LAYER, eax
.done:
    ret

; set_handle(edi=slot, eax=handle): see SET_HANDLE in ttfx.inc.
set_handle:
    SET_HANDLE
    ret

; ------------------------------------------------------------ the render side
; The renderer's own copy of what it needs per character, in dense arrays
; indexed by slot like the ch_* fields: [rs_link] holds (next occupant of
; the cell, layer), the pair a cell's scan reads; [rs_cell] holds (previous
; occupant, cell + 1, 0 = none), so the zeroed reservation starts out right
; for every slot; [rs_handle] the visual.

; render_apply(rsi=log start, rdi=log end): replay a change log onto the
; grid. Clobbers C but rbx, rbp, r12-r15.
render_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rsi
    mov     r13, rdi
    mov     rbx, [rs_link]
    mov     r14, [rs_cell]
.next:
    cmp     r12, r13
    jae     .done
    mov     edi, [r12]
    mov     eax, [r12 + 4]
    add     r12, 8
    mov     ecx, edi
    and     edi, LOG_SLOT_MASK
    shr     ecx, 30
    cmp     ecx, 1
    jb      .handle
    je      .layer
    ; a move: leave the old cell, join the new one
    mov     r11d, eax
    call    cell_unlink
    cmp     r11d, NONE
    je      .next
    mov     eax, r11d
    call    cell_link
    jmp     .next
.handle:
    ; the owner of a cell shows its new visual at once
    mov     rdx, [rs_handle]
    mov     [rdx + rdi * 4], eax
    mov     ecx, [r14 + rdi * 8 + RC_CELL]
    test    ecx, ecx
    jz      .next
    dec     ecx
    mov     rdx, [owner_grid]
    cmp     [rdx + rcx * 4], edi
    jne     .next
    mov     rdx, [handle_grid]
    cmp     [rdx + rcx * 4], eax
    je      .next
    mov     [rdx + rcx * 4], eax
    MARK_DIRTY rcx, rdx
    jmp     .next
.layer:
    ; the cell picks its owner again
    mov     [rbx + rdi * 8 + RL_LAYER], eax
    mov     eax, [r14 + rdi * 8 + RC_CELL]
    test    eax, eax
    jz      .next
    dec     eax
    call    cell_pending
    jmp     .next
.done:
    ; the crowded cells whose owner left choose again, once each
    mov     r12, [pending_cells]
    mov     r13d, [pending_count]
    mov     dword [pending_count], 0
.pending:
    test    r13d, r13d
    jz      .applied
    dec     r13d
    mov     eax, [r12 + r13 * 4]
    call    cell_rewin
    jmp     .pending
.applied:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; cell_link(edi=slot, eax=cell): put a visible character into a cell's list
; and let it compete for the cell. rbx = [rs_link], r14 = [rs_cell].
; Clobbers rcx, rdx, r8.
cell_link:
    lea     ecx, [rax + 1]
    mov     [r14 + rdi * 8 + RC_CELL], ecx
    mov     dword [r14 + rdi * 8 + RC_PREV], NONE
    mov     r8, [cell_rec]
    lea     r8, [r8 + rax * 8]
    mov     edx, [r8 + CR_HEAD]
    mov     [rbx + rdi * 8 + RL_NEXT], edx
    mov     [r8 + CR_HEAD], edi
    cmp     edx, NONE
    je      paint_rec
    mov     [r14 + rdx * 8 + RC_PREV], edi
; paint_rec(edi=slot, eax=cell, r8=the cell's record): take the cell when
; empty or when this character outranks its owner on (layer, character_id);
; a cell whose owner is pending chooses later. Clobbers rcx, rdx.
paint_rec:
    mov     ecx, [rbx + rdi * 8 + RL_LAYER]
    mov     rdx, [owner_grid]
    mov     edx, [rdx + rax * 4]
    cmp     edx, PENDING_SLOT
    jae     .other
    cmp     ecx, [r8 + CR_LAYER]
    jg      .take
    jl      .keep
    cmp     edi, edx
    jbe     .keep
.take:
    mov     rdx, [owner_grid]
    mov     [rdx + rax * 4], edi
    mov     [r8 + CR_LAYER], ecx
    mov     rcx, [rs_handle]
    mov     ecx, [rcx + rdi * 4]
    mov     rdx, [handle_grid]
    mov     [rdx + rax * 4], ecx
    mov     rcx, rax
    MARK_DIRTY rcx, rdx
.keep:
    ret
.other:
    je      .keep                       ; pending
    jmp     .take                       ; empty

; cell_unlink(edi=slot): take a character out of its cell; if it owned the
; cell, the best remaining character (or nobody) takes over: at once when
; one or none is left, else once the log is replayed. rbx = [rs_link],
; r14 = [rs_cell]. Clobbers rax, rcx, rdx, rsi, r8, r9.
cell_unlink:
    mov     r9d, [r14 + rdi * 8 + RC_CELL]
    test    r9d, r9d
    jz      .done
    mov     dword [r14 + rdi * 8 + RC_CELL], 0
    dec     r9d
    mov     r8, [cell_rec]
    lea     r8, [r8 + r9 * 8]
    mov     edx, [rbx + rdi * 8 + RL_NEXT]
    mov     eax, [r14 + rdi * 8 + RC_PREV]
    cmp     eax, NONE
    je      .was_head
    mov     [rbx + rax * 8 + RL_NEXT], edx
    jmp     .fix_next
.was_head:
    mov     [r8 + CR_HEAD], edx
.fix_next:
    cmp     edx, NONE
    je      .owner
    mov     [r14 + rdx * 8 + RC_PREV], eax
.owner:
    mov     rcx, [owner_grid]
    cmp     [rcx + r9 * 4], edi
    jne     .done
    mov     eax, r9d
    mov     ecx, [r8 + CR_HEAD]
    cmp     ecx, NONE
    je      cell_rewin                  ; empty now
    cmp     dword [rbx + rcx * 8 + RL_NEXT], NONE
    je      cell_rewin                  ; one left
    jmp     cell_pending
.done:
    ret

; cell_pending(eax=cell): the cell's owner is chosen again (cell_rewin) once
; the log is replayed: a crowded cell that many leave in one frame is
; scanned once, not once per departure. Clobbers rcx, rdx.
cell_pending:
    mov     rcx, [owner_grid]
    cmp     dword [rcx + rax * 4], PENDING_SLOT
    je      .done
    mov     dword [rcx + rax * 4], PENDING_SLOT
    mov     rcx, [pending_cells]
    mov     edx, [pending_count]
    mov     [rcx + rdx * 4], eax
    inc     dword [pending_count]
.done:
    ret

; cell_rewin(eax=cell): the cell's owner is the best of its list, or nobody;
; the cell shows it and is marked changed. rbx = [rs_link]. Clobbers rcx,
; rdx, rsi, r8, r9.
cell_rewin:
    push    r15
    mov     r9, [cell_rec]
    lea     r9, [r9 + rax * 8]
    mov     ecx, [r9 + CR_HEAD]         ; candidate
    mov     r15d, NONE                  ; best so far, esi its layer
.scan:
    cmp     ecx, NONE
    je      .chosen
    mov     r8d, [rbx + rcx * 8 + RL_LAYER]
    mov     edx, [rbx + rcx * 8 + RL_NEXT]
    cmp     r15d, NONE
    je      .take
    cmp     r8d, esi
    jg      .take
    jl      .next
    cmp     ecx, r15d
    jbe     .next
.take:
    mov     r15d, ecx
    mov     esi, r8d
.next:
    mov     ecx, edx
    jmp     .scan
.chosen:
    mov     rdx, [owner_grid]
    mov     [rdx + rax * 4], r15d
    mov     rdx, [handle_grid]
    cmp     r15d, NONE
    je      .empty
    mov     [r9 + CR_LAYER], esi
    mov     rcx, [rs_handle]
    mov     ecx, [rcx + r15 * 4]
    mov     [rdx + rax * 4], ecx
    jmp     .dirty
.empty:
    mov     ecx, [space_handle]
    mov     [rdx + rax * 4], ecx
.dirty:
    mov     rcx, rax
    MARK_DIRTY rcx, rsi
    pop     r15
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
; frame_iov[grid_height] (row_iov[0] ..), top row first; frame_iov[0] and the
; entry after the rows are the caller's. The array is the rows' own record, so
; it is written with writev_keep.
render_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, [handle_grid]
    mov     r14, [grid_width]
    mov     rbp, [grid_height]
    mov     rbx, [pool_base]
    test    rbp, rbp
    jz      .done
    cmp     byte [all_dirty], 0
    jne     .row
    call    rows_marked
.row:
    dec     rbp                         ; row index, counting down
    test    r14, r14
    jz      .scanned
    mov     rax, rbp
    imul    rax, r14
    cmp     byte [all_dirty], 0
    jne     .whole
    ; a row none of whose chunks changed is clean
    mov     rcx, [dirty_rows]
    cmp     byte [rcx + rbp], 0
    je      .next
    mov     byte [rcx + rbp], 0
    call    row_dirty
    test    rax, rax
    jz      .next
    ; a mostly dirty row is cheaper to format whole
    lea     rax, [rax * 4]
    cmp     rax, [full_blocks]
    jae     .full
    call    row_rebuild
    jmp     .next
.whole:
    call    row_dirty                   ; clears the row's marks
    jmp     .full
.scanned:
    cmp     byte [all_dirty], 0
    je      .next
.full:
    call    row_full
.next:
    test    rbp, rbp
    jnz     .row
    cmp     byte [all_dirty], 0
    je      .done
    ; the chunk marks are spent
    mov     rdi, [dirty_chunks]
    mov     rcx, [grid_cells]
    shr     rcx, CHUNK_SHIFT
    inc     rcx
    xor     eax, eax
    rep     stosb
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

; rows_marked: flag in [dirty_rows] every row that a marked chunk touches,
; and clear the chunk marks. One walk up the chunks and rows together.
; r14 = width, nonzero. Clobbers rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11.
rows_marked:
    mov     rsi, [dirty_chunks]
    mov     rdi, [dirty_rows]
    mov     r10, [grid_cells]
    add     r10, (1 << CHUNK_SHIFT) - 1
    shr     r10, CHUNK_SHIFT            ; chunks
    xor     ecx, ecx                    ; chunk
    xor     r8d, r8d                    ; row
    mov     r9, r14                     ; the row's end cell
    mov     r11, [grid_height]
.eight:
    cmp     rcx, r10
    jae     .done
    cmp     qword [rsi + rcx], 0
    jne     .bytes
    add     rcx, 8
    jmp     .eight
.bytes:
    lea     rdx, [rcx + 8]              ; the eight's end
.byte:
    cmp     byte [rsi + rcx], 0
    je      .skip
    mov     byte [rsi + rcx], 0
    mov     rax, rcx
    shl     rax, CHUNK_SHIFT            ; the chunk's first cell
.find:
    cmp     r9, rax
    ja      .found
    inc     r8
    add     r9, r14
    jmp     .find
.found:
    add     rax, (1 << CHUNK_SHIFT) - 1 ; its last
    push    r8
    push    r9
.flag:
    cmp     r8, r11
    jae     .flagged
    mov     byte [rdi + r8], 1
    cmp     r9, rax
    ja      .flagged
    inc     r8
    add     r9, r14
    jmp     .flag
.flagged:
    pop     r9
    pop     r8
.skip:
    inc     rcx
    cmp     rcx, rdx
    jb      .byte
    jmp     .eight
.done:
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
.extend:
    ; a short clean gap joins the run
    cmp     rax, [row_blocks]
    jae     .extended
    push    rax
    call    next_set
    pop     rcx
    lea     rdx, [rcx + MIN_GAP]
    cmp     rax, rdx
    jae     .gap_kept
    cmp     rax, [row_blocks]
    jae     .gap_kept
    call    next_clear
    jmp     .extend
.gap_kept:
    mov     rax, rcx
.extended:
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
; r9=the first block's start entry) -> rdi advanced. Each 4-cell block's
; start (the low half of its output address) is stored at [r9], r9
; advancing. rbx = pool base. Clobbers rax, rcx, rsi, r8, r9, r10, r11,
; vector registers.
emit_blocks:
    push    r12
    push    r13
.quad:
    ; a block per iteration; one test covers all four lengths (< 32 bytes
    ; leaves bits 5-7 of every length clear, so their OR stays below 32)
    lea     r8, [rsi + 16]
    cmp     r8, rdx
    ja      .tail
    mov     [r9], edi
    add     r9, 4
    mov     eax, [rsi]
    mov     ecx, [rsi + 4]
    mov     r8d, [rsi + 8]
    mov     r10d, [rsi + 12]
    mov     r11d, eax
    or      r11d, ecx
    or      r11d, r8d
    or      r11d, r10d
    test    r11d, 0xE0000000
    jnz     .slow
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
.slow:
    ; a block with a visual of 32 bytes or more: cell by cell
    lea     r12, [rsi + 16]
    jmp     .cell
.tail:
    ; the row's last, partial block
    cmp     rsi, rdx
    jae     .done
    mov     [r9], edi
    add     r9, 4
    mov     r12, rdx
.cell:
    cmp     rsi, r12
    jae     .quad
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
    jmp     .cell
.wide:
    COPY128 rdi, rbx + rax
    add     rdi, rcx
    jmp     .cell
.done:
    pop     r13
    pop     r12
    ret

; ------------------------------------------------------------ the frame ring
; Unpaced runs render on a thread of their own: the main thread runs the
; effect and logs its grid changes; the render thread replays frame N's log,
; formats and writes frame N while the main thread computes frame N+1. A
; frame is handed over through a ring of FRAME_RING entries (its log and its
; prefix bytes); r_submitted and r_completed count frames through it. Each
; side sleeps on a futex word of its own (render_seq, main_seq) with a
; *_sleeping flag the other side checks after a locked update, so a wake is
; only a syscall when someone sleeps. Without the thread, the main thread
; renders each frame itself from ring entry 0 (frame_submit, lib.asm).

; render_emit(rdi=ring entry) -> rax = 0 or -errno: replay the entry's log,
; format the frame, and write it with the entry's prefix bytes first.
; Clobbers C but rbx, rbp, r12-r15.
render_emit:
    push    rbx
    mov     rbx, rdi
    mov     rsi, [rbx + FS_LOG]
    mov     rdi, [rbx + FS_LOG_END]
    call    render_apply
    call    render_frame
    mov     rdi, [frame_iov]
    mov     rax, [rbx + FS_PREFIX]
    mov     [rdi], rax
    mov     rdx, [rbx + FS_PREFIX_LEN]
    mov     [rdi + 8], rdx
    add     rdx, [frame_len]
    mov     esi, [grid_height]
    inc     esi
    mov     rcx, [iov_scratch]
    call    writev_keep
    pop     rbx
    ret

; render_catch_up: replay the open log (ring entry 0's) and empty it, for a
; caller that renders on the main thread. Clobbers C but rbx, rbp, r12-r15.
render_catch_up:
    mov     rsi, [ring + FS_LOG]
    mov     rdi, [log_ptr]
    mov     [log_ptr], rsi
    jmp     render_apply

; pipeline_plan: before the effect is built, decide whether the frames will
; go to a render thread: output that is not paced on the real clock (and not
; the parity dump), at least two CPUs to run on, and no TTFX_ASM_THREADS=1
; (which keeps every run single-threaded, for testing). With one, visual
; changes are logged for the renderer (log_handles), which keeps a visual
; array of its own. Without, a visual change shows in the grid on the spot
; (handle_direct), and the renderer reads ch_handle itself: it only ever
; runs between frames. Clobbers C.
pipeline_plan:
    mov     rax, [ch_handle]
    mov     [rs_handle], rax
    cmp     byte [cfg_parity_dump], 0
    jne     .done
    cmp     byte [clock_is_virtual], 0
    jne     .unpaced
    cmp     qword [cfg_frame_rate], 0
    jne     .done
.unpaced:
    lea     rdi, [env_threads]
    ZEROUPPER
    CCALL   getenv
    test    rax, rax
    jz      .cpus
    cmp     word [rax], '1'             ; "1", NUL
    je      .done
.cpus:
    ; the CPUs this thread may run on: two or more (as far as it matters)
    sub     rsp, 128
    xor     edi, edi
    mov     esi, 128
    mov     rdx, rsp
    SYSCALL SYS_sched_getaffinity
    xor     ecx, ecx
    test    rax, rax
    jle     .counted
    shr     rax, 3
    xor     edx, edx
.word:
    mov     r8, [rsp + rdx * 8]
    test    r8, r8
    jz      .skip
    inc     ecx
    lea     r9, [r8 - 1]
    test    r8, r9
    jz      .skip
    inc     ecx                         ; two or more in this word
.skip:
    inc     rdx
    cmp     rdx, rax
    jb      .word
.counted:
    add     rsp, 128
    cmp     ecx, 2
    jb      .done
    mov     byte [log_handles], 1
    mov     rdi, CHAR_LIMIT * 4
    call    reserve_small
    mov     [rs_handle], rax
.done:
    ret

; pipeline_start: start the render thread planned for (pipeline_plan). Without
; it, frames are rendered on the main thread. Clobbers C.
pipeline_start:
    cmp     byte [log_handles], 0
    je      .done
    lea     rdi, [render_thread]
    lea     rsi, [render_tid]
    call    thread_start
    test    eax, eax
    jnz     .done                       ; no thread: render here
    mov     byte [pipe_running], 1
.done:
    ret

; pipeline_finish -> rax = -errno of the first frame that failed to write, or
; 0. Every frame handed over is written (or, after a failure, dropped) and
; the render thread has ended. Safe to call when there is none. Clobbers C.
pipeline_finish:
    cmp     byte [pipe_running], 0
    je      .done
    mov     byte [render_quit], 1
    xor     eax, eax
    xchg    [render_sleeping], al       ; locked: orders the store above
    test    al, al
    jz      .join
    lock inc dword [render_seq]
    lea     rdi, [render_seq]
    call    futex_wake
.join:
    mov     rdi, [render_tid]
    call    thread_join
    mov     byte [pipe_running], 0
.done:
    mov     rax, [render_err]
    ret

; render_thread: the render thread's start routine. Renders the frames
; handed over, in order, until told to quit with none left. After a failed
; write it only drops frames (the run is ending).
render_thread:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
.loop:
    mov     eax, [r_completed]
    cmp     eax, [r_submitted]
    jne     .work
    cmp     byte [render_quit], 0
    jne     .quitting
    mov     ebx, RENDER_SPIN
.spin:
    pause
    mov     eax, [r_completed]
    cmp     eax, [r_submitted]
    jne     .work
    cmp     byte [render_quit], 0
    jne     .quitting
    dec     ebx
    jnz     .spin
    ; sleep: the futex word first, then the flag, then a last look
    mov     esi, [render_seq]
    mov     al, 1
    xchg    [render_sleeping], al
    mov     eax, [r_completed]
    cmp     eax, [r_submitted]
    jne     .awake
    cmp     byte [render_quit], 0
    jne     .awake
    lea     rdi, [render_seq]
    call    futex_wait
.awake:
    mov     byte [render_sleeping], 0
    jmp     .loop
.quitting:
    ; quit comes after the last frame: one more look at the count
    mov     eax, [r_completed]
    cmp     eax, [r_submitted]
    jne     .work
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    xor     eax, eax
    ZEROUPPER
    ret
.work:
    and     eax, FRAME_RING - 1
    shl     eax, FS_SHIFT
    lea     rdi, [ring]
    add     rdi, rax
    cmp     qword [render_err], 0
    jne     .done
    call    render_emit
    test    rax, rax
    jz      .done
    mov     [render_err], rax
.done:
    lock inc dword [r_completed]
    ; a main thread waiting for room wakes when half the ring is free
    cmp     byte [main_sleeping], 0
    je      .loop
    mov     eax, [r_submitted]
    sub     eax, [r_completed]
    cmp     eax, FRAME_RING / 2
    ja      .loop
    xor     eax, eax
    xchg    [main_sleeping], al
    test    al, al
    jz      .loop
    lock inc dword [main_seq]
    lea     rdi, [main_seq]
    call    futex_wake
    jmp     .loop

section .rodata
env_threads:    db "TTFX_ASM_THREADS", 0

section .text

section .tstate
; Both threads read this block, which is fixed once render_init is done;
; it has its lines to itself, so neither thread's writes elsewhere evict it.
alignb 64
grid_width:     resq 1
grid_height:    resq 1
grid_cells:     resq 1
co_rbase:       resq 1
co_rspan:       resq 1
co_cbase:       resq 1
co_cspan:       resq 1
co_cell0:       resq 1
handle_grid:    resq 1
rs_link:        resq 1
owner_grid:     resq 1
rs_cell:        resq 1
rs_handle:      resq 1
cell_rec:       resq 1
pending_cells:  resq 1
out_base:       resq 1
row_store:      resq 1
row_stride:     resq 1
row_offs:       resq 1
offs_stride:    resq 1
row_sel:        resq 1
row_iov:        resq 1
frame_iov:      resq 1
iov_scratch:    resq 1
dirty_chunks:   resq 1
dirty_rows:     resq 1
dirty_cells:    resq 1
dirty_bits:     resq 1
full_blocks:    resq 1
row_blocks:     resq 1
render_tid:     resq 1
pipe_running:   resb 1                  ; frames go to the render thread
log_handles:    resb 1                  ; visual changes are logged for it
; what each thread writes as it goes, each on lines of its own
alignb 64
log_ptr:        resq 1                  ; the main side's end of the open log
render_quit:    resb 1
alignb 64
frame_len:      resq 1                  ; the renderer's
render_err:     resq 1                  ; the renderer's first failed write
pending_count:  resd 1
all_dirty:      resb 1
alignb 64
r_submitted:    resd 1                  ; frames handed over (main)
alignb 64
r_completed:    resd 1                  ; frames done (renderer)
alignb 64
render_seq:     resd 1                  ; the renderer's futex word
render_sleeping: resb 1
alignb 64
main_seq:       resd 1                  ; the main thread's futex word
main_sleeping:  resb 1
alignb 64
ring:           resb FRAME_RING * FS_SIZE
