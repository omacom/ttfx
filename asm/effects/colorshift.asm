; effects/colorshift.asm - "Display a gradient that shifts colors across the
; terminal" (src/effects/colorshift.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Colorshift). The effect draws
; nothing from the RNG.
;
; Per character: ch_user0 is loop_tracker_map's count, ch_user1 holds the
; "gradient" scene (low half) and "final_gradient" (high half).

struc COLORSHIFT
    .stops:             resq 1          ; *const u64 gradient_stops
    .stop_count:        resq 1
    .steps:             resq 1          ; *const i64 gradient_steps
    .step_count:        resq 1
    .frames:            resq 1          ; gradient_frames (fits 32 bits)
    .no_travel:         resq 1
    .travel_direction:  resq 1          ; GradientDirection
    .reverse:           resq 1          ; reverse_travel_direction
    .no_loop:           resq 1
    .cycles:            resq 1
    .skip_final:        resq 1          ; skip_final_gradient
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; scene names
%define CS_GRADIENT         NAME_LITERAL + 0
%define CS_FINAL_GRADIENT   NAME_LITERAL + 1

%define CS_MEMO_BITS        8           ; cs_memo entries: 1 << CS_MEMO_BITS

section .text

; colorshift_build: ColorShift::build.
colorshift_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     ; [rsp] = frame counter, [rsp+8] = spectrum index
    call    cs_final_color_map
    call    cs_gradient
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .built
    mov     ebp, [r12 + rbx * 4]
    mov     edi, ebp
    call    set_visible
    call    cs_rotation                 ; rax = k, the rotated spectrum's start
    mov     [rsp + 8], rax
    ; "gradient": the rotated spectrum, gradient_frames per color
    mov     edi, ebp
    mov     esi, CS_GRADIENT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r14d, eax
    mov     rax, [ch_sym]
    mov     rdi, [rax + rbp * 8]
    call    cs_symbol_handles
    mov     r15, rax
    mov     rax, [cs_len]
    mov     [rsp], rax
.frame:
    mov     rax, [rsp + 8]
    mov     esi, [r15 + rax * 4]
    test    esi, esi
    jnz     .cached
    mov     rcx, [cs_spectrum]
    mov     rdi, [rcx + rax * 8]
    mov     rsi, NONE
    mov     rdx, [ch_sym]
    mov     rdx, [rdx + rbp * 8]
    xor     ecx, ecx
    call    visual_make
    mov     rcx, [rsp + 8]
    mov     [r15 + rcx * 4], eax
    mov     esi, eax
.cached:
    mov     rax, [rsp + 8]
    inc     rax
    cmp     rax, [cs_len]
    jb      .wrapped
    xor     eax, eax
.wrapped:
    mov     [rsp + 8], rax
    mov     edi, r14d
    mov     rdx, [effect_config]
    mov     edx, [rdx + COLORSHIFT.frames]
    call    scene_add_frame_visual
    dec     qword [rsp]
    jnz     .frame
    ; the last color shown: spectrum[k - 1], wrapping
    mov     rax, [rsp + 8]
    test    rax, rax
    jnz     .prev
    mov     rax, [cs_len]
.prev:
    mov     rcx, [cs_spectrum]
    mov     rax, [rcx + rax * 8 - 8]
    mov     [cs_pair], rax
    mov     edi, ebp
    mov     esi, CS_FINAL_GRADIENT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     rcx, [ch_user1]
    mov     [rcx + rbp * 8], r14d
    mov     [rcx + rbp * 8 + 4], r15d
    cmp     qword [cfg_existing_colors], 1
    je      .dynamic
    ; last color -> the final gradient's color at the input coordinate
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [cs_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [cs_final_map]
    mov     rax, [rcx + rax * 8]
    lea     r8, [cs_fg_spectrum]
    call    cs_pair_gradient
    mov     r14d, eax
    xor     eax, eax
    mov     [rsp], rax
.final_frame:
    mov     rax, [rsp]
    cmp     eax, r14d
    jae     .activate
    inc     qword [rsp]
    lea     rcx, [cs_fg_spectrum]
    mov     rcx, [rcx + rax * 8]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edi, r15d
    mov     rdx, [effect_config]
    mov     edx, [rdx + COLORSHIFT.frames]
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .final_frame
.dynamic:
    ; last color -> the input colors, those the character has
    xor     r14d, r14d                  ; fg count
    mov     rax, [ch_fg]
    mov     rax, [rax + rbp * 8]
    cmp     rax, NONE
    je      .bg
    lea     r8, [cs_fg_spectrum]
    call    cs_pair_gradient
    mov     r14d, eax
.bg:
    xor     eax, eax
    mov     [rsp], rax                  ; bg count
    mov     rax, [ch_bg]
    mov     rax, [rax + rbp * 8]
    cmp     rax, NONE
    je      .dynamic_frames
    lea     r8, [cs_bg_spectrum]
    call    cs_pair_gradient
    mov     [rsp], rax
.dynamic_frames:
    mov     rcx, [effect_config]
    mov     ecx, [rcx + COLORSHIFT.frames]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     rax, [rsp]
    or      eax, r14d
    jnz     .apply
    mov     edi, r15d
    mov     edx, ecx
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .activate
.apply:
    mov     [cs_symbol], rsi
    mov     rax, [rsp]
    xor     edx, edx
    lea     r10, [cs_bg_spectrum]
    test    rax, rax
    cmovz   r10, rdx
    push    rax
    push    r10
    xor     r8d, r8d
    xor     r9d, r9d
    test    r14d, r14d
    jz      .no_fg
    lea     r8, [cs_fg_spectrum]
    mov     r9d, r14d
.no_fg:
    mov     edi, r15d
    lea     rsi, [cs_symbol]
    mov     edx, 1
    call    scene_apply_gradient
    add     rsp, 16
.activate:
    mov     edi, ebp
    mov     rax, [ch_user1]
    mov     esi, [rax + rbp * 8]
    call    scene_activate
    mov     edi, ebp
    call    active_insert
    push    0
    push    0
    mov     edi, ebp
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    mov     ecx, CS_GRADIENT
    mov     r8d, ACT_CALLBACK
    lea     r9, [cs_loop_tracker]
    call    event_register
    add     rsp, 16
    inc     rbx
    jmp     .char
.built:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; cs_symbol_handles(rdi=symbol) -> rax = the symbol's visual handles, one
; u32 per spectrum index (0 = not made yet): a direct-mapped memo of
; (symbol, spectrum color) -> visual_make handle. A colliding symbol takes
; the entry over with a fresh array. Clobbers C.
cs_symbol_handles:
    mov     rax, 0x9e3779b97f4a7c15
    imul    rax, rdi
    shr     rax, 64 - CS_MEMO_BITS
    shl     eax, 4
    lea     rcx, [cs_memo]
    add     rcx, rax
    mov     rax, [rcx + 8]
    test    rax, rax
    jz      .miss
    cmp     [rcx], rdi
    jne     .miss
    ret
.miss:
    push    rcx
    push    rdi
    mov     rdi, [cs_len]
    shl     rdi, 2
    call    alloc
    pop     rdi
    pop     rcx
    mov     [rcx], rdi
    mov     [rcx + 8], rax
    ret

; cs_pair_gradient(rax=end color, r8=out) -> eax = length:
; Gradient::with_steps(&[cs_pair, end], 8, false). Clobbers C.
cs_pair_gradient:
    mov     [cs_pair + 8], rax
    lea     rdi, [cs_pair]
    mov     esi, 2
    lea     rdx, [cs_eight]
    mov     ecx, 1
    jmp     gradient_new

; cs_rotation(ebp=slot) -> rax = k: the gradient's colors start at
; spectrum[k] (Python's spectrum[shift:] + spectrum[:shift]). 0 without
; travel. Clobbers C.
cs_rotation:
    mov     r8, [effect_config]
    xor     eax, eax
    cmp     qword [r8 + COLORSHIFT.no_travel], 0
    jne     .done
    mov     rax, [ch_irow]
    movsxd  r9, dword [rax + rbp * 4]   ; row
    mov     rax, [ch_icol]
    movsxd  r10, dword [rax + rbp * 4]  ; column
    mov     rax, [r8 + COLORSHIFT.travel_direction]
    cmp     eax, 1
    je      .horizontal
    cmp     eax, 2
    je      .radial
    cmp     eax, 3
    je      .diagonal
    ; vertical: row / canvas.top
    cvtsi2sd xmm0, r9
    cvtsi2sd xmm1, qword [canvas_top]
    divsd   xmm0, xmm1
    jmp     .shift
.horizontal:
    cvtsi2sd xmm0, r10
    cvtsi2sd xmm1, qword [canvas_right]
    divsd   xmm0, xmm1
    jmp     .shift
.diagonal:
    lea     rax, [r9 + r10]
    cvtsi2sd xmm0, rax
    mov     rax, [canvas_right]
    add     rax, [canvas_top]
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1
    jmp     .shift
.radial:
    mov     rdi, [text_bottom]
    mov     rsi, [text_top]
    mov     rdx, [text_left]
    mov     rcx, [text_right]
    mov     r8, r9
    shl     r8, 32
    mov     r10d, r10d
    or      r8, r10
    call    find_normalized_distance_from_center
    test    eax, eax
    jz      .outside
    mov     r8, [effect_config]
.shift:
    ; shift = (len as f64 * index) as i64, negated when reversed
    cvtsi2sd xmm1, qword [cs_len]
    mulsd   xmm0, xmm1
    call    f64_to_i64
    mov     r8, [effect_config]
    mov     rcx, rax
    neg     rcx
    cmp     qword [r8 + COLORSHIFT.reverse], 0
    cmovne  rax, rcx
    mov     rcx, [cs_len]
    test    rax, rax
    js      .negative
    cmp     rax, rcx
    cmova   rax, rcx
    jmp     .wrap
.negative:
    add     rax, rcx
    xor     edx, edx
    test    rax, rax
    cmovs   rax, rdx
.wrap:
    ; k == len rotates by nothing
    xor     edx, edx
    cmp     rax, rcx
    cmove   rax, rdx
.done:
    ret
.outside:
    FAIL    msg_not_in_rectangle

; cs_gradient: Gradient::new(gradient stops, steps, false, !no_loop). A
; looping gradient of two or more stops gets the first stop appended.
cs_gradient:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [effect_config]
    mov     r12, [rbx + COLORSHIFT.stops]
    mov     r13, [rbx + COLORSHIFT.stop_count]
    cmp     qword [rbx + COLORSHIFT.no_loop], 0
    jne     .sized
    cmp     r13, 1
    jbe     .sized
    lea     rdi, [r13 * 8 + 8]
    call    alloc
    xor     ecx, ecx
.copy:
    mov     rdx, [r12 + rcx * 8]
    mov     [rax + rcx * 8], rdx
    inc     rcx
    cmp     rcx, r13
    jb      .copy
    mov     rdx, [r12]
    mov     [rax + rcx * 8], rdx
    mov     r12, rax
    inc     r13
.sized:
    mov     rdi, [rbx + COLORSHIFT.steps]
    mov     rcx, [rbx + COLORSHIFT.step_count]
    mov     rsi, r13
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [cs_spectrum], rax
    mov     rdi, r12
    mov     esi, r13d
    mov     rdx, [rbx + COLORSHIFT.steps]
    mov     rcx, [rbx + COLORSHIFT.step_count]
    mov     r8, [cs_spectrum]
    call    gradient_new
    mov     eax, eax
    mov     [cs_len], rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; cs_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
cs_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + COLORSHIFT.final_steps]
    mov     rcx, [rbx + COLORSHIFT.final_step_count]
    mov     rsi, [rbx + COLORSHIFT.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [cs_final_spectrum], rax
    mov     rdi, [rbx + COLORSHIFT.final_stops]
    mov     rsi, [rbx + COLORSHIFT.final_stop_count]
    mov     rdx, [rbx + COLORSHIFT.final_steps]
    mov     rcx, [rbx + COLORSHIFT.final_step_count]
    mov     r8, [cs_final_spectrum]
    call    gradient_new
    mov     rdi, [cs_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [cs_final_map_width], rax
    push    qword [rbx + COLORSHIFT.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [cs_final_map], rax
    pop     rbx
    ret

; cs_loop_tracker(edi=slot, rsi=payload): ColorShift::dispatch_callback, on
; the "gradient" scene's completion.
cs_loop_tracker:
    mov     edi, edi
    mov     rax, [ch_user0]
    mov     rcx, [rax + rdi * 8]
    inc     rcx
    mov     [rax + rdi * 8], rcx
    mov     rdx, [effect_config]
    mov     rax, [ch_user1]
    mov     r8, [rdx + COLORSHIFT.cycles]
    test    r8, r8
    jz      .again
    cmp     rcx, r8
    jl      .again
    cmp     qword [rdx + COLORSHIFT.skip_final], 0
    jne     .done
    mov     esi, [rax + rdi * 8 + 4]    ; final_gradient
    jmp     scene_activate
.again:
    mov     esi, [rax + rdi * 8]        ; gradient
    jmp     scene_activate
.done:
    ret

; colorshift_next_frame -> eax = 1 while characters are active, else 0.
colorshift_next_frame:
    call    active_empty
    test    eax, eax
    jnz     .finished
    call    update
    mov     eax, 1
    ret
.finished:
    xor     eax, eax
    ret

section .rodata
align 8
cs_eight:       dq 8

section .tstate
alignb 8
cs_spectrum:        resq 1
cs_len:             resq 1
cs_final_spectrum:  resq 1
cs_final_map:       resq 1
cs_final_map_width: resq 1
cs_symbol:          resq 1
cs_pair:            resq 2
cs_fg_spectrum:     resq 16
cs_bg_spectrum:     resq 16
cs_memo:            resq 2 << CS_MEMO_BITS  ; (symbol, *u32 handles)
