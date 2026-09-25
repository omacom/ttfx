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
    call    reserve
    mov     [rbx + POOL.available], rax
    mov     rdi, POOL_CAPACITY * 4
    call    reserve
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
    mov     rax, [ch_paths]
    mov     dword [rax + rbx * 4], NONE
.scenes:
    test    r12d, RESET_CLEAR_SCENES
    jz      .events
    mov     rax, [ch_scenes]
    mov     dword [rax + rbx * 4], NONE
.events:
    test    r12d, RESET_CLEAR_EVENTS
    jz      .appearance
    mov     edi, ebx
    call    event_clear
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

section .rodata
STR msg_pool_symbols, "ParticlePool requires at least one symbol."
STR msg_pool_max, "max_size must be greater than or equal to initial_count."
