; effects/unstable.asm - "Spawn characters jumbled, explode them to the edge
; of the canvas, then reassemble them in the correct layout"
; (src/effects/unstable.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Unstable):
;
; Build walks the characters top to bottom, left to right, drawing each
; one's edge target and then its jumbled start, in Rust's order. The jumbled
; start is Vec::remove(randint(0, len - 1)) on the remaining input
; coordinates; an order-statistic Fenwick tree picks the same element without
; the O(n) shifts. That character order never changes, so it is fetched once.
;
; Rust renders the offset rumble frames mid-next_frame and then moves the
; characters back. Here the engine renders after next_frame returns, so the
; move back is deferred to the start of the next call.

struc UNSTABLE
    .unstable_color:    resq 1
    .explosion_ease:    resq 1
    .explosion_speed:   resq 1          ; f64
    .reassembly_ease:   resq 1
    .reassembly_speed:  resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; per-character record (un_recs + slot * UN_REC)
%define UR_JUMBLED          0           ; packed coordinate
%define UR_TARGET           8           ; the explosion waypoint (packed)
%define UR_EXPLOSION        16          ; path index
%define UR_REASSEMBLY       20          ; path index
%define UR_FINAL            24          ; scene index
%define UN_REC              32

; phases
%define UN_RUMBLE           0
%define UN_EXPLOSION        1
%define UN_REASSEMBLY       2

; path names
%define UN_P_EXPLOSION      NAME_LITERAL + 0
%define UN_P_REASSEMBLY     NAME_LITERAL + 1
; scene names
%define UN_S_RUMBLE         NAME_LITERAL + 0
%define UN_S_FINAL          NAME_LITERAL + 1

%define UN_NEUTRAL_GRAY     0x808080
%define UN_MAX_RUMBLE       150

section .text

; unstable_build: Unstable::build.
unstable_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    un_final_color_map
    mov     qword [un_last_fg], NONE
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     [un_chars], rax
    mov     [un_count], rdx
    mov     r13, rax
    mov     r14, rdx
    mov     edi, [char_count]
    shl     rdi, 5                      ; * UN_REC
    call    alloc
    mov     [un_recs], rax
    mov     rdi, r14
    call    un_fen_init
    mov     r15, [effect_config]
    xor     ebx, ebx
.char:
    cmp     rbx, r14
    jae     .built
    mov     r12d, [r13 + rbx * 4]
    mov     rbp, r12
    shl     rbp, 5
    add     rbp, [un_recs]
    ; the edge target: randint(0, 3) picks left, right, bottom or top
    xor     edi, edi
    mov     esi, 3
    call    rng_randint
    mov     [rsp], rax
    cmp     rax, 1
    ja      .vertical
    xor     edi, edi
    call    canvas_random_row
    mov     ecx, 1                      ; left
    cmp     qword [rsp], 0
    je      .target
    mov     rcx, [canvas_right]
    jmp     .target
.vertical:
    xor     edi, edi
    call    canvas_random_column
    mov     ecx, eax                    ; column
    mov     eax, 1                      ; bottom
    cmp     qword [rsp], 2
    je      .target
    mov     rax, [canvas_top]
.target:
    shl     rax, 32                     ; rax = row, ecx = column
    mov     ecx, ecx
    or      rax, rcx
    mov     [rbp + UR_TARGET], rax
    ; jumbled = character_coords.remove(randint(0, len - 1))
    xor     edi, edi
    mov     rsi, r14
    sub     rsi, rbx
    dec     rsi
    call    rng_randint
    mov     rdi, rax
    call    un_fen_take
    mov     edi, [r13 + rax * 4]
    call    char_input_coord
    mov     [rbp + UR_JUMBLED], rax
    mov     edi, r12d
    mov     rsi, rax
    call    set_coordinate
    ; explosion path to the edge, reassembly path home
    mov     edi, r12d
    movsd   xmm0, [r15 + UNSTABLE.explosion_speed]
    mov     esi, [r15 + UNSTABLE.explosion_ease]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, UN_P_EXPLOSION
    call    path_new
    mov     [rbp + UR_EXPLOSION], eax
    mov     edi, eax
    mov     rsi, [rbp + UR_TARGET]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, r12d
    movsd   xmm0, [r15 + UNSTABLE.reassembly_speed]
    mov     esi, [r15 + UNSTABLE.reassembly_ease]
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, UN_P_REASSEMBLY
    call    path_new
    mov     [rbp + UR_REASSEMBLY], eax
    mov     edi, r12d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, [rbp + UR_REASSEMBLY]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; scenes
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [un_symbol], rax
    mov     edi, r12d
    mov     esi, UN_S_RUMBLE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [un_rumble_scene], eax
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    call    un_mapped_color
    call    un_static_spectra
    mov     edi, [un_rumble_scene]
    mov     ecx, 10
    lea     r8, [un_rumble_spec]
    mov     r9, [un_rumble_len]
    call    un_apply_fg
    mov     edi, r12d
    mov     esi, UN_S_FINAL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rbp + UR_FINAL], eax
    mov     edi, eax
    mov     ecx, 3
    lea     r8, [un_final_spec]
    mov     r9, [un_final_len]
    call    un_apply_fg
    mov     edi, r12d
    mov     esi, [un_rumble_scene]
    call    scene_activate
    jmp     .visible
.dynamic:
    call    un_dynamic_scenes
.visible:
    mov     edi, r12d
    call    set_visible
    inc     rbx
    jmp     .char
.built:
    mov     qword [un_phase], UN_RUMBLE
    mov     qword [un_rumble_steps], 0
    mov     qword [un_mod_delay], 18
    mov     qword [un_hold], 30
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; un_mapped_color (r12d = slot): [un_fg] = final_gradient_mapping[input_coord].
un_mapped_color:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [un_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [un_map]
    mov     rax, [rcx + rax * 8]
    mov     [un_fg], rax
    ret

; un_static_spectra: the rumble ([fg, unstable]) and final ([unstable, fg])
; spectra of [un_fg], 12 steps each. Consecutive characters mostly share
; their color, so the last one's spectra are kept.
un_static_spectra:
    sub     rsp, 8
    mov     rax, [un_fg]
    cmp     rax, [un_last_fg]
    je      .done
    mov     [un_last_fg], rax
    mov     rdi, rax
    mov     rax, [effect_config]
    mov     rsi, [rax + UNSTABLE.unstable_color]
    lea     rdx, [un_rumble_spec]
    call    un_pair_gradient
    mov     [un_rumble_len], rax
    mov     rax, [effect_config]
    mov     rdi, [rax + UNSTABLE.unstable_color]
    mov     rsi, [un_last_fg]
    lea     rdx, [un_final_spec]
    call    un_pair_gradient
    mov     [un_final_len], rax
.done:
    add     rsp, 8
    ret

; un_pair_gradient(rdi=from, rsi=to, rdx=out) -> rax = length:
; Gradient::with_steps(&[from, to], 12, false).
un_pair_gradient:
    sub     rsp, 8
    mov     [un_pair], rdi
    mov     [un_pair + 8], rsi
    mov     r8, rdx
    lea     rdi, [un_pair]
    mov     esi, 2
    lea     rdx, [un_twelve]
    mov     ecx, 1
    call    gradient_new
    add     rsp, 8
    ret

; un_apply_fg(edi=scene, ecx=duration, r8=fg spectrum, r9=count):
; apply_gradient_to_symbols(&[input symbol], duration, Some(fg), None).
un_apply_fg:
    lea     rsi, [un_symbol]
    mov     edx, 1
    push    0
    push    0
    call    scene_apply_gradient
    add     rsp, 16
    ret

; un_apply(edi=scene, ecx=duration, r8=fg spectrum/0, r9=fg count,
; r10=bg spectrum/0, r11=bg count).
un_apply:
    lea     rsi, [un_symbol]
    mov     edx, 1
    push    r11
    push    r10
    call    scene_apply_gradient
    add     rsp, 16
    ret

; un_dynamic_scenes (r12d = slot, rbp = record): the rumble and final scenes
; under --existing-color-handling dynamic, the rumble activation and the
; start appearance. The rumble scene is [un_rumble_scene].
un_dynamic_scenes:
    push    rbx
    push    r13
    push    r14
    mov     rax, [ch_fg]
    mov     r13, [rax + r12 * 8]        ; input fg / NONE
    mov     rax, [ch_bg]
    mov     r14, [rax + r12 * 8]        ; input bg / NONE
    ; rumble: [start fg, unstable] and [bg, unstable], 10 ticks each
    mov     rdi, r13
    cmp     rdi, NONE
    jne     .start_fg
    mov     edi, UN_NEUTRAL_GRAY
.start_fg:
    mov     rax, [effect_config]
    mov     rsi, [rax + UNSTABLE.unstable_color]
    lea     rdx, [un_rumble_spec]
    call    un_pair_gradient
    mov     [un_rumble_len], rax
    xor     r10d, r10d
    xor     r11d, r11d
    cmp     r14, NONE
    je      .rumble
    mov     rdi, r14
    mov     rax, [effect_config]
    mov     rsi, [rax + UNSTABLE.unstable_color]
    lea     rdx, [un_bg_spec]
    call    un_pair_gradient
    mov     r11, rax
    lea     r10, [un_bg_spec]
.rumble:
    mov     edi, [un_rumble_scene]
    mov     ecx, 10
    lea     r8, [un_rumble_spec]
    mov     r9, [un_rumble_len]
    call    un_apply
    ; final
    mov     edi, r12d
    mov     esi, UN_S_FINAL
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rbp + UR_FINAL], eax
    mov     ebx, eax
    cmp     r13, NONE
    jne     .final_gradients
    cmp     r14, NONE
    jne     .final_gradients
    ; no input colors: [unstable, gray], then the plain symbol
    mov     rax, [effect_config]
    mov     rdi, [rax + UNSTABLE.unstable_color]
    mov     esi, UN_NEUTRAL_GRAY
    lea     rdx, [un_final_spec]
    call    un_pair_gradient
    mov     r9, rax
    mov     edi, ebx
    mov     ecx, 3
    lea     r8, [un_final_spec]
    call    un_apply_fg
    mov     edi, ebx
    mov     rsi, [un_symbol]
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .activate
.final_gradients:
    xor     eax, eax
    mov     [un_final_len], rax
    mov     [un_bg_len], rax
    cmp     r13, NONE
    je      .final_bg
    mov     rax, [effect_config]
    mov     rdi, [rax + UNSTABLE.unstable_color]
    mov     rsi, r13
    lea     rdx, [un_final_spec]
    call    un_pair_gradient
    mov     [un_final_len], rax
.final_bg:
    cmp     r14, NONE
    je      .final_apply
    mov     rax, [effect_config]
    mov     rdi, [rax + UNSTABLE.unstable_color]
    mov     rsi, r14
    lea     rdx, [un_bg_spec]
    call    un_pair_gradient
    mov     [un_bg_len], rax
.final_apply:
    xor     r8d, r8d
    xor     r9d, r9d
    cmp     r13, NONE
    je      .no_fg
    lea     r8, [un_final_spec]
    mov     r9, [un_final_len]
.no_fg:
    xor     r10d, r10d
    xor     r11d, r11d
    cmp     r14, NONE
    je      .no_bg
    lea     r10, [un_bg_spec]
    mov     r11, [un_bg_len]
.no_bg:
    mov     edi, ebx
    mov     ecx, 3
    call    un_apply
    cmp     r13, NONE
    jne     .activate
    mov     edi, ebx
    mov     rsi, [un_symbol]
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, r14
    xor     r9d, r9d
    call    scene_add_frame
.activate:
    mov     edi, r12d
    mov     esi, [un_rumble_scene]
    call    scene_activate
    ; set_appearance(input symbol, start colors)
    mov     rdx, r13
    cmp     rdx, NONE
    jne     .appear
    mov     edx, UN_NEUTRAL_GRAY
.appear:
    mov     edi, r12d
    xor     esi, esi
    mov     rcx, r14
    call    set_appearance
    pop     r14
    pop     r13
    pop     rbx
    ret

; un_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
un_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + UNSTABLE.final_steps]
    mov     rcx, [rbx + UNSTABLE.final_step_count]
    mov     rsi, [rbx + UNSTABLE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [un_spectrum], rax
    mov     rdi, [rbx + UNSTABLE.final_stops]
    mov     rsi, [rbx + UNSTABLE.final_stop_count]
    mov     rdx, [rbx + UNSTABLE.final_steps]
    mov     rcx, [rbx + UNSTABLE.final_step_count]
    mov     r8, [un_spectrum]
    call    gradient_new
    mov     rdi, [un_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [un_map_width], rax
    push    qword [rbx + UNSTABLE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [un_map], rax
    pop     rbx
    ret

; un_fen_init(rdi=n): a Fenwick tree over n present elements.
un_fen_init:
    push    rbx
    mov     rbx, rdi
    mov     [un_fen_n], rdi
    lea     rdi, [rdi * 4 + 4]
    call    alloc
    mov     [un_fen], rax
    mov     ecx, 1
.fill:
    cmp     rcx, rbx
    ja      .top
    mov     rdx, rcx
    neg     rdx
    and     rdx, rcx
    mov     [rax + rcx * 4], edx
    inc     rcx
    jmp     .fill
.top:
    xor     eax, eax
    test    rbx, rbx
    jz      .done
    bsr     rcx, rbx
    mov     eax, 1
    shl     rax, cl
.done:
    mov     [un_fen_top], rax
    pop     rbx
    ret

; un_fen_take(rdi=k) -> rax = the index of the k-th (0-based) remaining
; element, which is removed.
un_fen_take:
    mov     r8, [un_fen]
    mov     r9, [un_fen_n]
    lea     rdx, [rdi + 1]
    xor     eax, eax
    mov     rcx, [un_fen_top]
.step:
    test    rcx, rcx
    jz      .found
    lea     r10, [rax + rcx]
    cmp     r10, r9
    ja      .half
    mov     r11d, [r8 + r10 * 4]
    cmp     r11, rdx
    jae     .half
    mov     rax, r10
    sub     rdx, r11
.half:
    shr     rcx, 1
    jmp     .step
.found:
    lea     r10, [rax + 1]
.remove:
    cmp     r10, r9
    ja      .done
    dec     dword [r8 + r10 * 4]
    mov     r11, r10
    neg     r11
    and     r11, r10
    add     r10, r11
    jmp     .remove
.done:
    ret

; un_restore: move every character back to its jumbled coordinate after an
; offset rumble frame was rendered.
un_restore:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
.char:
    cmp     rbx, [un_count]
    jae     .done
    mov     rax, [un_chars]
    mov     r12d, [rax + rbx * 4]
    mov     r13, r12
    shl     r13, 5
    add     r13, [un_recs]
    mov     edi, r12d
    mov     rsi, [r13 + UR_JUMBLED]
    call    set_coordinate
    inc     rbx
    jmp     .char
.done:
    mov     byte [un_restore_pending], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

; UN_BIT_POP dest, bits: dest = the lowest set bit's index, cleared from
; bits (bits != 0). Clobbers rcx below TIER 3.
%macro UN_BIT_POP 2
%if TIER >= 3
    tzcnt   %1, %2
    blsr    %2, %2
%else
    bsf     %1, %2
    lea     rcx, [%2 - 1]
    and     %2, rcx
%endif
%endmacro

; un_tick_active: tick every active character in ascending slot order (no
; callbacks here, so the live set is its own snapshot). Walks the bitmap a
; word at a time; a tick only touches its own slot's bit.
un_tick_active:
    push    rbx
    push    r12
    push    r13
    mov     r13d, [char_count]
    add     r13, 63
    shr     r13, 6
    xor     ebx, ebx
.word:
    cmp     rbx, r13
    jae     .done
    mov     rax, [active_bits]
    mov     r12, [rax + rbx * 8]
.bit:
    test    r12, r12
    jz      .next
    UN_BIT_POP rdi, r12
    mov     rax, rbx
    shl     rax, 6
    add     rdi, rax
    call    tick
    jmp     .bit
.next:
    inc     rbx
    jmp     .word
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; un_retain(edi=0 explosion, 1 reassembly): drop the active characters that
; reached the phase's waypoint (and, reassembling, finished their scene).
un_retain:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, edi
    mov     r15d, [char_count]
    add     r15, 63
    shr     r15, 6
    xor     ebp, ebp                    ; word index
.word:
    cmp     rbp, r15
    jae     .done
    mov     rax, [active_bits]
    mov     r14, [rax + rbp * 8]
.slot:
    test    r14, r14
    jz      .next_word
    UN_BIT_POP rbx, r14
    mov     rax, rbp
    shl     rax, 6
    add     rbx, rax
    mov     edi, ebx
    call    char_coord
    mov     r13, rax
    test    r12d, r12d
    jnz     .home
    mov     rax, rbx
    shl     rax, 5
    add     rax, [un_recs]
    cmp     r13, [rax + UR_TARGET]
    jne     .slot
    jmp     .remove
.home:
    mov     edi, ebx
    call    char_input_coord
    cmp     r13, rax
    jne     .slot
    mov     edi, ebx
    call    scene_is_complete
    test    eax, eax
    jz      .slot
.remove:
    mov     edi, ebx
    call    active_remove
    jmp     .slot
.next_word:
    inc     rbp
    jmp     .word
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; unstable_next_frame -> eax = 1 for a frame, 0 when done.
unstable_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     byte [un_restore_pending], 0
    je      .phase
    call    un_restore
.phase:
    cmp     qword [un_phase], UN_RUMBLE
    jne     .explosion
    mov     rax, [un_rumble_steps]
    cmp     rax, UN_MAX_RUMBLE
    jge     .explode
    cmp     rax, 30
    jle     .plain_rumble
    cqo
    idiv    qword [un_mod_delay]
    test    rdx, rdx
    jnz     .plain_rumble
    ; offset every character by one random (row, column) step
    mov     edi, 3
    call    rng_below
    lea     r14, [rax - 1]              ; row offset
    mov     edi, 3
    call    rng_below
    lea     r15, [rax - 1]              ; column offset
    xor     ebx, ebx
.offset:
    cmp     rbx, [un_count]
    jae     .offset_done
    mov     rax, [un_chars]
    mov     r12d, [rax + rbx * 4]
    mov     edi, r12d
    call    char_coord
    mov     rsi, rax
    sar     rsi, 32
    add     rsi, r14
    shl     rsi, 32
    add     eax, r15d
    or      rsi, rax
    mov     edi, r12d
    call    set_coordinate
    mov     edi, r12d
    call    step_animation
    inc     rbx
    jmp     .offset
.offset_done:
    mov     byte [un_restore_pending], 1
    mov     rax, [un_mod_delay]
    dec     rax
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     [un_mod_delay], rax
    jmp     .rumbled
.plain_rumble:
    xor     ebx, ebx
.step:
    cmp     rbx, [un_count]
    jae     .rumbled
    mov     rax, [un_chars]
    mov     edi, [rax + rbx * 4]
    call    step_animation
    inc     rbx
    jmp     .step
.rumbled:
    inc     qword [un_rumble_steps]
    jmp     .frame
.explode:
    mov     qword [un_phase], UN_EXPLOSION
    xor     ebx, ebx
.activate_explosion:
    cmp     rbx, [un_count]
    jae     .activated
    mov     rax, [un_chars]
    mov     r12d, [rax + rbx * 4]
    mov     rax, r12
    shl     rax, 5
    add     rax, [un_recs]
    mov     edi, r12d
    mov     esi, [rax + UR_EXPLOSION]
    call    path_activate
    inc     rbx
    jmp     .activate_explosion
.activated:
    call    active_clear
    xor     ebx, ebx
.insert:
    cmp     rbx, [un_count]
    jae     .explosion
    mov     rax, [un_chars]
    mov     edi, [rax + rbx * 4]
    call    active_insert
    inc     rbx
    jmp     .insert
.explosion:
    cmp     qword [un_phase], UN_EXPLOSION
    jne     .reassembly
    call    active_empty
    test    eax, eax
    jnz     .exploded
    call    un_tick_active
    xor     edi, edi
    call    un_retain
    jmp     .frame
.exploded:
    cmp     qword [un_hold], 0
    je      .reassemble
    dec     qword [un_hold]
    jmp     .frame
.reassemble:
    mov     qword [un_phase], UN_REASSEMBLY
    xor     ebx, ebx
.home:
    cmp     rbx, [un_count]
    jae     .reassembly
    mov     rax, [un_chars]
    mov     r12d, [rax + rbx * 4]
    mov     r13, r12
    shl     r13, 5
    add     r13, [un_recs]
    mov     edi, r12d
    mov     esi, [r13 + UR_FINAL]
    call    scene_activate
    mov     edi, r12d
    call    active_insert
    mov     edi, r12d
    mov     esi, [r13 + UR_REASSEMBLY]
    call    path_activate
    inc     rbx
    jmp     .home
.reassembly:
    cmp     qword [un_phase], UN_REASSEMBLY
    jne     .finished
    call    active_empty
    test    eax, eax
    jnz     .finished
    call    un_tick_active
    mov     edi, 1
    call    un_retain
.frame:
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
un_twelve:          dq 12

section .tstate
alignb 8
un_spectrum:        resq 1
un_map:             resq 1
un_map_width:       resq 1
un_chars:           resq 1          ; u32 slots, top to bottom, left to right
un_count:           resq 1
un_recs:            resq 1
un_fen:             resq 1
un_fen_n:           resq 1
un_fen_top:         resq 1
un_phase:           resq 1
un_rumble_steps:    resq 1
un_mod_delay:       resq 1
un_hold:            resq 1
un_fg:              resq 1
un_last_fg:         resq 1
un_symbol:          resq 1
un_rumble_scene:    resq 1
un_pair:            resq 2
un_rumble_spec:     resq 16
un_rumble_len:      resq 1
un_final_spec:      resq 16
un_final_len:       resq 1
un_bg_spec:         resq 16
un_bg_len:          resq 1
un_restore_pending: resb 1
