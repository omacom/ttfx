%define MAX_REGIONS 64

; rt/sys.asm - raw syscall runtime: output, memory, tty queries, signals,
; clock. Replaces what std and libc provide to the Rust binary.

section .text

extern pthread_create
extern pthread_join
extern pthread_sigmask
extern getenv

; write_all(edi=fd, rsi=ptr, rdx=len) -> rax = 0, or -errno on failure.
; Retries short writes and EINTR, like Write::write_all.
write_all:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    test    r13, r13
    jz      .done
    mov     edi, ebx
    mov     rsi, r12
    mov     rdx, r13
    SYSCALL SYS_write
    cmp     rax, -EINTR
    je      .loop
    test    rax, rax
    js      .out
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.done:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; writev_all(rdi=iovec array, esi=count) -> rax = 0, or -errno on failure.
; Retries short writes (advancing through the vectors) and EINTR. The array
; is consumed in place.
writev_all:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12d, esi
.loop:
    ; skip vectors that are already empty
    test    r12d, r12d
    jz      .done
    cmp     qword [rbx + 8], 0
    jne     .write
    add     rbx, 16
    dec     r12d
    jmp     .loop
.write:
    mov     edi, 1
    mov     rsi, rbx
    mov     edx, r12d
    mov     eax, 1024                   ; IOV_MAX
    cmp     edx, eax
    cmova   edx, eax
    SYSCALL SYS_writev
    cmp     rax, -EINTR
    je      .loop
    test    rax, rax
    js      .out
.consume:
    test    rax, rax
    jz      .loop
    mov     rcx, [rbx + 8]
    cmp     rax, rcx
    jb      .partial
    sub     rax, rcx
    mov     qword [rbx + 8], 0
    add     rbx, 16
    dec     r12d
    jmp     .consume
.partial:
    add     [rbx], rax
    sub     [rbx + 8], rax
    jmp     .loop
.done:
    xor     eax, eax
.out:
    pop     r12
    pop     rbx
    ret

; exit(edi=code) - never returns.
exit:
    SYSCALL SYS_exit_group
    ud2

; reserve(rdi=bytes) -> rax = base of a lazily committed read/write mapping.
; Regions are sized far beyond need and never move, so pointers into them
; stay valid for the whole run (plan §7.1). They are recorded so the next run
; (after a terminal resize) can release them first.
;
; The regions are huge and mmap packs them together, so without care every
; region's base has the same low 28 bits: a slot's entries in all the
; character field arrays would share one cache set, and a load from one
; array would wait on a store to another (4K aliasing). Each region's base
; is therefore staggered by region_index * (4096 + 192) bytes, which gives
; every region its own 64-byte line offset within a page.
%define REGION_STAGGER  (4096 + 192)
reserve:
    mov     eax, [region_count]
    imul    eax, eax, REGION_STAGGER
    add     rdi, rax                    ; the stagger comes out of the region
    push    rax
    push    rdi
    mov     rsi, rdi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
    mov     r8, -1
    xor     r9d, r9d
    SYSCALL SYS_mmap
    pop     rdi
    pop     rsi                         ; stagger
    cmp     rax, -4096
    ja      .fail
    mov     ecx, [region_count]
    cmp     ecx, MAX_REGIONS
    jae     .fail
    lea     rdx, [regions]
    shl     ecx, 4
    mov     [rdx + rcx], rax
    mov     [rdx + rcx + 8], rdi
    inc     dword [region_count]
    add     rax, rsi
    ret
.fail:
    lea     rdi, [msg_oom]
    mov     esi, msg_oom_len
    jmp     fatal

; release_regions: unmap everything a previous run reserved.
release_regions:
    push    rbx
    xor     ebx, ebx
.next:
    cmp     ebx, [region_count]
    jae     .done
    lea     rax, [regions]
    mov     ecx, ebx
    shl     ecx, 4
    mov     rdi, [rax + rcx]
    mov     rsi, [rax + rcx + 8]
    SYSCALL SYS_munmap
    inc     ebx
    jmp     .next
.done:
    mov     dword [region_count], 0
    pop     rbx
    ret

; fatal(rdi=message, esi=length): an internal limit was hit; there is no
; sensible way to continue, so report it and exit like a Rust panic would
; (after the frames already handed to the render thread are out).
fatal:
    push    rdi
    push    rsi
    call    pipeline_finish
    pop     rsi
    pop     rdi
    mov     rdx, rsi
    mov     rsi, rdi
    mov     edi, 2
    call    write_all
    mov     edi, 101
    jmp     exit

; alloc(rdi=bytes) -> rax = 64-byte aligned, zeroed memory from the arena.
alloc:
    mov     rax, [arena_ptr]
    add     rdi, 63
    and     rdi, -64
    add     rdi, rax
    mov     [arena_ptr], rdi
    ret

; isatty(edi=fd) -> eax = 1 when the descriptor is a terminal (TCGETS works).
isatty:
    sub     rsp, 64
    mov     esi, TCGETS
    mov     rdx, rsp
    SYSCALL SYS_ioctl
    add     rsp, 64
    test    rax, rax
    sete    al
    movzx   eax, al
    ret

; winsize(edi=fd) -> eax = columns, edx = rows; both 0 when unavailable.
winsize:
    sub     rsp, 16
    mov     esi, TIOCGWINSZ
    mov     rdx, rsp
    SYSCALL SYS_ioctl
    test    rax, rax
    jnz     .none
    movzx   edx, word [rsp]             ; ws_row
    movzx   eax, word [rsp + 2]         ; ws_col
    add     rsp, 16
    ret
.none:
    xor     eax, eax
    xor     edx, edx
    add     rsp, 16
    ret

; monotonic_ns -> rax = CLOCK_MONOTONIC in nanoseconds.
monotonic_ns:
    sub     rsp, 16
    mov     edi, CLOCK_MONOTONIC
    mov     rsi, rsp
    SYSCALL SYS_clock_gettime
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp + 8]
    add     rsp, 16
    ret

; realtime_s -> xmm0 = CLOCK_REALTIME in seconds (SystemTime::now()).
realtime_s:
    sub     rsp, 16
    mov     edi, CLOCK_REALTIME
    mov     rsi, rsp
    SYSCALL SYS_clock_gettime
    cvtsi2sd xmm0, qword [rsp]
    cvtsi2sd xmm1, qword [rsp + 8]
    divsd   xmm1, [one_billion]
    addsd   xmm0, xmm1
    add     rsp, 16
    ret

; sleep_ns(rdi=nanoseconds). Resumes after signals, like thread::sleep.
sleep_ns:
    sub     rsp, 32
    mov     rax, rdi
    xor     edx, edx
    mov     ecx, 1000000000
    div     rcx
    mov     [rsp], rax
    mov     [rsp + 8], rdx
.again:
    mov     rdi, rsp
    lea     rsi, [rsp + 16]
    SYSCALL SYS_nanosleep
    cmp     rax, -EINTR
    jne     .done
    mov     rax, [rsp + 16]
    mov     [rsp], rax
    mov     rax, [rsp + 24]
    mov     [rsp + 8], rax
    jmp     .again
.done:
    add     rsp, 32
    ret

; ------------------------------------------------------------------ threads
; The render thread (render.asm) is a pthread: glibc is linked, and a raw
; clone would bypass its thread setup inside the Rust process.

; futex_wait(rdi=32-bit word, esi=expected): sleep while the word holds the
; expected value, until a futex_wake. May return early (a signal, a race);
; callers recheck.
futex_wait:
    mov     edx, esi
    mov     esi, FUTEX_WAIT_PRIVATE
    xor     r10d, r10d
    SYSCALL SYS_futex
    ret

; futex_wake(rdi=32-bit word): wake a thread sleeping on it.
futex_wake:
    mov     esi, FUTEX_WAKE_PRIVATE
    mov     edx, 1
    SYSCALL SYS_futex
    ret

; thread_start(rdi=start routine, rsi=pthread_t out) -> eax = 0, or an
; error number. The thread starts with every asynchronous signal blocked:
; the Rust handlers only set flags that the main thread's stop checks read,
; so SIGINT, SIGTERM and SIGWINCH must reach the main thread. Signals the
; thread raises itself stay deliverable: SIGPIPE from a write to a closed
; pipe must still end the process by default, as it does single-threaded,
; and faults must not be held pending. Clobbers C.
thread_start:
    push    rbx
    push    r12
    sub     rsp, 264                    ; the thread's mask, then main's
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rsp
    mov     rax, -1
    mov     ecx, 16
    rep     stosq
    mov     rax, ~((1 << (SIGPIPE - 1)) | (1 << (SIGSEGV - 1)) | (1 << (SIGBUS - 1)) | (1 << (SIGILL - 1)) | (1 << (SIGFPE - 1)) | (1 << (SIGTRAP - 1)))
    and     [rsp], rax
    mov     edi, SIG_SETMASK
    mov     rsi, rsp
    lea     rdx, [rsp + 128]
    ZEROUPPER
    CCALL   pthread_sigmask
    mov     rdi, r12
    xor     esi, esi
    mov     rdx, rbx
    xor     ecx, ecx
    CCALL   pthread_create
    mov     ebx, eax
    mov     edi, SIG_SETMASK
    lea     rsi, [rsp + 128]
    xor     edx, edx
    CCALL   pthread_sigmask
    mov     eax, ebx
    add     rsp, 264
    pop     r12
    pop     rbx
    ret

; thread_join(rdi=pthread_t): wait for the thread to end. Clobbers C.
thread_join:
    xor     esi, esi
    ZEROUPPER
    CCALL   pthread_join
    ret

; ----------------------------------------------------------------- utilities

; utf8_decode(rsi=ptr to valid UTF-8) -> eax = codepoint, edx = byte length.
utf8_decode:
    movzx   eax, byte [rsi]
    cmp     eax, 0x80
    jb      .one
    cmp     eax, 0xE0
    jb      .two
    cmp     eax, 0xF0
    jb      .three
    and     eax, 0x07
    mov     edx, 4
    jmp     .tail
.three:
    and     eax, 0x0F
    mov     edx, 3
    jmp     .tail
.two:
    and     eax, 0x1F
    mov     edx, 2
.tail:
    mov     ecx, 1
.more:
    shl     eax, 6
    movzx   r8d, byte [rsi + rcx]
    and     r8d, 0x3F
    or      eax, r8d
    inc     ecx
    cmp     ecx, edx
    jb      .more
    ret
.one:
    mov     edx, 1
    ret

; format_u64(rdi=buffer with >= 20 bytes, rsi=value) -> rax = length written.
format_u64:
    sub     rsp, 32
    lea     r8, [rsp + 32]
    mov     rax, rsi
    mov     ecx, 10
.loop:
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    test    rax, rax
    jnz     .loop
    lea     rcx, [rsp + 32]
    sub     rcx, r8
    xor     edx, edx
.copy:
    mov     al, [r8 + rdx]
    mov     [rdi + rdx], al
    inc     rdx
    cmp     rdx, rcx
    jb      .copy
    mov     rax, rcx
    add     rsp, 32
    ret

; format_i64(rdi=buffer with >= 21 bytes, rsi=value) -> rax = length written.
format_i64:
    test    rsi, rsi
    jns     format_u64
    mov     byte [rdi], '-'
    inc     rdi
    neg     rsi
    call    format_u64
    inc     rax
    ret

section .rodata
align 8
one_billion: dq 1.0e9
STR msg_oom, "ttfx: out of memory (asm engine)", 10


; Persistent across runs (not in the per-run state).
section .bss
alignb 8
regions:        resq 2 * MAX_REGIONS
region_count:   resd 1

section .tstate
arena_ptr:      resq 1
