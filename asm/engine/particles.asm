; engine/particles.asm - ParticlePool / ParticleReset
; (src/engine/particles.rs).
;
; A pool lives in the effect's own memory (a POOL struc). Rust passes the
; reset flags and the initializer closure per call; here they are pool fields
; the effect sets (and may change between calls). Callbacks take
; (edi = particle slot, rsi = the matching user word).
;
; The available queue pops and pushes on the right (Python deque.pop /
; append). Membership for reclaim's "no duplicate entries" rule is a flag bit
; on the character, since a character belongs to at most one pool.

%define CF_POOLED           256         ; in its pool's available queue

; ParticleReset bits; the default is CLEAR_PATHS | DEACTIVATE_PATH |
; DEACTIVATE_SCENE (ParticleReset::default)
%define RESET_CLEAR_PATHS       1
%define RESET_CLEAR_SCENES      2
%define RESET_CLEAR_EVENTS      4
%define RESET_DEACTIVATE_PATH   8
%define RESET_DEACTIVATE_SCENE  16
%define RESET_APPEARANCE        32
%define RESET_DEFAULT           (RESET_CLEAR_PATHS | RESET_DEACTIVATE_PATH | RESET_DEACTIVATE_SCENE)

struc POOL
    .symbols:       resq 1              ; packed symbols
    .symbol_count:  resq 1
    .max_size:      resq 1              ; -1 = unbounded
    .coord:         resq 1              ; where new particles are created
    .available:     resq 1              ; u32 slots (a stack: pop/push right)
    .available_count: resq 1
    .particles:     resq 1              ; u32 slots, every particle owned
    .particle_count: resq 1
    .reset:         resq 1              ; RESET_* bits for acquire/emit
    .initializer:   resq 1              ; fn(edi=slot, rsi=user) or 0
    .init_user:     resq 1
endstruc

%define POOL_CAPACITY       (1 << 22)

section .text

; pool_init(rdi=pool, rsi=symbols, rdx=symbol count, rcx=max size or -1,
;           r8=coord). ParticlePool::new: at least one symbol.
pool_init:
    push    rbx
    mov     rbx, rdi
    test    rdx, rdx
    jz      .no_symbols
    mov     [rbx + POOL.symbols], rsi
    mov     [rbx + POOL.symbol_count], rdx
    mov     [rbx + POOL.max_size], rcx
    mov     [rbx + POOL.coord], r8
    mov     qword [rbx + POOL.reset], RESET_DEFAULT
    mov     qword [rbx + POOL.initializer], 0
    mov     rdi, POOL_CAPACITY * 4
    call    reserve_small
    mov     [rbx + POOL.available], rax
    mov     rdi, POOL_CAPACITY * 4
    call    reserve_small
    mov     [rbx + POOL.particles], rax
    mov     qword [rbx + POOL.available_count], 0
    mov     qword [rbx + POOL.particle_count], 0
    pop     rbx
    ret
.no_symbols:
    FAIL    msg_pool_symbols

; pool_preallocate(rdi=pool, rsi=count): the initial_count loop of __init__,
; using the pool's initializer.
pool_preallocate:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx + POOL.max_size]
    cmp     rax, -1
    je      .loop
    cmp     rax, r12
    jb      .too_small
.loop:
    test    r12, r12
    jz      .done
    mov     rdi, rbx
    xor     esi, esi
    call    pool_create_particle
    mov     edi, eax
    mov     rdi, rbx
    call    pool_push_available
    dec     r12
    jmp     .loop
.done:
    pop     r12
    pop     rbx
    ret
.too_small:
    FAIL    msg_pool_max

; pool_create_particle(rdi=pool, rsi=symbol or 0 for a random one) -> eax.
; _create_particle: the symbol (drawn from the pool's symbols when none is
; given), a character at the pool's coordinate, the initializer, ownership.
pool_create_particle:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     rdx, rsi
    test    rdx, rdx
    jnz     .symbol
    mov     rdi, [rbx + POOL.symbol_count]
    call    rng_below
    mov     rcx, [rbx + POOL.symbols]
    mov     rdx, [rcx + rax * 8]
.symbol:
    mov     rdi, rdx
    mov     rsi, [rbx + POOL.coord]
    call    add_character
    mov     r12d, eax
    mov     rax, [rbx + POOL.initializer]
    test    rax, rax
    jz      .own
    mov     edi, r12d
    mov     rsi, [rbx + POOL.init_user]
    call    rax
.own:
    mov     rax, [rbx + POOL.particle_count]
    mov     rcx, [rbx + POOL.particles]
    mov     [rcx + rax * 4], r12d
    inc     qword [rbx + POOL.particle_count]
    mov     eax, r12d
    pop     r12
    pop     rbx
    ret

; pool_push_available(rdi=pool, esi... ) - internal: push slot eax.
pool_push_available:
    mov     rcx, [rdi + POOL.available_count]
    mov     rdx, [rdi + POOL.available]
    mov     [rdx + rcx * 4], eax
    inc     qword [rdi + POOL.available_count]
    mov     rdx, [ch_flags]
    or      word [rdx + rax * 2], CF_POOLED
    ret

; particle_reset(edi=slot, esi=RESET_* bits): _reset_particle.
particle_reset:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12d, esi
    call    doze_wake
    test    r12d, RESET_DEACTIVATE_PATH
    jz      .scene
    mov     rax, [ch_path]
    mov     dword [rax + rbx * 4], NONE
    MARK_CANDIDATE
.scene:
    test    r12d, RESET_DEACTIVATE_SCENE
    jz      .paths
    mov     rax, [ch_scene]
    mov     dword [rax + rbx * 4], NONE
    mov     edi, ebx
    MARK_CANDIDATE
.paths:
    test    r12d, RESET_CLEAR_PATHS
    jz      .scenes
    mov     edi, ebx
    call    paths_release
.scenes:
    test    r12d, RESET_CLEAR_SCENES
    jz      .events
    mov     edi, ebx
    call    scenes_release
.events:
    test    r12d, RESET_CLEAR_EVENTS
    jz      .appearance
    mov     edi, ebx
    call    events_release
.appearance:
    test    r12d, RESET_APPEARANCE
    jz      .done
    mov     edi, ebx
    call    reset_appearance
.done:
    pop     r12
    pop     rbx
    ret

; pool_acquire(rdi=pool, rsi=symbol or 0) -> eax = slot or NONE (the pool is
; at max_size). ParticlePool.acquire with the pool's reset and initializer.
pool_acquire:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx + POOL.available_count]
    test    rax, rax
    jz      .create
    dec     rax
    mov     [rbx + POOL.available_count], rax
    mov     rcx, [rbx + POOL.available]
    mov     r13d, [rcx + rax * 4]
    mov     rcx, [ch_flags]
    and     word [rcx + r13 * 2], ~CF_POOLED
    mov     edi, r13d
    mov     rsi, [rbx + POOL.reset]
    call    particle_reset
    test    r12, r12
    jz      .done
    ; a given symbol becomes the particle's input symbol and appearance
    mov     rax, [ch_sym]
    mov     [rax + r13 * 8], r12
    mov     edi, r13d
    mov     rsi, r12
    mov     rdx, NONE
    mov     rcx, NONE
    call    set_appearance
    jmp     .done
.create:
    mov     rax, [rbx + POOL.max_size]
    cmp     rax, -1
    je      .new
    cmp     [rbx + POOL.particle_count], rax
    jae     .exhausted
.new:
    mov     rdi, rbx
    mov     rsi, r12
    call    pool_create_particle
    mov     r13d, eax
    mov     edi, eax
    mov     rsi, [rbx + POOL.reset]
    call    particle_reset
.done:
    mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret
.exhausted:
    mov     eax, NONE
    pop     r13
    pop     r12
    pop     rbx
    ret

; pool_emit(rdi=pool, rsi=origin coord, rdx=symbol or 0, ecx=visible,
;           r8=on_emit fn or 0, r9=on_emit user) -> eax = slot or NONE.
; ParticlePool.emit: acquire, position, on_emit, visibility, activate.
pool_emit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13d, ecx
    mov     r14, r8
    mov     r15, r9
    mov     rsi, rdx
    call    pool_acquire
    cmp     eax, NONE
    je      .done
    mov     ebx, eax
    mov     edi, ebx
    mov     rsi, r12
    call    set_coordinate
    test    r14, r14
    jz      .visible
    mov     edi, ebx
    mov     rsi, r15
    call    r14
.visible:
    mov     edi, ebx
    mov     esi, r13d
    call    set_visibility
    mov     edi, ebx
    call    active_insert
    mov     eax, ebx
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; pool_reclaim(rdi=pool, esi=slot, edx=hide, ecx=deactivate):
; ParticlePool.reclaim (idempotent: no duplicate queue entries).
pool_reclaim:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     ebx, esi
    mov     r13d, ecx
    test    edx, edx
    jz      .deactivate
    mov     edi, ebx
    xor     esi, esi
    call    set_visibility
.deactivate:
    test    r13d, r13d
    jz      .remove
    mov     edi, ebx
    call    doze_wake
    mov     rax, [ch_path]
    mov     dword [rax + rbx * 4], NONE
    mov     rax, [ch_scene]
    mov     dword [rax + rbx * 4], NONE
.remove:
    mov     edi, ebx
    call    active_remove
    mov     rax, [ch_flags]
    test    word [rax + rbx * 2], CF_POOLED
    jnz     .done
    mov     rdi, r12
    mov     eax, ebx
    call    pool_push_available
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; pool_extend(rdi=pool, rsi=u32 slots, rdx=count): adopt existing
; characters, no reset.
pool_extend:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.next:
    test    r13, r13
    jz      .done
    mov     eax, [r12]
    mov     rcx, [rbx + POOL.particle_count]
    mov     rdx, [rbx + POOL.particles]
    mov     [rdx + rcx * 4], eax
    inc     qword [rbx + POOL.particle_count]
    mov     rdi, rbx
    call    pool_push_available
    add     r12, 4
    dec     r13
    jmp     .next
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------ recycling
;
; Rust drops the paths, scenes and events a reset clears (and thunderstorm's
; strike characters' scenes and events on reuse). Here records live in
; index-addressed regions that never shrink, so a particle effect running
; for hours would grow without bound. Cleared records therefore go to free
; lists, one per kind, which path_new, scene_alloc and event_register take
; from first.
;
; A release (at the reset) only puts the records in limbo, untouched:
; a reset can run inside an event dispatch or update's tick, which keep
; reading the old records (handle_event reads an action's successor after
; running it). recycle_flush, at the start of the next frame, moves them to
; the free lists. The storage a record owns goes with it to its next life:
; a path's waypoint and segment arrays (zeroed, as alloc's are) and its
; bezier control blocks, and a scene's frames. Records and arrays are only
; ever addressed, never compared or ordered, so which memory they reuse is
; unobservable.
;
; Kept out of reuse, because something else may still point at them:
; - an active path or scene a reset leaves active (it stays off the map);
; - a synced scene's frames (share_table may hand them to other scenes);
; - the controls of a path whose segments were ever shared (segshare_table
;   copies the waypoints, pointers and all), and every path's controls once
;   an event is keyed by a waypoint (the entry copies the pointer).

%define PAF_EVER_SHARED     (1 << 30)   ; the path walked a shared list once
%define RC_CAP_SHIFT        48          ; parked arrays: pointer | capacity << 48
%define RC_CAP_MAX          0xffff
%define BEZ_BLOCK_COUNT     8           ; controls that fit a 64-byte block

; paths_release(edi=slot): Motion.paths.clear(). Clobbers rax, rcx, rdx.
paths_release:
    push    rbx
    push    r8
    mov     rax, [ch_paths]
    mov     ecx, [rax + rdi * 4]
    mov     dword [rax + rdi * 4], NONE
    mov     rax, [ch_path]
    mov     edx, [rax + rdi * 4]        ; left active: not released
.next:
    cmp     ecx, NONE
    je      .done
    PATH_PTR r8, rcx
    mov     ebx, [r8 + PA_NEXT]
    cmp     ecx, edx
    je      .skip
    mov     eax, [rc_path_limbo]
    dec     eax                         ; head index or NONE
    mov     [r8 + PA_NEXT], eax
    lea     eax, [rcx + 1]
    mov     [rc_path_limbo], eax
.skip:
    mov     ecx, ebx
    jmp     .next
.done:
    pop     r8
    pop     rbx
    ret

; scenes_release(edi=slot): Animation.scenes.clear(). Clobbers rax, rcx, rdx.
scenes_release:
    push    rbx
    push    r8
    mov     rax, [ch_scenes]
    mov     ecx, [rax + rdi * 4]
    mov     dword [rax + rdi * 4], NONE
    mov     rax, [ch_scene]
    mov     edx, [rax + rdi * 4]        ; left active: not released
.next:
    cmp     ecx, NONE
    je      .done
    SCENE_PTR r8, rcx
    mov     ebx, [r8 + SC_NEXT]
    cmp     ecx, edx
    je      .skip
    mov     eax, [rc_scene_limbo]
    dec     eax
    mov     [r8 + SC_NEXT], eax
    lea     eax, [rcx + 1]
    mov     [rc_scene_limbo], eax
.skip:
    mov     ecx, ebx
    jmp     .next
.done:
    pop     r8
    pop     rbx
    ret

; events_release(edi=slot): EventHandler.clear, the entries (and with them
; their actions) to limbo. Clobbers rax, rcx, rdx.
events_release:
    mov     rax, [ch_events]
    mov     ecx, [rax + rdi * 4]
.next:
    cmp     ecx, NONE
    je      event_clear
    mov     rdx, rcx
    shl     rdx, 6                      ; ENTRY_SIZE
    add     rdx, [event_entries]
    mov     eax, [rc_entry_limbo]
    dec     eax
    xchg    eax, [rdx + EN_NEXT]
    inc     ecx
    mov     [rc_entry_limbo], ecx
    mov     ecx, eax
    jmp     .next

; recycle_flush: limbo to the free lists. Called by next_frame (lib.asm)
; before the effect's next_frame, when no dispatch or tick is running.
; Preserves rbx, rbp, r12-r15.
recycle_flush:
    mov     eax, [rc_path_limbo]
    or      eax, [rc_scene_limbo]
    or      eax, [rc_entry_limbo]
    jnz     .work
    ret
.work:
    push    rbx
    push    rbp
    push    r12
    push    r13
.path:
    mov     eax, [rc_path_limbo]
    test    eax, eax
    jz      .scene
    lea     ebx, [rax - 1]
    PATH_PTR rbp, rbx
    mov     eax, [rbp + PA_NEXT]
    inc     eax
    mov     [rc_path_limbo], eax
    call    path_recycle
    jmp     .path
.scene:
    mov     eax, [rc_scene_limbo]
    test    eax, eax
    jz      .entry
    lea     ebx, [rax - 1]
    SCENE_PTR rbp, rbx
    mov     eax, [rbp + SC_NEXT]
    inc     eax
    mov     [rc_scene_limbo], eax
    call    scene_recycle
    jmp     .scene
.entry:
    mov     eax, [rc_entry_limbo]
    test    eax, eax
    jz      .done
    dec     eax
    mov     rdx, rax
    shl     rdx, 6
    add     rdx, [event_entries]
    mov     ecx, [rdx + EN_NEXT]
    inc     ecx
    mov     [rc_entry_limbo], ecx
    ; the actions, first to last, onto the action free list
    mov     ecx, [rdx + EN_FIRST]
    cmp     ecx, NONE
    je      .entry_free
    mov     r8d, [rdx + EN_LAST]
    shl     r8, 5                       ; ACTION_SIZE
    add     r8, [event_actions]
    mov     r9d, [rc_action_free]
    dec     r9d
    mov     [r8 + AC_NEXT], r9d
    inc     ecx
    mov     [rc_action_free], ecx
.entry_free:
    mov     ecx, [rc_entry_free]
    dec     ecx
    mov     [rdx + EN_NEXT], ecx
    inc     eax
    mov     [rc_entry_free], eax
    jmp     .entry
.done:
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; path_recycle(ebx=path, rbp=record): recycle_flush for one path - its
; mirror dropped, its arrays zeroed and kept in the record, its bezier
; controls freed, the record onto the free list. Clobbers rax, rcx, rdx,
; rsi, rdi, r8-r11, r12, r13.
path_recycle:
%if TIER >= 3
    ; the owner's mirror may still stand for it
    mov     rax, [path_owners]
    mov     eax, [rax + rbx * 4]
    cmp     eax, MV_LIMIT
    jae     .unmirrored
    MV_P4   rcx, rax
    mov     edx, [rcx + rax * 4 + MVO_TAG]
    xor     edx, MV_TAG_BIT
    cmp     edx, ebx
    jne     .unmirrored
    call    mv_retire
.unmirrored:
%endif
    ; the segments: its own list, or the one parked while it walked a
    ; shared list (never the shared list itself)
    mov     r12, [rbp + PA_SEGS]
    mov     r13d, [rbp + PA_SEG_CAP]
    mov     rax, [rc_path_priv]
    test    rax, rax
    jz      .unparked
    mov     rcx, [rax + rbx * 8]
    test    rcx, rcx
    jz      .unparked
    mov     qword [rax + rbx * 8], 0
    test    dword [rbp + PA_FLAGS], PAF_SHARED
    jz      .segs                       ; it has its own (the parked one is dropped)
    mov     r13, rcx
    shr     r13, RC_CAP_SHIFT
    shl     rcx, 64 - RC_CAP_SHIFT
    shr     rcx, 64 - RC_CAP_SHIFT
    mov     r12, rcx
    jmp     .segs
.unparked:
    test    dword [rbp + PA_FLAGS], PAF_SHARED
    jz      .segs
    xor     r12d, r12d
    xor     r13d, r13d
.segs:
    test    r12, r12
    jnz     .segs_zero
    xor     r13d, r13d
.segs_zero:
    mov     rdi, r12
    imul    ecx, r13d, SEGMENT_SIZE
    xor     eax, eax
    rep     stosb
    mov     [rbp + PA_SEGS], r12
    mov     [rbp + PA_SEG_CAP], r13d
    ; the controls
    cmp     byte [rc_wp_events], 0
    jne     .wps
    test    dword [rbp + PA_FLAGS], PAF_EVER_SHARED
    jnz     .wps
    mov     rsi, [rbp + PA_WPS]
    mov     ecx, [rbp + PA_WP_COUNT]
.bez:
    test    ecx, ecx
    jz      .wps
    mov     rdx, [rsi + WP_BEZ]
    test    rdx, rdx
    jz      .bez_next
    cmp     dword [rsi + WP_BEZ_COUNT], BEZ_BLOCK_COUNT
    ja      .bez_next
    mov     rax, [rc_bez_free]
    mov     [rdx], rax
    mov     [rc_bez_free], rdx
.bez_next:
    add     rsi, WAYPOINT_SIZE
    dec     ecx
    jmp     .bez
.wps:
    mov     rdi, [rbp + PA_WPS]
    mov     ecx, [rbp + PA_WP_CAP]
    test    rdi, rdi
    jnz     .wps_zero
    xor     ecx, ecx
    mov     [rbp + PA_WP_CAP], ecx
.wps_zero:
    shl     ecx, 5                      ; WAYPOINT_SIZE
    xor     eax, eax
    rep     stosb
    ; onto the free list
    mov     eax, [rc_path_free]
    dec     eax
    mov     [rbp + PA_NEXT], eax
    lea     eax, [rbx + 1]
    mov     [rc_path_free], eax
    ret

; scene_recycle(ebx=scene, rbp=record): recycle_flush for one scene - its
; frame block parked for its next life, the record onto its bank's free
; list. Clobbers rax, rcx, rdx, rsi, rdi, r8-r11.
scene_recycle:
    mov     rsi, [rbp + SC_FRAMES]
    test    rsi, rsi
    jz      .free
    mov     r8, [rc_scene_blk]
    test    r8, r8
    jnz     .have_table
    mov     rdi, SCENE_LIMIT * 8
    call    reserve_small
    mov     [rc_scene_blk], rax
    mov     r8, rax
    mov     rsi, [rbp + SC_FRAMES]
.have_table:
    lea     r8, [r8 + rbx * 8]
    xor     eax, eax
    test    dword [rbp + SC_FLAGS], SCF_SYNC
    jnz     .park                       ; share_table may hand them out
    mov     ecx, [rbp + SC_COUNT]
    mov     rdx, [r8]
    mov     rax, rdx
    shl     rax, 64 - RC_CAP_SHIFT
    shr     rax, 64 - RC_CAP_SHIFT
    cmp     rax, rsi
    jne     .own                        ; it moved: the old block is lost
    shr     rdx, RC_CAP_SHIFT
    cmp     edx, ecx
    cmova   ecx, edx
.own:
    xor     eax, eax
    cmp     ecx, RC_CAP_MAX
    ja      .park
    mov     rax, rcx
    shl     rax, RC_CAP_SHIFT
    or      rax, rsi
.park:
    mov     [r8], rax
.free:
    cmp     byte [scene_unbanked], 0
    jne     .done                       ; (vhstape never resets scenes)
    imul    eax, [rbp + SC_NAME], 0x9E3779B1
    shr     eax, 32 - 6                 ; scene_alloc's bank
    lea     rdx, [rc_scene_free]
    lea     rdx, [rdx + rax * 4]
    mov     eax, [rdx]
    dec     eax
    mov     [rbp + SC_NEXT], eax
    lea     eax, [rbx + 1]
    mov     [rdx], eax
.done:
    ret

; ---------------------------------------- the takers (hooks in the owners)

; path_take_free -> eax = a recycled path index, or NONE (path_new). Its
; arrays wait in rc_take_* for path_take_restore. Clobbers rcx, rdx.
path_take_free:
    mov     eax, [rc_path_free]
    test    eax, eax
    jz      .none
    dec     eax
    PATH_PTR rcx, rax
    mov     edx, [rcx + PA_NEXT]
    inc     edx
    mov     [rc_path_free], edx
    mov     rdx, [rcx + PA_WPS]
    mov     [rc_take_wps], rdx
    mov     rdx, [rcx + PA_SEGS]
    mov     [rc_take_segs], rdx
    mov     edx, [rcx + PA_WP_CAP]
    mov     [rc_take_wp_cap], edx
    mov     edx, [rcx + PA_SEG_CAP]
    mov     [rc_take_seg_cap], edx
    ret
.none:
    mov     eax, NONE
    ret

; path_take_restore(r8=new path record): path_new, after zeroing the
; record - a recycled record's empty arrays. Clobbers rax.
path_take_restore:
    mov     rax, [rc_take_wps]
    test    rax, rax
    jz      .segs
    mov     [r8 + PA_WPS], rax
    mov     eax, [rc_take_wp_cap]
    mov     [r8 + PA_WP_CAP], eax
    mov     qword [rc_take_wps], 0
.segs:
    mov     rax, [rc_take_segs]
    test    rax, rax
    jz      .done
    mov     [r8 + PA_SEGS], rax
    mov     eax, [rc_take_seg_cap]
    mov     [r8 + PA_SEG_CAP], eax
    mov     qword [rc_take_segs], 0
.done:
    ret

; bez_alloc(rdi=bytes) -> rax: alloc for a waypoint's bezier controls
; (path_new_waypoint), from the freed 64-byte blocks when they fit.
; Clobbers rdi.
bez_alloc:
    cmp     rdi, BEZ_BLOCK_COUNT * 8
    ja      alloc
    mov     rax, [rc_bez_free]
    test    rax, rax
    jz      alloc
    mov     rdi, [rax]
    mov     [rc_bez_free], rdi
%assign bz 0
%rep 8
    mov     qword [rax + bz], 0
%assign bz bz + 8
%endrep
    ret

; path_park_segs(rbp=path record): path_seg_share, as the path starts
; walking a shared list - its own list is parked for path_unshare (or its
; next life) instead of dropped. Preserves rsi; clobbers rax, rcx, rdx, rdi,
; r8-r11.
path_park_segs:
    or      dword [rbp + PA_FLAGS], PAF_EVER_SHARED
    mov     rax, [rc_path_priv]
    test    rax, rax
    jnz     .have_table
    push    rsi
    mov     rdi, PATH_LIMIT * 8
    call    reserve_small
    pop     rsi
    mov     [rc_path_priv], rax
.have_table:
    mov     rcx, rbp
    sub     rcx, [paths]
    shr     rcx, 7                      ; PATH_SIZE
    cmp     qword [rax + rcx * 8], 0
    jne     .done                       ; one parked already: this one is lost
    mov     edx, [rbp + PA_SEG_CAP]
    cmp     edx, RC_CAP_MAX
    ja      .done
    shl     rdx, RC_CAP_SHIFT
    or      rdx, [rbp + PA_SEGS]
    mov     [rax + rcx * 8], rdx
.done:
    ret

; path_unpark_segs(rbp=path record, edi=bytes) -> rax: path_unshare's
; alloc for its own list - the parked one when it is big enough (then
; PA_SEG_CAP is its capacity), zeroed. Clobbers rcx, rdx, rdi, rsi.
path_unpark_segs:
    mov     rax, [rc_path_priv]
    test    rax, rax
    jz      alloc
    mov     rcx, rbp
    sub     rcx, [paths]
    shr     rcx, 7
    lea     rsi, [rax + rcx * 8]
    mov     rdx, [rsi]
    test    rdx, rdx
    jz      alloc
    mov     rax, rdx
    shr     rax, RC_CAP_SHIFT
    imul    ecx, eax, SEGMENT_SIZE
    cmp     ecx, edi
    jb      alloc
    mov     [rbp + PA_SEG_CAP], eax
    mov     qword [rsi], 0
    shl     rdx, 64 - RC_CAP_SHIFT
    shr     rdx, 64 - RC_CAP_SHIFT
    mov     rdi, rdx
    xor     eax, eax
    rep     stosb
    mov     rax, rdx
    ret

; scene_take_free(r12d=name) -> eax = a recycled scene index from the
; name's bank, or NONE (scene_alloc). Clobbers rcx, rdx.
scene_take_free:
    cmp     byte [scene_unbanked], 0
    jne     .none
    imul    eax, r12d, 0x9E3779B1
    shr     eax, 32 - 6
    lea     rdx, [rc_scene_free]
    lea     rdx, [rdx + rax * 4]
    mov     eax, [rdx]
    test    eax, eax
    jz      .none
    dec     eax
    SCENE_PTR rcx, rax
    mov     ecx, [rcx + SC_NEXT]
    inc     ecx
    mov     [rdx], ecx
    ret
.none:
    mov     eax, NONE
    ret

; scene_append_recycled(r8=scene record, eax=handle, edx=duration,
; ecx=SC_COUNT) -> CF set when the frame went into the scene's reused
; frame block: scene_append_frame's append, in place, for a record whose
; last life left a block with room. CF clear: nothing done, rcx kept.
; Preserves rax, rdx, r8; clobbers rsi, rdi, r9.
scene_append_recycled:
    mov     r9, [rc_scene_blk]
    test    r9, r9
    jz      .no
    mov     rsi, r8
    sub     rsi, [scenes]
    shr     rsi, SCENE_SHIFT
    mov     r9, [r9 + rsi * 8]
    test    r9, r9
    jz      .no
    mov     rsi, r9
    shr     rsi, RC_CAP_SHIFT
    cmp     ecx, esi
    jae     .no                         ; full: it moves to the region's end
    shl     r9, 64 - RC_CAP_SHIFT
    shr     r9, 64 - RC_CAP_SHIFT
    mov     rsi, [r8 + SC_FRAMES]
    test    rsi, rsi
    jnz     .placed
    test    ecx, ecx
    jnz     .no
    mov     [r8 + SC_FRAMES], r9
    mov     rsi, r9
.placed:
    cmp     rsi, r9
    jne     .no
    lea     rdi, [rsi + rcx * FRAME_SIZE]
    mov     r9d, edx
    shl     r9, 32
    mov     esi, eax
    or      r9, rsi
    mov     [rdi], r9                   ; FR_HANDLE, FR_DURATION
    add     [r8 + SC_EASE_TOTAL], edx
    lea     esi, [rcx + 1]
    mov     [r8 + SC_COUNT], esi
    and     dword [r8 + SC_FLAGS], ~(SCF_SHAPE | SCF_SHARED)
    cmp     ecx, [r8 + SC_HEAD]
    jne     .done
    mov     [r8 + SC_HEAD_HANDLE], eax
    mov     [r8 + SC_HEAD_DURATION], edx
    mov     dword [r8 + SC_TICKS], 0
.done:
    stc
    ret
.no:
    clc
    ret

; entry_take_free(edi=caller kind) -> eax = a recycled, zeroed event entry,
; or NONE (event_register). Clobbers rcx, rdx.
entry_take_free:
    cmp     edi, CALLER_WAYPOINT
    jne     .take
    mov     byte [rc_wp_events], 1      ; entries copy control pointers
.take:
    mov     eax, [rc_entry_free]
    test    eax, eax
    jz      .none
    dec     eax
    mov     rcx, rax
    shl     rcx, 6
    add     rcx, [event_entries]
    mov     edx, [rcx + EN_NEXT]
    inc     edx
    mov     [rc_entry_free], edx
%assign ez 0
%rep ENTRY_SIZE / 8
    mov     qword [rcx + ez], 0
%assign ez ez + 8
%endrep
    ret
.none:
    mov     eax, NONE
    ret

; action_take_free -> eax = a recycled, zeroed event action, or NONE
; (event_register). Clobbers rcx.
action_take_free:
    mov     eax, [rc_action_free]
    test    eax, eax
    jz      .none
    dec     eax
    mov     rcx, rax
    shl     rcx, 5
    add     rcx, [event_actions]
    push    rcx
    mov     ecx, [rcx + AC_NEXT]
    inc     ecx
    mov     [rc_action_free], ecx
    pop     rcx
%assign az 0
%rep ACTION_SIZE / 8
    mov     qword [rcx + az], 0
%assign az az + 8
%endrep
    ret
.none:
    mov     eax, NONE
    ret

section .tstate
alignb 8
rc_path_priv:   resq 1                  ; u64 per path: its own segments, parked
rc_scene_blk:   resq 1                  ; u64 per scene: its last life's frames
rc_bez_free:    resq 1                  ; 64-byte control blocks, linked
rc_take_wps:    resq 1                  ; path_take_free -> path_take_restore
rc_take_segs:   resq 1
rc_take_wp_cap: resd 1
rc_take_seg_cap: resd 1
; list heads: index + 1, 0 = empty; linked through the record's next field
rc_path_limbo:  resd 1
rc_path_free:   resd 1
rc_scene_limbo: resd 1
rc_entry_limbo: resd 1
rc_entry_free:  resd 1
rc_action_free: resd 1
rc_scene_free:  resd SCENE_BANKS
rc_wp_events:   resb 1                  ; an event is keyed by a waypoint

section .rodata
STR msg_pool_symbols, "ParticlePool requires at least one symbol."
STR msg_pool_max, "max_size must be greater than or equal to initial_count."
