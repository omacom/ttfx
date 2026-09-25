; effects/errorcorrect.asm - "Some characters start in the wrong position and
; are corrected in sequence" (src/effects/errorcorrect.rs).
;
; Config (src/asm/effects.rs, the Errorcorrect arm).
;
; character_final_color_map lives in ch_user0 (fg) and ch_user1 (bg). Scenes
; are created in Rust's order, so their auto ids (and so the event keys) are
; Rust's; the ids are read back from the scene records.

struc ERRORCORRECT
    .error_pairs:       resq 1          ; f64
    .swap_delay:        resq 1
    .error_color:       resq 1
    .correct_color:     resq 1
    .movement_speed:    resq 1          ; f64
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define EC_SCN_ERROR        NAME_LITERAL + 0
; path names
%define EC_PATH_INPUT       NAME_LITERAL + 0

; a packed block element U+2580..U+25BF (E2 96 xx)
%define EC_BLOCK(cp)        (0x300000000 | ((0x80 | ((cp) & 0x3f)) << 16) | 0x96e2)

section .text

; errorcorrect_build: ErrorCorrect::build.
errorcorrect_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    call    ec_final_map
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [ec_dynamic], al
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    mov     [ec_char_count], rdx
    ; the final color map, then a one-frame spawn scene per character
    ; (the map has no observable effect, so both loops run as one)
    xor     r14d, r14d
.spawn:
    cmp     r14, r13
    jae     .swaps
    mov     r15d, [r12 + r14 * 4]
    mov     edi, r15d
    call    ec_final_colors
    mov     rcx, [ch_user0]
    mov     [rcx + r15 * 8], rax
    mov     rcx, [ch_user1]
    mov     [rcx + r15 * 8], rdx
    mov     edi, r15d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     rcx, [ch_user0]
    mov     rcx, [rcx + r15 * 8]
    mov     r8, [ch_user1]
    mov     r8, [r8 + r15 * 8]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r15 * 8]
    mov     edi, ebp
    mov     edx, 1
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r15d
    mov     esi, ebp
    call    scene_activate
    mov     edi, r15d
    call    set_visible
    inc     r14
    jmp     .spawn
.swaps:
    ; the correcting gradient: error -> correct in 10 steps
    mov     rax, [rbx + ERRORCORRECT.error_color]
    mov     [ec_pair_stops], rax
    mov     rax, [rbx + ERRORCORRECT.correct_color]
    mov     [ec_pair_stops + 8], rax
    lea     rdi, [ec_pair_stops]
    mov     esi, 2
    lea     rdx, [ec_ten_steps]
    mov     ecx, 1
    lea     r8, [ec_correcting]
    call    gradient_new
    mov     eax, eax
    mov     [ec_correcting_len], rax
    ; all_characters: a copy of input_characters
    mov     r14, [input_count]
    lea     rdi, [r14 * 4 + 8]
    call    alloc
    mov     r12, rax
    mov     rsi, [input_chars]
    xor     ecx, ecx
.copy:
    cmp     rcx, r14
    jae     .copied
    mov     eax, [rsi + rcx * 4]
    mov     [r12 + rcx * 4], eax
    inc     rcx
    jmp     .copy
.copied:
    lea     rdi, [r14 * 4 + 8]
    call    alloc
    mov     [ec_swapped], rax
    mov     r13, rax                    ; write pointer
    ; pair_count = (error_pairs * characters.len()) as i64
    cvtsi2sd xmm1, qword [ec_char_count]
    movsd   xmm0, [rbx + ERRORCORRECT.error_pairs]
    mulsd   xmm0, xmm1
    call    f64_to_i64
    mov     r15, rax
.pair:
    test    r15, r15
    jle     .built
    cmp     r14, 2
    jb      .built
    call    ec_take
    mov     ebp, eax                    ; char1
    call    ec_take
    mov     [rsp], eax                  ; char2
    mov     [r13], ebp
    mov     [r13 + 4], eax
    add     r13, 8
    inc     qword [ec_swapped_count]
    mov     edi, ebp
    mov     esi, [rsp]
    call    ec_place
    mov     edi, [rsp]
    mov     esi, ebp
    call    ec_place
    mov     edi, ebp
    call    ec_configure
    mov     edi, [rsp]
    call    ec_configure
    dec     r15
    jmp     .pair
.built:
    mov     qword [ec_swap_delay], 0
    mov     qword [ec_swapped_head], 0
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ec_take -> eax = all_characters.remove(rng.randrange(0, len)), with
; r12 = all_characters and r14 = its length (decremented).
ec_take:
    xor     edi, edi
    mov     rsi, r14
    call    rng_randrange
    mov     ecx, [r12 + rax * 4]
    push    rcx
    dec     r14
.shift:
    cmp     rax, r14
    jae     .done
    mov     edx, [r12 + rax * 4 + 4]
    mov     [r12 + rax * 4], edx
    inc     rax
    jmp     .shift
.done:
    pop     rax
    ret

; ec_place(edi=slot, esi=other): the character starts at the other's input
; coordinate with an "input_coord" path home.
ec_place:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     edi, esi
    call    char_input_coord
    mov     rsi, rax
    mov     edi, ebx
    call    set_coordinate
    mov     rax, [effect_config]
    movsd   xmm0, [rax + ERRORCORRECT.movement_speed]
    mov     edi, ebx
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, EC_PATH_INPUT
    call    path_new
    mov     r13d, eax
    mov     edi, ebx
    call    char_input_coord
    mov     rsi, rax
    mov     edi, r13d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    pop     r13
    pop     r12
    pop     rbx
    ret

; ec_scene_name(eax=scene) -> eax = its name. Clobbers rcx.
ec_scene_name:
    SCENE_PTR rcx, rax
    mov     eax, [rcx + SC_NAME]
    ret

; ec_configure(edi=slot): _configure_swapped_character.
ec_configure:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     ebx, edi
    mov     r12, [effect_config]
    ; first_block_wipe and last_block_wipe
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax
    call    ec_scene_name
    mov     [rsp], eax                  ; first name
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    call    ec_scene_name
    mov     [rsp + 4], eax              ; last name
    xor     ebp, ebp
.first:
    lea     eax, [0x2581 + rbp]
    and     eax, 0x3f
    or      eax, 0x80
    shl     rax, 16
    mov     rsi, EC_BLOCK(0x2580) & ~0xff0000
    or      rsi, rax
    mov     edi, r13d
    mov     edx, 3
    mov     rcx, [r12 + ERRORCORRECT.error_color]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    cmp     ebp, 8
    jb      .first
    ; last: U+2587 down to U+2581 in the correct color; under dynamic
    ; handling the last block takes the final colors
    xor     ebp, ebp
.last:
    mov     eax, 0x2587
    sub     eax, ebp
    and     eax, 0x3f
    or      eax, 0x80
    shl     rax, 16
    mov     rsi, EC_BLOCK(0x2580) & ~0xff0000
    or      rsi, rax
    mov     edi, r14d
    mov     edx, 3
    mov     rcx, [r12 + ERRORCORRECT.correct_color]
    mov     r8, NONE
    cmp     ebp, 6
    jne     .last_frame
    cmp     byte [ec_dynamic], 0
    je      .last_frame
    mov     rcx, [ch_user0]
    mov     rcx, [rcx + rbx * 8]
    mov     r8, [ch_user1]
    mov     r8, [r8 + rbx * 8]
.last_frame:
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    cmp     ebp, 7
    jb      .last
    ; initial: the input symbol in the error color, activated now
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edi, r15d
    mov     edx, 1
    mov     rcx, [r12 + ERRORCORRECT.error_color]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, ebx
    mov     esi, r15d
    call    scene_activate
    ; "error": ten flickers of the block and the white input symbol
    mov     edi, ebx
    mov     esi, EC_SCN_ERROR
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    xor     ebp, ebp
.error:
    mov     edi, r15d
    mov     rsi, EC_BLOCK(0x2593)
    mov     edx, 3
    mov     rcx, [r12 + ERRORCORRECT.error_color]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edx, 3
    mov     ecx, 0xffffff
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     ebp
    cmp     ebp, 10
    jb      .error
    ; correcting: distance-synced full blocks over the correcting gradient
    mov     edi, ebx
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    call    ec_scene_name
    mov     [rsp + 8], eax              ; correcting name
    push    0
    push    0
    mov     edi, r15d
    lea     rsi, [ec_full_block]
    mov     edx, 1
    mov     ecx, 3
    lea     r8, [ec_correcting]
    mov     r9, [ec_correcting_len]
    call    scene_apply_gradient
    add     rsp, 16
    ; final
    mov     edi, ebx
    cmp     byte [ec_dynamic], 0
    je      .static_final
    call    ec_dynamic_final
    jmp     .final_named
.static_final:
    mov     rax, [r12 + ERRORCORRECT.correct_color]
    mov     [ec_pair_stops], rax
    mov     rax, [ch_user0]
    mov     rax, [rax + rbx * 8]
    mov     [ec_pair_stops + 8], rax
    lea     rdi, [ec_pair_stops]
    mov     esi, 2
    lea     rdx, [ec_ten_steps]
    mov     ecx, 1
    lea     r8, [ec_fg_spectrum]
    call    gradient_new
    mov     r15d, eax
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    push    0
    push    0
    mov     edi, ebp
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rbx * 8]
    mov     edx, 1
    mov     ecx, 3
    lea     r8, [ec_fg_spectrum]
    mov     r9d, r15d
    call    scene_apply_gradient
    add     rsp, 16
    mov     eax, ebp
.final_named:
    call    ec_scene_name
    mov     ebp, eax                    ; final name
    ; events, in Rust's order
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, EC_SCN_ERROR
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [rsp + 16]             ; first
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, [rsp + 16]             ; first
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [rsp + 24]             ; correcting
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, [rsp + 16]             ; first
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, EC_PATH_INPUT
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, EC_PATH_INPUT
    mov     r8d, ACT_SET_LAYER
    mov     r9d, 1
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, EC_PATH_INPUT
    mov     r8d, ACT_SET_LAYER
    xor     r9d, r9d
    call    event_register
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, EC_PATH_INPUT
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, [rsp + 20]             ; last
    call    event_register
    mov     edi, ebx
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, [rsp + 20]             ; last
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, ebp                    ; final
    call    event_register
    add     rsp, 16
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ec_dynamic_final(edi=slot) -> eax = scene: _get_dynamic_final_scene, the
; correct color fading to the input colors.
ec_dynamic_final:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    xor     r12d, r12d                  ; fg spectrum length (0 = none)
    xor     r13d, r13d                  ; bg spectrum length
    mov     rax, [effect_config]
    mov     rax, [rax + ERRORCORRECT.correct_color]
    mov     [ec_pair_stops], rax
    mov     rax, [ch_fg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .bg
    mov     [ec_pair_stops + 8], rax
    lea     rdi, [ec_pair_stops]
    mov     esi, 2
    lea     rdx, [ec_ten_steps]
    mov     ecx, 1
    lea     r8, [ec_fg_spectrum]
    call    gradient_new
    mov     r12d, eax
.bg:
    mov     rax, [ch_bg]
    mov     rax, [rax + rbx * 8]
    cmp     rax, NONE
    je      .frames
    mov     [ec_pair_stops + 8], rax
    lea     rdi, [ec_pair_stops]
    mov     esi, 2
    lea     rdx, [ec_ten_steps]
    mov     ecx, 1
    lea     r8, [ec_bg_spectrum]
    call    gradient_new
    mov     r13d, eax
.frames:
    mov     rsi, [ch_sym]
    lea     rsi, [rsi + rbx * 8]
    mov     eax, r12d
    or      eax, r13d
    jz      .plain
    xor     r8d, r8d
    test    r12d, r12d
    jz      .no_fg
    lea     r8, [ec_fg_spectrum]
.no_fg:
    xor     eax, eax
    test    r13d, r13d
    jz      .no_bg
    lea     rax, [ec_bg_spectrum]
.no_bg:
    push    r13
    push    rax
    mov     edi, ebp
    mov     edx, 1
    mov     ecx, 3
    mov     r9d, r12d
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .done
.plain:
    mov     rsi, [rsi]
    mov     edi, ebp
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.done:
    mov     eax, ebp
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ec_final_colors(edi=slot) -> rax = fg, rdx = bg: the final color map entry
; (the input colors under dynamic handling, else the gradient mapping).
ec_final_colors:
    cmp     byte [ec_dynamic], 0
    je      .mapped
    mov     rax, [ch_fg]
    mov     rax, [rax + rdi * 8]
    mov     rdx, [ch_bg]
    mov     rdx, [rdx + rdi * 8]
    ret
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    sub     rax, [text_bottom]
    imul    rax, [ec_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rdi * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [ec_final_map_ptr]
    mov     rax, [rcx + rax * 8]
    mov     rdx, NONE
    ret

; ec_final_map: Gradient::new(final stops, final steps) and its coordinate
; mapping over the text rectangle.
ec_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + ERRORCORRECT.final_steps]
    mov     rcx, [rbx + ERRORCORRECT.final_step_count]
    mov     rsi, [rbx + ERRORCORRECT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [ec_final_spectrum], rax
    mov     rdi, [rbx + ERRORCORRECT.final_stops]
    mov     rsi, [rbx + ERRORCORRECT.final_stop_count]
    mov     rdx, [rbx + ERRORCORRECT.final_steps]
    mov     rcx, [rbx + ERRORCORRECT.final_step_count]
    mov     r8, [ec_final_spectrum]
    call    gradient_new
    mov     rdi, [ec_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [ec_final_map_width], rax
    push    qword [rbx + ERRORCORRECT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [ec_final_map_ptr], rax
    pop     rbx
    ret

; errorcorrect_next_frame -> eax = 1 for a frame, 0 when done.
errorcorrect_next_frame:
    push    rbx
    mov     rax, [ec_swapped_head]
    cmp     rax, [ec_swapped_count]
    jae     .delay
    cmp     qword [ec_swap_delay], 0
    jne     .delay
    ; the next pair starts its error scene
    inc     qword [ec_swapped_head]
    mov     rcx, [ec_swapped]
    lea     rbx, [rcx + rax * 8]
    mov     edi, [rbx]
    mov     esi, EC_SCN_ERROR
    call    scene_activate_name
    mov     edi, [rbx]
    call    active_insert
    mov     edi, [rbx + 4]
    mov     esi, EC_SCN_ERROR
    call    scene_activate_name
    mov     edi, [rbx + 4]
    call    active_insert
    mov     rax, [effect_config]
    mov     rax, [rax + ERRORCORRECT.swap_delay]
    mov     [ec_swap_delay], rax
    jmp     .step
.delay:
    cmp     qword [ec_swap_delay], 0
    je      .step
    dec     qword [ec_swap_delay]
.step:
    call    active_empty
    test    eax, eax
    jnz     .done
    call    update
    mov     eax, 1
    pop     rbx
    ret
.done:
    xor     eax, eax
    pop     rbx
    ret

section .rodata
align 8
ec_ten_steps:       dq 10
ec_full_block:      dq EC_BLOCK(0x2588)

section .tstate
alignb 8
ec_final_spectrum:  resq 1
ec_final_map_ptr:   resq 1
ec_final_map_width: resq 1
ec_char_count:      resq 1
ec_swapped:         resq 1              ; (char1, char2) u32 pairs
ec_swapped_count:   resq 1
ec_swapped_head:    resq 1
ec_swap_delay:      resq 1
ec_correcting_len:  resq 1
ec_pair_stops:      resq 2
ec_correcting:      resq 16
ec_fg_spectrum:     resq 16
ec_bg_spectrum:     resq 16
ec_dynamic:         resb 1
