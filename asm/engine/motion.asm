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

; Walk index (see path_step), in the path and segment records' spare bytes.
%define PA_INT_COUNT        120         ; u16 leading segments of whole-number distance
%define PA_DONE             122         ; u16 leading segments with both events fired
%define PA_CURSOR           124         ; u16 the segment the last step landed in
%define SG_PREFIX           76          ; u32 distance sum of segments 0..=i (the run above)
; Eased factor tables (path_ease_table), in PA_OWNER's slot (never read).
%define PA_ETAB             PA_OWNER    ; u32 table offset / 8; 0 = not looked up
%define ETAB_NONE           0xffffffff
%define ETAB_MAX_STEPS      65536
%define ETAB_REGION         (1 << 28)
%define ETAB_MAP_BITS       12
%define ETAB_MAP_SIZE       (1 << ETAB_MAP_BITS)
%if PA_WP_CAP + 4 > PA_INT_COUNT || PA_CURSOR + 2 > PATH_SIZE
%error "path record layout overlaps the walk index"
%endif
%if SEGMENT_SIZE % 16 || WAYPOINT_SIZE != 32
%error "the segment copies assume these sizes"
%endif
%if SG_EXITED >= SG_PREFIX || SG_PREFIX + 4 > SEGMENT_SIZE
%error "segment record layout overlaps the walk index"
%endif

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
    pxor    xmm0, xmm0
%assign pz_off 0
%rep PATH_SIZE / 16
    movdqu  [r8 + pz_off], xmm0
%assign pz_off pz_off + 16
%endrep
    mov     [r8 + PA_NAME], r15d
    mov     dword [r8 + PA_NEXT], NONE
    movsd   xmm0, [rsp]
    movsd   [r8 + PA_SPEED], xmm0
    mov     [r8 + PA_EASE], ebp
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
    movdqu  xmm0, [rax]
    movdqu  xmm5, [rax + 16]
    movdqu  [rcx + SG_START], xmm0
    movdqu  [rcx + SG_START + 16], xmm5
    ; the new waypoint from registers (just stored: reloading it wide
    ; would stall on store forwarding)
    mov     [rcx + SG_END + WP_COORD], r12
    mov     [rcx + SG_END + WP_NAME], r15d
    mov     [rcx + SG_END + WP_BEZ_COUNT], r14d
    mov     [rcx + SG_END + WP_BEZ], r13
    mov     qword [rcx + SG_END + 24], 0
    movsd   xmm0, [rsp]
    movsd   [rcx + SG_DISTANCE], xmm0
    mov     word [rcx + SG_ENTERED], 0
    inc     dword [rbp + PA_SEG_COUNT]
    call    path_extend_index
    ; max_steps = round(total_distance / speed)
    movsd   xmm0, [rbp + PA_TOTAL]
    divsd   xmm0, [rbp + PA_SPEED]
    ROUND_HALF_EVEN
    mov     [rbp + PA_MAX], rax
    mov     dword [rbp + PA_ETAB], 0
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

; path_extend_index(rbp=path record): extend the run of whole-number
; segment distances (PA_INT_COUNT) and its prefix sums (SG_PREFIX) over the
; segments after it. Distances are at most 2^20 and sums below 2^30, so
; every sum is exact in an f64 and in a u32.
; Clobbers rax, rcx, rdx, r8, r9, xmm0, xmm1.
path_extend_index:
    movzx   ecx, word [rbp + PA_INT_COUNT]
    mov     r8, [rbp + PA_SEGS]
    xor     edx, edx                    ; the sum so far
    test    ecx, ecx
    jz      .next
    imul    eax, ecx, SEGMENT_SIZE
    mov     edx, [r8 + rax - SEGMENT_SIZE + SG_PREFIX]
.next:
    cmp     ecx, [rbp + PA_SEG_COUNT]
    jae     .done
    cmp     ecx, 0xffff
    jae     .done
    imul    eax, ecx, SEGMENT_SIZE
    movsd   xmm0, [r8 + rax + SG_DISTANCE]
    cvttsd2si r9, xmm0
    cmp     r9, 1 << 20
    ja      .done                       ; unsigned: also NaN and negatives
    cvtsi2sd xmm1, r9
    ucomisd xmm1, xmm0
    jne     .done
    add     edx, r9d
    cmp     edx, 1 << 30
    jae     .done
    mov     [r8 + rax + SG_PREFIX], edx
    inc     ecx
    mov     [rbp + PA_INT_COUNT], cx
    jmp     .next
.done:
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
    movdqu  xmm0, [rax]
    movdqu  xmm5, [rax + 16]
    movdqu  [rsp + 32], xmm0            ; first waypoint (segment end)
    movdqu  [rsp + 32 + 16], xmm5
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
.shift_chunk:
    sub     rcx, 16                     ; SEGMENT_SIZE is a multiple of 16
    jb      .shifted
    movdqu  xmm0, [rsi + rcx]
    movdqu  [rsi + rcx + SEGMENT_SIZE], xmm0
    jmp     .shift_chunk
.shifted:
    inc     dword [rbp + PA_SEG_COUNT]
    mov     rdi, [rbp + PA_SEGS]
.write_origin:
    mov     [rdi + SG_START + WP_COORD], r13
    mov     dword [rdi + SG_START + WP_NAME], ORIGIN_NAME
    mov     dword [rdi + SG_START + WP_BEZ_COUNT], 0
    mov     qword [rdi + SG_START + WP_BEZ], 0
    mov     qword [rdi + SG_START + 24], 0
    movdqu  xmm0, [rsp + 32]
    movdqu  xmm5, [rsp + 32 + 16]
    movdqu  [rdi + SG_END], xmm0
    movdqu  [rdi + SG_END + 16], xmm5
    movsd   xmm0, [rsp + 64]
    movsd   [rdi + SG_DISTANCE], xmm0
    movsd   [rbp + PA_ORIGIN_DIST], xmm0
    or      dword [rbp + PA_FLAGS], PAF_ORIGIN
    mov     qword [rbp + PA_STEP], 0
    mov     rax, [rbp + PA_HOLD]
    mov     [rbp + PA_HOLD_LEFT], rax
    movsd   xmm0, [rbp + PA_TOTAL]
    divsd   xmm0, [rbp + PA_SPEED]
    ROUND_HALF_EVEN
    mov     [rbp + PA_MAX], rax
    mov     dword [rbp + PA_ETAB], 0
    ; every segment's events can fire again; the origin changed the sums
    mov     ecx, [rbp + PA_SEG_COUNT]
    mov     rax, [rbp + PA_SEGS]
.clear:
    test    ecx, ecx
    jz      .index
    mov     word [rax + SG_ENTERED], 0
    add     rax, SEGMENT_SIZE
    dec     ecx
    jmp     .clear
.index:
    mov     dword [rbp + PA_INT_COUNT], 0   ; and PA_DONE
    mov     word [rbp + PA_CURSOR], 0
    call    path_extend_index
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

; path_ease_table(rbp=path record) -> eax = PA_ETAB: the path's eased
; factor table, ease(step / max_steps) at [etab_base + eax * 8 + step * 8]
; for step 1..=max_steps. Tables are shared by every path with the same
; easing and max_steps (found through a direct-mapped map; a collision just
; makes a fresh table) and filled on first use; an entry of 0 means not yet
; computed. ETAB_NONE: too many steps, or the region is full - use ease().
; Clobbers rax, rcx, rdx, rsi, rdi, r8.
path_ease_table:
    mov     rax, [rbp + PA_MAX]
    cmp     rax, ETAB_MAX_STEPS
    ja      .none
    mov     rdi, [etab_map]
    test    rdi, rdi
    jnz     .lookup
    mov     rdi, ETAB_REGION
    call    reserve
    mov     [etab_base], rax
    mov     qword [etab_used], 1        ; offset 0 means "no table yet"
    mov     edi, ETAB_MAP_SIZE * 16
    call    alloc
    mov     [etab_map], rax
    mov     rdi, rax
    mov     rax, [rbp + PA_MAX]
.lookup:
    mov     esi, [rbp + PA_EASE]
    inc     esi
    shl     rax, 32
    or      rsi, rax                    ; key: max_steps, easing + 1 (never 0)
    mov     rax, rsi
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    shr     rax, 64 - ETAB_MAP_BITS
    shl     rax, 4
    add     rdi, rax
    cmp     [rdi], rsi
    jne     .create
    mov     eax, [rdi + 8]
    mov     [rbp + PA_ETAB], eax
    ret
.create:
    mov     rcx, [rbp + PA_MAX]
    inc     rcx                         ; entries 0..=max_steps
    mov     rax, [etab_used]
    lea     rdx, [rax + rcx]
    cmp     rdx, ETAB_REGION / 8
    ja      .none
    mov     [etab_used], rdx
    mov     [rdi], rsi
    mov     [rdi + 8], eax
    mov     [rbp + PA_ETAB], eax
    ret
.none:
    mov     eax, ETAB_NONE
    mov     [rbp + PA_ETAB], eax
    ret

; path_step(edi=slot, esi=path) -> rax = the next coordinate. Path.step: the
; index-based segment walk with its reentrant segment events.
;
; The walk subtracts each passed segment's distance from the distance to
; travel, in order. While those distances are whole numbers (and the
; distance is below 2^52) every subtraction is exact, so the running value
; is the distance minus a prefix sum, bit for bit, and each `d <= distance`
; test is `d <= prefix sum`. Over the leading run of such segments whose
; events have all fired (PA_DONE), the walk is a cursor search over the
; prefix sums (SG_PREFIX), which steps along with the character.
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
    PATH_PTR rbp, r12                   ; records never move
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
    mov     rax, [rbp + PA_STEP]
    inc     rax
    mov     [rbp + PA_STEP], rax
    cmp     dword [rbp + PA_EASE], NONE
    je      .ratio_only
    ; eased: the factor for (easing, max_steps, step) from its table
    mov     ecx, [rbp + PA_ETAB]
    test    ecx, ecx
    jnz     .have_table
    call    path_ease_table             ; rbp = the path
    mov     ecx, eax
    mov     rax, [rbp + PA_STEP]
.have_table:
    cmp     ecx, ETAB_NONE
    je      .ratio_only
    mov     rdx, [etab_base]
    lea     rdx, [rdx + rcx * 8]
    movsd   xmm0, [rdx + rax * 8]
    movq    rcx, xmm0
    test    rcx, rcx
    jnz     .factor                     ; 0 = not filled (or +0.0: recomputed)
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [rbp + PA_MAX]
    divsd   xmm0, xmm1                  ; ratio
    mov     edi, [rbp + PA_EASE]
    call    ease
    mov     ecx, [rbp + PA_ETAB]
    mov     rax, [rbp + PA_STEP]
    mov     rdx, [etab_base]
    lea     rdx, [rdx + rcx * 8]
    movsd   [rdx + rax * 8], xmm0
    jmp     .factor
.ratio_only:
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [rbp + PA_MAX]
    divsd   xmm0, xmm1                  ; ratio
    mov     edi, [rbp + PA_EASE]
    cmp     edi, NONE
    je      .factor
    call    ease
.factor:
    mulsd   xmm0, [rbp + PA_TOTAL]
    movsd   [rbp + PA_LAST], xmm0       ; distance_to_travel
    mov     r13d, NONE                  ; active segment
    xor     r14d, r14d                  ; i
    ; the exact prefix: L = min(PA_INT_COUNT, PA_DONE) segments
    movzx   edx, word [rbp + PA_INT_COUNT]
    movzx   eax, word [rbp + PA_DONE]
    cmp     edx, eax
    cmova   edx, eax
    test    edx, edx
    jz      .slow
    movsd   xmm1, [path_two_p52]
    ucomisd xmm1, xmm0
    jbe     .slow                       ; too large, or NaN
    mov     r15, [rbp + PA_SEGS]
    movzx   ecx, word [rbp + PA_CURSOR]
    cmp     ecx, edx
    cmova   ecx, edx
.back:
    ; the first segment c with prefix(c + 1) >= d, else L
    test    ecx, ecx
    jz      .forward
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r15 + rax - SEGMENT_SIZE + SG_PREFIX]
    ucomisd xmm1, xmm0
    jb      .forward
    dec     ecx
    jmp     .back
.forward:
    cmp     ecx, edx
    jae     .found
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r15 + rax + SG_PREFIX]
    ucomisd xmm1, xmm0
    jae     .found
    inc     ecx
    jmp     .forward
.found:
    mov     [rbp + PA_CURSOR], cx
    mov     r14d, ecx
    imul    eax, ecx, SEGMENT_SIZE
    test    ecx, ecx
    jz      .skipped
    cvtsi2sd xmm1, dword [r15 + rax - SEGMENT_SIZE + SG_PREFIX]
    subsd   xmm0, xmm1
.skipped:
    movsd   [rsp], xmm0
    cmp     ecx, edx
    jae     .walk
    add     r15, rax                    ; segments[c] holds the destination
    jmp     .holds
.slow:
    movsd   [rsp], xmm0
.walk:
    cmp     r14d, [rbp + PA_SEG_COUNT]
    jae     .walked
    imul    r15d, r14d, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]        ; segments[i]
    movsd   xmm0, [rsp]
    ucomisd xmm0, [r15 + SG_DISTANCE]
    ja      .beyond
.holds:
    ; this segment holds the destination
    mov     r13d, r14d
    cmp     byte [r15 + SG_ENTERED], 0
    jne     .walked
    mov     byte [r15 + SG_ENTERED], 1
    mov     rax, [ch_subs]
    test    byte [rax + rbx], 1 << EV_SEGMENT_ENTERED
    jz      .walked
    movdqu  xmm0, [r15 + SG_END]
    movdqu  xmm1, [r15 + SG_END + 16]
    movdqu  [rsp + 16], xmm0            ; the end waypoint's key
    movdqu  [rsp + 32], xmm1
    mov     edi, ebx
    mov     esi, EV_SEGMENT_ENTERED
    mov     edx, CALLER_WAYPOINT
    lea     rcx, [rsp + 16]
    call    handle_event
    jmp     .walked
.beyond:
    subsd   xmm0, [r15 + SG_DISTANCE]
    movsd   [rsp], xmm0
    cmp     word [r15 + SG_ENTERED], 0x0101
    je      .advance                    ; both events already fired
    mov     rax, [ch_subs]
    test    byte [rax + rbx], (1 << EV_SEGMENT_ENTERED) | (1 << EV_SEGMENT_EXITED)
    jnz     .observed
    mov     word [r15 + SG_ENTERED], 0x0101
    jmp     .advance
.observed:
    movdqu  xmm0, [r15 + SG_END]
    movdqu  xmm1, [r15 + SG_END + 16]
    movdqu  [rsp + 16], xmm0
    movdqu  [rsp + 32], xmm1
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
    jne     .reload
    imul    r15d, r14d, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
    mov     byte [r15 + SG_EXITED], 1
    mov     edi, ebx
    mov     esi, EV_SEGMENT_EXITED
    mov     edx, CALLER_WAYPOINT
    lea     rcx, [rsp + 16]
    call    handle_event
.reload:
    ; an action may have grown (moved) or reset the segments
    cmp     r14d, [rbp + PA_SEG_COUNT]
    jae     .next_segment
    imul    r15d, r14d, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
.advance:
    ; extend the all-fired prefix
    movzx   eax, word [rbp + PA_DONE]
    cmp     eax, r14d
    jne     .next_segment
    cmp     word [r15 + SG_ENTERED], 0x0101
    jne     .next_segment
    cmp     eax, 0xfffe
    ja      .next_segment
    inc     eax
    mov     [rbp + PA_DONE], ax
.next_segment:
    inc     r14d
    jmp     .walk
.walked:
    cmp     r13d, NONE
    jne     .have_segment
    ; for-else: overshoot past the last waypoint re-adds its distance
    mov     r13d, [rbp + PA_SEG_COUNT]
    dec     r13d
    imul    r15d, r13d, SEGMENT_SIZE
    add     r15, [rbp + PA_SEGS]
    movsd   xmm0, [rsp]
    addsd   xmm0, [r15 + SG_DISTANCE]
    movsd   [rsp], xmm0
.have_segment:
    imul    r15d, r13d, SEGMENT_SIZE
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
    mov     rsi, [r15 + SG_END + WP_COORD]
    mov     edx, [r15 + SG_END + WP_BEZ_COUNT]
    test    edx, edx
    jnz     .curve
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    jmp     find_coord_on_line
.curve:
    mov     rcx, rsi
    mov     rsi, [r15 + SG_END + WP_BEZ]
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    jmp     find_coord_on_bezier_curve
.at_end:
    mov     eax, [rbp + PA_SEG_COUNT]
    dec     eax
    imul    rax, rax, SEGMENT_SIZE
    add     rax, [rbp + PA_SEGS]
    mov     rax, [rax + SG_END + WP_COORD]
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
    ; an unchanged coordinate needs no set_coordinate: the character's
    ; render cell already matches it
    mov     rcx, [ch_col]
    cmp     [rcx + rbx * 4], eax
    jne     .moved
    mov     rdx, rax
    sar     rdx, 32
    mov     rcx, [ch_row]
    cmp     [rcx + rbx * 4], edx
    je      .placed
.moved:
    mov     edi, ebx
    mov     rsi, rax
    call    set_coordinate
.placed:
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
    mov     dword [rax + PA_ETAB], 0
    mov     qword [rax + PA_LAST], 0
    mov     qword [rax + PA_ORIGIN_DIST], 0
    mov     qword [rax + PA_INT_COUNT], 0   ; and PA_DONE, PA_CURSOR
    push    rcx
    mov     rcx, [rax + PA_HOLD]
    mov     [rax + PA_HOLD_LEFT], rcx
    pop     rcx
    ret

section .rodata
align 8
path_one:   dq 1.0
path_two_p52: dq 0x4330000000000000     ; 2^52
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
etab_base:      resq 1
etab_map:       resq 1
etab_used:      resq 1              ; in f64 entries
path_count:     resd 1
