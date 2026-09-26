; engine/events.asm - EventHandler (src/engine/events.rs) and dispatch
; (EngineCtx::handle_event / register_event, src/engine/ctx.rs).
;
; Each character owns a list of entries in registration order; an entry is
; one (event, caller) pair with its actions, also in registration order.
; Dispatch runs the actions inline and reentrantly at the emission point, and
; re-reads each action's successor after running it, so actions appended
; while dispatching still run - Python list iteration, faithfully.
;
; Callers are keyed by name for scenes and paths (Scene/Path equality is by
; id upstream) and by the full waypoint record for waypoints (name,
; coordinate and bezier controls; equal records on different paths collide).

%define ENTRY_LIMIT         (1 << 24)
%define ACTION_LIMIT        (1 << 25)

section .text

events_init:
    mov     rdi, ENTRY_LIMIT * ENTRY_SIZE
    call    reserve
    mov     [event_entries], rax
    mov     rdi, ACTION_LIMIT * ACTION_SIZE
    call    reserve
    mov     [event_actions], rax
    ret

; entry_matches(r8=entry record, esi=event, edx=caller kind, rcx=caller)
; -> ZF set on a match. Clobbers rax, r9, r10, r11.
entry_matches:
    movzx   eax, byte [r8 + EN_EVENT]
    cmp     eax, esi
    jne     .done
    movzx   eax, byte [r8 + EN_KIND]
    cmp     eax, edx
    jne     .done
    cmp     edx, CALLER_WAYPOINT
    je      .waypoint
    cmp     [r8 + EN_WAYPOINT + WP_NAME], ecx
    ret
.waypoint:
    ; name, coordinate, then the bezier controls element by element
    mov     eax, [rcx + WP_NAME]
    cmp     [r8 + EN_WAYPOINT + WP_NAME], eax
    jne     .done
    mov     rax, [rcx + WP_COORD]
    cmp     [r8 + EN_WAYPOINT + WP_COORD], rax
    jne     .done
    mov     eax, [rcx + WP_BEZ_COUNT]
    cmp     [r8 + EN_WAYPOINT + WP_BEZ_COUNT], eax
    jne     .done
    mov     r9, [rcx + WP_BEZ]
    mov     r10, [r8 + EN_WAYPOINT + WP_BEZ]
    xor     r11d, r11d
.control:
    cmp     r11d, eax
    jae     .equal
    push    rax
    mov     rax, [r9 + r11 * 8]
    cmp     [r10 + r11 * 8], rax
    pop     rax
    jne     .done
    inc     r11d
    jmp     .control
.equal:
    cmp     eax, eax                    ; ZF set
.done:
    ret

; event_find(edi=slot, esi=event, edx=caller kind, rcx=caller) -> eax =
; entry index or NONE. Clobbers r8-r11.
event_find:
    mov     rax, [ch_events]
    mov     eax, [rax + rdi * 4]
.next:
    cmp     eax, NONE
    je      .done
    mov     r8, rax
    shl     r8, 6                       ; ENTRY_SIZE
    add     r8, [event_entries]
    push    rax
    call    entry_matches
    pop     rax
    je      .done
    mov     eax, [r8 + EN_NEXT]
    jmp     .next
.done:
    ret

; event_register(edi=slot, esi=event, edx=caller kind, rcx=caller name or
;   waypoint record, r8d=ACT_* kind, r9=arg0, [rsp+8]=arg1).
; EventHandler.register_event: an identical action on the same (event,
; caller) is a duplicate registration error.
event_register:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     ebp, esi
    mov     r12d, edx
    mov     r13, rcx
    mov     r14d, r8d
    mov     r15, r9
    call    event_find
    cmp     eax, NONE
    jne     .have_entry
    ; a new entry at the end of the character's list
    mov     edi, r12d
    call    entry_take_free             ; particles.asm: a recycled entry, or NONE
    cmp     eax, NONE
    jne     .new_entry
    mov     eax, [entry_count]
    cmp     eax, ENTRY_LIMIT
    jae     .full
    inc     dword [entry_count]
.new_entry:
    mov     r8, rax
    shl     r8, 6
    add     r8, [event_entries]
    mov     dword [r8 + EN_NEXT], NONE
    mov     [r8 + EN_EVENT], bpl
    mov     [r8 + EN_KIND], r12b
    mov     dword [r8 + EN_FIRST], NONE
    mov     dword [r8 + EN_LAST], NONE
    cmp     r12d, CALLER_WAYPOINT
    je      .copy_waypoint
    mov     [r8 + EN_WAYPOINT + WP_NAME], r13d
    jmp     .link
.copy_waypoint:
    movdqu  xmm0, [r13]
    movdqu  xmm1, [r13 + 16]
    movdqu  [r8 + EN_WAYPOINT], xmm0
    movdqu  [r8 + EN_WAYPOINT + 16], xmm1
.link:
    mov     rcx, [ch_events]
    lea     rcx, [rcx + rbx * 4]
.tail:
    cmp     dword [rcx], NONE
    je      .linked
    mov     edx, [rcx]
    shl     rdx, 6
    add     rdx, [event_entries]
    lea     rcx, [rdx + EN_NEXT]
    jmp     .tail
.linked:
    mov     [rcx], eax
.have_entry:
    mov     r8, rax
    shl     r8, 6
    add     r8, [event_entries]
    ; reject a duplicate action
    mov     eax, [r8 + EN_FIRST]
    mov     rdx, [rsp + 8 + 48 + 8]     ; arg1
.dup:
    cmp     eax, NONE
    je      .append
    mov     rcx, rax
    shl     rcx, 5
    add     rcx, [event_actions]
    cmp     [rcx + AC_KIND], r14d
    jne     .dup_next
    cmp     [rcx + AC_ARG0], r15
    jne     .dup_next
    cmp     [rcx + AC_ARG1], rdx
    je      .duplicate
.dup_next:
    mov     eax, [rcx + AC_NEXT]
    jmp     .dup
.append:
    call    action_take_free            ; particles.asm: a recycled action, or NONE
    cmp     eax, NONE
    jne     .new_action
    mov     eax, [action_count]
    cmp     eax, ACTION_LIMIT
    jae     .full
    inc     dword [action_count]
.new_action:
    mov     rcx, rax
    shl     rcx, 5
    add     rcx, [event_actions]
    mov     [rcx + AC_KIND], r14d
    mov     dword [rcx + AC_NEXT], NONE
    mov     [rcx + AC_ARG0], r15
    mov     [rcx + AC_ARG1], rdx
    mov     edx, [r8 + EN_LAST]
    mov     [r8 + EN_LAST], eax
    cmp     edx, NONE
    je      .first
    shl     rdx, 5
    add     rdx, [event_actions]
    mov     [rdx + AC_NEXT], eax
    jmp     .subscribed
.first:
    mov     [r8 + EN_FIRST], eax
.subscribed:
    ; a character that observes segments walks its own segment lists
    cmp     ebp, EV_SEGMENT_ENTERED
    je      .own_segments
    cmp     ebp, EV_SEGMENT_EXITED
    jne     .mark
.own_segments:
    mov     edi, ebx
    call    path_unshare_all            ; motion.asm
.mark:
    mov     rax, [ch_subs]
    bts     dword [rax + rbx], ebp
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
.duplicate:
    lea     rdi, [msg_duplicate_event]
    mov     esi, msg_duplicate_event_len
    jmp     fatal
.full:
    lea     rdi, [msg_events_full]
    mov     esi, msg_events_full_len
    jmp     fatal

; handle_event(edi=slot, esi=event, edx=caller kind, rcx=caller): run every
; action registered for (event, caller) on the character, in order, inline.
; Clobbers the C caller-saved set.
handle_event:
    mov     rax, [ch_subs]
    movzx   eax, byte [rax + rdi]
    bt      eax, esi
    jnc     .none
    push    rbx
    push    r12
    push    r13
    call    event_find
    cmp     eax, NONE
    je      .done
    mov     ebx, edi                    ; slot
    mov     r12, r8                     ; entry
    mov     r13d, [r8 + EN_FIRST]
.action:
    cmp     r13d, NONE
    je      .done
    mov     rax, r13
    shl     rax, 5
    add     rax, [event_actions]
    mov     ecx, [rax + AC_KIND]
    mov     rsi, [rax + AC_ARG0]
    mov     rdx, [rax + AC_ARG1]
    mov     edi, ebx
    call    run_action
    ; the successor is read after the action ran: appended actions run too
    mov     rax, r13
    shl     rax, 5
    add     rax, [event_actions]
    mov     r13d, [rax + AC_NEXT]
    jmp     .action
.done:
    pop     r13
    pop     r12
    pop     rbx
.none:
    ret

; run_action(edi=slot, ecx=ACT_* kind, rsi=arg0, rdx=arg1)
run_action:
    ; a callback, or an action on a character other than the one update is
    ; ticking, may change any path: update's precomputed steps are void
    cmp     ecx, ACT_CALLBACK
    je      .epoch
    cmp     edi, [upd_cursor]
    je      .dispatch
.epoch:
    inc     dword [motion_epoch]
%if TIER >= 3
    call    motion_void
%endif
.dispatch:
    cmp     ecx, ACT_ACTIVATE_PATH
    je      path_activate_name
    cmp     ecx, ACT_ACTIVATE_SCENE
    je      scene_activate_name
    cmp     ecx, ACT_DEACTIVATE_PATH
    je      path_deactivate
    cmp     ecx, ACT_DEACTIVATE_SCENE
    je      scene_deactivate
    cmp     ecx, ACT_RESET_APPEARANCE
    je      reset_appearance
    cmp     ecx, ACT_SET_LAYER
    je      set_layer
    cmp     ecx, ACT_SET_COORDINATE
    je      set_coordinate
    cmp     ecx, ACT_CALLBACK
    jne     .unknown
    mov     rax, rsi
    mov     rsi, rdx
    jmp     rax                         ; fn(edi=slot, rsi=payload)
.unknown:
    lea     rdi, [msg_unknown_action]
    mov     esi, msg_unknown_action_len
    jmp     fatal

; event_clear(edi=slot): EventHandler.clear (particle resets).
event_clear:
    mov     rax, [ch_events]
    mov     dword [rax + rdi * 4], NONE
    mov     rax, [ch_subs]
    mov     byte [rax + rdi], 0
    ret

section .rodata
STR msg_duplicate_event, "ttfx: asm engine: duplicate event registration", 10
STR msg_events_full, "ttfx: asm engine: event limit reached", 10
STR msg_unknown_action, "ttfx: asm engine: unknown event action", 10

section .tstate
alignb 8
event_entries:  resq 1
event_actions:  resq 1
entry_count:    resd 1
action_count:   resd 1
