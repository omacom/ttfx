; engine/update.asm - the active set, EffectCharacter.tick and
; BaseEffectIterator.update (src/engine/ctx.rs, active_characters.rs).
;
; The active set is a bitmap over slots, so iterating it visits characters in
; ascending slot order - the canonical order the parity rules demand. update
; ticks a snapshot and then prunes. Only candidates can have left the set:
; characters inserted since the last prune and characters whose scene or
; path ended or was deactivated (every such engine path does MARK_CANDIDATE).
; Pruning those equals Rust's retain over the whole set. The passes only
; visit the window of bitmap words [active_lo, active_hi), which
; active_insert widens and each prune narrows: most effects keep a band of
; active characters, not the whole store.
;
; Dozing. Most ticks only count down: no path, the visual unchanged, no
; event - a plain scene's head frame ticking (and retiring, but for the
; last frame), or an eased scene's steps that keep showing the same frame.
; When step_animation runs as update's tick of a character ([doze_slot]),
; it counts the pure ticks ahead (k) and advances the scene's counter
; (SC_TICKS or SC_EASE_STEP) past them at once; doze_try then sets the
; character's bit in doze_bits, which keeps it out of the snapshots, and
; ch_wake[slot], the update number (mod 256) whose snapshot takes it back.
; So a dozing character costs nothing per update. A plain doze may end on
; its head frame's last tick; that retirement happens when it wakes
; (doze_retire).
;
; Anything that could make one of those ticks impure, or that reads or
; rewrites the active scene's playback state, first calls doze_wake: scene
; activation and deactivation, step_animation, set_appearance, scene_reset,
; scene_copy, scene_new over a used record, particle resets, active_remove,
; active_clear, path_activate (motion.asm) and thunderstorm's easing
; change. doze_wake gives back the ticks not yet due, and a character woken
; during update ahead of the ticking slot rejoins this update's snapshot,
; so it ticks exactly where Rust ticks it.
;
; Batched motion (TIER 3+). Before ticking a word, update hands its bits to
; motion_batch (motion.asm), which works out the pure path steps of the
; word's movers ahead of time; their motion_move becomes motion_apply, or
; nothing when the step neither moves the character nor ends the path.
; Ticks that do nothing at all (mb_idle_bits) are left out of the word,
; and those that only move a character without a scene (mb_bare_bits) are
; a set_coordinate.
; A callback or an action on another character bumps motion_epoch (and
; motion_void takes the word's unticked steps back), and the rest of the
; word ticks through motion_move, the idle ticks not reached yet included.

%define UPD_STAGGER     640         ; bytes between the bitmaps' page offsets

section .text

; update_init: once per run. chars_init already runs it, since input parsing
; (terminal_init) can set appearances, which wake dozers.
update_init:
    cmp     qword [active_bits], 0
    jne     .done
    ; the arrays are staggered within a page: the same word of two of them
    ; would share its address's low 12 bits, and a load then waits on a
    ; store to the other (4K aliasing)
    ; only short prefixes of these widely separated arrays are normally
    ; touched: keep their pages small, like the character fields'
    mov     rdi, 4 * (CHAR_LIMIT / 8) + CHAR_LIMIT + 5 * UPD_STAGGER
    call    reserve_small
    mov     [active_bits], rax
    add     rax, CHAR_LIMIT / 8 + UPD_STAGGER
    mov     [snapshot_bits], rax
    add     rax, CHAR_LIMIT / 8 + UPD_STAGGER
    mov     [candidate_bits], rax
    add     rax, CHAR_LIMIT / 8 + UPD_STAGGER
    mov     [doze_bits], rax
    add     rax, CHAR_LIMIT / 8 + UPD_STAGGER
    mov     [ch_wake], rax
    mov     dword [upd_cursor], -1
    mov     dword [doze_slot], -1
.done:
    ret

; BIT_POP dest, word: dest = index of word's lowest set bit (word != 0),
; which is then cleared. Clobbers rcx below TIER 3.
%macro BIT_POP 2
%if TIER >= 3
    tzcnt   %1, %2
    blsr    %2, %2
%else
    bsf     %1, %2
    lea     rcx, [%2 - 1]
    and     %2, rcx
%endif
%endmacro

; doze_wake(edi=slot): end slot's doze, if any, settling its scene's
; ticks_elapsed. Clobbers rax only.
doze_wake:
    push    rcx
    mov     rax, [doze_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     rax, [rax + rcx * 8]
    bt      rax, rdi
    jc      .wake
    pop     rcx
    ret
.wake:
    push    rdx
    push    rsi
    btr     rax, rdi
    mov     rdx, [doze_bits]
    mov     [rdx + rcx * 8], rax
    ; ticks still owed: wake - update when this update's tick is still
    ; ahead (it rejoins the snapshot), one less when it is behind us or no
    ; update is running
    mov     rax, [ch_wake]
    movzx   edx, byte [rax + rdi]
    sub     edx, [upd_count]
    movzx   edx, dl
    cmp     edi, [upd_cursor]
    jae     .ahead
    dec     edx
    jmp     .settle
.ahead:
    mov     rax, [snapshot_bits]
    mov     rsi, [rax + rcx * 8]
    bts     rsi, rdi
    mov     [rax + rcx * 8], rsi
.settle:
    push    r8
    mov     rax, [ch_scene]
    mov     eax, [rax + rdi * 4]
    SCENE_PTR r8, rax
    test    dword [r8 + SC_FLAGS], SCF_EASED
    jnz     .eased
    sub     [r8 + SC_TICKS], edx
    call    doze_retire
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    ret
.eased:
    sub     [r8 + SC_EASE_STEP], edx
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    ret

; doze_try(edi=slot, esi=k > 0 pure ticks ahead) -> esi = the ticks it
; dozes through (k, at most 254 so the wake byte stays unambiguous), or 0
; when it can't (a path, or no longer in the set). step_animation calls it
; on update's tick ([doze_slot]) and advances its counters by esi. Clobbers
; rax, rcx, rdx.
doze_try:
    mov     eax, 254
    cmp     esi, eax
    cmova   esi, eax
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    jne     .refuse
    mov     rax, [active_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     rdx, [rax + rcx * 8]
    bt      rdx, rdi
    jnc     .refuse
    mov     rax, [doze_bits]
    mov     rdx, [rax + rcx * 8]
    bts     rdx, rdi
    mov     [rax + rcx * 8], rdx
    mov     eax, [upd_count]
    lea     eax, [eax + esi + 1]
    mov     rdx, [ch_wake]
    mov     [rdx + rdi], al
    ret
.refuse:
    xor     esi, esi
    ret

; doze_retire(r8=scene record): a doze may end just after its head frame's
; last tick; that tick's retirement (never the scene's last frame) happens
; here. Clobbers rax, rcx.
doze_retire:
    mov     eax, [r8 + SC_TICKS]
    cmp     eax, [r8 + SC_HEAD_DURATION]
    jne     .done
    mov     dword [r8 + SC_TICKS], 0
    inc     dword [r8 + SC_HEAD]
    jmp     scene_load_head
.done:
    ret

; active_words -> rax = bitmap words in use (covers every allocated slot).
%macro ACTIVE_WORDS 2                   ; 64-bit register, its 32-bit name
    mov     %2, [char_count]
    add     %1, 63
    shr     %1, 6
%endmacro

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
    ; widen the window of words that can hold active characters
    mov     eax, [active_hi]
    cmp     eax, [active_lo]
    jbe     .first
    cmp     ecx, [active_lo]
    jae     .above
    mov     [active_lo], ecx
.above:
    inc     ecx
    cmp     ecx, eax
    jbe     .done
    mov     [active_hi], ecx
.done:
    ret
.first:
    mov     [active_lo], ecx
    inc     ecx
    mov     [active_hi], ecx
    ret

; active_remove(edi=slot)
active_remove:
    call    doze_wake
    mov     rax, [active_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     edx, edi
    and     edx, 63
    btr     qword [rax + rcx * 8], rdx
    ret

; active_contains(edi=slot) -> eax
active_contains:
    mov     rax, [active_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     edx, edi
    and     edx, 63
    bt      qword [rax + rcx * 8], rdx
    setc    al
    movzx   eax, al
    ret

; active_clear: empty the set, waking every dozing character first.
active_clear:
    push    rbx
    push    r12
    push    r13
    ACTIVE_WORDS r13, r13d
    xor     ebx, ebx
.word:
    cmp     rbx, r13
    jae     .clear
    mov     rax, [doze_bits]
    mov     r12, [rax + rbx * 8]
.bit:
    test    r12, r12
    jz      .next
    BIT_POP rdi, r12
    mov     rax, rbx
    shl     rax, 6
    add     rdi, rax
    call    doze_wake
    jmp     .bit
.next:
    inc     rbx
    jmp     .word
.clear:
    mov     rdi, [active_bits]
    mov     rcx, r13
    xor     eax, eax
    rep     stosq
    mov     [active_lo], eax
    mov     [active_hi], eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; active_empty -> eax = 1 when no character is active.
active_empty:
    mov     rax, [active_bits]
    ACTIVE_WORDS rcx, ecx
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

; active_count -> rax = number of active characters.
active_count:
    mov     rsi, [active_bits]
    ACTIVE_WORDS rcx, ecx
    xor     eax, eax
    xor     edx, edx
.loop:
    cmp     rdx, rcx
    jae     .done
%if TIER >= 2
    popcnt  r8, [rsi + rdx * 8]
    add     rax, r8
%else
    mov     r8, [rsi + rdx * 8]
.bit:
    test    r8, r8
    jz      .counted
    lea     r9, [r8 - 1]
    and     r8, r9
    inc     rax
    jmp     .bit
.counted:
%endif
    inc     rdx
    jmp     .loop
.done:
    ret

; is_active(edi=slot) -> eax: EffectCharacter.is_active - an active path, or
; an active scene that is not complete (looping scenes read as complete).
is_active:
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    jne     .yes
    call    scene_is_complete
    xor     eax, 1
    ret
.yes:
    mov     eax, 1
    ret

; tick(edi=slot): EffectCharacter.tick - motion first, then animation.
; A character without an active path has nothing to move.
tick:
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    je      step_animation
    push    rbx
    mov     ebx, edi
    call    motion_move
    mov     edi, ebx
    call    step_animation
    pop     rbx
    ret

; tick_awake(edi=slot): tick for update's pass, where the character is not
; dozing (nothing but update's own tick without a path starts a doze).
tick_awake:
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    je      step_animation_awake
    push    rbx
    mov     ebx, edi
    call    motion_move
    mov     edi, ebx
    call    step_animation_awake
    pop     rbx
    ret

; WAKE_MASK dest: dest = bit i set where byte i of the 64 at rsi equals the
; byte broadcast in xmm7 (zmm7 at TIER 4). Clobbers xmm0 and rdx below
; TIER 4, k1 at TIER 4.
%macro WAKE_MASK 1
%if TIER >= 4
    vpcmpeqb k1, zmm7, [rsi]
    kmovq   %1, k1
%else
    movdqu  xmm0, [rsi + 48]
    pcmpeqb xmm0, xmm7
    pmovmskb edx, xmm0
    mov     %1, rdx
    shl     %1, 16
    movdqu  xmm0, [rsi + 32]
    pcmpeqb xmm0, xmm7
    pmovmskb edx, xmm0
    or      %1, rdx
    shl     %1, 16
    movdqu  xmm0, [rsi + 16]
    pcmpeqb xmm0, xmm7
    pmovmskb edx, xmm0
    or      %1, rdx
    shl     %1, 16
    movdqu  xmm0, [rsi]
    pcmpeqb xmm0, xmm7
    pmovmskb edx, xmm0
    or      %1, rdx
%endif
%endmacro

; update: tick a snapshot of the active set in ascending order, then prune.
update:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40                     ; prune slot, batch bits, batch epoch, idle bits
    mov     r12, [active_bits]
    mov     r13, [snapshot_bits]
    ; only the window of words that can hold active characters
    mov     r14d, [active_hi]
    mov     ebp, [active_lo]
    ; the snapshot (callbacks may change the live set while we tick): this
    ; update's dozers wake, the others stay out
    mov     eax, [upd_count]
    inc     eax
    mov     [upd_count], eax
    movzx   eax, al
%if TIER >= 4
    vpbroadcastb zmm7, eax
%else
    movd    xmm7, eax
    punpcklbw xmm7, xmm7
    pshuflw xmm7, xmm7, 0
    pshufd  xmm7, xmm7, 0
%endif
    mov     r8, [doze_bits]
    mov     rsi, rbp
    shl     rsi, 6
    add     rsi, [ch_wake]
    mov     ebx, ebp
.snap_word:
    cmp     rbx, r14
    jae     .snapped
    mov     rax, [r12 + rbx * 8]
    mov     r9, [r8 + rbx * 8]
    test    r9, r9
    jz      .snap_store
    ; those waking now join the snapshot; their doze ends at their tick
    WAKE_MASK r10
    and     r10, r9
    xor     r9, r10
    not     r9
    and     rax, r9
.snap_store:
    mov     [r13 + rbx * 8], rax
    add     rsi, 64
    inc     rbx
    jmp     .snap_word
.snapped:
%if TIER >= 4
    vzeroupper
%endif
    mov     ebx, ebp
.tick_word:
    cmp     rbx, r14
    jae     .prune
    mov     r15, [r13 + rbx * 8]
    test    r15, r15
    jz      .tick_next
    mov     rbp, rbx
    shl     rbp, 6
    ; the word's pure path steps, worked out ahead (motion_batch)
    mov     qword [rsp + 8], 0
    mov     qword [rsp + 24], 0
%if TIER >= 3
    cmp     dword [path_count], 0
    je      .tick_bit
    mov     rdi, r15
    mov     esi, ebp
    call    motion_batch
    mov     [rsp + 8], rax
    mov     eax, [motion_epoch]
    mov     [rsp + 16], eax
    ; idle ticks do nothing: skip them (they come back if the epoch moves)
    mov     rax, [mb_idle_bits]
    mov     [rsp + 24], rax
    andn    r15, rax, r15
    jnz     .tick_bit
    mov     [r13 + rbx * 8], r15
    inc     rbx
    jmp     .tick_word
%endif
.tick_bit:
    BIT_POP rdi, r15
    mov     [r13 + rbx * 8], r15
%if TIER >= 3
    mov     rdx, [rsp + 8]
    bt      rdx, rdi
    jc      .batched
%endif
    add     rdi, rbp
    mov     [upd_cursor], edi
    mov     rdx, [doze_bits]
    mov     rax, [rdx + rbx * 8]
    bt      rax, rdi
    jc      .waking
.tick:
    ; without a path, the tick is step_animation, which may start a doze
    mov     rax, [ch_path]
    cmp     dword [rax + rdi * 4], NONE
    jne     .moving
    mov     [doze_slot], edi
    call    step_animation_awake
    mov     dword [doze_slot], -1
    jmp     .ticked
.moving:
    ; tick_awake, inline
    call    motion_move
.moved:
    mov     edi, [upd_cursor]
    call    step_animation_awake
.ticked:
    ; a callback or an action on another character may have changed any
    ; path: the rest of the word steps without the precomputed results
    mov     eax, [motion_epoch]
    cmp     eax, [rsp + 16]
    je      .epoch_same
    mov     qword [rsp + 8], 0
%if TIER >= 3
    ; the idle ticks not reached yet tick after all
    mov     ecx, [upd_cursor]
    sub     ecx, ebp
    mov     rax, -2
    shl     rax, cl
    and     rax, [rsp + 24]
    or      [r13 + rbx * 8], rax
    mov     qword [rsp + 24], 0
%endif
.epoch_same:
    ; re-read: a character woken during the pass may have joined this word
    mov     r15, [r13 + rbx * 8]
    test    r15, r15
    jnz     .tick_bit
    inc     rbx
    jmp     .tick_word
.waking:
    ; its doze ran out: settle a pending retirement, then tick as usual
    btr     rax, rdi
    mov     [rdx + rbx * 8], rax
    mov     rax, [ch_scene]
    mov     eax, [rax + rdi * 4]
    SCENE_PTR r8, rax
    call    doze_retire
    jmp     .tick
.tick_next:
    inc     rbx
    jmp     .tick_word
%if TIER >= 3
.batched:
    ; a path step motion_batch worked out (so a path, and no doze)
    mov     eax, edi
    add     rdi, rbp
    mov     [upd_cursor], edi
    mov     rdx, [mb_act_bits]
    bt      rdx, rax
    jnc     .moved                      ; worked out, and nothing to do
    mov     rdx, [mb_bare_bits]
    bt      rdx, rax
    jc      .bare
    call    motion_apply
    jmp     .moved
.bare:
    ; a move and nothing else: no path event, no scene
    lea     rdx, [mb]
    mov     rsi, [rdx + MB_COORD + rax * 8]
    call    set_coordinate
    jmp     .ticked
%endif
.prune:
    mov     dword [upd_cursor], -1
%if TIER >= 3
    mov     qword [mb_mirror_bits], 0   ; nothing left for motion_void
%endif
    ; the set may have grown during the pass (new characters); candidates
    ; outside the window are not active
    mov     r14d, [active_hi]
    mov     r13, [candidate_bits]
    mov     ebx, [active_lo]
.prune_word:
    cmp     rbx, r14
    jae     .shrink
    mov     r15, [r13 + rbx * 8]
    test    r15, r15
    jz      .prune_next
    mov     qword [r13 + rbx * 8], 0
    mov     rbp, rbx
    shl     rbp, 6
.prune_bit:
    test    r15, r15
    jz      .prune_next
    BIT_POP rdi, r15
    add     rdi, rbp
    mov     [rsp], edi
    call    is_active
    mov     edi, [rsp]
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
.shrink:
    ; narrow the window to the words still in use
    mov     eax, [active_lo]
.shrink_lo:
    cmp     eax, r14d
    jae     .empty
    cmp     qword [r12 + rax * 8], 0
    jne     .shrink_hi
    inc     eax
    jmp     .shrink_lo
.shrink_hi:
    cmp     qword [r12 + r14 * 8 - 8], 0
    jne     .narrowed
    dec     r14d
    jmp     .shrink_hi
.empty:
    xor     eax, eax
    xor     r14d, r14d
.narrowed:
    mov     [active_lo], eax
    mov     [active_hi], r14d
.done:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .tstate
alignb 8
active_bits:    resq 1
snapshot_bits:  resq 1
candidate_bits: resq 1
doze_bits:      resq 1              ; characters dozing through pure ticks
ch_wake:        resq 1              ; u8 per slot: the update that wakes it
active_lo:      resd 1              ; words [lo, hi) hold every active
active_hi:      resd 1              ; character (empty when hi <= lo)
upd_count:      resd 1              ; updates started
upd_cursor:     resd 1              ; the slot ticking now, or -1
doze_slot:      resd 1
              ; the slot whose update tick is running, or -1
