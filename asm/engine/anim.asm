; engine/anim.asm - scenes, frames, SCENE_COMPLETE actions, the active set
; and the update pass (animation.rs + ctx.rs step_animation/update).
;
; A scene's frame queue is represented by its head index: frames before the
; head have played, frames from it on remain. That is exactly Rust's
; frames/played_frames pair for plain scenes, because frames retire in order
; and reset_scene restores the original order. Only the head frame ever has
; nonzero ticks_elapsed, so one counter per scene suffices. The record caches
; the head frame's handle and duration, so a tick touches only the record.

%define SCENES_RESERVE      (1 << 36)
%define FRAMES_RESERVE      (1 << 37)
%define ACTIONS_RESERVE     (1 << 34)

section .text

; anim_init: reserve the scene/frame/action stores and the active bitmaps.
anim_init:
    mov     rdi, SCENES_RESERVE
    call    reserve
    mov     [scenes], rax
    mov     rdi, FRAMES_RESERVE
    call    reserve
    mov     [frames], rax
    mov     rdi, ACTIONS_RESERVE
    call    reserve
    mov     [actions], rax
    mov     rax, [char_capacity]
    add     rax, 64 + 63
    shr     rax, 6
    mov     [active_words], rax
    lea     rdi, [rax * 8]
    call    alloc
    mov     [active_bits], rax
    mov     rax, [active_words]
    lea     rdi, [rax * 8]
    call    alloc
    mov     [snapshot_bits], rax
    mov     rax, [active_words]
    lea     rdi, [rax * 8]
    call    alloc
    mov     [candidate_bits], rax
    ret

; scene_new(edi=flags) -> eax = scene index. Frames added next belong to it.
scene_new:
    mov     eax, [scene_count]
    mov     rcx, rax
    shl     rcx, 5
    add     rcx, [scenes]
    mov     edx, [frame_count]
    mov     [rcx + SC_FRAMES], edx
    mov     dword [rcx + SC_COUNT], 0
    mov     dword [rcx + SC_HEAD], 0
    mov     dword [rcx + SC_TICKS], 0
    mov     dword [rcx + SC_ON_COMPLETE], NONE
    mov     [rcx + SC_FLAGS], edi
    inc     dword [scene_count]
    ret

; scene_add_frame(edi=scene, esi=handle, edx=duration). Scene.add_frame for
; the most recently created scene (frames of a scene are contiguous).
scene_add_frame:
    mov     rax, rdi
    shl     rax, 5
    add     rax, [scenes]
    mov     ecx, [rax + SC_FRAMES]
    add     ecx, [rax + SC_COUNT]
    cmp     ecx, [frame_count]
    jne     .broken
    inc     dword [rax + SC_COUNT]
    mov     r8, [frames]
    mov     [r8 + rcx * 8 + FR_HANDLE], esi
    mov     [r8 + rcx * 8 + FR_DURATION], edx
    inc     dword [frame_count]
    ; the new frame is the head when every earlier frame has played
    sub     ecx, [rax + SC_FRAMES]
    cmp     ecx, [rax + SC_HEAD]
    jne     .done
    mov     [rax + SC_HEAD_HANDLE], esi
    mov     [rax + SC_HEAD_DURATION], edx
.done:
    ret
.broken:
    lea     rdi, [msg_frames_broken]
    mov     esi, msg_frames_broken_len
    jmp     fatal

; on_scene_complete(edi=scene, esi=kind, edx=arg): register_event for
; (SCENE_COMPLETE, scene) -> action, appended in registration order.
on_scene_complete:
    mov     eax, [action_count]
    mov     rcx, [actions]
    mov     r8, rax
    shl     r8, 4
    add     r8, rcx
    mov     [r8 + AC_KIND], esi
    mov     [r8 + AC_ARG], edx
    mov     dword [r8 + AC_NEXT], NONE
    inc     dword [action_count]
    mov     r9, rdi
    shl     r9, 5
    add     r9, [scenes]
    mov     edx, [r9 + SC_ON_COMPLETE]
    cmp     edx, NONE
    je      .first
.walk:
    ; append after the last registered action (lists are short)
    mov     r8, rdx
    shl     r8, 4
    mov     edx, [rcx + r8 + AC_NEXT]
    cmp     edx, NONE
    jne     .walk
    mov     [rcx + r8 + AC_NEXT], eax
    ret
.first:
    mov     [r9 + SC_ON_COMPLETE], eax
    ret

; activate_scene(edi=slot, esi=scene): resume semantics - the visual is the
; head of the remaining queue; playback is not reset.
activate_scene:
    mov     rax, rsi
    shl     rax, 5
    add     rax, [scenes]
    mov     ecx, [rax + SC_HEAD]
    cmp     ecx, [rax + SC_COUNT]
    jae     .empty
    mov     rdx, [ch_scene]
    mov     [rdx + rdi * 4], esi
    mov     eax, [rax + SC_HEAD_HANDLE]
    SET_HANDLE
    ret
.empty:
    FAIL    msg_scene_empty

; step_animation(edi=slot): Animation.step_animation for plain scenes plus
; _complete_scene_if_finished, including SCENE_COMPLETE dispatch.
step_animation:
    mov     rax, [ch_scene]
    mov     esi, [rax + rdi * 4]
    cmp     esi, NONE
    je      .done
    mov     r8, rsi
    shl     r8, 5
    add     r8, [scenes]
    mov     ecx, [r8 + SC_HEAD]
    cmp     ecx, [r8 + SC_COUNT]
    jae     .done                       ; no remaining frames: nothing to step
    ; get_next_visual: the head frame's visual (usually what is shown already)
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
    test    byte [r8 + SC_FLAGS], SC_LOOPING
    jz      .exhausted
    xor     ecx, ecx
.advance:
    mov     [r8 + SC_HEAD], ecx
    add     ecx, [r8 + SC_FRAMES]
    mov     rdx, [frames]
    mov     r9d, [rdx + rcx * 8 + FR_HANDLE]
    mov     [r8 + SC_HEAD_HANDLE], r9d
    mov     r9d, [rdx + rcx * 8 + FR_DURATION]
    mov     [r8 + SC_HEAD_DURATION], r9d
.ticked:
    mov     [r8 + SC_TICKS], eax
    ; looping scenes report complete on every tick (faithfully)
    test    byte [r8 + SC_FLAGS], SC_LOOPING
    jnz     .complete
.done:
    ret
.exhausted:
    ; queue empty: reset_scene (back to the first frame) and deactivate
    mov     dword [r8 + SC_HEAD], 0
    mov     dword [r8 + SC_TICKS], 0
    mov     ecx, [r8 + SC_FRAMES]
    mov     rdx, [frames]
    mov     r9d, [rdx + rcx * 8 + FR_HANDLE]
    mov     [r8 + SC_HEAD_HANDLE], r9d
    mov     r9d, [rdx + rcx * 8 + FR_DURATION]
    mov     [r8 + SC_HEAD_DURATION], r9d
    mov     rax, [ch_scene]
    mov     dword [rax + rdi * 4], NONE
.complete:
    MARK_CANDIDATE
    jmp     scene_complete_actions

; scene_complete_actions(edi=slot, r8=scene record): run the scene's
; SCENE_COMPLETE actions inline, in registration order.
scene_complete_actions:
    mov     eax, [r8 + SC_ON_COMPLETE]
    cmp     eax, NONE
    je      .done
    push    rbx
    push    r12
    mov     ebx, eax
    mov     r12d, edi
.each:
    mov     rax, [actions]
    mov     rcx, rbx
    shl     rcx, 4
    add     rax, rcx
    mov     ecx, [rax + AC_KIND]
    cmp     ecx, ACT_ACTIVATE_SCENE
    jne     .next
    mov     edi, r12d
    mov     esi, [rax + AC_ARG]
    call    activate_scene
.next:
    mov     rax, [actions]
    mov     rcx, rbx
    shl     rcx, 4
    mov     ebx, [rax + rcx + AC_NEXT]
    cmp     ebx, NONE
    jne     .each
    pop     r12
    pop     rbx
.done:
    ret

; is_active(edi=slot) -> eax: an active scene that is not complete. (This
; slice has no motion, so movement is always complete.)
is_active:
    mov     rax, [ch_scene]
    mov     eax, [rax + rdi * 4]
    cmp     eax, NONE
    je      .no
    shl     rax, 5
    add     rax, [scenes]
    test    byte [rax + SC_FLAGS], SC_LOOPING
    jnz     .no
    mov     ecx, [rax + SC_HEAD]
    cmp     ecx, [rax + SC_COUNT]
    je      .no
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

; active_insert(edi=slot)
active_insert:
    mov     rax, [active_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     edx, edi
    and     edx, 63
    bts     qword [rax + rcx * 8], rdx
    mov     rax, [candidate_bits]
    bts     qword [rax + rcx * 8], rdx
    ret

; active_empty -> eax = 1 when no character is active.
active_empty:
    mov     rax, [active_bits]
    mov     rcx, [active_words]
    xor     edx, edx
.loop:
    cmp     rdx, rcx
    jae     .empty
    cmp     qword [rax + rdx * 8], 0
    jne     .not_empty
    inc     rdx
    jmp     .loop
.empty:
    mov     eax, 1
    ret
.not_empty:
    xor     eax, eax
    ret

; update: BaseEffectIterator.update - tick a snapshot of the active set in
; ascending slot order, then prune the characters that are no longer active.
update:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, [active_bits]
    mov     r13, [snapshot_bits]
    mov     r14, [active_words]
    ; snapshot (callbacks may change the live set while we tick)
    xor     ecx, ecx
.copy:
    cmp     rcx, r14
    jae     .tick
    mov     rax, [r12 + rcx * 8]
    mov     [r13 + rcx * 8], rax
    inc     rcx
    jmp     .copy
.tick:
    xor     ebx, ebx                    ; word index
.tick_word:
    cmp     rbx, r14
    jae     .prune
    mov     rax, [r13 + rbx * 8]
.tick_bit:
    test    rax, rax
    jz      .tick_next
    tzcnt   rdi, rax
    blsr    rax, rax
    mov     [r13 + rbx * 8], rax
    mov     rcx, rbx
    shl     rcx, 6
    add     rdi, rcx
    call    step_animation
    mov     rax, [r13 + rbx * 8]
    jmp     .tick_bit
.tick_next:
    inc     rbx
    jmp     .tick_word
.prune:
    ; Only candidates can have left the active set: characters inserted since
    ; the last pass and characters whose scene completed during it. Every
    ; engine path that can make is_active false marks its character
    ; (MARK_CANDIDATE), so this equals Rust's retain over the whole set.
    mov     r13, [candidate_bits]
    xor     ebx, ebx
.prune_word:
    cmp     rbx, r14
    jae     .done
    mov     rax, [r13 + rbx * 8]
    mov     qword [r13 + rbx * 8], 0
    mov     [prune_scratch], rax
.prune_bit:
    mov     rax, [prune_scratch]
    test    rax, rax
    jz      .prune_next
    tzcnt   rdi, rax
    blsr    rax, rax
    mov     [prune_scratch], rax
    mov     rcx, rbx
    shl     rcx, 6
    add     rdi, rcx
    push    rdi
    call    is_active
    pop     rdi
    test    eax, eax
    jnz     .prune_bit
    mov     ecx, edi
    shr     ecx, 6
    and     edi, 63
    btr     qword [r12 + rcx * 8], rdi
    jmp     .prune_bit
.prune_next:
    inc     rbx
    jmp     .prune_word
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
STR msg_frames_broken, "ttfx: asm engine: frames added to a scene out of order", 10
STR msg_scene_empty, "activate_scene: empty scene"

section .tstate
alignb 8
scenes:         resq 1
frames:         resq 1
actions:        resq 1
scene_count:    resd 1
frame_count:    resd 1
action_count:   resd 1
active_bits:    resq 1
snapshot_bits:  resq 1
candidate_bits: resq 1
prune_scratch:  resq 1
active_words:   resq 1
