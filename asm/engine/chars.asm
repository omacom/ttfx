; engine/chars.asm - the character store (EffectCharacter, engine/character.rs).
;
; Characters live in struct-of-arrays form, indexed by slot. Slots are
; allocated in the order Rust pushes EffectCharacters to its arena, so
; ascending slot order is ascending character_id order - the canonical order
; the parity rules demand. Every array is a reserved region sized for
; CHAR_LIMIT characters and committed lazily, so particles and added
; characters can keep growing the store without moving anything.
;
; Field arrays (pointer globals; index by slot):
;   ch_sym      u64  input symbol, packed (utf8_pack format)
;   ch_row/col  i32  current coordinate (Motion.current_coord)
;   ch_irow/icol i32 input coordinate
;   ch_id       u32  character_id (Python-compatible allocation id)
;   ch_layer    i32
;   ch_handle   u32  current visual (see visual.asm; SET_HANDLE to change it)
;   ch_scene    i32  active scene index or NONE
;   ch_scenes   i32  first scene of the character's scene map or NONE
;   ch_path     i32  active path index or NONE
;   ch_done_path i32 completed path index or NONE (Motion.completed_path)
;   ch_paths    i32  first path of the character's path map or NONE
;   ch_events   i32  first event entry or NONE
;   ch_subs     u8   bitmask of subscribed event kinds (1 << EV_*)
;   ch_flags    u16  CF_* bits
;   ch_fg/bg    u64  input colors (NONE when absent)
;   ch_nbr      4 x i32 neighbors: north, east, south, west (NONE at edges)
;   ch_cell     i32  render cell (render.asm)
;   ch_user0/1  u64  two words per character for the effect's own use

%define CHAR_LIMIT      (1 << 26)

%define CF_VISIBLE      1
%define CF_ORPHAN       2               ; overwritten while parsing input
%define CF_INPUT        4               ; a kept input character
%define CF_FILL_INNER   8               ; fill character inside the text box
%define CF_FILL_OUTER   16              ; fill character outside it
%define CF_ADDED        32              ; Terminal.add_character
%define CF_PREEXISTING  64              ; uses_input_preexisting_colors
%define CF_BOLD         128             ; input_bold
%define CF_FILL         (CF_FILL_INNER | CF_FILL_OUTER)

%define NBR_NORTH       0
%define NBR_EAST        4
%define NBR_SOUTH       8
%define NBR_WEST        12

; field name, bytes per character, initial value (0 = leave zeroed)
%macro CHAR_FIELDS 1
    %1 ch_sym, 8, 0
    %1 ch_row, 4, 0
    %1 ch_col, 4, 0
    %1 ch_irow, 4, 0
    %1 ch_icol, 4, 0
    %1 ch_id, 4, 0
    %1 ch_layer, 4, 0
    %1 ch_handle, 4, 0
    %1 ch_scene, 4, NONE
    %1 ch_scenes, 4, NONE
    %1 ch_path, 4, NONE
    %1 ch_done_path, 4, NONE
    %1 ch_paths, 4, NONE
    %1 ch_events, 4, NONE
    %1 ch_subs, 1, 0
    %1 ch_flags, 2, 0
    %1 ch_fg, 8, NONE
    %1 ch_bg, 8, NONE
    %1 ch_nbr, 16, NONE
    %1 ch_cell, 4, NONE
    %1 ch_user0, 8, 0
    %1 ch_user1, 8, 0
%endmacro

section .text

; chars_init: reserve every field array. (Staggering them within a page
; against 4K aliasing measured neutral overall and cost matrix 10%.)
chars_init:
%macro RESERVE_FIELD 3
    mov     rdi, CHAR_LIMIT * %2
    call    reserve
    mov     [%1], rax
%endmacro
    CHAR_FIELDS RESERVE_FIELD
    mov     rdi, CHAR_LIMIT * 4
    call    reserve
    mov     [added_chars], rax
    jmp     update_init

; new_char(rdi=packed symbol, esi=column, edx=row) -> eax = slot.
; EffectCharacter::new: the next character_id, the coordinate as both input
; and current coordinate, and the plain visual of the symbol as the current
; visual (Animation::new). Clobbers rcx, rdx, rsi, rdi, r8-r11 and vectors.
new_char:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    mov     ebx, [char_count]
    cmp     ebx, CHAR_LIMIT
    jae     .full
    inc     dword [char_count]
    ; generic sentinels, then the 16-byte neighbor record
    mov     rax, [ch_scene]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_scenes]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_path]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_done_path]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_paths]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_events]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_fg]
    mov     qword [rax + rbx * 8], NONE
    mov     rax, [ch_bg]
    mov     qword [rax + rbx * 8], NONE
    mov     rax, [ch_cell]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_nbr]
    mov     rcx, rbx
    shl     rcx, 4
    mov     qword [rax + rcx], NONE
    mov     qword [rax + rcx + 8], NONE
    ; identity, symbol, coordinates
    mov     rax, [ch_id]
    mov     ecx, [next_character_id]
    mov     [rax + rbx * 4], ecx
    inc     dword [next_character_id]
    mov     rax, [ch_sym]
    mov     [rax + rbx * 8], r12
    mov     rax, [ch_row]
    mov     [rax + rbx * 4], edx
    mov     rax, [ch_irow]
    mov     [rax + rbx * 4], edx
    mov     rax, [ch_col]
    mov     [rax + rbx * 4], r13d
    mov     rax, [ch_icol]
    mov     [rax + rbx * 4], r13d
    ; the plain visual of the symbol
    mov     rdi, NONE
    mov     rsi, NONE
    mov     rdx, r12
    xor     ecx, ecx
    call    visual_make
    mov     rcx, [ch_handle]
    mov     [rcx + rbx * 4], eax
    mov     eax, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret
.full:
    lea     rdi, [msg_chars_full]
    mov     esi, msg_chars_full_len
    jmp     fatal

; add_character(rdi=packed symbol, rsi=coord) -> eax = slot.
; Terminal.add_character: registered only in added_characters (not in the
; input-coordinate map or the neighbor graph), fill-less, no preexisting
; colors.
add_character:
    push    rbx
    mov     rdx, rsi
    sar     rdx, 32                     ; row
    ; esi keeps the column (low half)
    call    new_char
    mov     ebx, eax
    mov     rcx, [ch_flags]
    or      word [rcx + rbx * 2], CF_ADDED
    mov     ecx, [added_count]
    mov     rdx, [added_chars]
    mov     [rdx + rcx * 4], ebx
    inc     dword [added_count]
    mov     eax, ebx
    pop     rbx
    ret

; char_coord(edi=slot) -> rax = current coordinate (packed).
char_coord:
    mov     rax, [ch_row]
    mov     eax, [rax + rdi * 4]
    shl     rax, 32
    mov     rcx, [ch_col]
    mov     ecx, [rcx + rdi * 4]
    or      rax, rcx
    ret

; char_input_coord(edi=slot) -> rax = input coordinate (packed).
char_input_coord:
    mov     rax, [ch_irow]
    mov     eax, [rax + rdi * 4]
    shl     rax, 32
    mov     rcx, [ch_icol]
    mov     ecx, [rcx + rdi * 4]
    or      rax, rcx
    ret

; set_coordinate(edi=slot, rsi=coord): Motion.set_coordinate. A visible
; character that changes cells invalidates the render grid.
set_coordinate:
    mov     rax, [ch_row]
    mov     rcx, rsi
    sar     rcx, 32
    mov     [rax + rdi * 4], ecx
    mov     rax, [ch_col]
    mov     [rax + rdi * 4], esi
    jmp     coordinate_changed

; set_layer(edi=slot, rsi=layer)
set_layer:
    mov     rax, [ch_layer]
    cmp     [rax + rdi * 4], esi
    je      .same
    mov     [rax + rdi * 4], esi
    jmp     layer_changed
.same:
    ret

section .rodata
STR msg_chars_full, "ttfx: asm engine: character limit reached", 10

section .tstate
alignb 8
%macro DECLARE_FIELD 3
%1: resq 1
%endmacro
CHAR_FIELDS DECLARE_FIELD
char_count:         resd 1
next_character_id:  resd 1
added_chars:        resq 1
added_count:        resd 1
