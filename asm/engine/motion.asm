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
%define PA_REACH            126         ; u16 min(PA_INT_COUNT, PA_DONE + 1)
%define SG_PREFIX           76          ; u32 distance sum of segments 0..=i (the run above)
; Eased factor tables (path_ease_table), in PA_OWNER's slot (never read).
%define PA_ETAB             PA_OWNER    ; u32 table offset / 8; 0 = not looked up
%define ETAB_NONE           0xffffffff
%define ETAB_MAX_STEPS      65536
%define ETAB_REGION         (1 << 28)
%define ETAB_MAP_BITS       12
%define ETAB_MAP_SIZE       (1 << ETAB_MAP_BITS)
; Shared segment lists (see path_seg_share).
%define PAF_SHARED          8           ; PA_SEGS is a shared list
%define SEGSHARE_BITS       14
%define SEGSHARE_SIZE       (1 << SEGSHARE_BITS)    ; 16-byte entries: list, count, tag
%define SEGSHARE_PROBATION  256
%if PA_WP_CAP + 4 > PA_INT_COUNT || PA_REACH + 2 > PATH_SIZE
%error "path record layout overlaps the walk index"
%endif
%if SEGMENT_SIZE % 16 || WAYPOINT_SIZE != 32
%error "the segment copies assume these sizes"
%endif
%if SG_EXITED >= SG_PREFIX || SG_PREFIX + 4 > SEGMENT_SIZE
%error "segment record layout overlaps the walk index"
%endif

; Mirrors and the motion batch scratch (see motion_batch).
%define MV_LIMIT    (1 << 24)           ; slots with a mirror
; The mirrors are blocks of 8 slots, each field 8 entries in a row, so a
; group's fields are one run of memory. [MV_P8(slot) + slot * 8 + MVO_x]
; addresses an 8-byte field, [MV_P4(slot) + slot * 4 + MVO_x] a 4-byte one.
%define MV_BLOCK    704
%define MVO_TAG     0                   ; u32 path ^ MV_TAG_BIT, 0 = none
%define MVO_ETAB    32                  ; u32 PA_ETAB, 0 = linear
%define MVO_STEP    64                  ; f64 current_step (the path's, while mirrored)
%define MVO_MAX     128                 ; f64 max_steps
%define MVO_TOTAL   192                 ; f64 total_distance
%define MVO_OFF     256                 ; f64 distance before the segment
%define MVO_HI      320                 ; f64 segment distance
%define MVO_FLAGS   384                 ; u64 MVF_*
%define MVO_S       448                 ; u64 segment start
%define MVO_C       512                 ; u64 control (the end for a line)
%define MVO_E       576                 ; u64 segment end
%define MVO_LAST    640                 ; f64 last_distance_reached (the path's)
%define MV_SIZE     (MV_LIMIT / 8 * MV_BLOCK)

; MV_P8 dest64, slot64 / MV_P4: the block's base for 8- or 4-byte fields.
%macro MV_P8 2
    mov     %1, %2
    shr     %1, 3
    imul    %1, %1, MV_BLOCK - 64
    add     %1, [mv_base]
%endmacro
%macro MV_P4 2
    mov     %1, %2
    shr     %1, 3
    imul    %1, %1, MV_BLOCK - 32
    add     %1, [mv_base]
%endmacro
%define MV_TAG_BIT  0x80000000
%define MVF_CURVE   1                   ; one control point
%define MVF_OVER    2                   ; past the end: the for-else
%define MVF_FIRST   4                   ; no lower bound (lo = -inf)

; motion batch scratch (mb): lanes k are .resolve's interpolations, bits b
; the word's slots
%define MB_DL       0                   ; f64[64] distance into the segment
%define MB_SD       512                 ; f64[64] segment distance
%define MB_S        1024                ; u64[64] segment start
%define MB_C        1536                ; u64[64] control (the end for a line)
%define MB_E        2048                ; u64[64] segment end
%define MB_CLAMP    2560                ; u64[64] -1: a linear ratio (min 1.0)
%define MB_CURVE    3072                ; u64[64] -1: one-control curve
%define MB_COL      3584                ; i32[64] rounded column
%define MB_ROW      3840                ; i32[64] rounded row
%define MB_BIT      4096                ; u8[64] lane -> bit
%define MB_CURSOR   4160                ; u16[64] per bit: PA_CURSOR after the step
%define MB_COORD    4352                ; u64[64] per bit: the coordinate
%define MB_LAST     4864                ; f64[64] per bit: PA_LAST after the step
%define MB_STEPF    5376                ; f64[64] per bit: PA_STEP after the step
%define MB_OLDLAST  5888                ; f64[64] per bit: MVO_LAST before it
%define MB_SIZE     6400

; MV_RETIRE slot32: write the slot's mirror back and drop it. Clobbers rax.
%macro MV_RETIRE 1
%if TIER >= 3
    mov     eax, %1
    call    mv_retire
%endif
%endmacro

; MV_RETIRE_PATH path64: MV_RETIRE for the path's owner. Clobbers rax.
%macro MV_RETIRE_PATH 1
%if TIER >= 3
    mov     rax, [path_owners]
    mov     eax, [rax + %1 * 4]
    call    mv_retire
%endif
%endmacro

section .text

paths_init:
    mov     rdi, PATH_LIMIT * PATH_SIZE
    call    reserve
    mov     [paths], rax
%if TIER >= 3
    mov     rdi, MV_SIZE
    call    reserve
    mov     [mv_base], rax
    mov     rdi, PATH_LIMIT * 4
    call    reserve
    mov     [path_owners], rax
%endif
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
    call    path_take_free              ; particles.asm: a recycled index, or NONE
    cmp     eax, NONE
    jne     .recycled
    mov     eax, [path_count]
    cmp     eax, PATH_LIMIT
    jae     .full
    inc     dword [path_count]
.recycled:
    mov     [rsp + 8], rax
%if TIER >= 3
    mov     rcx, [path_owners]
    mov     [rcx + rax * 4], ebx
%endif
    PATH_PTR r8, rax
    pxor    xmm0, xmm0
%assign pz_off 0
%rep PATH_SIZE / 16
    movdqu  [r8 + pz_off], xmm0
%assign pz_off pz_off + 16
%endrep
    call    path_take_restore           ; particles.asm: its empty arrays
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
    MV_RETIRE_PATH rbx
    PATH_PTR rbp, rbx
    call    path_unshare
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
    call    bez_alloc                   ; particles.asm: alloc, or a freed block
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

; PATH_REACH record: store PA_REACH after PA_INT_COUNT or PA_DONE changed.
; Clobbers rax, rcx.
%macro PATH_REACH 1
    movzx   eax, word [%1 + PA_DONE]
    inc     eax
    movzx   ecx, word [%1 + PA_INT_COUNT]
    cmp     ecx, eax
    cmova   ecx, eax
    mov     [%1 + PA_REACH], cx
%endmacro

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
    PATH_REACH rbp
    ret

; ------------------------------------------------------------ shared segments
;
; Effects sometimes give several characters the same path (binarypath's
; eight bits per input character), and each walks its own copy of the
; segments. When a path is activated and its owner has no segment events,
; its segments are looked up by content (everything but the event flags)
; in segshare_table, and the path then walks the table's copy, which is
; never written: its flags read as fired. Without events nothing can reset
; the path mid-walk, so the path's own flags follow from its record: the
; segments before PA_DONE fired, and segment PA_DONE entered once any step
; was taken (every walk that moves PA_DONE ends in the new PA_DONE, and the
; first one enters where it ends). Anything that would write the segments
; or could observe the flags first gives the path a private copy with the
; flags spelled out (path_unshare): new waypoints, activation, path_reset
; and a segment event registered for the owner (event_register).

; path_unshare(rbp=path record): give a shared path its own segments.
; Clobbers rax, rcx, rdx, rsi, rdi.
path_unshare:
    test    dword [rbp + PA_FLAGS], PAF_SHARED
    jnz     .copy
    ret
.copy:
    mov     ecx, [rbp + PA_SEG_COUNT]
    mov     eax, 4
    cmp     ecx, eax
    cmovb   ecx, eax
    mov     [rbp + PA_SEG_CAP], ecx
    imul    edi, ecx, SEGMENT_SIZE
    call    path_unpark_segs            ; particles.asm: alloc, or its parked list
    mov     rsi, [rbp + PA_SEGS]
    mov     [rbp + PA_SEGS], rax
    mov     rdi, rax
    imul    ecx, [rbp + PA_SEG_COUNT], SEGMENT_SIZE
    rep     movsb
    ; the flags: fired before PA_DONE, entered at PA_DONE after a step
    mov     rdi, [rbp + PA_SEGS]
    movzx   edx, word [rbp + PA_DONE]
    xor     ecx, ecx
.flag:
    cmp     ecx, [rbp + PA_SEG_COUNT]
    jae     .flagged
    mov     eax, 0x0101
    cmp     ecx, edx
    jb      .store
    mov     eax, 0
    jne     .store
    cmp     qword [rbp + PA_STEP], 0
    je      .store
    mov     eax, 1
.store:
    mov     [rdi + SG_ENTERED], ax
    add     rdi, SEGMENT_SIZE
    inc     ecx
    jmp     .flag
.flagged:
    and     dword [rbp + PA_FLAGS], ~PAF_SHARED
    ret

; path_unshare_all(edi=slot): path_unshare for every path of the character
; (it is about to observe segment events). Preserves rdi, rsi; clobbers
; rax, rcx, rdx.
path_unshare_all:
    push    rbp
    push    rdi
    push    rsi
    push    rbx
    sub     rsp, 8
    MV_RETIRE edi
    mov     rax, [ch_paths]
    mov     ebx, [rax + rdi * 4]
.next:
    cmp     ebx, NONE
    je      .done
    PATH_PTR rbp, rbx
    call    path_unshare
    mov     ebx, [rbp + PA_NEXT]
    jmp     .next
.done:
    add     rsp, 8
    pop     rbx
    pop     rsi
    pop     rdi
    pop     rbp
    ret

; SEG_HASH_STEP acc, segment register, offset: fold one qword.
%macro SEG_HASH_STEP 3
    add     %1, [%2 + %3]
    xor     rdx, %1
    rol     rdx, 7
%endmacro

; path_seg_share(rbp=path record, ebx=owner slot): after activation, walk
; the shared copy of the segments when there is one (or make one).
; Clobbers rax, rcx, rdx, rsi, rdi, r8-r11.
path_seg_share:
    cmp     byte [segshare_off], 0
    jne     .done
    mov     rax, [ch_subs]
    test    byte [rax + rbx], (1 << EV_SEGMENT_ENTERED) | (1 << EV_SEGMENT_EXITED)
    jnz     .done
    mov     ecx, [rbp + PA_SEG_COUNT]
    test    ecx, ecx
    jz      .done
    cmp     ecx, 0xfff0
    jae     .done
    mov     r9, [segshare_table]
    test    r9, r9
    jnz     .hash
    mov     rdi, SEGSHARE_SIZE * 16
    call    reserve
    mov     [segshare_table], rax
    mov     r9, rax
    mov     ecx, [rbp + PA_SEG_COUNT]
.hash:
    ; a running sum of each segment's end and distance and the xor of its
    ; rotated prefixes (the compare checks the rest)
    mov     r10, [rbp + PA_SEGS]
    mov     rax, rcx                    ; seeded with the count
    xor     edx, edx
.fold:
    SEG_HASH_STEP rax, r10, SG_END + WP_COORD
    SEG_HASH_STEP rax, r10, SG_DISTANCE
    add     r10, SEGMENT_SIZE
    dec     ecx
    jnz     .fold
    mov     r11, 0x9E3779B97F4A7C15
    imul    rax, r11
    xor     rax, rdx
    imul    rax, r11
    mov     r10, rax                    ; the hash
    shr     rax, 64 - SEGSHARE_BITS
.probe:
    mov     rdx, rax
    shl     rdx, 4
    add     rdx, r9                     ; the entry
    mov     rsi, [rdx]
    test    rsi, rsi
    jz      .insert
    cmp     [rdx + 12], r10d
    jne     .next
    mov     ecx, [rbp + PA_SEG_COUNT]
    cmp     [rdx + 8], ecx
    jne     .next
    ; compare everything but the flags
    mov     rdi, [rbp + PA_SEGS]
.compare:
%assign so 0
%rep 9
    mov     r11, [rdi + so]
    cmp     r11, [rsi + so]
    jne     .next
%assign so so + 8
%endrep
    mov     r11d, [rdi + SG_PREFIX]
    cmp     r11d, [rsi + SG_PREFIX]
    jne     .next
    add     rdi, SEGMENT_SIZE
    add     rsi, SEGMENT_SIZE
    dec     ecx
    jnz     .compare
    inc     dword [segshare_hits]
    mov     rsi, [rdx]
    jmp     .use
.next:
    inc     eax
    and     eax, SEGSHARE_SIZE - 1
    jmp     .probe
.insert:
    ; a new list: the table keeps its own copy, with every flag fired
    mov     ecx, [segshare_count]
    cmp     ecx, SEGSHARE_SIZE * 3 / 4
    jae     .off
    cmp     ecx, SEGSHARE_PROBATION
    jb      .keep
    mov     r11d, [segshare_hits]
    shl     r11d, 2
    cmp     r11d, ecx
    jb      .off                        ; under one hit in four new lists
.keep:
    inc     dword [segshare_count]
    mov     r8, rdx
    imul    edi, [rbp + PA_SEG_COUNT], SEGMENT_SIZE
    call    alloc
    mov     [r8], rax
    mov     ecx, [rbp + PA_SEG_COUNT]
    mov     [r8 + 8], ecx
    mov     [r8 + 12], r10d
    mov     rdi, rax
    mov     rsi, [rbp + PA_SEGS]
    imul    ecx, ecx, SEGMENT_SIZE
    rep     movsb
    mov     rsi, [r8]
    mov     rdi, rsi
    mov     ecx, [rbp + PA_SEG_COUNT]
.fire:
    mov     word [rdi + SG_ENTERED], 0x0101
    add     rdi, SEGMENT_SIZE
    dec     ecx
    jnz     .fire
.use:
    ; the path walks the shared list; activation left every flag clear
    call    path_park_segs              ; particles.asm: its own list, for reuse
    mov     [rbp + PA_SEGS], rsi
    mov     ecx, [rbp + PA_SEG_COUNT]
    mov     [rbp + PA_SEG_CAP], ecx
    or      dword [rbp + PA_FLAGS], PAF_SHARED
.done:
    ret
.off:
    mov     byte [segshare_off], 1
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
%if TIER >= 3
    MV_RETIRE_PATH r12                  ; its previous owner's mirror
    mov     rax, [path_owners]
    mov     [rax + r12 * 4], ebx
%endif
    MV_RETIRE ebx
    PATH_PTR rbp, r12
    cmp     dword [rbp + PA_WP_COUNT], 0
    je      .empty
    call    path_unshare
    mov     edi, ebx
    call    char_coord
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
    call    path_seg_share
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
; makes a fresh table) and filled when made; an entry of 0 means not
; stored (ease gave +0.0). ETAB_NONE: too many steps, or the region is
; full - use ease(). A new table is filled at once. Clobbers C.
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
    ; fill it now: the paths that make a table nearly always walk it to
    ; the end, and a filled table lets motion_batch step them in vectors
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r14, rsp
    and     rsp, -16
    mov     ebx, eax
    mov     r12, [rbp + PA_MAX]
    mov     r13d, 1
.fill:
    cmp     r13, r12
    ja      .filled
    cvtsi2sd xmm0, r13
    cvtsi2sd xmm1, r12
    divsd   xmm0, xmm1                  ; path_step's ratio
    mov     edi, [rbp + PA_EASE]
    call    ease
    mov     rax, [etab_base]
    lea     rax, [rax + rbx * 8]
    movsd   [rax + r13 * 8], xmm0
    inc     r13
    jmp     .fill
.filled:
    mov     rsp, r14
    mov     eax, ebx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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
; prefix sums (SG_PREFIX), which steps along with the character. The search
; also covers the segment just after that run (PA_REACH): it may hold the
; destination too.
;
; When the segment the walk would test next holds the destination and was
; entered already - nearly every step - no event can fire, and the step
; finishes without saving any register; only the rest of the walk (.slow)
; keeps its state in callee-saved ones.
path_step:
    MV_RETIRE edi                       ; the step reads and writes the record
    PATH_PTR r8, rsi                    ; records never move
    mov     rax, [r8 + PA_MAX]
    test    rax, rax
    jz      .at_end
    cmp     [r8 + PA_STEP], rax
    jge     .at_end
    xorpd   xmm1, xmm1
    ucomisd xmm1, [r8 + PA_TOTAL]
    jne     .step
    jnp     .at_end
.step:
    mov     rax, [r8 + PA_STEP]
    inc     rax
    mov     [r8 + PA_STEP], rax
    cmp     dword [r8 + PA_EASE], NONE
    je      .ratio_only
    ; eased: the factor for (easing, max_steps, step) from its table
    mov     ecx, [r8 + PA_ETAB]
    test    ecx, ecx
    jz      .find_table
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
    cvtsi2sd xmm1, qword [r8 + PA_MAX]
    divsd   xmm0, xmm1                  ; ratio
    push    rdi
    push    r8
    sub     rsp, 8
    mov     edi, [r8 + PA_EASE]
    call    ease
    add     rsp, 8
    pop     r8
    pop     rdi
    mov     ecx, [r8 + PA_ETAB]
    mov     rax, [r8 + PA_STEP]
    mov     rdx, [etab_base]
    lea     rdx, [rdx + rcx * 8]
    movsd   [rdx + rax * 8], xmm0
    jmp     .factor
.find_table:
    push    rbp
    push    rdi
    push    r8
    mov     rbp, r8
    call    path_ease_table
    pop     r8
    pop     rdi
    pop     rbp
    mov     ecx, eax
    mov     rax, [r8 + PA_STEP]
    jmp     .have_table
.ratio_only:
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [r8 + PA_MAX]
    divsd   xmm0, xmm1                  ; ratio
    mov     eax, [r8 + PA_EASE]
    cmp     eax, NONE
    je      .factor
    push    rdi
    push    r8
    sub     rsp, 8
    mov     edi, eax
    call    ease
    add     rsp, 8
    pop     r8
    pop     rdi
.factor:
    mulsd   xmm0, [r8 + PA_TOTAL]
    movsd   [r8 + PA_LAST], xmm0        ; distance_to_travel
    ; the exact prefix: the walk skips the first L = min(PA_INT_COUNT,
    ; PA_DONE) segments, and the one after them may hold the destination
    ; too (L2 = min(PA_INT_COUNT, PA_DONE + 1))
    xor     ecx, ecx
    movzx   edx, word [r8 + PA_REACH]   ; L2
    test    edx, edx
    jz      .try
    movsd   xmm1, [path_two_p52]
    ucomisd xmm1, xmm0
    jbe     .try                        ; too large, or NaN
    mov     r9, [r8 + PA_SEGS]
    movzx   ecx, word [r8 + PA_CURSOR]
    cmp     ecx, edx
    cmova   ecx, edx
.back:
    ; the first segment c with prefix(c + 1) >= d, else L2
    test    ecx, ecx
    jz      .forward
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    ucomisd xmm1, xmm0
    jb      .forward
    dec     ecx
    jmp     .back
.forward:
    cmp     ecx, edx
    jae     .past
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax + SG_PREFIX]
    ucomisd xmm1, xmm0
    jae     .found
    inc     ecx
    jmp     .forward
.found:
    ; segments[c] holds the destination
    mov     [r8 + PA_CURSOR], cx
    imul    eax, ecx, SEGMENT_SIZE
    test    ecx, ecx
    jz      .entered
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    subsd   xmm0, xmm1
    jmp     .entered
.past:
    ; the walk goes on from segment L
    movzx   ecx, word [r8 + PA_DONE]
    cmp     ecx, edx
    cmova   ecx, edx
    mov     [r8 + PA_CURSOR], cx
    test    ecx, ecx
    jz      .try
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    subsd   xmm0, xmm1
.try:
    ; the walk's test of segment c with xmm0 left to travel: when it holds
    ; the destination and was entered already, no event fires, and no
    ; callee-saved register is needed
    cmp     ecx, [r8 + PA_SEG_COUNT]
    jae     .slow
    imul    eax, ecx, SEGMENT_SIZE
    mov     r9, [r8 + PA_SEGS]
    ucomisd xmm0, [r9 + rax + SG_DISTANCE]
    ja      .slow
.entered:
    cmp     byte [r9 + rax + SG_ENTERED], 0
    je      .slow                       ; its enter event is due
.finish:
    ; no event, so no callee-saved register is needed
    add     r9, rax
    movsd   xmm1, [r9 + SG_DISTANCE]
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    jne     .fast_ratio
    jp      .fast_ratio
    xorpd   xmm0, xmm0                  ; zero-length segment: t = 0
    jmp     .fast_position
.fast_ratio:
    divsd   xmm0, xmm1
    cmp     dword [r8 + PA_EASE], NONE
    jne     .fast_position              ; eased: unclamped, overshoot allowed
    minsd   xmm0, [path_one]            ; f64::min(x, 1.0)
.fast_position:
    mov     rdi, [r9 + SG_START + WP_COORD]
    mov     rsi, [r9 + SG_END + WP_COORD]
    mov     edx, [r9 + SG_END + WP_BEZ_COUNT]
    test    edx, edx
    jz      find_coord_on_line
    mov     rcx, rsi
    mov     rsi, [r9 + SG_END + WP_BEZ]
    jmp     find_coord_on_bezier_curve
.at_end:
    mov     eax, [r8 + PA_SEG_COUNT]
    dec     eax
    imul    rax, rax, SEGMENT_SIZE
    add     rax, [r8 + PA_SEGS]
    mov     rax, [rax + SG_END + WP_COORD]
    ret
.shared_walk:
    ; the walk over a shared list: its owner has no segment events, so a
    ; passed segment only extends PA_DONE (see path_unshare)
    cmp     ecx, [r8 + PA_SEG_COUNT]
    jae     .shared_over
    imul    eax, ecx, SEGMENT_SIZE
    mov     r9, [r8 + PA_SEGS]
    ucomisd xmm0, [r9 + rax + SG_DISTANCE]
    jna     .finish
    subsd   xmm0, [r9 + rax + SG_DISTANCE]
    movzx   edx, word [r8 + PA_DONE]
    cmp     ecx, edx
    jne     .shared_next
    inc     edx
    mov     [r8 + PA_DONE], dx
    inc     edx
    movzx   r10d, word [r8 + PA_INT_COUNT]
    cmp     r10d, edx
    cmova   r10d, edx
    mov     [r8 + PA_REACH], r10w
.shared_next:
    inc     ecx
    jmp     .shared_walk
.shared_over:
    ; for-else: overshoot past the last waypoint re-adds its distance
    lea     eax, [ecx - 1]
    imul    eax, eax, SEGMENT_SIZE
    mov     r9, [r8 + PA_SEGS]
    addsd   xmm0, [r9 + rax + SG_DISTANCE]
    jmp     .finish
.slow:
    ; the walk from segment ecx with xmm0 still to travel, which may fire
    ; segment events
    test    dword [r8 + PA_FLAGS], PAF_SHARED
    jnz     .shared_walk
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     ebx, edi
    mov     rbp, r8
    mov     r13d, NONE                  ; active segment
    mov     r14d, ecx                   ; i
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
    PATH_REACH rbp
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
.stepped:
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

; ------------------------------------------------------------ batched steps
;
; update ticks the active set a bitmap word (64 slots) at a time. At TIER 3
; and up, before it ticks a word, motion_batch works out the step of every
; character in it whose step is pure - one inside a segment already
; entered, with no event due, or at the end of the path - without changing
; anything a tick could observe. update then ticks the word in order as
; before; such a character's motion_move is motion_apply, which only calls
; set_coordinate when the character moved and runs the rest of motion_move
; (holds, loops, completion and their events) when the step reached
; max_steps. Below TIER 3 update calls motion_move as always.
;
; The mirror. A path record, its segments, its waypoints' controls and its
; eased-factor table are four scattered cache lines per character, and
; steps are bound by those misses. So each slot keeps a mirror of what its
; next pure steps need, in slot-ordered arrays (mv_base, MVO_*): the path
; it describes (MVO_TAG, path ^ MV_TAG_BIT; 0 = none); current_step and
; last_distance_reached, which the mirror holds for the path record while
; it stands; max_steps and total_distance; the eased table (MVO_ETAB, the
; path's PA_ETAB, or 0 for a linear ratio); and one segment: its start,
; control and end, its distance (MVO_HI) and the distance before it
; (MVO_OFF). For a destination d above off (any d but NaN with MVF_FIRST)
; and d - off <= hi, path_step lands in that segment with d - off still to
; travel and writes nothing but the step, the last distance and the cursor
; (which only says where the search starts: its results never depend on
; it); with MVF_OVER it also lands there past the end of the path, through
; its for-else. Those are the three ways path_step reaches its fast case
; with the segment's events fired or no longer observable:
;
; - the prefix search finds segment c below PA_REACH: prefix(c) < d <=
;   prefix(c + 1), and d - prefix(c) is exact, so the test on d is the
;   test on d - off (no lower bound for c = 0, which subtracts nothing);
; - the search runs past the prefix (c = PA_REACH = PA_INT_COUNT, all
;   fired): prefix(c) < d, then .try's d - off <= distance;
; - there is no prefix (PA_REACH = 0): .try on segment 0 with d.
;
; motion_batch's scalar walk (.resolve) writes a mirror when a step goes
; one of those ways. Anything that reads or changes the path state
; otherwise first retires it (mv_retire: the step and last distance go
; back to the record): path_step (each step it takes), path_activate,
; path_new_waypoint and path_reset (through path_owners),
; path_unshare_all, and .resolve itself; the synced scene step reads them
; through path_view. The vector pass does 8 slots at a time (TIER 4) or 4
; (TIER 3): the same divide, multiplies and adds per lane as the scalar
; code, no FMA, and cvtpd2dq's half-to-even rounding; a lane outside i32
; goes to motion_move.
;
; A step depends only on the character's own path, so the results hold
; until something outside the ticking character's own tick runs: an effect
; callback, or an action on another character. run_action bumps
; motion_epoch and calls motion_void for those: the mirrored steps of the
; characters not yet ticked are taken back, and update ticks the rest of
; the word through motion_move.

; MV_AXIS4: ymm7 = start, ymm8 = control, ymm9 = end on one axis, ymm2 = t,
; ymm3 = 1 - t, ymm13 = the curve lanes -> ymm7 = the point: the line
; start.interpolate(end, t), or the one-control curve. Clobbers ymm10-12.
%macro MV_AXIS4 0
    vmulpd  ymm10, ymm7, ymm3
    vmulpd  ymm11, ymm8, ymm2
    vaddpd  ymm10, ymm10, ymm11         ; a = start.interpolate(control, t)
    vmulpd  ymm11, ymm8, ymm3
    vmulpd  ymm12, ymm9, ymm2
    vaddpd  ymm11, ymm11, ymm12         ; b = control.interpolate(end, t)
    vmulpd  ymm12, ymm10, ymm3
    vmulpd  ymm11, ymm11, ymm2
    vaddpd  ymm12, ymm12, ymm11         ; a.interpolate(b, t)
    vblendvpd ymm7, ymm10, ymm12, ymm13
%endmacro

; path_view(edi=slot, eax=its active path) -> rdx = the path's
; current_step, max_steps, total_distance and last_distance_reached at
; their PA_* offsets, for the synced scene step: the record, or while the
; slot's mirror stands a copy of them (mv_view), which spares the record's
; cache lines. Preserves everything else.
path_view:
%if TIER >= 3
    cmp     edi, MV_LIMIT
    jae     .record
    push    rcx
    MV_P4   rdx, rdi
    mov     ecx, [rdx + rdi * 4 + MVO_TAG]
    xor     ecx, MV_TAG_BIT
    cmp     ecx, eax
    jne     .unmirrored
    MV_P8   rdx, rdi
    cvttsd2si rcx, [rdx + rdi * 8 + MVO_STEP]
    mov     [mv_view + PA_STEP], rcx
    cvttsd2si rcx, [rdx + rdi * 8 + MVO_MAX]
    mov     [mv_view + PA_MAX], rcx
    mov     rcx, [rdx + rdi * 8 + MVO_TOTAL]
    mov     [mv_view + PA_TOTAL], rcx
    mov     rcx, [rdx + rdi * 8 + MVO_LAST]
    mov     [mv_view + PA_LAST], rcx
    lea     rdx, [mv_view]
    pop     rcx
    ret
.unmirrored:
    pop     rcx
.record:
%endif
    mov     rdx, rax
    shl     rdx, 7                      ; PATH_SIZE
    add     rdx, [paths]
    ret

%if TIER >= 3

; mv_sync(eax=slot): write the slot's mirrored step and last distance back
; to its path record. Preserves everything but rax.
mv_sync:
    cmp     eax, MV_LIMIT
    jae     .ret
    push    rcx
    push    rdx
    MV_P4   rdx, rax
    mov     ecx, [rdx + rax * 4 + MVO_TAG]
    test    ecx, ecx
    jz      .out
    MV_P8   rdx, rax
    xor     ecx, MV_TAG_BIT
    shl     rcx, 7                      ; PATH_SIZE
    add     rcx, [paths]
    push    rsi
    cvttsd2si rsi, [rdx + rax * 8 + MVO_STEP]
    mov     [rcx + PA_STEP], rsi
    mov     rsi, [rdx + rax * 8 + MVO_LAST]
    mov     [rcx + PA_LAST], rsi
    pop     rsi
.out:
    pop     rdx
    pop     rcx
.ret:
    ret

; mv_retire(eax=slot): mv_sync, then drop the mirror. Preserves everything
; but rax.
mv_retire:
    cmp     eax, MV_LIMIT
    jae     .ret
    push    rax
    call    mv_sync
    pop     rax
    push    rcx
    MV_P4   rcx, rax
    mov     dword [rcx + rax * 4 + MVO_TAG], 0
    pop     rcx
.ret:
    ret

; motion_void: run_action is about to run an action that may change any
; path. The mirrored steps motion_batch took for characters update has not
; ticked yet are taken back. Preserves everything but rax and the vector
; registers.
motion_void:
    mov     rax, [mb_mirror_bits]
    test    rax, rax
    jz      .done
    push    rcx
    push    rdx
    push    rsi
    push    r8
    mov     ecx, [upd_cursor]
    sub     ecx, [mb_first]
    cmp     ecx, 63
    jae     .clear                      ; the word is ticked
    mov     rdx, -2
    shl     rdx, cl
    and     rax, rdx                    ; the bits after the ticking one
    jz      .clear
    lea     r8, [mb]
    movsd   xmm1, [path_one]
.undo:
    tzcnt   rcx, rax
    blsr    rax, rax
    mov     edx, [mb_first]
    add     edx, ecx
    MV_P8   rsi, rdx
    movsd   xmm0, [rsi + rdx * 8 + MVO_STEP]
    subsd   xmm0, xmm1
    movsd   [rsi + rdx * 8 + MVO_STEP], xmm0
    movsd   xmm0, [r8 + MB_OLDLAST + rcx * 8]
    movsd   [rsi + rdx * 8 + MVO_LAST], xmm0
    test    rax, rax
    jnz     .undo
.clear:
    mov     qword [mb_mirror_bits], 0
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
.done:
    ret

; motion_batch(rdi=snapshot word, esi=its first slot) -> rax = the bits
; whose motion_move is taken care of: motion_apply when their bit is in
; mb_act_bits, nothing otherwise. Clobbers C.
motion_batch:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    ; [rsp] resolved steps (motion_apply writes them), [rsp + 8] tails,
    ; [rsp + 16] the prefix-search flag, [rsp + 24] moves, [rsp + 32]
    ; mirrored steps, [rsp + 40] ready bits while assembling
    mov     r12, rdi                    ; candidates
    mov     r13d, esi                   ; first slot
    xor     r14d, r14d                  ; ready bits
    xor     r15d, r15d                  ; lanes
    xor     eax, eax
    mov     [rsp], rax
    mov     [rsp + 8], rax
    mov     [rsp + 24], rax
    mov     [rsp + 32], rax
    mov     [mb_first], r13d
    mov     rbp, [ch_path]
    mov     rbx, [mv_base]
    lea     rdi, [mb]
    cmp     r13d, MV_LIMIT
    jae     .resolve
    mov     r8, [etab_base]
    mov     r9, [ch_col]
    mov     r10, [ch_row]
    ; ---- the mirrored steps, a vector of slots at a time
%if TIER >= 4
    vbroadcastsd zmm20, [path_one]
    vpxorq  zmm21, zmm21, zmm21
    vpbroadcastd ymm22, [mv_tag_bit]
    vpbroadcastq zmm24, [mv_flag_curve]
    vpbroadcastq zmm25, [mv_flag_over]
    vpbroadcastq zmm26, [mv_flag_first]
    xor     ecx, ecx                    ; the group's first bit
.group:
    mov     rax, r12
    shr     rax, cl
    test    al, al
    jz      .group_next
    kmovb   k1, eax
    lea     esi, [r13 + rcx]            ; the group's first slot
    MV_P8   rbx, rsi
    MV_P4   rdx, rsi
    vpxord  ymm0, ymm22, [rbp + rsi * 4]
    vpcmpeqd k1{k1}, ymm0, [rdx + rsi * 4 + MVO_TAG]
    kortestb k1, k1
    jz      .group_next
    vmovupd zmm1, [rbx + rsi * 8 + MVO_STEP]
    vmovupd zmm2, [rbx + rsi * 8 + MVO_MAX]
    vcmppd  k1{k1}, zmm1, zmm2, 0x11    ; step < max_steps (LT_OQ)
    kortestb k1, k1
    jz      .group_next
    vaddpd  zmm1, zmm1, zmm20           ; the new step
    vdivpd  zmm3, zmm1, zmm2            ; ratio
    vmovdqu32 ymm4, [rdx + rsi * 4 + MVO_ETAB]
    vptestmd k2{k1}, ymm4, ymm4         ; eased lanes
    kortestb k2, k2
    jz      .linear
    vcvttpd2dq ymm5, zmm1
    vpaddd  ymm4, ymm4, ymm5
    kmovb   k3, k2
    vpxorq  zmm6, zmm6, zmm6
    vpgatherdq zmm6{k3}, [r8 + ymm4 * 8]
    vptestnmq k3{k2}, zmm6, zmm6        ; not filled yet: .resolve eases it
    kandnb  k1, k3, k1
    vmovapd zmm3{k2}, zmm6              ; the eased factor
.linear:
    vmulpd  zmm3, zmm3, [rbx + rsi * 8 + MVO_TOTAL]   ; distance_to_travel
    vmovupd zmm7, [rbx + rsi * 8 + MVO_OFF]
    vmovdqu64 zmm9, [rbx + rsi * 8 + MVO_FLAGS]
    vptestmq k4, zmm9, zmm26            ; MVF_FIRST
    vptestmq k5, zmm9, zmm25            ; MVF_OVER
    vptestmq k6, zmm9, zmm24            ; MVF_CURVE
    vcmppd  k7, zmm3, zmm7, 0x1e        ; off < d (GT_OQ)
    vcmppd  k3, zmm3, zmm3, 7           ; not NaN (ORD_Q)
    kandb   k3, k3, k4
    kandnb  k7, k4, k7
    korb    k7, k7, k3
    kandb   k1, k1, k7
    vsubpd  zmm7, zmm3, zmm7            ; d - off
    vmovupd zmm8, [rbx + rsi * 8 + MVO_HI]
    vcmppd  k4{k1}, zmm7, zmm8, 0x12    ; inside: d - off <= hi (LE_OQ)
    kandnb  k5, k4, k5
    kandb   k5, k5, k1                  ; past the end
    korb    k1, k4, k5
    vsubpd  zmm10, zmm7, zmm8
    vaddpd  zmm7{k5}, zmm10, zmm8       ; the for-else adds the distance back
    vdivpd  zmm9, zmm7, zmm8            ; t
    knotb   k7, k2
    vminpd  zmm9{k7}, zmm9, zmm20       ; linear: f64::min(t, 1.0)
    vcmppd  k7, zmm8, zmm21, 0          ; zero-length segment: t = 0
    vmovapd zmm9{k7}, zmm21
    vsubpd  zmm10, zmm20, zmm9          ; 1 - t
    vmovdqu64 zmm4, [rbx + rsi * 8 + MVO_S]
    vpmovqd ymm11, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm12, zmm4
    vcvtdq2pd zmm11, ymm11              ; start column
    vcvtdq2pd zmm12, ymm12              ; start row
    vmovdqu64 zmm4, [rbx + rsi * 8 + MVO_C]
    vpmovqd ymm13, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm14, zmm4
    vcvtdq2pd zmm13, ymm13              ; control column
    vcvtdq2pd zmm14, ymm14              ; control row
    vmovdqu64 zmm4, [rbx + rsi * 8 + MVO_E]
    vpmovqd ymm15, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm16, zmm4
    vcvtdq2pd zmm15, ymm15              ; end column
    vcvtdq2pd zmm16, ymm16              ; end row
    ; a = start.interpolate(control, t), the line itself (control = end)
    vmulpd  zmm17, zmm11, zmm10
    vmulpd  zmm4, zmm13, zmm9
    vaddpd  zmm17, zmm17, zmm4
    vmulpd  zmm18, zmm12, zmm10
    vmulpd  zmm4, zmm14, zmm9
    vaddpd  zmm18, zmm18, zmm4
    ; b = control.interpolate(end, t), then a.interpolate(b, t)
    vmulpd  zmm13, zmm13, zmm10
    vmulpd  zmm4, zmm15, zmm9
    vaddpd  zmm13, zmm13, zmm4
    vmulpd  zmm14, zmm14, zmm10
    vmulpd  zmm4, zmm16, zmm9
    vaddpd  zmm14, zmm14, zmm4
    vmulpd  zmm11, zmm17, zmm10
    vmulpd  zmm4, zmm13, zmm9
    vaddpd  zmm17{k6}, zmm11, zmm4
    vmulpd  zmm12, zmm18, zmm10
    vmulpd  zmm4, zmm14, zmm9
    vaddpd  zmm18{k6}, zmm12, zmm4
    vcvtpd2dq ymm17, zmm17
    vcvtpd2dq ymm18, zmm18
    ; a lane outside i32 (cvtpd2dq's 0x80000000) takes motion_move
    vpcmpeqd k7, ymm17, ymm22
    vpcmpeqd k3, ymm18, ymm22
    korb    k7, k7, k3
    kandnb  k1, k7, k1
    ; moved: the coordinate differs from the character's
    vpcmpeqd k3, ymm17, [r9 + rsi * 4]
    vpcmpeqd k4, ymm18, [r10 + rsi * 4]
    kandb   k3, k3, k4
    kandnb  k3, k3, k1
    vpmovzxdq zmm17, ymm17
    vpmovzxdq zmm18, ymm18
    vpsllq  zmm18, zmm18, 32
    vporq   zmm17, zmm17, zmm18
    vmovdqu64 [rdi + MB_COORD + rcx * 8], zmm17
    vcmppd  k7{k1}, zmm1, zmm2, 0       ; the step reached max_steps
    ; the mirror takes the step (motion_void takes it back)
    vmovupd zmm4, [rbx + rsi * 8 + MVO_LAST]
    vmovupd [rdi + MB_OLDLAST + rcx * 8], zmm4
    vmovupd [rbx + rsi * 8 + MVO_STEP]{k1}, zmm1
    vmovupd [rbx + rsi * 8 + MVO_LAST]{k1}, zmm3
    kmovb   eax, k1
    shl     rax, cl
    or      r14, rax
    or      [rsp + 32], rax
    kmovb   eax, k3
    shl     rax, cl
    or      [rsp + 24], rax
    kmovb   eax, k7
    shl     rax, cl
    or      [rsp + 8], rax
.group_next:
    add     ecx, 8
    cmp     ecx, 64
    jb      .group
    vzeroupper
%else
    vbroadcastsd ymm15, [path_one]
    vmovdqu ymm14, [mb_split]
    xor     ecx, ecx                    ; the group's first bit
.group:
    mov     rax, r12
    shr     rax, cl
    and     eax, 15
    jz      .group_next
    lea     esi, [r13 + rcx]            ; the group's first slot
    shl     eax, 5
    lea     rdx, [mv_lane_masks]
    vmovdqu ymm0, [rdx + rax]           ; the candidates
    MV_P8   rbx, rsi
    MV_P4   rdx, rsi
    vpbroadcastd xmm1, [mv_tag_bit]
    vpxor   xmm1, xmm1, [rbp + rsi * 4]
    vpcmpeqd xmm1, xmm1, [rdx + rsi * 4 + MVO_TAG]
    vpmovsxdq ymm1, xmm1
    vpand   ymm0, ymm0, ymm1
    vmovmskpd eax, ymm0
    test    eax, eax
    jz      .group_next
    vmovupd ymm1, [rbx + rsi * 8 + MVO_STEP]
    vmovupd ymm2, [rbx + rsi * 8 + MVO_MAX]
    vcmppd  ymm3, ymm1, ymm2, 0x11      ; step < max_steps (LT_OQ)
    vandpd  ymm0, ymm0, ymm3
    vmovmskpd eax, ymm0
    test    eax, eax
    jz      .group_next
    vaddpd  ymm1, ymm1, ymm15           ; the new step
    vmovupd [rdi + MB_STEPF + rcx * 8], ymm1
    vcmppd  ymm3, ymm1, ymm2, 0         ; the step reaches max_steps
    vmovmskpd r11d, ymm3
    vdivpd  ymm3, ymm1, ymm2            ; ratio
    vmovdqu xmm4, [rdx + rsi * 4 + MVO_ETAB]
    vpxor   xmm5, xmm5, xmm5
    vpcmpeqd xmm5, xmm4, xmm5
    vpmovsxdq ymm5, xmm5                ; linear lanes
    vpandn  ymm6, ymm5, ymm0            ; eased lanes
    vmovmskpd eax, ymm6
    test    eax, eax
    jz      .linear
    vcvttpd2dq xmm7, ymm1
    vpaddd  xmm4, xmm4, xmm7
    vpxor   ymm8, ymm8, ymm8
    vmovdqa ymm9, ymm6
    vpgatherdq ymm8, [r8 + xmm4 * 8], ymm9
    vpxor   ymm9, ymm9, ymm9
    vpcmpeqq ymm9, ymm8, ymm9
    vpand   ymm9, ymm9, ymm6            ; not filled yet: .resolve eases it
    vpandn  ymm0, ymm9, ymm0
    vblendvpd ymm3, ymm3, ymm8, ymm6    ; the eased factor
.linear:
    vmulpd  ymm3, ymm3, [rbx + rsi * 8 + MVO_TOTAL]   ; distance_to_travel
    vmovupd [rdi + MB_LAST + rcx * 8], ymm3
    vmovupd ymm4, [rbx + rsi * 8 + MVO_LAST]
    vmovupd [rdi + MB_OLDLAST + rcx * 8], ymm4
    vmovdqu ymm10, [rbx + rsi * 8 + MVO_FLAGS]
    vpbroadcastq ymm11, [mv_flag_first]
    vpand   ymm12, ymm10, ymm11
    vpcmpeqq ymm11, ymm12, ymm11        ; MVF_FIRST
    vmovupd ymm7, [rbx + rsi * 8 + MVO_OFF]
    vcmppd  ymm12, ymm3, ymm7, 0x1e     ; off < d (GT_OQ)
    vcmppd  ymm4, ymm3, ymm3, 7         ; not NaN (ORD_Q)
    vblendvpd ymm12, ymm12, ymm4, ymm11
    vandpd  ymm0, ymm0, ymm12
    vsubpd  ymm7, ymm3, ymm7            ; d - off
    vmovupd ymm8, [rbx + rsi * 8 + MVO_HI]
    vcmppd  ymm9, ymm7, ymm8, 0x12      ; inside: d - off <= hi (LE_OQ)
    vpbroadcastq ymm11, [mv_flag_over]
    vpand   ymm12, ymm10, ymm11
    vpcmpeqq ymm11, ymm12, ymm11
    vpandn  ymm11, ymm9, ymm11          ; past the end
    vorpd   ymm9, ymm9, ymm11
    vandpd  ymm0, ymm0, ymm9
    vsubpd  ymm12, ymm7, ymm8
    vaddpd  ymm12, ymm12, ymm8          ; the for-else adds the distance back
    vblendvpd ymm7, ymm7, ymm12, ymm11
    vdivpd  ymm2, ymm7, ymm8            ; t
    vminpd  ymm12, ymm2, ymm15
    vblendvpd ymm2, ymm2, ymm12, ymm5   ; linear: f64::min(t, 1.0)
    vxorpd  ymm12, ymm12, ymm12
    vcmppd  ymm12, ymm8, ymm12, 0       ; zero-length segment: t = 0
    vandnpd ymm2, ymm12, ymm2
    vsubpd  ymm3, ymm15, ymm2           ; 1 - t
    vpbroadcastq ymm11, [mv_flag_curve]
    vpand   ymm12, ymm10, ymm11
    vpcmpeqq ymm13, ymm12, ymm11        ; MVF_CURVE
    vpermd  ymm4, ymm14, [rbx + rsi * 8 + MVO_S]
    vpermd  ymm5, ymm14, [rbx + rsi * 8 + MVO_C]
    vpermd  ymm6, ymm14, [rbx + rsi * 8 + MVO_E]
    vcvtdq2pd ymm7, xmm4
    vcvtdq2pd ymm8, xmm5
    vcvtdq2pd ymm9, xmm6
    MV_AXIS4
    vcvtpd2dq xmm1, ymm7                ; columns
    vextracti128 xmm4, ymm4, 1
    vextracti128 xmm5, ymm5, 1
    vextracti128 xmm6, ymm6, 1
    vcvtdq2pd ymm7, xmm4
    vcvtdq2pd ymm8, xmm5
    vcvtdq2pd ymm9, xmm6
    MV_AXIS4
    vcvtpd2dq xmm7, ymm7                ; rows
    ; a lane outside i32 (cvtpd2dq's 0x80000000) takes motion_move
    vpbroadcastd xmm8, [mv_tag_bit]
    vpcmpeqd xmm9, xmm1, xmm8
    vpcmpeqd xmm10, xmm7, xmm8
    vpor    xmm9, xmm9, xmm10
    vpmovsxdq ymm9, xmm9
    vpandn  ymm0, ymm9, ymm0
    ; moved: the coordinate differs from the character's
    vpcmpeqd xmm9, xmm1, [r9 + rsi * 4]
    vpcmpeqd xmm10, xmm7, [r10 + rsi * 4]
    vpand   xmm9, xmm9, xmm10
    vpmovsxdq ymm9, xmm9
    vpandn  ymm9, ymm9, ymm0
    vpmovzxdq ymm1, xmm1
    vpmovzxdq ymm7, xmm7
    vpsllq  ymm7, ymm7, 32
    vpor    ymm1, ymm1, ymm7
    vmovdqu [rdi + MB_COORD + rcx * 8], ymm1
    ; the mirror takes the step (motion_void takes it back)
    vmovupd ymm4, [rdi + MB_STEPF + rcx * 8]
    vmaskmovpd [rbx + rsi * 8 + MVO_STEP], ymm0, ymm4
    vmovupd ymm4, [rdi + MB_LAST + rcx * 8]
    vmaskmovpd [rbx + rsi * 8 + MVO_LAST], ymm0, ymm4
    vmovmskpd eax, ymm0
    and     r11d, eax
    shl     rax, cl
    or      r14, rax
    or      [rsp + 32], rax
    vmovmskpd eax, ymm9
    shl     rax, cl
    or      [rsp + 24], rax
    shl     r11, cl
    or      [rsp + 8], r11
.group_next:
    add     ecx, 4
    cmp     ecx, 64
    jb      .group
    vzeroupper
%endif
    ; ---- the rest, one at a time, their path records fetched together
    andn    r12, r14, r12
    mov     rsi, r12
    mov     r8, [paths]
.prefetch:
    tzcnt   rcx, rsi
    jc      .resolve
    blsr    rsi, rsi
    add     ecx, r13d
    mov     eax, [rbp + rcx * 4]
    shl     rax, 7                      ; PATH_SIZE (NONE: a harmless prefetch)
    prefetcht0 [r8 + rax]
    prefetcht0 [r8 + rax + 64]
    jmp     .prefetch
.resolve:
    test    r12, r12
    jz      .compute
    tzcnt   r11, r12
    blsr    r12, r12
    lea     edx, [r13 + r11]
    MV_RETIRE edx                       ; the record is read from here on
    mov     eax, [rbp + rdx * 4]
    cmp     eax, NONE
    je      .resolve
    shl     rax, 7                      ; PATH_SIZE
    add     rax, [paths]
    mov     r8, rax
    mov     r9d, [r8 + PA_SEG_COUNT]
    test    r9d, r9d
    jz      .resolve                    ; motion_move does nothing
    ; path_step, without its writes
    mov     rax, [r8 + PA_MAX]
    test    rax, rax
    jz      .at_end
    mov     rdx, [r8 + PA_STEP]
    cmp     rdx, rax
    jge     .at_end
    xorpd   xmm1, xmm1
    ucomisd xmm1, [r8 + PA_TOTAL]
    jne     .step
    jnp     .at_end
.step:
    inc     rdx
    cvtsi2sd xmm2, rdx
    movsd   [rdi + MB_STEPF + r11 * 8], xmm2
    cmp     rdx, rax
    jne     .not_last
    bts     qword [rsp + 8], r11        ; the tail runs
.not_last:
    xor     r10d, r10d                  ; eased: no clamp
    cmp     dword [r8 + PA_EASE], NONE
    je      .ratio
    mov     ecx, [r8 + PA_ETAB]
    test    ecx, ecx
    jz      .find_table
.have_table:
    cmp     ecx, ETAB_NONE
    je      .resolve
    mov     rsi, [etab_base]
    lea     rsi, [rsi + rcx * 8]
    movsd   xmm0, [rsi + rdx * 8]
    movq    rcx, xmm0
    test    rcx, rcx
    jnz     .factor
    ; not filled: ease it as path_step does (pure, and not observable)
    cvtsi2sd xmm0, rdx
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1                  ; ratio
    push    rsi
    push    rdx
    push    rax
    push    r8
    push    r11
    push    r10
    mov     edi, [r8 + PA_EASE]
    call    ease
    pop     r10
    pop     r11
    pop     r8
    pop     rax
    pop     rdx
    pop     rsi
    lea     rdi, [mb]
    movsd   [rsi + rdx * 8], xmm0
    jmp     .factor
.find_table:
    push    rdx
    push    rax
    push    r8
    push    r11
    push    r10
    push    rbp
    mov     rbp, r8
    call    path_ease_table
    pop     rbp
    pop     r10
    pop     r11
    pop     r8
    pop     rax
    pop     rdx
    lea     rdi, [mb]
    mov     ecx, [r8 + PA_ETAB]
    jmp     .have_table
.ratio:
    dec     r10
    cvtsi2sd xmm0, rdx
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1
.factor:
    mulsd   xmm0, [r8 + PA_TOTAL]
    movsd   [rdi + MB_LAST + r11 * 8], xmm0
    xorpd   xmm4, xmm4                  ; off
    xorpd   xmm5, xmm5                  ; MVF_FIRST unless NaN (no mirror) or 1
    mov     byte [rsp + 16], 0          ; the prefix search found it
    movzx   esi, word [r8 + PA_CURSOR]  ; unchanged unless the search moves it
    xor     ecx, ecx
    movzx   edx, word [r8 + PA_REACH]
    test    edx, edx
    jz      .try
    movsd   xmm1, [path_two_p52]
    ucomisd xmm1, xmm0
    ja      .search
    movsd   xmm5, [mv_nan]              ; .try at 0 despite a prefix: no mirror
    jmp     .try
.search:
    mov     r9, [r8 + PA_SEGS]
    mov     ecx, esi
    cmp     ecx, edx
    cmova   ecx, edx
.back:
    test    ecx, ecx
    jz      .forward
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    ucomisd xmm1, xmm0
    jb      .forward
    dec     ecx
    jmp     .back
.forward:
    cmp     ecx, edx
    jae     .past
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax + SG_PREFIX]
    ucomisd xmm1, xmm0
    jae     .found
    inc     ecx
    jmp     .forward
.found:
    mov     esi, ecx
    mov     byte [rsp + 16], 1
    imul    eax, ecx, SEGMENT_SIZE
    test    ecx, ecx
    jz      .entered
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    subsd   xmm0, xmm1
    movapd  xmm4, xmm1
    movsd   xmm5, [path_one]            ; a lower bound
    jmp     .entered
.past:
    movzx   ecx, word [r8 + PA_DONE]
    cmp     ecx, edx
    cmova   ecx, edx
    mov     esi, ecx
    test    ecx, ecx
    jnz     .past_sum
    movsd   xmm5, [mv_nan]              ; no mirror
    jmp     .try
.past_sum:
    imul    eax, ecx, SEGMENT_SIZE
    cvtsi2sd xmm1, dword [r9 + rax - SEGMENT_SIZE + SG_PREFIX]
    subsd   xmm0, xmm1
    movapd  xmm4, xmm1
    movsd   xmm5, [path_one]            ; a lower bound
.try:
    cmp     ecx, [r8 + PA_SEG_COUNT]
    jae     .resolve
    imul    eax, ecx, SEGMENT_SIZE
    mov     r9, [r8 + PA_SEGS]
    ucomisd xmm0, [r9 + rax + SG_DISTANCE]
    ja      .beyond
.entered:
    cmp     byte [r9 + rax + SG_ENTERED], 0
    je      .resolve                    ; an event is due
.finish:
    ; path_step's .finish, as lane r15
    add     r9, rax
    mov     edx, [r9 + SG_END + WP_BEZ_COUNT]
    cmp     edx, 1
    ja      .resolve                    ; several controls: path_step
    movsd   [rdi + MB_DL + r15 * 8], xmm0
    mov     rax, [r9 + SG_DISTANCE]
    mov     [rdi + MB_SD + r15 * 8], rax
    mov     [rdi + MB_CLAMP + r15 * 8], r10
    mov     rax, [r9 + SG_START + WP_COORD]
    mov     [rdi + MB_S + r15 * 8], rax
    mov     rax, [r9 + SG_END + WP_COORD]
    mov     [rdi + MB_E + r15 * 8], rax
    neg     edx
    movsxd  rdx, edx
    mov     [rdi + MB_CURVE + r15 * 8], rdx
    jz      .control
    mov     rax, [r9 + SG_END + WP_BEZ]
    mov     rax, [rax]
.control:
    mov     [rdi + MB_C + r15 * 8], rax
    mov     [rdi + MB_BIT + r15], r11b
    mov     [rdi + MB_CURSOR + r11 * 2], si
    bts     r14, r11
    bts     qword [rsp], r11            ; motion_apply writes the step
    ; the mirror, when this is one of the three ways (xmm5 not NaN)
    lea     edx, [r13 + r11]
    cmp     edx, MV_LIMIT
    jae     .lane_done
    ucomisd xmm5, xmm5
    jp      .lane_done
    movsd   xmm1, [r9 + SG_DISTANCE]
    ucomisd xmm1, [mv_two_p51]
    jae     .lane_done
    jp      .lane_done
    MV_P8   rbx, rdx
    movsd   [rbx + rdx * 8 + MVO_HI], xmm1
    movsd   [rbx + rdx * 8 + MVO_OFF], xmm4
    cvtsi2sd xmm1, qword [r8 + PA_STEP]
    movsd   [rbx + rdx * 8 + MVO_STEP], xmm1
    mov     rax, [r8 + PA_LAST]
    mov     [rbx + rdx * 8 + MVO_LAST], rax
    cvtsi2sd xmm1, qword [r8 + PA_MAX]
    movsd   [rbx + rdx * 8 + MVO_MAX], xmm1
    mov     rax, [r8 + PA_TOTAL]
    mov     [rbx + rdx * 8 + MVO_TOTAL], rax
    xor     eax, eax
    test    r10, r10
    jnz     .mirror_linear
    mov     eax, [r8 + PA_ETAB]
.mirror_linear:
    MV_P4   rbx, rdx
    mov     [rbx + rdx * 4 + MVO_ETAB], eax
    MV_P8   rbx, rdx
    mov     rax, [rdi + MB_S + r15 * 8]
    mov     [rbx + rdx * 8 + MVO_S], rax
    mov     rax, [rdi + MB_C + r15 * 8]
    mov     [rbx + rdx * 8 + MVO_C], rax
    mov     rax, [rdi + MB_E + r15 * 8]
    mov     [rbx + rdx * 8 + MVO_E], rax
    ; MVF_CURVE; MVF_FIRST without a lower bound; MVF_OVER when the walk
    ; past the last segment changes nothing: not the prefix search's case,
    ; both events fired, and PA_DONE beyond it
    mov     eax, [rdi + MB_CURVE + r15 * 8]
    and     eax, MVF_CURVE
    xorpd   xmm1, xmm1
    ucomisd xmm5, xmm1
    jne     .mirror_bounded
    or      eax, MVF_FIRST
.mirror_bounded:
    cmp     byte [rsp + 16], 0
    jne     .mirror_flags
    mov     ecx, [r8 + PA_SEG_COUNT]
    dec     ecx
    imul    r10d, ecx, SEGMENT_SIZE
    add     r10, [r8 + PA_SEGS]
    cmp     r10, r9
    jne     .mirror_flags               ; not the last segment
    cmp     word [r9 + SG_ENTERED], 0x0101
    jne     .mirror_flags
    cmp     cx, [r8 + PA_DONE]
    je      .mirror_flags
    or      eax, MVF_OVER
.mirror_flags:
    mov     [rbx + rdx * 8 + MVO_FLAGS], rax
    MV_P4   rbx, rdx
    mov     eax, [rbp + rdx * 4]
    xor     eax, MV_TAG_BIT
    mov     [rbx + rdx * 4 + MVO_TAG], eax
.lane_done:
    inc     r15d
    jmp     .resolve
.beyond:
    ; past the last segment (an eased overshoot): when its events fired
    ; and PA_DONE is past it, the walk changes nothing, and its for-else
    ; adds the distance back
    lea     edx, [ecx + 1]
    cmp     edx, [r8 + PA_SEG_COUNT]
    jne     .resolve
    cmp     word [r9 + rax + SG_ENTERED], 0x0101
    jne     .resolve
    cmp     cx, [r8 + PA_DONE]
    je      .resolve
    subsd   xmm0, [r9 + rax + SG_DISTANCE]
    addsd   xmm0, [r9 + rax + SG_DISTANCE]
    jmp     .finish
.at_end:
    ; the last waypoint; nothing changes but the tail runs
    dec     r9d
    imul    r9, r9, SEGMENT_SIZE
    add     r9, [r8 + PA_SEGS]
    mov     rax, [r9 + SG_END + WP_COORD]
    mov     [rdi + MB_COORD + r11 * 8], rax
    bts     r14, r11
    bts     qword [rsp + 8], r11
    lea     edx, [r13 + r11]
    mov     rcx, [ch_col]
    cmp     [rcx + rdx * 4], eax
    jne     .at_end_moved
    shr     rax, 32
    mov     rcx, [ch_row]
    cmp     [rcx + rdx * 4], eax
    je      .resolve
.at_end_moved:
    bts     qword [rsp + 24], r11
    jmp     .resolve
.compute:
    test    r15d, r15d
    jz      .done
%if TIER >= 4
    ; 8 lanes at a time (the lanes past r15 are stale and ignored)
    xor     eax, eax
    vbroadcastsd zmm20, [path_one]
    vpxorq  zmm21, zmm21, zmm21
.lanes8:
    vmovupd zmm0, [rdi + MB_DL + rax * 8]
    vmovupd zmm1, [rdi + MB_SD + rax * 8]
    vdivpd  zmm2, zmm0, zmm1
    vmovdqu64 zmm3, [rdi + MB_CLAMP + rax * 8]
    vpmovq2m k1, zmm3
    vminpd  zmm2{k1}, zmm2, zmm20       ; f64::min(t, 1.0)
    vcmppd  k2, zmm1, zmm21, 0          ; zero-length segment: t = 0
    vmovapd zmm2{k2}, zmm21
    vsubpd  zmm3, zmm20, zmm2           ; 1 - t
    vmovdqu64 zmm4, [rdi + MB_CURVE + rax * 8]
    vpmovq2m k3, zmm4
    vmovdqu64 zmm4, [rdi + MB_S + rax * 8]
    vpmovqd ymm5, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm6, zmm4
    vcvtdq2pd zmm5, ymm5                ; start column
    vcvtdq2pd zmm6, ymm6                ; start row
    vmovdqu64 zmm4, [rdi + MB_C + rax * 8]
    vpmovqd ymm7, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm8, zmm4
    vcvtdq2pd zmm7, ymm7                ; control column
    vcvtdq2pd zmm8, ymm8                ; control row
    vmovdqu64 zmm4, [rdi + MB_E + rax * 8]
    vpmovqd ymm9, zmm4
    vpsrlq  zmm4, zmm4, 32
    vpmovqd ymm10, zmm4
    vcvtdq2pd zmm9, ymm9                ; end column
    vcvtdq2pd zmm10, ymm10              ; end row
    vmulpd  zmm11, zmm5, zmm3
    vmulpd  zmm12, zmm7, zmm2
    vaddpd  zmm11, zmm11, zmm12
    vmulpd  zmm13, zmm6, zmm3
    vmulpd  zmm12, zmm8, zmm2
    vaddpd  zmm13, zmm13, zmm12
    vmulpd  zmm14, zmm7, zmm3
    vmulpd  zmm12, zmm9, zmm2
    vaddpd  zmm14, zmm14, zmm12
    vmulpd  zmm15, zmm8, zmm3
    vmulpd  zmm12, zmm10, zmm2
    vaddpd  zmm15, zmm15, zmm12
    vmulpd  zmm16, zmm11, zmm3
    vmulpd  zmm12, zmm14, zmm2
    vaddpd  zmm11{k3}, zmm16, zmm12
    vmulpd  zmm17, zmm13, zmm3
    vmulpd  zmm12, zmm15, zmm2
    vaddpd  zmm13{k3}, zmm17, zmm12
    vcvtpd2dq ymm11, zmm11
    vcvtpd2dq ymm13, zmm13
    vmovdqu32 [rdi + MB_COL + rax * 4], ymm11
    vmovdqu32 [rdi + MB_ROW + rax * 4], ymm13
    add     eax, 8
    cmp     eax, r15d
    jb      .lanes8
    vzeroupper
%else
    ; 4 lanes at a time (the lanes past r15 are stale and ignored)
    xor     eax, eax
    vbroadcastsd ymm15, [path_one]
    vmovdqu ymm14, [mb_split]
.lanes4:
    vmovupd ymm0, [rdi + MB_DL + rax * 8]
    vmovupd ymm1, [rdi + MB_SD + rax * 8]
    vdivpd  ymm2, ymm0, ymm1
    vminpd  ymm3, ymm2, ymm15           ; f64::min(t, 1.0)
    vmovupd ymm4, [rdi + MB_CLAMP + rax * 8]
    vblendvpd ymm2, ymm2, ymm3, ymm4
    vxorpd  ymm4, ymm4, ymm4
    vcmppd  ymm4, ymm1, ymm4, 0         ; zero-length segment: t = 0
    vandnpd ymm2, ymm4, ymm2
    vsubpd  ymm3, ymm15, ymm2           ; 1 - t
    vpermd  ymm4, ymm14, [rdi + MB_S + rax * 8]
    vpermd  ymm5, ymm14, [rdi + MB_C + rax * 8]
    vpermd  ymm6, ymm14, [rdi + MB_E + rax * 8]
    vmovupd ymm13, [rdi + MB_CURVE + rax * 8]
    vcvtdq2pd ymm7, xmm4
    vcvtdq2pd ymm8, xmm5
    vcvtdq2pd ymm9, xmm6
    MV_AXIS4
    vcvtpd2dq xmm7, ymm7
    vmovdqu [rdi + MB_COL + rax * 4], xmm7
    vextracti128 xmm4, ymm4, 1
    vextracti128 xmm5, ymm5, 1
    vextracti128 xmm6, ymm6, 1
    vcvtdq2pd ymm7, xmm4
    vcvtdq2pd ymm8, xmm5
    vcvtdq2pd ymm9, xmm6
    MV_AXIS4
    vcvtpd2dq xmm7, ymm7
    vmovdqu [rdi + MB_ROW + rax * 4], xmm7
    add     eax, 4
    cmp     eax, r15d
    jb      .lanes4
    vzeroupper
%endif
    ; each lane's coordinate into its bit, and whether it moved; a lane
    ; outside i32 (cvtpd2dq's 0x80000000) through the scalar functions
    mov     [rsp + 40], r14
    xor     r14d, r14d
    lea     rbp, [mb]
.assemble_lane:
    mov     eax, [rbp + MB_COL + r14 * 4]
    mov     edx, [rbp + MB_ROW + r14 * 4]
    cmp     eax, 0x80000000
    je      .scalar_lane
    cmp     edx, 0x80000000
    je      .scalar_lane
    shl     rdx, 32
    or      rax, rdx
.assembled:
    movzx   ecx, byte [rbp + MB_BIT + r14]
    mov     [rbp + MB_COORD + rcx * 8], rax
    lea     edx, [r13 + rcx]
    mov     rsi, [ch_col]
    cmp     [rsi + rdx * 4], eax
    jne     .lane_moved
    shr     rax, 32
    mov     rsi, [ch_row]
    cmp     [rsi + rdx * 4], eax
    je      .lane_next
.lane_moved:
    bts     qword [rsp + 24], rcx
.lane_next:
    inc     r14d
    cmp     r14d, r15d
    jb      .assemble_lane
    mov     r14, [rsp + 40]
.done:
    mov     rax, [rsp]
    mov     [mb_write_bits], rax
    mov     rcx, [rsp + 8]
    mov     [mb_tail_bits], rcx
    or      rax, rcx
    mov     rcx, [rsp + 24]
    mov     [mb_moved_bits], rcx
    or      rax, rcx
    mov     [mb_act_bits], rax
    mov     rax, [rsp + 32]
    mov     [mb_mirror_bits], rax
    mov     rax, r14
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.scalar_lane:
    ; path_step's .finish
    movsd   xmm1, [rbp + MB_SD + r14 * 8]
    xorpd   xmm0, xmm0
    ucomisd xmm1, xmm0
    jne     .scalar_ratio
    jnp     .scalar_position
.scalar_ratio:
    movsd   xmm0, [rbp + MB_DL + r14 * 8]
    divsd   xmm0, xmm1
    cmp     qword [rbp + MB_CLAMP + r14 * 8], 0
    je      .scalar_position
    minsd   xmm0, [path_one]
.scalar_position:
    mov     rdi, [rbp + MB_S + r14 * 8]
    cmp     qword [rbp + MB_CURVE + r14 * 8], 0
    jne     .scalar_curve
    mov     rsi, [rbp + MB_E + r14 * 8]
    call    find_coord_on_line
    jmp     .assembled
.scalar_curve:
    lea     rsi, [rbp + MB_C + r14 * 8]
    mov     edx, 1
    mov     rcx, [rbp + MB_E + r14 * 8]
    call    find_coord_on_bezier_curve
    jmp     .assembled

; motion_apply(edi=slot): motion_move for a character motion_batch worked
; out and whose bit is in mb_act_bits: a resolved step's writes, then
; set_coordinate when it moved, and the rest of motion_move when the step
; reached max_steps (or was at the end).
motion_apply:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, edi
    and     r12d, 63
    mov     rax, [mb_write_bits]
    bt      rax, r12
    jnc     .coord
    lea     rdx, [mb]
    mov     rax, [ch_path]
    mov     eax, [rax + rbx * 4]
    PATH_PTR r8, rax
    movsd   xmm0, [rdx + MB_STEPF + r12 * 8]
    cvttsd2si rax, xmm0
    mov     [r8 + PA_STEP], rax
    mov     rcx, [rdx + MB_LAST + r12 * 8]
    mov     [r8 + PA_LAST], rcx
    movzx   eax, word [rdx + MB_CURSOR + r12 * 2]
    mov     [r8 + PA_CURSOR], ax
    cmp     ebx, MV_LIMIT
    jae     .coord
    MV_P8   rax, rbx
    movsd   [rax + rbx * 8 + MVO_STEP], xmm0
    mov     [rax + rbx * 8 + MVO_LAST], rcx
.coord:
    mov     rax, [mb_moved_bits]
    bt      rax, r12
    jnc     .placed
    lea     rdx, [mb]
    mov     rsi, [rdx + MB_COORD + r12 * 8]
    mov     edi, ebx
    call    set_coordinate
.placed:
    mov     rax, [mb_tail_bits]
    bt      rax, r12
    jnc     .done
    mov     eax, ebx
    call    mv_sync                     ; the tail reads current_step
    jmp     motion_move.placed
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

%endif

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
    MV_RETIRE_PATH rdi
    PATH_PTR rax, rdi
    test    dword [rax + PA_FLAGS], PAF_SHARED
    jz      .own
    mov     qword [rax + PA_SEGS], 0    ; the next segment starts a list
    mov     dword [rax + PA_SEG_CAP], 0
.own:
    and     dword [rax + PA_FLAGS], ~(PAF_ORIGIN | PAF_SHARED)
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
align 32
mb_split:   dd 0, 2, 4, 6, 1, 3, 5, 7   ; columns low, rows high (vpermd)
mv_lane_masks:                          ; 4 bits -> 4 qword lane masks
%assign mv_i 0
%rep 16
    dq -(mv_i & 1), -((mv_i >> 1) & 1), -((mv_i >> 2) & 1), -((mv_i >> 3) & 1)
%assign mv_i mv_i + 1
%endrep
mv_flag_curve:  dq MVF_CURVE
mv_flag_over:   dq MVF_OVER
mv_nan:         dq 0x7ff8000000000000
mv_two_p51:     dq 0x4320000000000000   ; 2^51
mv_flag_first:  dq MVF_FIRST
mv_tag_bit:     dd MV_TAG_BIT           ; also cvtpd2dq's out-of-range value
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
segshare_count: resd 1              ; lists in segshare_table
segshare_hits:  resd 1              ; lookups that found one
alignb 8
segshare_table: resq 1
segshare_off:   resb 1              ; lookups stopped
alignb 4
motion_epoch:   resd 1              ; bumped by actions that may touch any path
alignb 8
mv_base:        resq 1              ; the mirrors (MVO_*)
path_owners:    resq 1              ; u32 per path: the slot it was made for or activated on
mb_write_bits:  resq 1              ; motion_batch's word: resolved steps to write
mb_tail_bits:   resq 1              ; steps that run motion_move's tail
mb_moved_bits:  resq 1              ; steps that move the character
mb_act_bits:    resq 1              ; any of those
mb_mirror_bits: resq 1              ; mirrored steps (motion_void)
mb_first:       resd 1              ; the word's first slot
alignb 8
mv_view:        resb PATH_SIZE      ; path_view's copy of a mirrored path's fields
alignb 64
mb:             resb MB_SIZE        ; motion_batch scratch
