; engine/scene.asm - Scene, Frame and the scene half of Animation
; (src/engine/animation.rs; stepping from src/engine/ctx.rs).
;
; A scene's frame queue is its head index: frames before the head have
; played, frames from it on remain. That is exactly Rust's frames /
; played_frames pair, because frames retire in order, reset_scene restores the
; original order, and synced/eased stepping index the remaining queue or the
; whole frame list without reordering either. Only the head frame of a plain
; scene has nonzero ticks_elapsed, so one counter per scene suffices, and the
; record caches the head frame's handle and duration.
;
; Scenes belong to a character's scene map (ch_scenes, linked through
; SC_NEXT in insertion order) and are addressed by index into [scenes].

%define FRAME_REGION        (1 << 36)

section .text

scenes_init:
    mov     rdi, 2 * SCENE_LIMIT * SCENE_SIZE
    call    reserve
    mov     [scenes], rax
    mov     rdi, SCENE_LIMIT * 16
    call    reserve
    mov     [scene_pre], rax
    mov     rdi, FRAME_REGION
    call    reserve
    mov     [frame_region], rax
    mov     [frame_region_end], rax
    ret

; scene_ptr(esi=scene) -> r8 = record. Clobbers nothing else.
%macro SCENE_PTR 2                      ; dest, index register (32-bit)
    mov     %1, %2
    shl     %1, SCENE_SHIFT
    add     %1, [scenes]
%endmacro

; scene_find(edi=slot, esi=name) -> eax = scene index or NONE.
scene_find:
    mov     rax, [ch_scenes]
    mov     eax, [rax + rdi * 4]
.next:
    cmp     eax, NONE
    je      .done
    mov     rcx, rax
    shl     rcx, SCENE_SHIFT
    add     rcx, [scenes]
    cmp     [rcx + SC_NAME], esi
    je      .done
    mov     eax, [rcx + SC_NEXT]
    jmp     .next
.done:
    ret

; scene_new(edi=slot, esi=name or AUTO, edx=SCF_LOOPING/SCF_SYNC_* flags,
;           ecx=easing id or NONE) -> eax = scene index.
; Animation.new_scene: an auto id is the scene count, probing upward past
; taken ids; an existing name is overwritten in place (it keeps its position
; in the map), faithfully. Preexisting input colors apply under
; --existing-color-handling always for characters that use them.
scene_new:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi                    ; slot
    mov     r12d, esi                   ; name
    mov     r13d, edx                   ; flags
    mov     r14d, ecx                   ; easing
    cmp     r12d, AUTO
    jne     .named
    ; auto id: len(scenes), then upward while taken
    mov     rax, [ch_scenes]
    mov     eax, [rax + rbx * 4]
    xor     r12d, r12d
.count:
    cmp     eax, NONE
    je      .probe
    inc     r12d
    SCENE_PTR rcx, rax
    mov     eax, [rcx + SC_NEXT]
    jmp     .count
.probe:
    mov     edi, ebx
    mov     esi, r12d
    call    scene_find
    cmp     eax, NONE
    je      .fresh
    inc     r12d
    jmp     .probe
.named:
    mov     edi, ebx
    mov     esi, r12d
    call    scene_find
    cmp     eax, NONE
    jne     .reuse
.fresh:
    ; a new record, appended to the character's map
    mov     r15d, [scene_count]
    cmp     r15d, SCENE_LIMIT
    jae     .full
    inc     dword [scene_count]
    SCENE_PTR r8, r15
    mov     dword [r8 + SC_NEXT], NONE
    mov     rax, [ch_scenes]
    lea     rax, [rax + rbx * 4]
.tail:
    cmp     dword [rax], NONE
    je      .link
    mov     ecx, [rax]
    SCENE_PTR rax, rcx
    add     rax, SC_NEXT
    jmp     .tail
.link:
    mov     [rax], r15d
    jmp     .init
.reuse:
    mov     r15d, eax
    SCENE_PTR r8, r15
.init:
    ; everything but the map link starts over
    mov     ecx, [r8 + SC_NEXT]
    vpxor   xmm0, xmm0, xmm0
    vmovdqu [r8], ymm0
    vmovdqu [r8 + SCENE_COLD], ymm0
    vzeroupper
    mov     [r8 + SC_NEXT], ecx
    mov     [r8 + SC_NAME], r12d
    mov     [r8 + SC_OWNER], ebx
    mov     eax, r13d
    and     eax, SCF_LOOPING | SCF_SYNC
    cmp     r14d, NONE
    je      .flags
    or      eax, SCF_EASED
    mov     [r8 + SC_EASE], r14d
.flags:
    ; existing_color_handling == always and the character uses its colors
    cmp     qword [cfg_existing_colors], 0
    jne     .store_flags
    mov     rcx, [ch_flags]
    movzx   ecx, word [rcx + rbx * 2]
    test    ecx, CF_PREEXISTING
    jz      .store_flags
    or      eax, SCF_PREEXISTING
    test    ecx, CF_BOLD
    jz      .colors
    or      eax, SCF_PRE_BOLD
.colors:
    mov     rdx, r15
    shl     rdx, 4
    add     rdx, [scene_pre]
    mov     rcx, [ch_fg]
    mov     rcx, [rcx + rbx * 8]
    mov     [rdx], rcx
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rbx * 8]
    mov     [rdx + 8], rcx
.store_flags:
    mov     [r8 + SC_FLAGS], eax
    mov     eax, r15d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.full:
    lea     rdi, [msg_scenes_full]
    mov     esi, msg_scenes_full_len
    jmp     fatal

; scene_add_frame(edi=scene, rsi=packed symbol, edx=duration, rcx=fg or
;                 NONE, r8=bg or NONE, r9d=ATTR_* bits).
; Scene.add_frame: preexisting colors replace the given ones and preexisting
; bold forces bold; a duration below 1 is an error.
scene_add_frame:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, edx
    cmp     edx, 1
    jl      .bad_duration
    SCENE_PTR r13, rbx
    mov     eax, [r13 + SC_FLAGS]
    test    eax, SCF_PREEXISTING
    jz      .bold
    mov     rcx, rbx
    shl     rcx, 4
    add     rcx, [scene_pre]
    mov     r8, [rcx + 8]
    mov     rcx, [rcx]
.bold:
    test    eax, SCF_PRE_BOLD
    jz      .visual
    or      r9d, ATTR_BOLD
.visual:
    mov     rdx, rsi
    mov     rdi, rcx
    mov     rsi, r8
    mov     ecx, r9d
    call    visual_make
    mov     edx, r12d
    mov     r8, r13
    call    scene_append_frame
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad_duration:
    movsxd  rsi, edx
    lea     rdi, [msg_frame_duration]
    mov     edx, msg_frame_duration_len
    jmp     fail_with_number

; scene_add_frame_visual(edi=scene, esi=handle, edx=duration): add_frame
; for an effect that built (and cached) the visual itself. Under a scene's
; preexisting colors the visual is rebuilt from its header with them, so the
; result is exactly scene_add_frame's.
scene_add_frame_visual:
    cmp     edx, 1
    jl      .bad_duration
    SCENE_PTR r8, rdi
    test    dword [r8 + SC_FLAGS], SCF_PREEXISTING | SCF_PRE_BOLD
    jnz     .rebuild
    mov     eax, esi
    jmp     scene_append_frame
.rebuild:
    mov     eax, esi
    call    visual_meta
    mov     rsi, [rax + VH_SYMBOL]
    mov     rcx, [rax + VH_FG]
    mov     r8, [rax + VH_BG]
    mov     r9d, [rax + VH_ATTRS]
    jmp     scene_add_frame
.bad_duration:
    movsxd  rsi, edx
    lea     rdi, [msg_frame_duration]
    mov     edx, msg_frame_duration_len
    jmp     fail_with_number

; scene_append_frame(r8=scene record, eax=handle, edx=duration): push a frame
; and keep the head cache current. Frames live in one region: a scene appends
; in place while its frames end the region - the usual case, since effects
; build one scene at a time - and otherwise first moves them to the end. So a
; character's scenes lie in creation order, which is roughly tick order.
scene_append_frame:
    push    rbx
    mov     ebx, eax
    mov     ecx, [r8 + SC_COUNT]
    mov     rdi, rcx
    shl     rdi, FRAME_SHIFT
    add     rdi, [r8 + SC_FRAMES]       ; where the next frame goes
    cmp     rdi, [frame_region_end]
    je      .append
    ; relocate this scene's frames to the end of the region
    mov     rsi, [r8 + SC_FRAMES]
    mov     rdi, [frame_region_end]
    mov     [r8 + SC_FRAMES], rdi
    push    rcx
    shl     ecx, FRAME_SHIFT
    rep     movsb
    pop     rcx
.append:
    mov     rax, [r8 + SC_FRAMES]
    mov     rdi, rcx
    shl     rdi, FRAME_SHIFT
    add     rdi, rax
    lea     rax, [rdi + FRAME_SIZE]
    mov     [frame_region_end], rax
    mov     [rdi + FR_HANDLE], ebx
    mov     [rdi + FR_DURATION], edx
    mov     esi, [r8 + SC_EASE_TOTAL]
    add     esi, edx
    mov     [r8 + SC_EASE_TOTAL], esi
    inc     dword [r8 + SC_COUNT]
    cmp     ecx, [r8 + SC_HEAD]
    jne     .done
    mov     [r8 + SC_HEAD_HANDLE], ebx
    mov     [r8 + SC_HEAD_DURATION], edx
.done:
    pop     rbx
    ret

; scene_load_head(r8=scene record): refresh the head cache after the head
; moved. Clobbers rax, rcx.
scene_load_head:
    mov     ecx, [r8 + SC_HEAD]
    cmp     ecx, [r8 + SC_COUNT]
    jae     .done
    shl     rcx, FRAME_SHIFT
    add     rcx, [r8 + SC_FRAMES]
    mov     eax, [rcx + FR_HANDLE]
    mov     [r8 + SC_HEAD_HANDLE], eax
    mov     eax, [rcx + FR_DURATION]
    mov     [r8 + SC_HEAD_DURATION], eax
.done:
    ret

; scene_reset(edi=scene): Scene.reset_scene - every frame back in the queue
; in original order, tick counters and the easing step zeroed.
scene_reset:
    SCENE_PTR r8, rdi
    mov     dword [r8 + SC_HEAD], 0
    mov     dword [r8 + SC_TICKS], 0
    mov     dword [r8 + SC_EASE_STEP], 0
    jmp     scene_load_head

; scene_apply_gradient(edi=scene, rsi=symbols (packed), rdx=symbol count,
;   ecx=duration, r8=fg spectrum or 0, r9=fg count, [rsp+8]=bg spectrum or 0,
;   [rsp+16]=bg count). Scene.apply_gradient_to_symbols with the exact
; cyclic_distribution semantics.
scene_apply_gradient:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    mov     [rsp], rdi                  ; scene
    mov     [rsp + 8], rsi              ; symbols
    mov     [rsp + 16], rdx             ; symbol count
    mov     [rsp + 24], rcx             ; duration
    mov     [rsp + 32], r8              ; fg
    mov     [rsp + 40], r9              ; fg count
    mov     rax, [rsp + 72 + 48 + 8]
    mov     [rsp + 48], rax             ; bg
    mov     rax, [rsp + 72 + 48 + 16]
    mov     [rsp + 56], rax             ; bg count
    ; errors, in Rust's order
    test    r8, r8
    jnz     .some
    test    rax, rax
    jz      .none_error
.some:
    xor     ebx, ebx                    ; bit 0: fg has colors, bit 1: bg
    test    r8, r8
    jz      .bg_has
    cmp     qword [rsp + 40], 0
    je      .bg_has
    or      ebx, 1
.bg_has:
    cmp     qword [rsp + 48], 0
    je      .check
    cmp     qword [rsp + 56], 0
    je      .check
    or      ebx, 2
.check:
    test    ebx, ebx
    jz      .empty_error
    ; color pairs: (fg, bg) per element of the longer spectrum
    cmp     ebx, 3
    jne     .single
    mov     rax, [rsp + 40]
    cmp     rax, [rsp + 56]
    jb      .bg_longer
    ; fg longer or equal: cyclic_distribution(fg, bg) -> (f, b)
    mov     rdi, [rsp + 40]
    mov     rsi, [rsp + 56]
    call    cyclic_distribution         ; rax = smaller-index array
    mov     r12, [rsp + 40]             ; pair count
    call    .pairs_alloc
    xor     ecx, ecx
.fg_pairs:
    cmp     rcx, r12
    jae     .symbols
    mov     rdx, [rsp + 32]
    mov     rdx, [rdx + rcx * 8]
    mov     [r13 + rcx * 8], rdx
    mov     edx, [rbp + rcx * 4]
    mov     rsi, [rsp + 48]
    mov     rdx, [rsi + rdx * 8]
    mov     [r14 + rcx * 8], rdx
    inc     rcx
    jmp     .fg_pairs
.bg_longer:
    ; cyclic_distribution(bg, fg) -> (f, b)
    mov     rdi, [rsp + 56]
    mov     rsi, [rsp + 40]
    call    cyclic_distribution
    mov     r12, [rsp + 56]
    call    .pairs_alloc
    xor     ecx, ecx
.bg_pairs:
    cmp     rcx, r12
    jae     .symbols
    mov     rdx, [rsp + 48]
    mov     rdx, [rdx + rcx * 8]
    mov     [r14 + rcx * 8], rdx
    mov     edx, [rbp + rcx * 4]
    mov     rsi, [rsp + 32]
    mov     rdx, [rsi + rdx * 8]
    mov     [r13 + rcx * 8], rdx
    inc     rcx
    jmp     .bg_pairs
.single:
    ; only one side has colors
    xor     eax, eax
    mov     r12, [rsp + 40]
    mov     r15, [rsp + 32]             ; source
    cmp     ebx, 1
    je      .single_alloc
    mov     r12, [rsp + 56]
    mov     r15, [rsp + 48]
.single_alloc:
    call    .pairs_alloc
    xor     ecx, ecx
.single_pairs:
    cmp     rcx, r12
    jae     .symbols
    mov     rdx, [r15 + rcx * 8]
    mov     rsi, NONE
    cmp     ebx, 1
    jne     .as_bg
    mov     [r13 + rcx * 8], rdx
    mov     [r14 + rcx * 8], rsi
    jmp     .single_next
.as_bg:
    mov     [r13 + rcx * 8], rsi
    mov     [r14 + rcx * 8], rdx
.single_next:
    inc     rcx
    jmp     .single_pairs
.symbols:
    ; r13/r14 = fg/bg per pair, r12 = pair count
    mov     rax, [rsp + 16]
    cmp     rax, r12
    jb      .pairs_major
    ; symbols major: for (symbol, colors) in cyclic(symbols, pairs)
    mov     rdi, rax
    mov     rsi, r12
    call    cyclic_distribution
    mov     rbp, rax
    xor     r15d, r15d
.sym_frames:
    cmp     r15, [rsp + 16]
    jae     .done
    mov     eax, [rbp + r15 * 4]        ; pair index
    mov     rsi, [rsp + 8]
    mov     rsi, [rsi + r15 * 8]
    call    .add
    inc     r15
    jmp     .sym_frames
.pairs_major:
    ; for (colors, symbol) in cyclic(pairs, symbols)
    mov     rdi, r12
    mov     rsi, rax
    call    cyclic_distribution
    mov     rbp, rax
    xor     r15d, r15d
.pair_frames:
    cmp     r15, r12
    jae     .done
    mov     ecx, [rbp + r15 * 4]        ; symbol index
    mov     rsi, [rsp + 8]
    mov     rsi, [rsi + rcx * 8]
    mov     eax, r15d
    call    .add
    inc     r15
    jmp     .pair_frames
.done:
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.add:
    ; add_frame(symbol rsi, duration, colors of pair eax) - note the extra
    ; return address on the stack
    mov     rcx, [r13 + rax * 8]
    mov     r8, [r14 + rax * 8]
    mov     rdi, [rsp + 8]
    mov     rdx, [rsp + 8 + 24]
    xor     r9d, r9d
    mov     rdi, [rsp + 8 + 0]
    jmp     scene_add_frame
.pairs_alloc:
    ; rbp = the distribution (if any), r13/r14 = fg/bg arrays of r12 entries
    mov     rbp, rax
    lea     rdi, [r12 * 8 + 8]
    call    alloc
    mov     r13, rax
    lea     rdi, [r12 * 8 + 8]
    call    alloc
    mov     r14, rax
    ret
.none_error:
    FAIL    msg_gradient_none
.empty_error:
    FAIL    msg_gradient_empty

; cyclic_distribution(rdi=larger count, rsi=smaller count) -> rax = u32 array
; of `larger` indices into the smaller sequence, in iteration order.
cyclic_distribution:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    lea     rdi, [r12 * 4 + 8]
    call    alloc
    mov     rbx, rax
    mov     rax, r12
    xor     edx, edx
    div     r13                         ; rax = repeat factor, rdx = overflow
    mov     r8, rax
    mov     r9, rdx
    xor     r10d, r10d                  ; overflow used
    xor     r11d, r11d                  ; smaller index
    xor     esi, esi                    ; current repeat factor
    xor     ecx, ecx
.next:
    cmp     rcx, r12
    jae     .done
    cmp     rsi, r8
    jb      .emit
    test    r9, r9
    jz      .advance
    test    r10d, r10d
    jz      .use_overflow
    inc     r11
    xor     esi, esi
    xor     r10d, r10d
    jmp     .emit
.use_overflow:
    mov     r10d, 1
    dec     r9
    jmp     .emit
.advance:
    inc     r11
    xor     esi, esi
.emit:
    inc     rsi
    mov     [rbx + rcx * 4], r11d
    inc     rcx
    jmp     .next
.done:
    mov     rax, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

; scene_copy(edi=slot, esi=source scene, edx=name) -> eax = new scene
; index: a clone of the source (frames, flags, playback state) inserted
; into the character's scene map under `name`, overwriting like new_scene.
scene_copy:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     edi, ebx
    mov     esi, r13d
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    push    rax
    SCENE_PTR r8, rax
    SCENE_PTR rsi, r12
    ; copy everything but the name, the map link and the owner
    mov     r9d, [r8 + SC_NEXT]
    vmovdqu ymm0, [rsi]
    vmovdqu [r8], ymm0
    vmovdqu ymm0, [rsi + SCENE_COLD]
    vmovdqu [r8 + SCENE_COLD], ymm0
    vzeroupper
    ; and its preexisting colors
    mov     rdx, [scene_pre]
    mov     rcx, r12
    shl     rcx, 4
    vmovdqu xmm0, [rdx + rcx]
    mov     ecx, [rsp]
    shl     rcx, 4
    vmovdqu [rdx + rcx], xmm0
    mov     [r8 + SC_NEXT], r9d
    mov     [r8 + SC_NAME], r13d
    mov     [r8 + SC_OWNER], ebx
    ; the frames are the clone's own, at the end of the frame region
    mov     rsi, [r8 + SC_FRAMES]
    mov     rdi, [frame_region_end]
    mov     [r8 + SC_FRAMES], rdi
    mov     ecx, [r8 + SC_COUNT]
    shl     ecx, FRAME_SHIFT
    rep     movsb
    mov     [frame_region_end], rdi
    pop     rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------ activation

; scene_activate(edi=slot, esi=scene): Animation.activate_scene - resume
; semantics: the visual is the head of the remaining queue and playback is
; not reset. Fires SCENE_ACTIVATED.
scene_activate:
    SCENE_PTR r8, rsi
    mov     ecx, [r8 + SC_HEAD]
    cmp     ecx, [r8 + SC_COUNT]
    jae     .empty
    mov     rdx, [ch_scene]
    mov     [rdx + rdi * 4], esi
    mov     eax, [r8 + SC_HEAD_HANDLE]
    SET_HANDLE
    mov     rax, [ch_subs]
    test    byte [rax + rdi], 1 << EV_SCENE_ACTIVATED
    jz      .done
    mov     ecx, [r8 + SC_NAME]
    mov     esi, EV_SCENE_ACTIVATED
    mov     edx, CALLER_SCENE
    jmp     handle_event
.done:
    ret
.empty:
    FAIL    msg_scene_empty

; scene_activate_name(edi=slot, esi=name)
scene_activate_name:
    push    rdi
    call    scene_find
    pop     rdi
    cmp     eax, NONE
    je      .missing
    mov     esi, eax
    jmp     scene_activate
.missing:
    FAIL    msg_scene_missing

; scene_deactivate(edi=slot, esi=name or NONE): Animation.deactivate_scene -
; any active scene, or only the named one.
scene_deactivate:
    mov     rax, [ch_scene]
    mov     ecx, [rax + rdi * 4]
    cmp     ecx, NONE
    je      .done
    cmp     esi, NONE
    je      .clear
    SCENE_PTR rdx, rcx
    cmp     [rdx + SC_NAME], esi
    jne     .done
.clear:
    mov     dword [rax + rdi * 4], NONE
    MARK_CANDIDATE
.done:
    ret

; scene_is_complete(edi=slot) -> eax = 1 when Animation.active_scene_is_complete
; (no scene, no remaining frames, or a looping scene).
scene_is_complete:
    mov     rax, [ch_scene]
    mov     eax, [rax + rdi * 4]
    cmp     eax, NONE
    je      .yes
    SCENE_PTR rcx, rax
    test    dword [rcx + SC_FLAGS], SCF_LOOPING
    jnz     .yes
    mov     eax, [rcx + SC_HEAD]
    cmp     eax, [rcx + SC_COUNT]
    je      .yes
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

; ------------------------------------------------------------ stepping

; step_animation(edi=slot): Animation.step_animation plus
; _complete_scene_if_finished, SCENE_COMPLETE dispatch included.
step_animation:
    mov     rax, [ch_scene]
    mov     esi, [rax + rdi * 4]
    cmp     esi, NONE
    je      .done
    SCENE_PTR r8, rsi
    mov     ecx, [r8 + SC_HEAD]
    cmp     ecx, [r8 + SC_COUNT]
    jae     .done                       ; no remaining frames: nothing to step
    mov     eax, [r8 + SC_FLAGS]
    test    eax, SCF_SYNC
    jnz     .synced
    test    eax, SCF_EASED
    jnz     .eased
    ; get_next_visual: the head frame's visual (usually shown already)
    mov     eax, [r8 + SC_HEAD_HANDLE]
    mov     rdx, [ch_handle]
    cmp     [rdx + rdi * 4], eax
    je      .shown
    SET_HANDLE
.shown:
    mov     eax, [r8 + SC_TICKS]
    inc     eax
    cmp     eax, [r8 + SC_HEAD_DURATION]
    jne     .ticked
    ; the head frame retires
    xor     eax, eax
    mov     ecx, [r8 + SC_HEAD]
    inc     ecx
    cmp     ecx, [r8 + SC_COUNT]
    jne     .advance
    test    dword [r8 + SC_FLAGS], SCF_LOOPING
    jz      .exhausted
    xor     ecx, ecx
.advance:
    mov     [r8 + SC_HEAD], ecx
    mov     [r8 + SC_TICKS], eax
    call    scene_load_head
    jmp     .check
.exhausted:
    mov     [r8 + SC_HEAD], ecx
.ticked:
    mov     [r8 + SC_TICKS], eax
    jmp     .check
.synced:
    call    step_synced_scene
    jmp     .check
.eased:
    call    step_eased_scene
.check:
    ; _complete_scene_if_finished
    test    dword [r8 + SC_FLAGS], SCF_LOOPING
    jnz     .complete
    mov     ecx, [r8 + SC_HEAD]
    cmp     ecx, [r8 + SC_COUNT]
    jne     .done
    ; reset_scene, then no active scene
    mov     dword [r8 + SC_HEAD], 0
    mov     dword [r8 + SC_TICKS], 0
    mov     dword [r8 + SC_EASE_STEP], 0
    call    scene_load_head
    mov     rax, [ch_scene]
    mov     dword [rax + rdi * 4], NONE
.complete:
    ; SCENE_COMPLETE fires every tick for looping scenes, faithfully
    push    r8
    MARK_CANDIDATE
    pop     r8
    mov     rax, [ch_subs]
    test    byte [rax + rdi], 1 << EV_SCENE_COMPLETE
    jz      .done
    mov     ecx, [r8 + SC_NAME]
    mov     esi, EV_SCENE_COMPLETE
    mov     edx, CALLER_SCENE
    jmp     handle_event
.done:
    ret

; step_synced_scene(edi=slot, r8=scene record): Animation._step_synced_scene.
; Preserves rdi and r8.
step_synced_scene:
    mov     rax, [ch_path]
    mov     eax, [rax + rdi * 4]
    cmp     eax, NONE
    jne     .path
    ; no active path: jump to the final frame and force completion
    mov     ecx, [r8 + SC_COUNT]
    dec     ecx
    shl     rcx, FRAME_SHIFT
    add     rcx, [r8 + SC_FRAMES]
    mov     eax, [rcx + FR_HANDLE]
    SET_HANDLE
    mov     ecx, [r8 + SC_COUNT]
    mov     [r8 + SC_HEAD], ecx
    ret
.path:
    mov     rdx, rax
    shl     rdx, 7                      ; PATH_SIZE
    add     rdx, [paths]
    mov     ecx, [r8 + SC_COUNT]
    sub     ecx, [r8 + SC_HEAD]
    dec     ecx
    movsxd  r9, ecx                     ; final_frame_index
    test    dword [r8 + SC_FLAGS], SCF_SYNC_STEP
    jz      .distance
    ; max(current_step, 1) / max(max_steps, 1)
    mov     rax, [rdx + PA_STEP]
    mov     ecx, 1
    cmp     rax, rcx
    cmovl   rax, rcx
    cvtsi2sd xmm0, rax
    mov     rax, [rdx + PA_MAX]
    cmp     rax, rcx
    cmovl   rax, rcx
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1
    jmp     .index
.distance:
    ; total = max(total_distance, 1); remaining = max(total_distance - last, 1)
    ; reached = max(total - remaining, 1); ratio = reached / total
    movsd   xmm3, [scene_one]
    movsd   xmm0, [rdx + PA_TOTAL]
    maxsd   xmm0, xmm3                  ; f64::max: a NaN yields the 1.0
    movsd   xmm1, [rdx + PA_TOTAL]
    subsd   xmm1, [rdx + PA_LAST]
    maxsd   xmm1, xmm3
    movapd  xmm2, xmm0
    subsd   xmm2, xmm1
    maxsd   xmm2, xmm3
    divsd   xmm2, xmm0
    movapd  xmm0, xmm2
.index:
    ; round(final * ratio).min(final).max(0)
    cvtsi2sd xmm1, r9
    mulsd   xmm1, xmm0
    movapd  xmm0, xmm1
    call    round_half_even_i64
    cmp     rax, r9
    cmovg   rax, r9
    xor     ecx, ecx
    test    rax, rax
    cmovs   rax, rcx
    add     eax, [r8 + SC_HEAD]
    shl     rax, FRAME_SHIFT
    add     rax, [r8 + SC_FRAMES]
    mov     eax, [rax + FR_HANDLE]
    SET_HANDLE
    ret

; step_eased_scene(edi=slot, r8=scene record): Animation._step_eased_scene.
; Preserves rdi and r8 (the easing call clobbers everything else).
step_eased_scene:
    push    rdi
    push    r8
    sub     rsp, 8
    mov     eax, [r8 + SC_EASE_STEP]
    cvtsi2sd xmm0, rax
    mov     eax, [r8 + SC_EASE_TOTAL]
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1
    mov     edi, [r8 + SC_EASE]
    call    ease
    mov     r8, [rsp + 8]
    mov     rdi, [rsp + 16]
    ; final = max(total - 1, 0); index = round(factor * final).min(final).max(0)
    mov     eax, [r8 + SC_EASE_TOTAL]
    dec     rax
    xor     ecx, ecx
    test    rax, rax
    cmovs   rax, rcx
    mov     r9, rax
    cvtsi2sd xmm1, rax
    mulsd   xmm0, xmm1
    call    round_half_even_i64
    cmp     rax, r9
    cmovg   rax, r9
    xor     ecx, ecx
    test    rax, rax
    cmovs   rax, rcx
    ; frame_index_map[index]: the frame whose tick range holds index. A
    ; cursor (frame, its first tick) walks from the previous lookup, so the
    ; usual small moves cost a step or two.
    mov     rsi, [r8 + SC_FRAMES]
    mov     ecx, [r8 + SC_CURSOR]
    mov     edx, [r8 + SC_CURSOR_START]
.back:
    cmp     eax, edx
    jae     .forward
    dec     ecx
    sub     edx, [rsi + rcx * 8 + FR_DURATION]
    jmp     .back
.forward:
    mov     r9d, edx
    add     r9d, [rsi + rcx * 8 + FR_DURATION]
    cmp     eax, r9d
    jb      .found
    mov     edx, r9d
    inc     ecx
    jmp     .forward
.found:
    mov     [r8 + SC_CURSOR], ecx
    mov     [r8 + SC_CURSOR_START], edx
    mov     eax, [rsi + rcx * 8 + FR_HANDLE]
    SET_HANDLE
    ; advance; the end either loops or empties the queue
    mov     eax, [r8 + SC_EASE_STEP]
    inc     eax
    mov     [r8 + SC_EASE_STEP], eax
    cmp     eax, [r8 + SC_EASE_TOTAL]
    jne     .done
    test    dword [r8 + SC_FLAGS], SCF_LOOPING
    jz      .played
    mov     dword [r8 + SC_EASE_STEP], 0
    jmp     .done
.played:
    mov     eax, [r8 + SC_COUNT]
    mov     [r8 + SC_HEAD], eax
.done:
    add     rsp, 8
    pop     r8
    pop     rdi
    ret

; ------------------------------------------------------------ appearance

; set_appearance(edi=slot, rsi=packed symbol or 0 for the input symbol,
;                rdx=fg or NONE, rcx=bg or NONE): Animation.set_appearance.
; Under --existing-color-handling always, a character that uses its input
; colors shows those (and its bold) instead.
set_appearance:
    push    rbx
    mov     ebx, edi
    test    rsi, rsi
    jnz     .symbol
    mov     rax, [ch_sym]
    mov     rsi, [rax + rbx * 8]
.symbol:
    xor     r9d, r9d                    ; attributes
    cmp     qword [cfg_existing_colors], 0
    jne     .make
    mov     rax, [ch_flags]
    movzx   eax, word [rax + rbx * 2]
    test    eax, CF_PREEXISTING
    jz      .make
    mov     rdx, [ch_fg]
    mov     rdx, [rdx + rbx * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rbx * 8]
    test    eax, CF_BOLD
    jz      .make
    mov     r9d, ATTR_BOLD
.make:
    mov     rdi, rdx
    mov     rdx, rsi
    mov     rsi, rcx
    mov     ecx, r9d
    call    visual_make
    mov     edi, ebx
    SET_HANDLE
    pop     rbx
    ret

; reset_appearance(edi=slot): the RESET_APPEARANCE action - the input symbol
; with no colors (subject to set_appearance's existing-color rule).
reset_appearance:
    xor     esi, esi
    mov     rdx, NONE
    mov     rcx, NONE
    jmp     set_appearance

section .rodata
align 8
scene_one:  dq 1.0
STR msg_scenes_full, "ttfx: asm engine: scene limit reached", 10
STR msg_scene_empty, "activate_scene: empty scene"
STR msg_scene_missing, "activate_scene: scene not found"
STR msg_frame_duration, "Frame duration must be at least 1. Received: "
STR msg_gradient_none, "Foreground and background gradient are None. At least one gradient must be provided."
STR msg_gradient_empty, "Foreground and background gradient are empty. At least one gradient must have at least one color."

section .tstate
alignb 8
scenes:         resq 1
scene_pre:      resq 1
frame_region:   resq 1
frame_region_end: resq 1
scene_count:    resd 1
