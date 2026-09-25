; effects/decrypt.asm - "Display a movie style decryption effect"
; (src/effects/decrypt.rs).
;
; Config (src/asm/effects.rs DecryptAsm):
;
; Scenes are created in exactly the order Rust creates them, so every RNG
; draw lines up.

struc DECRYPT
    .typing_speed:      resq 1
    .cipher_colors:     resq 1          ; *const u64
    .cipher_count:      resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

%define ENCRYPTED_COUNT     523         ; 94 + 24 + 127 + 278 symbols

; scene names
%define TYPING              NAME_LITERAL + 0
%define FAST_DECRYPT        NAME_LITERAL + 1
%define SLOW_DECRYPT        NAME_LITERAL + 2
%define DISCOVERED          NAME_LITERAL + 3

; ch_user0 holds the typing scene (low half) and fast_decrypt (high half)

section .text

; decrypt_build: DecryptIterator.__init__ + build().
decrypt_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    call    make_encrypted_symbols
    ; memo of (cipher color, symbol) -> handle: colors x (523 + 4 blocks)
    mov     rax, [effect_config]
    mov     rdi, [rax + DECRYPT.cipher_count]
    imul    rdi, rdi, (ENCRYPTED_COUNT + 4) * 4
    call    alloc
    mov     [decrypt_memo], rax
    ; the final gradient mapped over the text rectangle
    call    final_color_map
    mov     r12, [input_chars]
    mov     r13, [input_count]
    ; --- prepare_data_for_type_effect: one "typing" scene per character
    xor     ebx, ebx
.typing:
    cmp     rbx, r13
    jae     .decrypting
    mov     edi, [r12 + rbx * 4]
    mov     esi, TYPING
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    mov     edi, [r12 + rbx * 4]
    mov     rcx, [ch_user0]
    mov     [rcx + rdi * 8], eax
    xor     ebp, ebp
.block:
    call    choose_cipher               ; eax = color index
    lea     esi, [ENCRYPTED_COUNT + rbp]
    call    memo_visual
    mov     esi, eax
    mov     edi, r14d
    mov     edx, 2
    call    scene_add_frame_visual
    inc     ebp
    cmp     ebp, 4
    jb      .block
    mov     edi, ENCRYPTED_COUNT
    call    rng_below                   ; symbol first ...
    mov     r15d, eax
    call    choose_cipher               ; ... then its color
    mov     esi, r15d
    call    memo_visual
    mov     esi, eax
    mov     edi, r14d
    mov     edx, 1
    call    scene_add_frame_visual
    inc     rbx
    jmp     .typing
.decrypting:
    ; --- prepare_data_for_decrypt_effect
    xor     ebx, ebx
.decrypt_char:
    cmp     rbx, r13
    jae     .built
    mov     edi, [r12 + rbx * 4]
    call    make_decrypting_scenes
    inc     rbx
    jmp     .decrypt_char
.built:
    mov     qword [typing_pos], 0
    mov     byte [decrypt_phase], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; make_decrypting_scenes(edi=slot) with rbx = the character's position k.
make_decrypting_scenes:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi                   ; slot
    ; fast_decrypt: one color, 80 random symbols of duration 2
    mov     esi, FAST_DECRYPT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r13d, eax                   ; fast scene
    mov     rcx, [ch_user0]
    mov     [rcx + r12 * 8 + 4], eax
    call    choose_cipher
    mov     r14d, eax                   ; color index for the whole character
    xor     ebp, ebp
.fast:
    mov     edi, ENCRYPTED_COUNT
    call    rng_below
    mov     esi, eax
    mov     eax, r14d
    call    memo_visual
    mov     esi, eax
    mov     edi, r13d
    mov     edx, 2
    call    scene_add_frame_visual
    inc     ebp
    cmp     ebp, 80
    jb      .fast
    ; slow_decrypt: 1-15 frames of long or flickering durations
    mov     edi, r12d
    mov     esi, SLOW_DECRYPT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax                   ; slow scene
    mov     edi, 1
    mov     esi, 15
    call    rng_randint
    mov     ebp, eax
.slow:
    test    ebp, ebp
    jz      .discovered
    mov     edi, ENCRYPTED_COUNT
    call    rng_below
    mov     ebx, eax                    ; symbol
    xor     edi, edi
    mov     esi, 100
    call    rng_randint
    cmp     rax, 30
    jg      .short
    mov     edi, 35
    mov     esi, 60
    jmp     .duration
.short:
    mov     edi, 3
    mov     esi, 6
.duration:
    call    rng_randrange
    push    rax
    mov     esi, ebx
    mov     eax, r14d
    call    memo_visual
    mov     esi, eax
    mov     edi, r15d
    pop     rdx
    call    scene_add_frame_visual
    dec     ebp
    jmp     .slow
.discovered:
    ; discovered: white -> final color in 10 steps (11 colors), duration 5
    mov     edi, r12d
    mov     esi, DISCOVERED
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax                    ; discovered scene
    mov     rax, [ch_row]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [final_map_width]
    mov     rcx, [ch_col]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [final_map]
    mov     rax, [rcx + rax * 8]
    mov     qword [pair_stops], 0xffffff
    mov     [pair_stops + 8], rax
    lea     rdi, [pair_stops]
    mov     esi, 2
    lea     rdx, [ten_steps]
    mov     ecx, 1
    lea     r8, [pair_spectrum]
    call    gradient_new
    mov     ebx, eax                    ; 11
    xor     r14d, r14d
.gradient:
    cmp     r14d, ebx
    jae     .events
    lea     rax, [pair_spectrum]
    mov     rcx, [rax + r14 * 8]
    mov     r8, NONE
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r12 * 8]
    mov     edi, ebp
    mov     edx, 5
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14d
    jmp     .gradient
.events:
    ; fast complete -> slow; slow complete -> discovered; start on fast
    push    0
    push    0
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, FAST_DECRYPT
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, SLOW_DECRYPT
    call    event_register
    mov     edi, r12d
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, SLOW_DECRYPT
    mov     r8d, ACT_ACTIVATE_SCENE
    mov     r9d, DISCOVERED
    call    event_register
    add     rsp, 16
    mov     edi, r12d
    mov     esi, r13d
    call    scene_activate
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; choose_cipher -> eax = rng.choice over the ciphertext colors (an index).
choose_cipher:
    mov     rax, [effect_config]
    mov     rdi, [rax + DECRYPT.cipher_count]
    jmp     rng_below

; memo_visual(eax=color index, esi=symbol index) -> eax = handle. Symbol
; indices past ENCRYPTED_COUNT are the four typing blocks.
memo_visual:
    push    rbx
    imul    ebx, eax, ENCRYPTED_COUNT + 4
    add     ebx, esi
    mov     rcx, [decrypt_memo]
    mov     edx, [rcx + rbx * 4]
    test    edx, edx
    jnz     .hit
    mov     rcx, [effect_config]
    mov     rcx, [rcx + DECRYPT.cipher_colors]
    mov     rdi, [rcx + rax * 8]
    lea     rcx, [encrypted_symbols]
    mov     rdx, [rcx + rsi * 8]
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     rcx, [decrypt_memo]
    mov     [rcx + rbx * 4], eax
    mov     edx, eax
.hit:
    mov     eax, edx
    pop     rbx
    ret

; make_encrypted_symbols: the _DecryptChars ranges, then the typing blocks.
make_encrypted_symbols:
    push    rbx
    push    r12
    xor     r12d, r12d
    lea     rbx, [symbol_ranges]
.range:
    mov     edi, [rbx]
    test    edi, edi
    jz      .blocks
.code:
    cmp     edi, [rbx + 4]
    jae     .next_range
    push    rdi
    call    utf8_pack
    pop     rdi
    lea     rcx, [encrypted_symbols]
    mov     [rcx + r12 * 8], rax
    inc     r12d
    inc     edi
    jmp     .code
.next_range:
    add     rbx, 8
    jmp     .range
.blocks:
    lea     rbx, [block_codes]
.block:
    mov     edi, [rbx]
    test    edi, edi
    jz      .done
    call    utf8_pack
    lea     rcx, [encrypted_symbols]
    mov     [rcx + r12 * 8], rax
    inc     r12d
    add     rbx, 4
    jmp     .block
.done:
    pop     r12
    pop     rbx
    ret

; final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    ; spectrum capacity: sum over pairs of the step counts, plus one per pair
    mov     rdi, [rbx + DECRYPT.final_steps]
    mov     rcx, [rbx + DECRYPT.final_step_count]
    mov     rsi, [rbx + DECRYPT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [final_spectrum], rax
    mov     rdi, [rbx + DECRYPT.final_stops]
    mov     rsi, [rbx + DECRYPT.final_stop_count]
    mov     rdx, [rbx + DECRYPT.final_steps]
    mov     rcx, [rbx + DECRYPT.final_step_count]
    mov     r8, [final_spectrum]
    call    gradient_new
    mov     rdi, [final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [final_map_width], rax
    push    qword [rbx + DECRYPT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [final_map], rax
    pop     rbx
    ret

; decrypt_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
decrypt_next_frame:
    push    rbx
    push    r12
    cmp     byte [decrypt_phase], 0
    jne     .decrypting
    mov     rax, [typing_pos]
    cmp     rax, [input_count]
    jb      .typing
    call    active_empty
    test    eax, eax
    jz      .typing
    ; every character typed and settled: start decrypting all of them
    xor     ebx, ebx
.start:
    cmp     rbx, [input_count]
    jae     .started
    mov     rax, [input_chars]
    mov     edi, [rax + rbx * 4]
    push    rdi
    call    active_insert
    pop     rdi
    mov     rax, [ch_user0]
    mov     esi, [rax + rdi * 8 + 4]    ; fast_decrypt
    call    scene_activate
    inc     rbx
    jmp     .start
.started:
    mov     byte [decrypt_phase], 1
.decrypting:
    call    active_empty
    test    eax, eax
    jnz     .finished
    call    update
    mov     eax, 1
    pop     r12
    pop     rbx
    ret
.typing:
    mov     rax, [typing_pos]
    cmp     rax, [input_count]
    jae     .tick
    xor     edi, edi
    mov     esi, 100
    call    rng_randint
    cmp     rax, 75
    jg      .tick
    mov     r12, [effect_config]
    mov     r12, [r12 + DECRYPT.typing_speed]
.type:
    test    r12, r12
    jz      .tick
    dec     r12
    mov     rbx, [typing_pos]
    cmp     rbx, [input_count]
    jae     .type
    inc     qword [typing_pos]
    mov     rax, [input_chars]
    mov     edi, [rax + rbx * 4]
    push    rdi
    call    set_visible
    mov     rdi, [rsp]
    mov     rax, [ch_user0]
    mov     esi, [rax + rdi * 8]        ; typing
    call    scene_activate
    pop     rdi
    call    active_insert
    jmp     .type
.tick:
    call    update
    mov     eax, 1
    pop     r12
    pop     rbx
    ret
.finished:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

section .rodata
align 8
ten_steps:      dq 10
; [start, end) codepoint ranges of the encrypted symbol alphabet
symbol_ranges:  dd 33, 127, 9608, 9632, 9472, 9599, 174, 452, 0, 0
; typing blocks: ▉ ▓ ▒ ░
block_codes:    dd 0x2589, 0x2593, 0x2592, 0x2591, 0

section .tstate
alignb 8
encrypted_symbols:  resq ENCRYPTED_COUNT + 4
decrypt_memo:       resq 1
final_spectrum:     resq 1
final_map:          resq 1
final_map_width:    resq 1
typing_pos:         resq 1
pair_stops:         resq 2
pair_spectrum:      resq 16
decrypt_phase:      resb 1
