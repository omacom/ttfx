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

; The instruction-set budget (PORTING.md "CPU tiers"). Only TIER 1 has a
; NASM CPU level that fits: NASM 3.02's levels stop at Ivy Bridge, do not
; flag BMI or LZCNT, and its nehalem/westmere levels reject SSSE3 and SSE4.
; tools/asm/isa-audit.sh checks every tier's object exactly. build.rs passes
; -DTTFX_NO_CPU_CHECK for its unchecked dev build.
%ifndef TTFX_NO_CPU_CHECK
%if TIER == 1
cpu x86-64
%endif
%endif

; EXPORT name: a SysV entry point. Every tier's object exports it as
; name_v<TIER>, so the four objects link side by side; within the file the
; plain name keeps working. Reference the name's local labels through a
; ..@ label, since name.local is one token that does not expand.
%macro EXPORT 1
%xdefine %1 %1 %+ _v %+ TIER
global %1
%endmacro

; ZEROUPPER: vzeroupper where VEX code may have dirtied the upper halves
; (TIER 3+); nothing below that.
%macro ZEROUPPER 0
%if TIER >= 3
    vzeroupper
%endif
%endmacro

; FLOORSD xmm, gpr64, xmm_tmp: xmm = floor(xmm), bit for bit roundsd's mode 1
; for every finite value, zero and infinity (NaN passes through unchanged,
; where roundsd would quiet a signalling one). TIER 1 uses cvttsd2si, which
; is exact below 2^52; at and above 2^52 every double is already integral.
; Clobbers the gpr, xmm_tmp and flags.
%macro FLOORSD 3
%if TIER >= 2
    roundsd %1, %1, 1
%else
    movq    %2, %1
    add     %2, %2                      ; drop the sign; zero is its own floor
    jz      %%done
    shr     %2, 53
    cmp     %2, 0x433                   ; |x| >= 2^52, infinity or NaN
    jae     %%done
    cvttsd2si %2, %1
    cvtsi2sd %3, %2
    ucomisd %3, %1
    jbe     %%store                     ; trunc(x) <= x: that is the floor
    dec     %2
    cvtsi2sd %3, %2
%%store:
    movapd  %1, %3
%%done:
%endif
%endmacro

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

; ------------------------------------------------------------- engine records
%define NONE                -1          ; "no scene/path/character" sentinel
%define AUTO                -1          ; "generate the next auto id" for names

; Names of scenes, paths and waypoints are u32. Rust's auto ids are decimal
; strings "0", "1", ...; those are the numbers themselves. Effects give their
; literal names (e.g. "fast_decrypt") constants from NAME_LITERAL up.
%define NAME_LITERAL        0x80000000

; scene record: a 32-byte hot half (what a tick touches) at [scenes] +
; index * 32, and a 32-byte cold half at a fixed distance past it in the same
; reservation, so cold fields are plain displacements from the same pointer.
%define SCENE_LIMIT         (1 << 24)
%define SCENE_SIZE          32
%define SCENE_SHIFT         5
%define SCENE_COLD          (SCENE_LIMIT * SCENE_SIZE + 2080)  ; off the hot half's page offset
%define SC_FRAMES           0           ; u64 pointer to the frame array
%define SC_COUNT            8           ; u32 frames
%define SC_HEAD             12          ; u32 head of the remaining-frames queue
%define SC_TICKS            16          ; u32 ticks_elapsed of the head frame
%define SC_HEAD_HANDLE      20          ; u32 the head frame's visual (cached)
%define SC_HEAD_DURATION    24          ; u32 the head frame's duration (cached)
%define SC_FLAGS            28          ; u32 SCF_*
%define SC_NAME             SCENE_COLD + 0   ; u32
%define SC_NEXT             SCENE_COLD + 4   ; i32 next scene of the same character
%define SC_EASE             SCENE_COLD + 8   ; u32 easing id (SCF_EASED)
%define SC_EASE_TOTAL       SCENE_COLD + 12  ; u32 easing_total_steps
%define SC_EASE_STEP        SCENE_COLD + 16  ; u32 easing_current_step
%define SC_OWNER            SCENE_COLD + 20  ; u32 character slot
%define SC_CURSOR           SCENE_COLD + 24  ; u32 eased lookup cursor: a frame ...
%define SC_CURSOR_START     SCENE_COLD + 28  ; u32 ... and its first tick
; a scene's preexisting colors (SCF_PREEXISTING) live in [scene_pre]:
; 16 bytes per scene, fg then bg

%define SCF_LOOPING         1
%define SCF_SYNC_STEP       2
%define SCF_SYNC_DISTANCE   4
%define SCF_EASED           8
%define SCF_PREEXISTING     16
%define SCF_PRE_BOLD        32
%define SCF_SYNC            (SCF_SYNC_STEP | SCF_SYNC_DISTANCE)

; frame record (FRAME_SIZE bytes)
%define FRAME_SIZE          8
%define FRAME_SHIFT         3
%define FR_HANDLE           0           ; u32 visual
%define FR_DURATION         4           ; u32 ticks

; path record (PATH_SIZE bytes; index into [paths])
%define PATH_SIZE           128
%define PA_NAME             0           ; u32
%define PA_NEXT             4           ; i32 next path of the same character
%define PA_SPEED            8           ; f64
%define PA_EASE             16          ; i32 easing id or NONE
%define PA_LAYER            20          ; i32 (PAF_LAYER)
%define PA_FLAGS            24          ; u32 PAF_*
%define PA_OWNER            28          ; u32 character slot
%define PA_HOLD             32          ; i64 hold_time
%define PA_HOLD_LEFT        40          ; i64 hold_time_remaining
%define PA_TOTAL            48          ; f64 total_distance
%define PA_STEP             56          ; i64 current_step
%define PA_MAX              64          ; i64 max_steps
%define PA_LAST             72          ; f64 last_distance_reached
%define PA_ORIGIN_DIST      80          ; f64 origin segment distance (PAF_ORIGIN)
%define PA_SEGS             88          ; u64 pointer to segments
%define PA_SEG_COUNT        96          ; u32
%define PA_SEG_CAP          100         ; u32
%define PA_WPS              104         ; u64 pointer to waypoints
%define PA_WP_COUNT         112         ; u32
%define PA_WP_CAP           116         ; u32

%define PAF_LAYER           1
%define PAF_LOOP            2
%define PAF_ORIGIN          4

; waypoint record (WAYPOINT_SIZE bytes) - also a waypoint event key
%define WAYPOINT_SIZE       32
%define WP_COORD            0           ; u64 packed coordinate
%define WP_NAME             8           ; u32
%define WP_BEZ_COUNT        12          ; u32 bezier control points
%define WP_BEZ              16          ; u64 pointer to packed coordinates, 0 if none

; segment record (SEGMENT_SIZE bytes): start and end waypoints by value
%define SEGMENT_SIZE        80
%define SG_START            0
%define SG_END              32
%define SG_DISTANCE         64          ; f64
%define SG_ENTERED          72          ; u8 enter_event_triggered
%define SG_EXITED           73          ; u8 exit_event_triggered

; events (Event enum order)
%define EV_SEGMENT_ENTERED  0
%define EV_SEGMENT_EXITED   1
%define EV_PATH_ACTIVATED   2
%define EV_PATH_COMPLETE    3
%define EV_PATH_HOLDING     4
%define EV_SCENE_ACTIVATED  5
%define EV_SCENE_COMPLETE   6

%define CALLER_SCENE        1           ; caller = scene name
%define CALLER_PATH         2           ; caller = path name
%define CALLER_WAYPOINT     3           ; caller = pointer to a waypoint record

; event entry (ENTRY_SIZE bytes; index into [event_entries])
%define ENTRY_SIZE          64
%define EN_NEXT             0           ; i32 next entry of the same character
%define EN_EVENT            4           ; u8
%define EN_KIND             5           ; u8 CALLER_*
%define EN_WAYPOINT         8           ; waypoint key (WAYPOINT_SIZE) or name at +8
%define EN_FIRST            40          ; i32 first action
%define EN_LAST             44          ; i32 last action

; event action (ACTION_SIZE bytes; index into [event_actions])
%define ACTION_SIZE         32
%define AC_KIND             0           ; u32 ACT_*
%define AC_NEXT             4           ; i32
%define AC_ARG0             8
%define AC_ARG1             16

%define ACT_ACTIVATE_PATH       1       ; arg0 = path name
%define ACT_ACTIVATE_SCENE      2       ; arg0 = scene name
%define ACT_DEACTIVATE_PATH     3       ; arg0 = path name or NONE (any)
%define ACT_DEACTIVATE_SCENE    4       ; arg0 = scene name or NONE (any)
%define ACT_RESET_APPEARANCE    5
%define ACT_SET_LAYER           6       ; arg0 = layer
%define ACT_SET_COORDINATE      7       ; arg0 = packed coordinate
%define ACT_CALLBACK            8       ; arg0 = fn(edi=slot, rsi=arg1), arg1 = payload

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
