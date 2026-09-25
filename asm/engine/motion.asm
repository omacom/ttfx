; engine/motion.asm - Waypoint, Segment, Path and Motion
; (src/engine/motion.rs; stepping from src/engine/ctx.rs).
;
; Paths belong to a character's path map (ch_paths, linked through PA_NEXT in
; insertion order) and are addressed by index into [paths]. Records never
; move; their segment and waypoint arrays can (they grow by copying), so
; stepping re-reads the array after every event emission, the same way Rust
; re-resolves the path after each reentrant action.

%define PATH_LIMIT          (1 << 24)
%define ORIGIN_NAME         0x7fffffff  ; the synthetic origin waypoint ("origin")

section .text

paths_init:
    mov     rdi, PATH_LIMIT * PATH_SIZE
    call    reserve
    mov     [paths], rax
    ret

%macro PATH_PTR 2                       ; dest, index register
    mov     %1, %2
    shl     %1, 7                       ; PATH_SIZE
    add     %1, [paths]
%endmacro

; path_find(edi=slot, esi=name) -> eax = path index or NONE.
path_find:
    mov     rax, [ch_paths]
    mov     eax, [rax + rdi * 4]
.next:
    cmp     eax, NONE
    je      .done
    PATH_PTR rcx, rax
    cmp     [rcx + PA_NAME], esi
    je      .done
    mov     eax, [rcx + PA_NEXT]
    jmp     .next
.done:
    ret

; path_new(edi=slot, xmm0=speed, esi=easing id or NONE, rdx=layer or
;          NONE_I64, rcx=hold time, r8d=loop, r9d=name or AUTO) -> eax.
; Motion.new_path: auto ids are the path count probing upward; a duplicate
; explicit id is an error (an effect bug, so fatal here).
path_new:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    movsd   [rsp], xmm0
    mov     ebx, edi
    mov     ebp, esi
    mov     r12, rdx
    mov     r13, rcx
    mov     r14d, r8d
    mov     r15d, r9d
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe     .bad_speed
    cmp     r15d, AUTO
    jne     .named
    mov     rax, [ch_paths]
    mov     eax, [rax + rbx * 4]
    xor     r15d, r15d
.count:
    cmp     eax, NONE
    je      .probe
    inc     r15d
    PATH_PTR rcx, rax
    mov     eax, [rcx + PA_NEXT]
    jmp     .count
.probe:
    mov     edi, ebx
    mov     esi, r15d
    call    path_find
    cmp     eax, NONE
    je      .fresh
    inc     r15d
    jmp     .probe
.named:
    mov     edi, ebx
    mov     esi, r15d
    call    path_find
    cmp     eax, NONE
    jne     .duplicate
.fresh:
    mov     eax, [path_count]
    cmp     eax, PATH_LIMIT
    jae     .full
    inc     dword [path_count]
    mov     [rsp + 8], rax
    PATH_PTR r8, rax
    vpxorq  zmm0, zmm0, zmm0
    vmovdqu64 [r8], zmm0
    vmovdqu64 [r8 + 64], zmm0
    vzeroupper
    mov     [r8 + PA_NAME], r15d
    mov     dword [r8 + PA_NEXT], NONE
    movsd   xmm0, [rsp]
    movsd   [r8 + PA_SPEED], xmm0
    mov     [r8 + PA_EASE], ebp
    mov     [r8 + PA_OWNER], ebx
    xor     eax, eax
    mov     rcx, NONE_I64
    cmp     r12, rcx
    je      .no_layer
    mov     [r8 + PA_LAYER], r12d
    or      eax, PAF_LAYER
.no_layer:
    test    r14d, r14d
    jz      .flags
    or      eax, PAF_LOOP
.flags:
    mov     [r8 + PA_FLAGS], eax
    mov     [r8 + PA_HOLD], r13
    mov     [r8 + PA_HOLD_LEFT], r13
    ; append to the character's map
    mov     rcx, [ch_paths]
    lea     rcx, [rcx + rbx * 4]
.tail:
    cmp     dword [rcx], NONE
    je      .link
    mov     edx, [rcx]
    PATH_PTR rcx, rdx
    add     rcx, PA_NEXT
    jmp     .tail
.link:
    mov     rax, [rsp + 8]
    mov     [rcx], eax
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.bad_speed:
    lea     rdi, [msg_path_speed]
    mov     esi, msg_path_speed_len
    jmp     fatal
.duplicate:
    lea     rdi, [msg_duplicate_path]
    mov     esi, msg_duplicate_path_len
    jmp     fatal
.full:
    lea     rdi, [msg_paths_full]
    mov     esi, msg_paths_full_len
    jmp     fatal

; path_new_waypoint(edi=path, rsi=coord, rdx=bezier controls or 0, ecx=control
;                   count, r8d=name or AUTO) -> rax = pointer to the waypoint.
; Path.new_waypoint + _add_waypoint_to_path: from the second waypoint on, a
; segment from the previous one, the running total and max_steps.
path_new_waypoint:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15d, r8d
    PATH_PTR rbp, rbx
    cmp     r15d, AUTO
    jne     .named
    mov     r15d, [rbp + PA_WP_COUNT]
.probe:
    mov     esi, r15d
    call    waypoint_named
    test    rax, rax
    jz      .have_name
    inc     r15d
    jmp     .probe
.named:
    mov     esi, r15d
    call    waypoint_named
    test    rax, rax
    jnz     .duplicate
.have_name:
    ; a private copy of the controls (the caller's array may not live on)
    xor     eax, eax
    test    r14d, r14d
    jz      .no_controls
    test    r13, r13
    jz      .no_controls
    lea     rdi, [r14 * 8]
    call    alloc
    mov     rdi, rax
    mov     rsi, r13
    mov     ecx, r14d
    rep     movsq
    mov     r13, rax
    jmp     .grow
.no_controls:
    xor     r13d, r13d
    xor     r14d, r14d
.grow:
    mov     ecx, [rbp + PA_WP_COUNT]
    cmp     ecx, [rbp + PA_WP_CAP]
    jb      .room
    lea     rdi, [rbp + PA_WPS]
    mov     esi, WAYPOINT_SIZE
    lea     rdx, [rbp + PA_WP_COUNT]
    call    grow_array
.room:
    mov     ecx, [rbp + PA_WP_COUNT]
    shl     rcx, 5
    add     rcx, [rbp + PA_WPS]
    mov     [rcx + WP_COORD], r12
    mov     [rcx + WP_NAME], r15d
    mov     [rcx + WP_BEZ_COUNT], r14d
    mov     [rcx + WP_BEZ], r13
    inc     dword [rbp + PA_WP_COUNT]
    mov     [rsp + 32], rcx             ; the new waypoint
    cmp     dword [rbp + PA_WP_COUNT], 2
    jb      .done
    ; distance from the previous waypoint
    lea     rsi, [rcx - WAYPOINT_SIZE]
    mov     rdi, [rsi + WP_COORD]
    test    r14d, r14d
    jz      .line
    mov     rsi, r13
    mov     edx, r14d
    mov     rcx, r12
    call    find_length_of_bezier_curve
    jmp     .distance
.line:
    mov     rsi, r12
    mov     edx, 1
    call    find_length_of_line
.distance:
    movsd   [rsp], xmm0
    PATH_PTR rbp, rbx
    movsd   xmm1, [rbp + PA_TOTAL]
    addsd   xmm1, xmm0
    movsd   [rbp + PA_TOTAL], xmm1
    ; the segment: previous and new waypoint by value
    mov     ecx, [rbp + PA_SEG_COUNT]
    cmp     ecx, [rbp + PA_SEG_CAP]
    jb      .seg_room
    lea     rdi, [rbp + PA_SEGS]
    mov     esi, SEGMENT_SIZE
    lea     rdx, [rbp + PA_SEG_COUNT]
    call    grow_array
.seg_room:
    mov     ecx, [rbp + PA_SEG_COUNT]
    imul    rcx, rcx, SEGMENT_SIZE
    add     rcx, [rbp + PA_SEGS]
    mov     eax, [rbp + PA_WP_COUNT]
    sub     eax, 2
    shl     rax, 5
    add     rax, [rbp + PA_WPS]
    vmovdqu ymm0, [rax]
    vmovdqu [rcx + SG_START], ymm0
    vmovdqu ymm0, [rax + WAYPOINT_SIZE]
    vmovdqu [rcx + SG_END], ymm0
    vzeroupper
    movsd   xmm0, [rsp]
    movsd   [rcx + SG_DISTANCE], xmm0
    mov     word [rcx + SG_ENTERED], 0
    inc     dword [rbp + PA_SEG_COUNT]
    ; max_steps = round(total_distance / speed)
    movsd   xmm0, [rbp + PA_TOTAL]
    divsd   xmm0, [rbp + PA_SPEED]
    call    round_half_even
    mov     [rbp + PA_MAX], rax
    mov     eax, [rbp + PA_WP_COUNT]
    dec     eax
    shl     rax, 5
    add     rax, [rbp + PA_WPS]
    mov     [rsp + 32], rax
.done:
    mov     rax, [rsp + 32]
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.duplicate:
    lea     rdi, [msg_duplicate_waypoint]
    mov     esi, msg_duplicate_waypoint_len
    jmp     fatal

; waypoint_named(rbp=path record, esi=name) -> rax = the waypoint or 0.
waypoint_named:
    mov     ecx, [rbp + PA_WP_COUNT]
    mov     rax, [rbp + PA_WPS]
.next:
    test    ecx, ecx
    jz      .none
    cmp     [rax + WP_NAME], esi
    je      .done
    add     rax, WAYPOINT_SIZE
    dec     ecx
    jmp     .next
.none:
    xor     eax, eax
.done:
    ret

; grow_array(rdi=pointer field, esi=element size, rdx=count field (u32, the
; capacity follows it)): double the capacity (at least 4) by copying.
grow_array:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     eax, [r13 + 4]
    add     eax, eax
    mov     ecx, 4
    cmp     eax, ecx
    cmovb   eax, ecx
    mov     [r13 + 4], eax
    imul    rdi, rax, 1
    imul    rdi, r12
    call    alloc
    mov     rsi, [rbx]
    mov     rdi, rax
    mov     ecx, [r13]
    imul    ecx, r12d
    rep     movsb
    mov     [rbx], rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------ activation

; path_activate(edi=slot, esi=path): Motion.activate_path - a synthetic origin
; segment from the current coordinate to the first waypoint replaces the
; previous one (rebasing the total distance), playback restarts, the path's
; layer applies, and PATH_ACTIVATED fires.
path_activate:
    call    doze_wake                   ; update.asm: it must tick again
    push    rbx
    push    rbp
    push    r12
    push    r13
    sub     rsp, 104
    mov     ebx, edi
    mov     r12d, esi
    PATH_PTR rbp, r12
    cmp     dword [rbp + PA_WP_COUNT], 0
    je      .empty
    call    char_coord                  ; rdi still the slot
    mov     r13, rax                    ; current coordinate
    ; distance to the first waypoint
    mov     rax, [rbp + PA_WPS]
    vmovdqu ymm0, [rax]
    vmovdqu [rsp + 32], ymm0            ; first waypoint (segment end)
    vzeroupper
    mov     edx, [rax + WP_BEZ_COUNT]
    test    edx, edx
    jz      .line
    mov     rdi, r13
    mov     rsi, [rax + WP_BEZ]
    mov     rcx, [rax + WP_COORD]
    call    find_length_of_bezier_curve
    jmp     .distance
.line:
    mov     rdi, r13
    mov     rsi, [rax + WP_COORD]
    mov     edx, 1
    call    find_length_of_line
.distance:
    movsd   [rsp + 64], xmm0
    ; the origin segment's start waypoint
    mov     [rsp], r13
    mov     dword [rsp + 8], ORIGIN_NAME
    mov     dword [rsp + 12], 0
    mov     qword [rsp + 16], 0
    mov     rax, [ch_path]
    mov     [rax + rbx * 4], r12d
    PATH_PTR rbp, r12
    movsd   xmm1, [rbp + PA_TOTAL]
    addsd   xmm1, xmm0
    test    dword [rbp + PA_FLAGS], PAF_ORIGIN
    jz      .insert
    subsd   xmm1, [rbp + PA_ORIGIN_DIST]
    movsd   [rbp + PA_TOTAL], xmm1
    mov     rdi, [rbp + PA_SEGS]        ; replace segments[0]
    jmp     .write_origin
.insert:
    movsd   [rbp + PA_TOTAL], xmm1
    mov     ecx, [rbp + PA_SEG_COUNT]
    cmp     ecx, [rbp + PA_SEG_CAP]
    jb      .shift
    lea     rdi, [rbp + PA_SEGS]
    mov     esi, SEGMENT_SIZE
    lea     rdx, [rbp + PA_SEG_COUNT]
    call    grow_array
.shift:
    ; move the segments up by one (from the end), then write segments[0]
    mov     ecx, [rbp + PA_SEG_COUNT]
    imul    rcx, rcx, SEGMENT_SIZE
    mov     rsi, [rbp + PA_SEGS]
    lea     rdi, [rsi + rcx + SEGMENT_SIZE - 1]
    lea     rsi, [rsi + rcx - 1]
    std
    rep     movsb
    cld
    inc     dword [rbp + PA_SEG_COUNT]
    mov     rdi, [rbp + PA_SEGS]
.write_origin:
    vmovdqu ymm0, [rsp]
    vmovdqu [rdi + SG_START], ymm0
    vmovdqu ymm0, [rsp + 32]
    vmovdqu [rdi + SG_END], ymm0
    vzeroupper
    movsd   xmm0, [rsp + 64]
    movsd   [rdi + SG_DISTANCE], xmm0
    movsd   [rbp + PA_ORIGIN_DIST], xmm0
    or      dword [rbp + PA_FLAGS], PAF_ORIGIN
    mov     qword [rbp + PA_STEP], 0
    mov     rax, [rbp + PA_HOLD]
    mov     [rbp + PA_HOLD_LEFT], rax
    movsd   xmm0, [rbp + PA_TOTAL]
    divsd   xmm0, [rbp + PA_SPEED]
    call    round_half_even
    mov     [rbp + PA_MAX], rax
    ; every segment's events can fire again
    mov     ecx, [rbp + PA_SEG_COUNT]
    mov     rax, [rbp + PA_SEGS]
.clear:
    test    ecx, ecx
    jz      .layer
    mov     word [rax + SG_ENTERED], 0
    add     rax, SEGMENT_SIZE
    dec     ecx
    jmp     .clear
.layer:
    test    dword [rbp + PA_FLAGS], PAF_LAYER
    jz      .event
    mov     edi, ebx
    movsxd  rsi, dword [rbp + PA_LAYER]
    call    set_layer
.event:
    mov     rax, [ch_subs]
    test    byte [rax + rbx], 1 << EV_PATH_ACTIVATED
    jz      .done
    mov     edi, ebx
    mov     esi, EV_PATH_ACTIVATED
    mov     edx, CALLER_PATH
    mov     ecx, [rbp + PA_NAME]
    call    handle_event
.done:
    add     rsp, 104
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.empty:
    lea     rdi, [msg_empty_path]
    mov     esi, msg_empty_path_len
    jmp     fatal

; path_activate_name(edi=slot, esi=name)
path_activate_name:
    push    rdi
    call    path_find
    pop     rdi
    cmp     eax, NONE
    je      .missing
    mov     esi, eax
    jmp     path_activate
.missing:
    lea     rdi, [msg_path_missing]
    mov     esi, msg_path_missing_len
    jmp     fatal

; path_deactivate(edi=slot, esi=name or NONE): Motion.deactivate_path - any
; active path, or only the named one.
path_deactivate:
    mov     rax, [ch_path]
    mov     ecx, [rax + rdi * 4]
    cmp     ecx, NONE
    je      .done
    cmp     esi, NONE
    je      .clear
    PATH_PTR rdx, rcx
    cmp     [rdx + PA_NAME], esi
    jne     .done
.clear:
    mov     dword [rax + rdi * 4], NONE
    MARK_CANDIDATE
.done:
    ret

; chain_paths(edi=slot, rsi=path names (u32), rdx=count, ecx=loop):
; Motion.chain_paths - each path's completion activates the next.
chain_paths:
    cmp     rdx, 2
    jb      .done
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15d, 1
.link:
    cmp     r15, r13
    jae     .loop
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [r12 + r15 * 4 - 4]
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, [r12 + r15 * 4]
    push    0
    push    0
    call    event_register
    add     rsp, 16
    inc     r15
    jmp     .link
.loop:
    test    r14d, r14d
    jz      .out
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [r12 + r13 * 4 - 4]
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, [r12]
    push    0
    push    0
    call    event_register
    add     rsp, 16
.out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.done:
    ret

; ------------------------------------------------------------ stepping

; path_step(edi=slot, esi=path) -> rax = the next coordinate. Path.step: the
; index-based segment walk with its reentrant segment events.
path_step:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     ebx, edi
    mov     r12d, esi
    PATH_PTR rbp, r12
    mov     rax, [rbp + PA_MAX]
    test    rax, rax
    jz      .at_end
    cmp     [rbp + PA_STEP], rax
    jge     .at_end
    xorpd   xmm1, xmm1
    ucomisd xmm1, [rbp + PA_TOTAL]
    jne     .step
    jnp     .at_end
.step:
    inc     qword [rbp + PA_STEP]
    cvtsi2sd xmm0, qword [rbp + PA_STEP]
    cvtsi2sd xmm1, qword [rbp + PA_MAX]
    divsd   xmm0, xmm1                  ; ratio
    mov     edi, [rbp + PA_EASE]
    cmp     edi, NONE
    je      .factor
    call    ease
    PATH_PTR rbp, r12
.factor:
    mulsd   xmm0, [rbp + PA_TOTAL]
    movsd   [rbp + PA_LAST], xmm0
    movsd   [rsp], xmm0                 ; distance_to_travel
    mov     r13d, NONE                  ; active segment
    xor     r14d, r14d                  ; i
.walk:
    PATH_PTR rbp, r12
    cmp     r14d, [rbp + PA_SEG_COUNT]
    jae     .walked
    imul    r15, r14, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]        ; segments[i]
    movsd   xmm0, [rsp]
    ucomisd xmm0, [r15 + SG_DISTANCE]
    ja      .beyond
    ; this segment holds the destination
    mov     r13d, r14d
    cmp     byte [r15 + SG_ENTERED], 0
    jne     .walked
    mov     byte [r15 + SG_ENTERED], 1
    mov     rax, [ch_subs]
    test    byte [rax + rbx], 1 << EV_SEGMENT_ENTERED
    jz      .walked
    vmovdqu ymm0, [r15 + SG_END]
    vmovdqu [rsp + 16], ymm0            ; the end waypoint's key
    vzeroupper
    mov     edi, ebx
    mov     esi, EV_SEGMENT_ENTERED
    mov     edx, CALLER_WAYPOINT
    lea     rcx, [rsp + 16]
    call    handle_event
    jmp     .walked
.beyond:
    subsd   xmm0, [r15 + SG_DISTANCE]
    movsd   [rsp], xmm0
    movzx   eax, byte [r15 + SG_ENTERED]
    and     al, [r15 + SG_EXITED]
    jnz     .next_segment
    mov     rax, [ch_subs]
    test    byte [rax + rbx], (1 << EV_SEGMENT_ENTERED) | (1 << EV_SEGMENT_EXITED)
    jnz     .observed
    mov     word [r15 + SG_ENTERED], 0x0101
    jmp     .next_segment
.observed:
    vmovdqu ymm0, [r15 + SG_END]
    vmovdqu [rsp + 16], ymm0
    vzeroupper
    mov     al, [r15 + SG_EXITED]
    mov     [rsp + 8], al               ; exit already triggered?
    cmp     byte [r15 + SG_ENTERED], 0
    jne     .exit
    mov     byte [r15 + SG_ENTERED], 1
    mov     edi, ebx
    mov     esi, EV_SEGMENT_ENTERED
    mov     edx, CALLER_WAYPOINT
    lea     rcx, [rsp + 16]
    call    handle_event
.exit:
    cmp     byte [rsp + 8], 0
    jne     .next_segment
    PATH_PTR rbp, r12
    imul    r15, r14, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
    mov     byte [r15 + SG_EXITED], 1
    mov     edi, ebx
    mov     esi, EV_SEGMENT_EXITED
    mov     edx, CALLER_WAYPOINT
    lea     rcx, [rsp + 16]
    call    handle_event
.next_segment:
    inc     r14d
    jmp     .walk
.walked:
    PATH_PTR rbp, r12
    cmp     r13d, NONE
    jne     .have_segment
    ; for-else: overshoot past the last waypoint re-adds its distance
    mov     r13d, [rbp + PA_SEG_COUNT]
    dec     r13d
    imul    r15, r13, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
    movsd   xmm0, [rsp]
    addsd   xmm0, [r15 + SG_DISTANCE]
    movsd   [rsp], xmm0
.have_segment:
    imul    r15, r13, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
    movsd   xmm1, [r15 + SG_DISTANCE]
    xorpd   xmm0, xmm0
    ucomisd xmm1, xmm0
    jne     .ratio
    jnp     .position                   ; zero-length segment: t = 0
.ratio:
    movsd   xmm0, [rsp]
    divsd   xmm0, xmm1
    cmp     dword [rbp + PA_EASE], NONE
    jne     .position                   ; eased: unclamped, overshoot allowed
    minsd   xmm0, [path_one]            ; f64::min(x, 1.0)
.position:
    mov     rdi, [r15 + SG_START + WP_COORD]
    mov     ecx, [r15 + SG_END + WP_BEZ_COUNT]
    test    ecx, ecx
    jz      .line
    mov     rsi, [r15 + SG_END + WP_BEZ]
    mov     edx, ecx
    mov     rcx, [r15 + SG_END + WP_COORD]
    call    find_coord_on_bezier_curve
    jmp     .done
.line:
    mov     rsi, [r15 + SG_END + WP_COORD]
    call    find_coord_on_line
    jmp     .done
.at_end:
    mov     eax, [rbp + PA_SEG_COUNT]
    dec     eax
    imul    rax, rax, SEGMENT_SIZE
    add     rax, [rbp + PA_SEGS]
    mov     rax, [rax + SG_END + WP_COORD]
.done:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; motion_move(edi=slot): Motion.move - step the active path, then holds,
; loops, completion and their events.
motion_move:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    ; (Motion.previous_coord is not kept: nothing reads it)
    mov     rax, [ch_path]
    mov     esi, [rax + rbx * 4]
    cmp     esi, NONE
    je      .done
    PATH_PTR rax, rsi
    cmp     dword [rax + PA_SEG_COUNT], 0
    je      .done
    mov     edi, ebx
    call    path_step
    mov     edi, ebx
    mov     rsi, rax
    call    set_coordinate
    ; Python re-reads active_path after the step (a callback may swap it)
    mov     rax, [ch_path]
    mov     r12d, [rax + rbx * 4]
    cmp     r12d, NONE
    je      .cleared
    PATH_PTR r13, r12
    mov     rax, [r13 + PA_STEP]
    cmp     rax, [r13 + PA_MAX]
    jne     .done
    mov     rax, [r13 + PA_HOLD]
    test    rax, rax
    jz      .no_hold
    cmp     rax, [r13 + PA_HOLD_LEFT]
    jne     .no_hold
    mov     rax, [ch_subs]
    test    byte [rax + rbx], 1 << EV_PATH_HOLDING
    jz      .hold
    mov     edi, ebx
    mov     esi, EV_PATH_HOLDING
    mov     edx, CALLER_PATH
    mov     ecx, [r13 + PA_NAME]
    call    handle_event
.hold:
    PATH_PTR r13, r12
    dec     qword [r13 + PA_HOLD_LEFT]
    jmp     .done
.no_hold:
    cmp     qword [r13 + PA_HOLD_LEFT], 0
    je      .held
    dec     qword [r13 + PA_HOLD_LEFT]
    jmp     .done
.held:
    test    dword [r13 + PA_FLAGS], PAF_LOOP
    jz      .complete
    cmp     dword [r13 + PA_SEG_COUNT], 1
    jbe     .complete
    ; loop: deactivate and activate again
    mov     edi, ebx
    mov     esi, [r13 + PA_NAME]
    call    path_deactivate
    mov     edi, ebx
    mov     esi, r12d
    call    path_activate
    jmp     .done
.complete:
    mov     rax, [ch_done_path]
    mov     [rax + rbx * 4], r12d
    mov     edi, ebx
    mov     esi, [r13 + PA_NAME]
    call    path_deactivate
    mov     rax, [ch_subs]
    test    byte [rax + rbx], 1 << EV_PATH_COMPLETE
    jz      .done
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [r13 + PA_NAME]
    call    handle_event
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.cleared:
    lea     rdi, [msg_path_cleared]
    mov     esi, msg_path_cleared_len
    jmp     fatal

; paths_clear(edi=slot): drop the character's path map (particle resets).
paths_clear:
    mov     rax, [ch_paths]
    mov     dword [rax + rdi * 4], NONE
    ret

; path_reset(edi=path): `motion.paths.remove(id)` followed by `new_path` with
; the same id and parameters (rings' "disperse"): the record is emptied in
; place - no waypoints, segments or distances, playback at the start - and
; keeps its name, speed, easing, layer, hold time and loop flag. Its arrays'
; capacity is reused. Clobbers rax.
path_reset:
    PATH_PTR rax, rdi
    and     dword [rax + PA_FLAGS], ~PAF_ORIGIN
    mov     dword [rax + PA_WP_COUNT], 0
    mov     dword [rax + PA_SEG_COUNT], 0
    mov     qword [rax + PA_TOTAL], 0
    mov     qword [rax + PA_STEP], 0
    mov     qword [rax + PA_MAX], 0
    mov     qword [rax + PA_LAST], 0
    mov     qword [rax + PA_ORIGIN_DIST], 0
    push    rcx
    mov     rcx, [rax + PA_HOLD]
    mov     [rax + PA_HOLD_LEFT], rcx
    pop     rcx
    ret

section .rodata
align 8
path_one:   dq 1.0
STR msg_path_speed, "ttfx: asm engine: path speed must be greater than 0", 10
STR msg_duplicate_path, "ttfx: asm engine: duplicate path id", 10
STR msg_duplicate_waypoint, "ttfx: asm engine: duplicate waypoint id", 10
STR msg_paths_full, "ttfx: asm engine: path limit reached", 10
STR msg_empty_path, "ttfx: asm engine: activated an empty path", 10
STR msg_path_missing, "ttfx: asm engine: path not found", 10
STR msg_path_cleared, "ttfx: asm engine: active path cleared mid-move", 10

section .tstate
alignb 8
paths:          resq 1
path_count:     resd 1
