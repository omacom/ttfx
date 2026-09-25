; engine/update.asm - the active set, EffectCharacter.tick and
; BaseEffectIterator.update (src/engine/ctx.rs, active_characters.rs).
;
; The active set is a bitmap over slots, so iterating it visits characters in
; ascending slot order - the canonical order the parity rules demand. update
; ticks a snapshot and then prunes. Only candidates can have left the set:
; characters inserted since the last prune and characters whose scene or
; path ended or was deactivated (every such engine path does MARK_CANDIDATE).
; Pruning those equals Rust's retain over the whole set.

section .text

update_init:
    mov     rdi, CHAR_LIMIT / 8
    call    reserve
    mov     [active_bits], rax
    mov     rdi, CHAR_LIMIT / 8
    call    reserve
    mov     [snapshot_bits], rax
    mov     rdi, CHAR_LIMIT / 8
    call    reserve
    mov     [candidate_bits], rax
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
    ret

; active_remove(edi=slot)
active_remove:
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

; active_clear: empty the set.
active_clear:
    mov     rdi, [active_bits]
    ACTIVE_WORDS rcx, ecx
    xor     eax, eax
    rep     stosq
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
    popcnt  r8, [rsi + rdx * 8]
    add     rax, r8
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

; update: tick a snapshot of the active set in ascending order, then prune.
update:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, [active_bits]
    mov     r13, [snapshot_bits]
    ACTIVE_WORDS r14, r14d
    ; snapshot (callbacks may change the live set while we tick)
    mov     rdi, r13
    mov     rsi, r12
    mov     rcx, r14
    rep     movsq
    xor     ebx, ebx
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
    call    tick
    mov     rax, [r13 + rbx * 8]
    jmp     .tick_bit
.tick_next:
    inc     rbx
    jmp     .tick_word
.prune:
    ; the set may have grown during the pass (new characters)
    ACTIVE_WORDS r14, r14d
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

section .tstate
alignb 8
active_bits:    resq 1
snapshot_bits:  resq 1
candidate_bits: resq 1
prune_scratch:  resq 1
