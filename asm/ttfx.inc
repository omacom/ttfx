; ttfx.inc - constants, register conventions and macros shared by every
; ttfx-asm source file. See plans/asm-x86.md.
;
; Conventions (plan §4): SysV-shaped register use. Arguments in rdi, rsi, rdx,
; rcx, r8, r9; results in rax / xmm0; rbx, rbp, r12-r15 are callee-saved.
; Nothing here calls C, so the stack only needs 8-byte alignment; no code uses
; aligned vector accesses to the stack.
;
; MXCSR stays at its power-on default (round-to-nearest-even, no FTZ/DAZ) and
; no engine code uses FMA, so float results match the Rust oracle bit for bit.

%ifndef TTFX_INC
%define TTFX_INC

%ifndef TIER
%define TIER 4                  ; 4 = x86-64-v4 (AVX-512), tuned for Zen 5
%endif

default rel
bits 64

; ---------------------------------------------------------------- syscalls
%define SYS_read            0
%define SYS_write           1
%define SYS_close           3
%define SYS_mmap            9
%define SYS_rt_sigaction    13
%define SYS_rt_sigreturn    15
%define SYS_ioctl           16
%define SYS_writev          20
%define SYS_nanosleep       35
%define SYS_getpid          39
%define SYS_kill            62
%define SYS_clock_gettime   228
%define SYS_exit_group      231
%define SYS_openat          257

%define AT_FDCWD            -100
%define O_RDONLY            0
%define O_CLOEXEC           0x80000

%define PROT_RW             3
%define MAP_PRIVATE         0x02
%define MAP_ANONYMOUS       0x20
%define MAP_NORESERVE       0x4000

%define TCGETS              0x5401
%define TIOCGWINSZ          0x5413

%define SIGINT              2
%define SIGPIPE             13
%define SIGTERM             15
%define SA_RESTART          0x10000000
%define SA_RESTORER         0x04000000
%define SIG_DFL             0

%define EINTR               4
%define EIO                 5
%define EPIPE               32

%define CLOCK_MONOTONIC     1

%include "effects/ids.inc"

%define NONE_I64            0x8000000000000001  ; "absent" for i64 values
%define MADV_DONTNEED       4
%define SYS_munmap          11
%define SYS_madvise         28
%define CLOCK_REALTIME      0

; ------------------------------------------------------------ the request
; struct Request (src/asm/mod.rs), all fields 8 bytes.
%define RQ_INPUT_PTR        0
%define RQ_INPUT_LEN        8
%define RQ_EFFECT           16          ; effect id (EFFECT_* below)
%define RQ_EFFECT_CONFIG    24          ; pointer to the effect's config struct
%define RQ_TAB_WIDTH        32
%define RQ_FRAME_RATE       40
%define RQ_CANVAS_WIDTH     48
%define RQ_CANVAS_HEIGHT    56
%define RQ_ANCHOR_CANVAS    64          ; Anchor enum order: n ne e se s sw w nw c
%define RQ_ANCHOR_TEXT      72
%define RQ_EXISTING_COLORS  80          ; 0 always, 1 dynamic, 2 ignore
%define RQ_BACKGROUND       88          ; color (format below)
%define RQ_FLAGS            96
%define RQ_MAX_FRAMES       104         ; -1 = no limit
%define RQ_TERM_WIDTH       112
%define RQ_TERM_HEIGHT      120
%define RQ_RNG_STATE        128         ; 4 x u64, read at start, written back
%define RQ_STOP_CHECK       160         ; extern "C" fn(ctx) -> u64 (STOP_*)
%define RQ_STOP_CTX         168
%define RQ_LINE_LENGTHS     176         ; out: *const i64 pre-wrap line lengths
%define RQ_LINE_COUNT       184         ; out
%define RQ_ERROR_PTR        192         ; out: message or ANSI sequence bytes
%define RQ_ERROR_LEN        200         ; out
%define RQ_ERROR_KIND       208         ; out: ERR_*

; RQ_FLAGS bits
%define FL_XTERM_COLORS     0
%define FL_NO_COLOR         1
%define FL_WRAP_TEXT        2
%define FL_IGNORE_DIMS      3
%define FL_REUSE_CANVAS     4
%define FL_NO_EOL           5
%define FL_NO_RESTORE       6
%define FL_PARITY_DUMP      7
%define FL_VIRTUAL_CLOCK    8
%define FL_TTY_OUTPUT       9

; ttfx_asm_run outcomes; negative values are -errno from a failed write
%define OUT_DECLINED        0
%define OUT_COMPLETE        1
%define OUT_INTERRUPTED     2
%define OUT_TERMINATED      3
%define OUT_RESIZED         4
%define OUT_OUTPUT_CLOSED   5
%define OUT_ERROR           6

; stop_check results
%define STOP_NONE           0
%define STOP_INTERRUPT      1
%define STOP_TERMINATE      2
%define STOP_RESIZE         3

%define ERR_ANSI            1           ; error bytes are the unsupported sequence
%define ERR_MESSAGE         2           ; error bytes are the message

; Colors are u64: 0xRRGGBB in the low 24 bits; a color built from an xterm
; code (Color::from_xterm) also carries that code in bits 32-39 and bit 40.
%define COLOR_XTERM_BIT     40

; ------------------------------------------------------------- engine sizes
%define NONE                -1          ; "no scene" / "no action" sentinel
%define SCENE_SIZE          32          ; bytes per scene record
%define FRAME_SIZE          8           ; bytes per frame record
%define ACTION_SIZE         16          ; bytes per event action record

; scene record layout (SCENE_SIZE bytes)
%define SC_FRAMES           0           ; u32 index of the first frame
%define SC_COUNT            4           ; u32 number of frames
%define SC_HEAD             8           ; u32 head of the remaining-frames queue
%define SC_TICKS            12          ; u32 ticks_elapsed of the head frame
%define SC_HEAD_HANDLE      16          ; u32 the head frame's visual (cached)
%define SC_HEAD_DURATION    20          ; u32 the head frame's duration (cached)
%define SC_ON_COMPLETE      24          ; i32 first SCENE_COMPLETE action, NONE if none
%define SC_FLAGS            28          ; u32 bit 0: looping
%define SC_LOOPING          1

; frame record layout (FRAME_SIZE bytes)
%define FR_HANDLE           0           ; u32 visual handle
%define FR_DURATION         4           ; u32 duration in ticks

; action record layout (ACTION_SIZE bytes)
%define AC_KIND             0           ; u32 action kind
%define AC_ARG              4           ; u32 argument (scene index, ...)
%define AC_NEXT             8           ; i32 next action in the list, NONE at the end
%define ACT_ACTIVATE_SCENE  1

; A visual handle packs its pool offset (low 24 bits) and byte length (high 8).
%define HANDLE_OFFSET_MASK  0x00ffffff
%define HANDLE_LEN_SHIFT    24
%define POOL_LIMIT          0x00ffff00  ; offsets must stay below this

; ------------------------------------------------------------------ macros
%macro SYSCALL 1
    mov     eax, %1
    syscall
%endmacro

; CCALL fn: call a C function (libm, a Rust callback) with the stack aligned
; as the SysV ABI requires. Arguments must already be in place. The callee
; clobbers rax, rcx, rdx, rsi, rdi, r8-r11 and every vector register.
%macro CCALL 1
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    call    %1
    mov     rsp, rbp
    pop     rbp
%endmacro

; FAIL label: return OUT_ERROR from ttfx_asm_run with the message at label
; (label_len must exist), unwinding whatever the engine was doing.
%macro FAIL 1
    lea     rdi, [%1]
    mov     esi, %1_len
    jmp     engine_fail
%endmacro

; Write a constant string to a file descriptor, ignoring failures.
%macro PUTS 2                           ; fd, label (label_len must exist)
    mov     edi, %1
    lea     rsi, [%2]
    mov     edx, %2_len
    call    write_all
%endmacro

; Define a string constant and its length.
%macro STR 2+
%1: db %2
%1_len equ $ - %1
%endmacro

; set_handle(edi=slot, eax=handle): the character's current visual changes;
; its cell shows the new visual at once if it owns that cell.
; Clobbers rcx, rdx.
; MARK_CANDIDATE: slot edi may have stopped being active; the next prune
; re-checks it. Clobbers rax, rcx, rdx.
%macro MARK_CANDIDATE 0
    mov     rax, [candidate_bits]
    mov     ecx, edi
    shr     ecx, 6
    mov     edx, edi
    and     edx, 63
    bts     qword [rax + rcx * 8], rdx
%endmacro

; SET_HANDLE: slot edi's current visual becomes handle eax. When the
; character owns its grid cell, the cell shows the new visual at once and,
; if that changed anything, its row is marked for re-emission.
; Clobbers rcx, rdx.
%macro SET_HANDLE 0
    mov     rcx, [ch_handle]
    mov     [rcx + rdi * 4], eax
    mov     rcx, [ch_cell]
    mov     ecx, [rcx + rdi * 4]
    cmp     ecx, NONE
    je      %%done
    mov     rdx, [slot_grid]
    cmp     [rdx + rcx * 4], edi
    jne     %%done
    mov     rdx, [handle_grid]
    cmp     [rdx + rcx * 4], eax
    je      %%done
    mov     [rdx + rcx * 4], eax
    mov     rdx, [dirty_cells]
    mov     byte [rdx + rcx], 1
%%done:
%endmacro


%endif
