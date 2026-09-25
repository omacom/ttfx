; effects/spotlights.asm - "Search the text with spotlights that converge in
; the center" (src/effects/spotlights.rs).
;
; Config (src/asm/effects.rs, the Spotlights arm).
;
; The spotlights are added characters that are never shown; each walks its
; eleven chained bezier paths ("0".."10", looping) until the search ends and
; then its "center" path. Every frame the input characters inside any
; spotlight's ellipse show their bright colors, dimmed towards the beam's
; edge; characters that left every beam fall back to their dark colors.
;
; The illuminated set is a list plus a per-character frame stamp. Order does
; not matter: a frame draws nothing from the RNG and only sets appearances.
;
; Speed: each character keeps its bright and dark visual handles; a
; character well inside the beam's edge by exact integer distance skips the
; hypot fold; beam distances come from a memo of hypot over (|dx|, |dy|);
; dimmed visuals are memoized per character (its last factor) and by
; (bright handle, brightness factor bits), which determines the symbol and
; both adjusted colors.

struc SPOTLIGHTS
    .beam_width_ratio:  resq 1          ; f64
    .beam_falloff:      resq 1          ; f64
    .search_duration:   resq 1
    .speed_lo:          resq 1          ; f64
    .speed_hi:          resq 1          ; f64
    .count:             resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; per input character (spl_recs + slot * SPL_REC_size)
struc SPL_REC
    .fg:        resq 1                  ; bright pair
    .bg:        resq 1
    .bright:    resd 1                  ; visual handles
    .dark:      resd 1
    .mark:      resd 1                  ; frame stamp: in range this frame
    .flags:     resd 1                  ; SPLF_*
    .factor:    resq 1                  ; the last brightness factor's bits
    .dimmed:    resd 1                  ; and its visual (0: none yet)
    .pad:       resd 1
endstruc

%define SPLF_LIT            1           ; _is_spotlightable
%define SPLF_UNCACHED       2           ; shows its input colors (always)
%define SPLF_OVERRIDE       4           ; _get_expand_color_override applies

; path names: "0".."10" are NAME_LITERAL + k
%define SPL_CENTER          NAME_LITERAL + 11
%define SPL_IN_OUT_SINE     3
%define SPL_IN_OUT_QUAD     6

%define SPL_MEMO_BITS       19
%define SPL_MEMO_SIZE       (1 << SPL_MEMO_BITS)

section .text

; spotlights_build: Spotlights::build.
spotlights_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    spl_make_spotlights
    call    spl_final_color_map
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [spl_dynamic], al
    ; per-character records and the two illuminated lists
    mov     ebx, [char_count]
    imul    rdi, rbx, SPL_REC_size
    add     rdi, 64
    call    alloc
    mov     [spl_recs], rax
    lea     rdi, [rbx * 4 + 64]
    call    alloc
    mov     [spl_lit], rax
    lea     rdi, [rbx * 4 + 64]
    call    alloc
    mov     [spl_next], rax
    ; memo tables
    mov     rdi, SPL_MEMO_SIZE * 16
    call    reserve
    mov     [spl_memo], rax
    mov     rax, [canvas_right]
    inc     rax
    mov     [spl_hyp_w], rax
    mov     rcx, [canvas_top]
    inc     rcx
    mov     [spl_hyp_h], rcx
    imul    rax, rcx
    lea     rdi, [rax * 8 + 64]
    call    reserve
    mov     [spl_hyp], rax
    ; every input character: colors, visible, dark appearance
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     r15d, r15d
.char:
    cmp     r15, r13
    jae     .range
    mov     ebp, [r12 + r15 * 4]
    lea     r14, [rbp + rbp * 2]
    shl     r14, 4
    add     r14, [spl_recs]
    mov     rax, [ch_fg]
    mov     rbx, [rax + rbp * 8]        ; input fg
    mov     rax, [ch_bg]
    mov     rcx, [rax + rbp * 8]        ; input bg
    ; flags
    xor     edx, edx
    mov     rax, [ch_sym]
    mov     rax, [rax + rbp * 8]
    cmp     rax, [spl_space]
    jne     .lit
    cmp     rbx, NONE
    jne     .lit
    cmp     rcx, NONE
    je      .unlit
.lit:
    or      edx, SPLF_LIT
.unlit:
    cmp     qword [cfg_existing_colors], 0
    jne     .override
    mov     rax, [ch_flags]
    test    word [rax + rbp * 2], CF_PREEXISTING
    jz      .override
    or      edx, SPLF_UNCACHED
.override:
    cmp     byte [spl_dynamic], 0
    je      .flags
    cmp     rbx, NONE
    jne     .flags                      ; fg present: no override
    or      edx, SPLF_OVERRIDE          ; (None, bg) or no input colors
.flags:
    mov     [r14 + SPL_REC.flags], edx
    cmp     byte [spl_dynamic], 0
    je      .gradient
    ; dynamic: the input colors, gray standing in for a missing fg
    cmp     rbx, NONE
    jne     .dyn_pair
    mov     rbx, 0x808080
.dyn_pair:
    mov     [r14 + SPL_REC.fg], rbx
    mov     [r14 + SPL_REC.bg], rcx
    jmp     .pairs
.gradient:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [spl_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [spl_map]
    mov     rax, [rcx + rax * 8]
    mov     [r14 + SPL_REC.fg], rax
    mov     qword [r14 + SPL_REC.bg], NONE
.pairs:
    ; bright and dark (0.2) visuals
    mov     edi, ebp
    mov     rdx, [r14 + SPL_REC.fg]
    mov     rcx, [r14 + SPL_REC.bg]
    call    spl_visual
    mov     [r14 + SPL_REC.bright], eax
    movsd   xmm0, [spl_dim]
    call    spl_adjusted
    mov     [r14 + SPL_REC.dark], eax
    mov     edi, ebp
    mov     esi, 1
    call    set_visibility
    mov     edi, ebp
    mov     eax, [r14 + SPL_REC.dark]
    SET_HANDLE
    inc     r15
    jmp     .char
.range:
    ; illuminate_range = max(int(min(floor(smallest / ratio), smallest)), 1)
    mov     rax, [canvas_right]
    cmp     rax, [canvas_top]
    cmovg   rax, [canvas_top]
    cvtsi2sd xmm1, rax
    movapd  xmm0, xmm1
    mov     rcx, [effect_config]
    divsd   xmm0, [rcx + SPOTLIGHTS.beam_width_ratio]
    roundsd xmm0, xmm0, 1
    minsd   xmm0, xmm1                  ; NaN takes smallest, as f64::min
    call    f64_to_i64
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [spl_range], rax
    mov     rcx, [effect_config]
    mov     rax, [rcx + SPOTLIGHTS.search_duration]
    mov     [spl_search_left], rax
    mov     byte [spl_searching], 1
    ; every spotlight starts on path "0"
    xor     ebx, ebx
.start:
    cmp     rbx, [spl_live]
    jae     .done
    mov     rax, [spl_slots]
    mov     ebp, [rax + rbx * 4]
    mov     edi, ebp
    mov     esi, NAME_LITERAL
    call    path_activate_name
    mov     edi, ebp
    call    active_insert
    inc     rbx
    jmp     .start
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; spl_make_spotlights: SpotlightsIterator.make_spotlights, draw for draw.
spl_make_spotlights:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8 + 11 * 8 + 11 * 4 + 12 ; control, targets, names
    ; [rsp] bezier control, [rsp+8] 11 targets, [rsp+96] 11 names
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SPOTLIGHTS.count]
    mov     [spl_live], rdi
    lea     rdi, [rdi * 4 + 64]
    call    alloc
    mov     [spl_slots], rax
    mov     rdi, [rbx + SPOTLIGHTS.count]
    shl     rdi, 4
    add     rdi, 64
    call    alloc
    mov     [spl_coords], rax
    ; minimum_distance = canvas.right // 4
    mov     rdi, [canvas_right]
    mov     esi, 4
    call    floor_div
    cvtsi2sd xmm0, rax
    movsd   [spl_min_distance], xmm0
    xor     eax, eax
.name:
    lea     ecx, [rax + NAME_LITERAL]
    mov     [rsp + 96 + rax * 4], ecx
    inc     eax
    cmp     eax, 11
    jb      .name
    xor     r12d, r12d                  ; spotlight index
.spotlight:
    cmp     r12, [rbx + SPOTLIGHTS.count]
    jae     .done
    mov     edi, 1
    xor     esi, esi
    call    canvas_random_coord
    mov     rsi, rax
    mov     rdi, [spl_symbol]
    call    add_character
    mov     r13d, eax                   ; slot
    mov     rcx, [spl_slots]
    mov     [rcx + r12 * 4], eax
    ; the targets: a random coordinate, then ten more at minimum distance
    xor     edi, edi
    xor     esi, esi
    call    canvas_random_coord
    mov     [rsp + 8], rax
    mov     r14d, 1
.target:
    xor     edi, edi
    xor     esi, esi
    call    canvas_random_coord
    mov     rbp, rax
    mov     rdi, [rsp + r14 * 8]        ; the previous target
    mov     rsi, rbp
    xor     edx, edx
    call    find_length_of_line
    ucomisd xmm0, [spl_min_distance]
    jb      .target
    mov     [rsp + 8 + r14 * 8], rbp
    inc     r14d
    cmp     r14d, 11
    jb      .target
    ; one bezier path per target
    xor     r14d, r14d
.path:
    movsd   xmm0, [rbx + SPOTLIGHTS.speed_lo]
    movsd   xmm1, [rbx + SPOTLIGHTS.speed_hi]
    call    rng_uniform
    mov     edi, r13d
    mov     esi, SPL_IN_OUT_QUAD
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    lea     r9d, [r14 + NAME_LITERAL]
    call    path_new
    mov     r15d, eax
    mov     edi, 1
    xor     esi, esi
    call    canvas_random_coord
    mov     [rsp], rax
    mov     edi, r15d
    mov     rsi, [rsp + 8 + r14 * 8]
    mov     rdx, rsp
    mov     ecx, 1
    mov     r8d, AUTO
    call    path_new_waypoint
    inc     r14d
    cmp     r14d, 11
    jb      .path
    mov     edi, r13d
    lea     rsi, [rsp + 96]
    mov     edx, 11
    mov     ecx, 1
    call    chain_paths
    ; "center": straight to the canvas center
    mov     edi, r13d
    movsd   xmm0, [spl_half]
    mov     esi, SPL_IN_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, SPL_CENTER
    call    path_new
    mov     edi, eax
    mov     rsi, [center_row]
    shl     rsi, 32
    mov     ecx, [center_col]
    or      rsi, rcx
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    inc     r12
    jmp     .spotlight
.done:
    add     rsp, 8 + 11 * 8 + 11 * 4 + 12
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; spl_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
spl_final_color_map:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SPOTLIGHTS.final_steps]
    mov     rcx, [rbx + SPOTLIGHTS.final_step_count]
    mov     rsi, [rbx + SPOTLIGHTS.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     r12, rax
    mov     rdi, [rbx + SPOTLIGHTS.final_stops]
    mov     rsi, [rbx + SPOTLIGHTS.final_stop_count]
    mov     rdx, [rbx + SPOTLIGHTS.final_steps]
    mov     rcx, [rbx + SPOTLIGHTS.final_step_count]
    mov     r8, r12
    call    gradient_new
    mov     rdi, r12
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [spl_map_width], rax
    push    qword [rbx + SPOTLIGHTS.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [spl_map], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; spl_visual(edi=slot, rdx=fg or NONE, rcx=bg or NONE) -> eax = the visual
; Animation.set_appearance(input_symbol, ..., colors) makes: under
; --existing-color-handling always, a character using its input colors
; shows those and its bold instead. Clobbers what visual_make does.
spl_visual:
    mov     rax, [ch_sym]
    mov     r10, [rax + rdi * 8]
    xor     r9d, r9d
    cmp     qword [cfg_existing_colors], 0
    jne     .make
    mov     rax, [ch_flags]
    movzx   eax, word [rax + rdi * 2]
    test    eax, CF_PREEXISTING
    jz      .make
    mov     rdx, [ch_fg]
    mov     rdx, [rdx + rdi * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rdi * 8]
    test    eax, CF_BOLD
    jz      .make
    mov     r9d, ATTR_BOLD
.make:
    mov     rdi, rdx
    mov     rsi, rcx
    mov     rdx, r10
    mov     ecx, r9d
    jmp     visual_make

; spl_adjusted(ebp=slot, r14=record, xmm0=brightness) -> eax = the visual
; of _adjust_color_pair_brightness(bright pair, brightness).
; Clobbers C except rbx, rbp, r12-r15.
spl_adjusted:
    push    rbx
    sub     rsp, 16
    movsd   [rsp], xmm0
    mov     rbx, NONE
    mov     rdi, [r14 + SPL_REC.fg]
    cmp     rdi, NONE
    je      .bg
    call    adjust_color_brightness
    mov     rbx, rax
.bg:
    mov     rcx, NONE
    mov     rdi, [r14 + SPL_REC.bg]
    cmp     rdi, NONE
    je      .make
    movsd   xmm0, [rsp]
    call    adjust_color_brightness
    mov     rcx, rax
.make:
    mov     edi, ebp
    mov     rdx, rbx
    call    spl_visual
    add     rsp, 16
    pop     rbx
    ret

; spl_override(ebp=slot) -> eax = the visual of the expand override
; (None, input bg): (None, bg) for a bg-only character, (None, None) for one
; without input colors, whose bg is NONE.
spl_override:
    mov     edi, ebp
    mov     rdx, NONE
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rbp * 8]
    jmp     spl_visual

; spl_dimmed(ebp=slot, r14=record, xmm0=brightness factor) -> eax: the
; memoized spl_adjusted: the character's last factor and visual first, then
; a memo keyed by (bright handle, factor bits), emptied when half full.
; Characters showing their input colors (always) are not memoized.
; Clobbers C except rbx, rbp, r12-r15.
spl_dimmed:
    test    dword [r14 + SPL_REC.flags], SPLF_UNCACHED
    jnz     spl_adjusted
    movq    rax, xmm0
    cmp     [r14 + SPL_REC.factor], rax
    jne     .memo
    mov     ecx, [r14 + SPL_REC.dimmed]
    test    ecx, ecx
    jz      .memo
    mov     eax, ecx
    ret
.memo:
    mov     [r14 + SPL_REC.factor], rax
    call    .lookup
    mov     [r14 + SPL_REC.dimmed], eax
    ret
.lookup:
    mov     edx, [r14 + SPL_REC.bright]
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rcx, rdx
    xor     rcx, rax
    mov     rsi, 0xff51afd7ed558ccd
    imul    rcx, rsi
    shr     rcx, 64 - SPL_MEMO_BITS
    mov     rsi, [spl_memo]
.probe:
    mov     rdi, rcx
    shl     rdi, 4
    add     rdi, rsi
    mov     r8d, [rdi + 8]
    test    r8d, r8d
    jz      .miss
    cmp     r8d, edx
    jne     .next
    cmp     [rdi], rax
    jne     .next
    mov     eax, [rdi + 12]
    ret
.next:
    inc     ecx
    and     ecx, SPL_MEMO_SIZE - 1
    jmp     .probe
.miss:
    push    rdi
    push    rax
    call    spl_adjusted
    pop     rcx                         ; factor bits
    pop     rdi                         ; the empty entry
    cmp     qword [spl_memo_count], SPL_MEMO_SIZE / 2
    jb      .store
    ; half full: start over (the entry found is not kept either)
    push    rax
    push    rcx
    mov     rdi, [spl_memo]
    mov     ecx, SPL_MEMO_SIZE * 2
    xor     eax, eax
    rep     stosq
    mov     qword [spl_memo_count], 0
    pop     rcx
    pop     rax
    ret
.store:
    inc     qword [spl_memo_count]
    mov     [rdi], rcx
    mov     edx, [r14 + SPL_REC.bright]
    mov     [rdi + 8], edx
    mov     [rdi + 12], eax
    ret

; spl_distance(ebp=slot) -> xmm0 = the smallest find_length_of_line(
; spotlight, input coordinate, double_row_diff) over the live spotlights
; (spl_coords), folded from +inf with f64::min. hypot is memoized over
; (|column delta|, |row delta|); glibc's hypot takes absolute values first.
; Clobbers C except rbx, rbp, r12-r15.
spl_distance:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rax, [ch_icol]
    movsxd  r12, dword [rax + rbp * 4]
    mov     rax, [ch_irow]
    movsxd  r13, dword [rax + rbp * 4]
    mov     rax, [spl_inf]
    mov     [rsp], rax                  ; the running minimum
    xor     ebx, ebx
    mov     r15, [spl_coords]
.spotlight:
    cmp     rbx, [spl_live]
    jae     .done
    mov     rsi, r12
    sub     rsi, [r15]                  ; column delta
    mov     rax, rsi
    neg     rax
    cmovns  rsi, rax
    mov     rdi, r13
    sub     rdi, [r15 + 8]              ; row delta
    mov     rax, rdi
    neg     rax
    cmovns  rdi, rax
    mov     r14, -1                     ; memo index, or -1
    cmp     rsi, [spl_hyp_w]
    jae     .hypot
    cmp     rdi, [spl_hyp_h]
    jae     .hypot
    mov     r14, rdi
    imul    r14, [spl_hyp_w]
    add     r14, rsi
    mov     rax, [spl_hyp]
    movsd   xmm0, [rax + r14 * 8]
    movq    rax, xmm0
    test    rax, rax
    jnz     .min
.hypot:
    cvtsi2sd xmm0, rsi
    cvtsi2sd xmm1, rdi
    addsd   xmm1, xmm1
    CCALL   hypot
    test    r14, r14
    js      .min
    mov     rax, [spl_hyp]
    movsd   [rax + r14 * 8], xmm0
.min:
    movsd   xmm1, [rsp]
    minsd   xmm1, xmm0
    movsd   [rsp], xmm1
    add     r15, 16
    inc     rbx
    jmp     .spotlight
.done:
    movsd   xmm0, [rsp]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; spl_illuminate: SpotlightsIterator.illuminate_chars(illuminate_range).
; Each spotlightable character met in an ellipse for the first time this
; frame is stamped, listed and given its colors at once (a frame's colors
; don't depend on visiting order); then the previously illuminated
; characters without this frame's stamp go dark. The ellipse is
; coords_in_circle's, walked column by column over the canvas cells only
; (the input-coordinate map holds nothing outside them).
spl_illuminate:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, CIRCLE_ITER_size + 16
    ; [rsp] the ellipse's a^2/b^2 (CIRCLE_ITER), [rsp + 72] last column
    inc     dword [spl_stamp]
    mov     qword [spl_next_count], 0
    ; the live spotlights' coordinates
    xor     ebx, ebx
.coords:
    cmp     rbx, [spl_live]
    jae     .gather
    mov     rax, [spl_slots]
    mov     ecx, [rax + rbx * 4]
    mov     rdx, rbx
    shl     rdx, 4
    add     rdx, [spl_coords]
    mov     rax, [ch_col]
    movsxd  rax, dword [rax + rcx * 4]
    mov     [rdx], rax
    mov     rax, [ch_row]
    movsxd  rax, dword [rax + rcx * 4]
    mov     [rdx + 8], rax
    inc     rbx
    jmp     .coords
.gather:
    xor     r15d, r15d                  ; spotlight index
.ellipse:
    cmp     r15, [spl_live]
    jae     .dark
    mov     rsi, r15
    shl     rsi, 4
    add     rsi, [spl_coords]
    mov     rax, [rsi + 8]
    shl     rax, 32
    mov     ecx, [rsi]
    or      rax, rcx
    mov     rdi, rsp
    mov     rsi, rax
    mov     rdx, [spl_range]
    call    coords_in_circle_init
    mov     r13, [rsp + CIRCLE_ITER.x]  ; column
    mov     rax, [rsp + CIRCLE_ITER.x_end]
    mov     [rsp + 72], rax
.column:
    cmp     r13, [rsp + 72]
    jg      .next_ellipse
    cmp     r13, 1
    jl      .next_column
    cmp     r13, [canvas_right]
    jg      .next_ellipse
    mov     rdi, r13
    mov     rsi, [rsp + CIRCLE_ITER.h]
    mov     rdx, [rsp + CIRCLE_ITER.k]
    movsd   xmm2, [rsp + CIRCLE_ITER.a_squared]
    movsd   xmm3, [rsp + CIRCLE_ITER.b_squared]
    call    circle_column_range
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    cmp     rdx, [canvas_top]
    cmovg   rdx, [canvas_top]
    mov     r12, rdx
    sub     r12, rax
    inc     r12                         ; rows (<= 0: none)
    lea     rbx, [rax - 1]
    imul    rbx, [canvas_right]
    lea     rbx, [rbx + r13 - 1]        ; coord_map_index
.cell:
    test    r12, r12
    jle     .next_column
    dec     r12
    mov     rax, [coord_map]
    mov     ebp, [rax + rbx * 4]
    add     rbx, [canvas_right]
    cmp     ebp, NONE
    je      .cell
    lea     r14, [rbp + rbp * 2]
    shl     r14, 4
    add     r14, [spl_recs]
    test    dword [r14 + SPL_REC.flags], SPLF_LIT
    jz      .cell
    mov     eax, [spl_stamp]
    cmp     [r14 + SPL_REC.mark], eax
    je      .cell
    mov     [r14 + SPL_REC.mark], eax
    mov     rax, [spl_next]
    mov     rcx, [spl_next_count]
    mov     [rax + rcx * 4], ebp
    inc     qword [spl_next_count]
    call    spl_shine
    call    spl_expand_override
    mov     edi, ebp
    SET_HANDLE
    jmp     .cell
.next_column:
    inc     r13
    jmp     .column
.next_ellipse:
    inc     r15
    jmp     .ellipse
.dark:
    ; characters that left every beam go dark
    mov     r12, [spl_lit]
    mov     r13, [spl_lit_count]
    mov     r15d, [spl_stamp]
    xor     ebx, ebx
.dark_char:
    cmp     rbx, r13
    jae     .swap
    mov     ebp, [r12 + rbx * 4]
    inc     rbx
    lea     r14, [rbp + rbp * 2]
    shl     r14, 4
    add     r14, [spl_recs]
    cmp     [r14 + SPL_REC.mark], r15d
    je      .dark_char
    mov     eax, [r14 + SPL_REC.dark]
    call    spl_expand_override
    mov     edi, ebp
    SET_HANDLE
    jmp     .dark_char
.swap:
    mov     rax, [spl_lit]
    mov     rcx, [spl_next]
    mov     [spl_lit], rcx
    mov     [spl_next], rax
    mov     rax, [spl_next_count]
    mov     [spl_lit_count], rax
    add     rsp, CIRCLE_ITER_size + 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; spl_shine(ebp=slot, r14=record) -> eax = the visual of an illuminated
; character: its bright pair, dimmed past the beam's edge by
; max(1 - (distance - edge) / (range * falloff), 0.2). A character whose
; nearest spotlight is well inside the edge by exact integer distance
; (dx^2 + (2 dy)^2 against edge^2 less a margin far above hypot's error)
; skips the hypot fold: its distance cannot exceed the edge.
; Clobbers C except rbx, rbp, r12-r15.
spl_shine:
    mov     rax, [ch_icol]
    movsxd  rsi, dword [rax + rbp * 4]
    mov     rax, [ch_irow]
    movsxd  rdi, dword [rax + rbp * 4]
    mov     r8, [spl_coords]
    mov     r9, [spl_live]
    mov     r10, 0x7fffffffffffffff     ; smallest squared distance
.nearest:
    mov     rax, rsi
    sub     rax, [r8]
    imul    rax, rax
    mov     rcx, rdi
    sub     rcx, [r8 + 8]
    add     rcx, rcx
    imul    rcx, rcx
    add     rax, rcx
    cmp     rax, r10
    cmovl   r10, rax
    add     r8, 16
    dec     r9
    jnz     .nearest
    cvtsi2sd xmm0, r10
    ucomisd xmm0, [spl_core2]
    jae     .measure
    mov     eax, [r14 + SPL_REC.bright]
    ret
.measure:
    sub     rsp, 8
    call    spl_distance
    add     rsp, 8
    mov     eax, [r14 + SPL_REC.bright]
    ucomisd xmm0, [spl_edge]
    jbe     .done
    subsd   xmm0, [spl_edge]
    divsd   xmm0, [spl_falloff_width]
    movsd   xmm1, [spl_one]
    subsd   xmm1, xmm0
    maxsd   xmm1, [spl_dim]             ; NaN takes 0.2, as f64::max
    movapd  xmm0, xmm1
    sub     rsp, 8
    call    spl_dimmed
    add     rsp, 8
.done:
    ret

; spl_expand_override(eax=handle, ebp=slot, r14=record) -> eax: the
; _get_expand_color_override visual in place of eax while expanding under
; dynamic color handling. Preserves rbx, rbp, r12-r15.
spl_expand_override:
    cmp     byte [spl_expanding], 0
    je      .keep
    test    dword [r14 + SPL_REC.flags], SPLF_OVERRIDE
    jz      .keep
    jmp     spl_override
.keep:
    ret

; spotlights_next_frame -> eax = 1 for a frame, 0 when done.
spotlights_next_frame:
    push    rbx
    push    rbp
    sub     rsp, 8
    cmp     byte [spl_complete], 0
    jne     .finished
    ; this frame's beam edge: range * (1 - falloff), and range * falloff
    mov     rax, [effect_config]
    cvtsi2sd xmm0, qword [spl_range]
    movsd   xmm1, [spl_one]
    subsd   xmm1, [rax + SPOTLIGHTS.beam_falloff]
    mulsd   xmm1, xmm0
    movsd   [spl_edge], xmm1
    mulsd   xmm0, [rax + SPOTLIGHTS.beam_falloff]
    movsd   [spl_falloff_width], xmm0
    ; edge^2 less a relative 1e-9 when the edge is positive, else -1
    movsd   xmm0, [spl_minus_one]
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    jbe     .core
    mulsd   xmm1, xmm1
    mulsd   xmm1, [spl_margin]
    movapd  xmm0, xmm1
.core:
    movsd   [spl_core2], xmm0
    call    spl_illuminate
    cmp     byte [spl_searching], 0
    je      .paths
    dec     qword [spl_search_left]
    jnz     .paths
    xor     ebx, ebx
.center:
    cmp     rbx, [spl_live]
    jae     .searched
    mov     rax, [spl_slots]
    mov     edi, [rax + rbx * 4]
    mov     esi, SPL_CENTER
    call    path_activate_name
    inc     rbx
    jmp     .center
.searched:
    mov     byte [spl_searching], 0
.paths:
    ; any live spotlight still on a path?
    xor     ebx, ebx
.any:
    cmp     rbx, [spl_live]
    jae     .expand
    mov     rax, [spl_slots]
    mov     ecx, [rax + rbx * 4]
    mov     rax, [ch_path]
    cmp     dword [rax + rcx * 4], NONE
    jne     .update
    inc     rbx
    jmp     .any
.expand:
    mov     qword [spl_live], 1
    mov     byte [spl_expanding], 1
    inc     qword [spl_range]
    mov     rax, [canvas_right]
    cmp     rax, [canvas_top]
    cmovl   rax, [canvas_top]
    cvtsi2sd xmm0, rax
    divsd   xmm0, [spl_one_half]
    roundsd xmm0, xmm0, 1
    cvtsi2sd xmm1, qword [spl_range]
    ucomisd xmm1, xmm0
    jbe     .update
    mov     byte [spl_complete], 1
.update:
    call    update
    mov     eax, 1
    jmp     .done
.finished:
    xor     eax, eax
.done:
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
spl_space:      dq 0x20 | (1 << 32)     ; " "
spl_symbol:     dq 'O' | (1 << 32)
spl_dim:        dq 0.2
spl_half:       dq 0.5
spl_one:        dq 1.0
spl_one_half:   dq 1.5
spl_inf:        dq 0x7ff0000000000000
spl_minus_one:  dq -1.0
spl_margin:     dq 0.999999999

section .tstate
alignb 8
spl_slots:          resq 1          ; the spotlights (u32 slots)
spl_live:           resq 1          ; len(self.spotlights)
spl_coords:         resq 1          ; (column, row) i64 pairs, this frame
spl_min_distance:   resq 1          ; f64
spl_map:            resq 1
spl_map_width:      resq 1
spl_recs:           resq 1
spl_lit:            resq 1          ; illuminated_chars
spl_lit_count:      resq 1
spl_next_count:     resq 1
spl_next:           resq 1          ; illuminated_scratch
spl_memo:           resq 1
spl_memo_count:     resq 1
spl_hyp:            resq 1
spl_hyp_w:          resq 1
spl_hyp_h:          resq 1
spl_range:          resq 1          ; illuminate_range
spl_search_left:    resq 1
spl_edge:           resq 1          ; f64
spl_falloff_width:  resq 1          ; f64
spl_core2:          resq 1          ; f64: squared distances below are lit
spl_stamp:          resd 1
spl_searching:      resb 1
spl_expanding:      resb 1
spl_complete:       resb 1
spl_dynamic:        resb 1
