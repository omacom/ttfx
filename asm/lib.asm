; lib.asm - the ttfx assembly engine, linked into the Rust binary
; (plans/asm-x86.md). Rust parses the command line, reads and validates the
; input, seeds the RNG and installs signal handlers; it then offers the run to
; ttfx_asm_run, which either declines before doing anything observable or runs
; the effect to completion and reports how it ended.
;
; One translation unit: every component is included here. Entry points follow
; the SysV ABI; everything internal uses the conventions in ttfx.inc.

%include "ttfx.inc"

; Per-run state lives in one section that ttfx_asm_run zeroes on entry, so a
; rerun after a terminal resize starts clean.
section .tstate nobits alloc write align=64
tstate_begin:

section .text
global ttfx_asm_tier
global ttfx_asm_run
global ttfx_asm_effect_supported

extern pow
extern sin
extern cos
extern sincos
extern exp2
extern hypot

; ttfx_asm_tier() -> eax = the best ISA tier this CPU and OS support
; (plan §5.2), 0 when none of the assembled tiers can run.
ttfx_asm_tier:
    push    rbx
    xor     eax, eax
    cpuid
    cmp     eax, 7
    jb      .none
    mov     eax, 1
    cpuid
    ; OSXSAVE (27), AVX (28), FMA (12), MOVBE (22), F16C (29)
    mov     eax, ecx
    and     eax, (1 << 27) | (1 << 28) | (1 << 12) | (1 << 22) | (1 << 29)
    cmp     eax, (1 << 27) | (1 << 28) | (1 << 12) | (1 << 22) | (1 << 29)
    jne     .none
    xor     ecx, ecx
    xgetbv
    ; XMM, YMM, opmask, ZMM_Hi256, Hi16_ZMM state enabled by the OS
    and     eax, 0xe6
    cmp     eax, 0xe6
    jne     .none
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    ; AVX2 (5), BMI1 (3), BMI2 (8), AVX512F (16), DQ (17), CD (28), BW (30), VL (31)
    mov     eax, ebx
    and     eax, (1 << 5) | (1 << 3) | (1 << 8) | (1 << 16) | (1 << 17) | (1 << 28) | (1 << 30) | (1 << 31)
    cmp     eax, (1 << 5) | (1 << 3) | (1 << 8) | (1 << 16) | (1 << 17) | (1 << 28) | (1 << 30) | (1 << 31)
    jne     .none
    mov     eax, 0x80000000
    cpuid
    cmp     eax, 0x80000001
    jb      .none
    mov     eax, 0x80000001
    cpuid
    test    ecx, 1 << 5                 ; LZCNT
    jz      .none
    mov     eax, 4
    pop     rbx
    ret
.none:
    xor     eax, eax
    pop     rbx
    ret

; ttfx_asm_effect_supported(rdi=effect id) -> eax = 1 when this build has it.
ttfx_asm_effect_supported:
    xor     eax, eax
    cmp     rdi, EFFECT_COUNT
    jae     .done
    lea     rax, [effect_table]
    shl     rdi, 4
    cmp     qword [rax + rdi], 0
    setne   al
    movzx   eax, al
.done:
    ret

; ttfx_asm_run(rdi=request) -> rax = outcome (OUT_*, or -errno).
ttfx_asm_run:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    ; a fresh run: release the previous run's memory, zero the state
    push    rdi
    call    release_regions
    pop     rdi
    push    rdi
    lea     rdi, [tstate_begin]
    lea     rcx, [tstate_end]
    sub     rcx, rdi
    xor     eax, eax
    rep     stosb
    pop     rdi
    mov     [request], rdi
    mov     [fail_rsp], rsp
    ; the effect must be one this build has
    mov     rax, [rdi + RQ_EFFECT]
    cmp     rax, EFFECT_COUNT
    jae     .declined
    lea     rcx, [effect_table]
    shl     rax, 4
    mov     rdx, [rcx + rax]
    test    rdx, rdx
    jz      .declined
    mov     [effect_build], rdx
    mov     rdx, [rcx + rax + 8]
    mov     [effect_next_frame], rdx
    call    load_request
    mov     rdi, 1 << 38
    call    reserve
    mov     [arena_ptr], rax
    call    visual_init
    call    terminal_init
    call    monotonic_ns
    mov     [last_frame_ns], rax        ; Terminal::new's last_time_printed
    call    anim_init
    call    render_init
    call    clock_init
    call    [effect_build]
    cmp     byte [cfg_parity_dump], 0
    jne     .dump
    call    run_effect
    jmp     .return
.dump:
    call    dump_effect
.return:
    push    rax
    call    store_rng_state
    pop     rax
.epilogue:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    vzeroupper
    ret
.declined:
    xor     eax, eax
    jmp     .epilogue

; engine_fail(rdi=message, esi=length): the effect or engine hit an error
; that Rust reports as "Error: <message>". Unwinds to ttfx_asm_run.
engine_fail:
    mov     rax, [request]
    mov     [rax + RQ_ERROR_PTR], rdi
    mov     [rax + RQ_ERROR_LEN], rsi
    mov     qword [rax + RQ_ERROR_KIND], ERR_MESSAGE
    mov     rsp, [fail_rsp]
    mov     eax, OUT_ERROR
    jmp     ttfx_asm_run.return

; load_request: copy the request's settings into the cfg_* globals.
load_request:
    mov     rsi, [request]
    mov     rax, [rsi + RQ_TAB_WIDTH]
    mov     [cfg_tab_width], rax
    mov     rax, [rsi + RQ_FRAME_RATE]
    mov     [cfg_frame_rate], rax
    mov     rax, [rsi + RQ_CANVAS_WIDTH]
    mov     [cfg_canvas_width], rax
    mov     rax, [rsi + RQ_CANVAS_HEIGHT]
    mov     [cfg_canvas_height], rax
    mov     rax, [rsi + RQ_ANCHOR_CANVAS]
    mov     [cfg_anchor_canvas], rax
    mov     rax, [rsi + RQ_ANCHOR_TEXT]
    mov     [cfg_anchor_text], rax
    mov     rax, [rsi + RQ_EXISTING_COLORS]
    mov     [cfg_existing_colors], rax
    mov     rax, [rsi + RQ_MAX_FRAMES]
    mov     [cfg_max_frames], rax
    mov     rax, [rsi + RQ_TERM_WIDTH]
    mov     [term_width], rax
    mov     rax, [rsi + RQ_TERM_HEIGHT]
    mov     [term_height], rax
    mov     rax, [rsi + RQ_INPUT_PTR]
    mov     [input_ptr], rax
    mov     rax, [rsi + RQ_INPUT_LEN]
    mov     [input_len], rax
    mov     rax, [rsi + RQ_EFFECT_CONFIG]
    mov     [effect_config], rax
    mov     rax, [rsi + RQ_FLAGS]
    lea     rdi, [cfg_flag_bytes]
    xor     ecx, ecx
.flag:
    bt      rax, rcx
    setc    dl
    mov     [rdi + rcx], dl
    inc     ecx
    cmp     ecx, 16
    jb      .flag
    ; the RNG continues from Rust's state
    lea     rdi, [rsi + RQ_RNG_STATE]
    jmp     rng_load

; store_rng_state: hand the RNG state back (a resize continues the stream).
store_rng_state:
    mov     rdi, [request]
    add     rdi, RQ_RNG_STATE
    jmp     rng_store

; stop_requested -> eax = STOP_*: asks Rust (interrupt, terminate, a settled
; resize on a tty), exactly at run_effect's requested_stop points.
stop_requested:
    mov     rax, [request]
    mov     rdi, [rax + RQ_STOP_CTX]
    mov     rax, [rax + RQ_STOP_CHECK]
    vzeroupper
    CCALL   rax
    ret

; clock_init: Clock::real() / Clock::virtual_with_frame_rate().
clock_init:
    cmp     byte [cfg_parity_dump], 0
    jne     .virtual
    cmp     byte [cfg_virtual_clock], 0
    jne     .virtual
    mov     byte [clock_is_virtual], 0
    call    realtime_s
    movsd   [clock_wall_start], xmm0
    call    monotonic_ns
    mov     [clock_start_ns], rax
    ret
.virtual:
    mov     byte [clock_is_virtual], 1
    xorpd   xmm0, xmm0
    movsd   [clock_now], xmm0
    mov     rax, [cfg_frame_rate]
    test    rax, rax
    jle     .default_rate
    cvtsi2sd xmm1, rax
    jmp     .dt
.default_rate:
    mov     eax, 60
    cvtsi2sd xmm1, rax
.dt:
    mov     rax, __float64__(1.0)
    movq    xmm0, rax
    divsd   xmm0, xmm1
    movsd   [clock_dt], xmm0
    ret

; clock_advance_frame: virtual time moves one frame (repeated addition).
clock_advance_frame:
    cmp     byte [clock_is_virtual], 0
    je      .done
    movsd   xmm0, [clock_now]
    addsd   xmm0, [clock_dt]
    movsd   [clock_now], xmm0
.done:
    ret

; clock_wall -> xmm0 (time.time() analog); clock_monotonic -> xmm0.
clock_wall:
    cmp     byte [clock_is_virtual], 0
    jne     clock_virtual_now
    call    monotonic_ns
    sub     rax, [clock_start_ns]
    cvtsi2sd xmm0, rax
    divsd   xmm0, [one_billion]
    addsd   xmm0, [clock_wall_start]
    ret
clock_monotonic:
    cmp     byte [clock_is_virtual], 0
    jne     clock_virtual_now
    call    monotonic_ns
    sub     rax, [clock_start_ns]
    cvtsi2sd xmm0, rax
    divsd   xmm0, [one_billion]
    ret
clock_virtual_now:
    movsd   xmm0, [clock_now]
    ret

; next_frame -> eax = 1 when the effect produced a frame (the effect's
; next_frame followed by ctx.frame(): pacing, then the virtual clock).
next_frame:
    call    [effect_next_frame]
    test    eax, eax
    jz      .done
    call    enforce_framerate
    call    clock_advance_frame
    mov     eax, 1
.done:
    ret

; run_effect -> rax = outcome. Prep the canvas, stream frames, always
; restore the cursor. r12 = pending-bytes cursor, r13 = pending base.
run_effect:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, [out_base]
    mov     r12, r13
    mov     r15d, OUT_COMPLETE
    ; prep_canvas
    lea     rsi, [ansi_hide_cursor]
    mov     ecx, ansi_hide_cursor_len
    call    out_bytes
    call    build_move_to_top
    cmp     byte [cfg_reuse_canvas], 0
    je      .prep_rows
    call    out_move_to_top
.prep_rows:
    mov     rbx, [visible_top]
.prep_row:
    test    rbx, rbx
    jle     .prep_done
    mov     rcx, [visible_right]
    test    rcx, rcx
    jle     .prep_newline
    mov     rdi, r12
    mov     al, ' '
    rep     stosb
    mov     r12, rdi
.prep_newline:
    mov     byte [r12], 10
    inc     r12
    dec     rbx
    jmp     .prep_row
.prep_done:
    lea     rsi, [ansi_dec_save]
    mov     ecx, ansi_dec_save_len
    call    out_bytes
.frame:
    call    check_stop
    jnz     .teardown
    call    next_frame
    test    eax, eax
    jz      .teardown
    mov     r14, r12                    ; where this frame's prefix starts
    call    out_move_to_top
    call    render_frame
    call    check_stop
    jnz     .discard
    ; pending bytes (prep, cursor move) and the frame's rows in one writev
    mov     rdi, [frame_iov]
    mov     [rdi], r13
    mov     rax, r12
    sub     rax, r13
    mov     [rdi + 8], rax
    mov     esi, [grid_height]
    inc     esi
    call    writev_all
    mov     r12, r13
    test    rax, rax
    jnz     .write_failed
    jmp     .frame
.discard:
    mov     r12, r14
.teardown:
    cmp     r15d, OUT_RESIZED
    je      .resized
    call    restore_cursor
    call    flush_output
    test    rax, rax
    jnz     .write_failed_late
    jmp     .finish
.resized:
    ; leave the cursor hidden, parked at the top of the wiped area
    lea     rsi, [ansi_dec_restore]
    mov     ecx, ansi_dec_restore_len
    call    out_bytes
    mov     rsi, [visible_top]
    test    rsi, rsi
    jle     .clear
    mov     byte [r12], 0x1b
    mov     byte [r12 + 1], '['
    lea     rdi, [r12 + 2]
    call    format_u64
    lea     r12, [r12 + rax + 2]
    mov     byte [r12], 'A'
    inc     r12
.clear:
    lea     rsi, [ansi_clear_to_end]
    mov     ecx, ansi_clear_to_end_len
    call    out_bytes
    call    flush_output
    test    rax, rax
    jnz     .write_failed_late
    jmp     .finish
.write_failed:
    ; a failed frame still gets its teardown attempt, as run_effect does
    mov     rbx, rax
    mov     r12, r13
    call    restore_cursor
    call    flush_output
    mov     rax, rbx
.write_failed_late:
    ; the terminal went away (EIO, EPIPE): a quiet end, not an error
    cmp     byte [cfg_tty_output], 0
    je      .io_error
    cmp     rax, -EIO
    je      .closed
    cmp     rax, -EPIPE
    je      .closed
.io_error:
    mov     r15, rax
    jmp     .finish
.closed:
    mov     r15d, OUT_OUTPUT_CLOSED
.finish:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; check_stop -> ZF clear (and r15 = outcome) when the run must stop.
check_stop:
    call    stop_requested
    cmp     eax, STOP_INTERRUPT
    je      .interrupt
    cmp     eax, STOP_TERMINATE
    je      .terminate
    cmp     eax, STOP_RESIZE
    je      .resize
    xor     eax, eax                    ; ZF set: keep going
    ret
.interrupt:
    mov     r15d, OUT_INTERRUPTED
    jmp     .stop
.terminate:
    mov     r15d, OUT_TERMINATED
    jmp     .stop
.resize:
    mov     r15d, OUT_RESIZED
.stop:
    or      eax, 1                      ; ZF clear
    ret

; restore_cursor: show the cursor and end the line unless configured not to.
restore_cursor:
    cmp     byte [cfg_no_restore_cursor], 0
    jne     .eol
    lea     rsi, [ansi_show_cursor]
    mov     ecx, ansi_show_cursor_len
    call    out_bytes
.eol:
    cmp     byte [cfg_no_eol], 0
    jne     .done
    mov     byte [r12], 10
    inc     r12
.done:
    ret

; dump_effect -> rax: length-prefixed frames, no tty framing, "frames=N" on
; stderr (effect.rs dump_effect).
dump_effect:
    push    rbx
    push    r12
    push    r13
    push    r15
    mov     r13, [out_base]
    xor     r15d, r15d                  ; frame count
.frame:
    call    next_frame
    test    eax, eax
    jz      .done
    call    render_frame
    ; "<len>\n" header, the rows, then the frame's trailing newline
    mov     rdi, r13
    mov     rsi, rax
    call    format_u64
    mov     byte [r13 + rax], 10
    inc     rax
    mov     rdi, [frame_iov]
    mov     [rdi], r13
    mov     [rdi + 8], rax
    mov     rcx, [grid_height]
    inc     rcx
    shl     rcx, 4
    lea     rax, [newline]
    mov     [rdi + rcx], rax
    mov     qword [rdi + rcx + 8], 1
    mov     esi, [grid_height]
    add     esi, 2
    call    writev_all
    test    rax, rax
    jnz     .failed
    inc     r15
    cmp     r15, [cfg_max_frames]       ; unsigned: -1 (no limit) is never reached
    jb      .frame
.done:
    lea     rsi, [msg_frames_eq]
    mov     rdi, r13
    mov     ecx, msg_frames_eq_len
    rep     movsb
    mov     rsi, r15
    call    format_u64
    lea     rdx, [rax + msg_frames_eq_len]
    mov     byte [r13 + rdx], 10
    inc     rdx
    mov     rsi, r13
    mov     edi, 2
    call    write_all
    mov     eax, OUT_COMPLETE
.failed:
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret

; out_bytes(rsi=src, ecx=len): append to the pending buffer at r12.
out_bytes:
    mov     rdi, r12
    rep     movsb
    mov     r12, rdi
    ret

; flush_output -> rax = 0 or -errno: write r13..r12 and rewind.
flush_output:
    mov     edi, 1
    mov     rsi, r13
    mov     rdx, r12
    sub     rdx, r13
    call    write_all
    mov     r12, r13
    ret

; build_move_to_top: "\x1b8\x1b7\x1b[<visible_top.max(0)>A".
build_move_to_top:
    lea     rdi, [move_to_top]
    mov     dword [rdi], 0x371b381b     ; ESC 8 ESC 7
    mov     word [rdi + 4], 0x5b1b      ; ESC [
    add     rdi, 6
    mov     rsi, [visible_top]
    xor     eax, eax
    test    rsi, rsi
    cmovs   rsi, rax
    call    format_u64
    lea     rdi, [move_to_top + 6]
    add     rdi, rax
    mov     byte [rdi], 'A'
    add     eax, 7
    mov     [move_to_top_len], eax
    ret

out_move_to_top:
    lea     rsi, [move_to_top]
    mov     ecx, [move_to_top_len]
    jmp     out_bytes

; enforce_framerate: Terminal.enforce_framerate on the real clock only.
; The timestamp is taken after the sleep, so drift accumulates, faithfully.
enforce_framerate:
    cmp     byte [clock_is_virtual], 0
    jne     .done
    mov     rcx, [cfg_frame_rate]
    test    rcx, rcx
    jz      .done
    mov     eax, 1000000000
    xor     edx, edx
    div     rcx
    push    rax                         ; frame delay in ns
    call    monotonic_ns
    sub     rax, [last_frame_ns]
    pop     rdi
    cmp     rax, rdi
    jge     .stamp
    sub     rdi, rax
    call    sleep_ns
.stamp:
    call    monotonic_ns
    mov     [last_frame_ns], rax
.done:
    ret

%include "rt/sys.asm"
%include "utils/rng.asm"
%include "utils/graphics.asm"
%include "utils/hexterm.asm"
%include "engine/visual.asm"
%include "engine/terminal.asm"
%include "engine/anim.asm"
%include "engine/render.asm"
%include "effects/registry.asm"

section .rodata
STR msg_frames_eq, "frames="
STR ansi_hide_cursor, 27, "[?25l"
STR ansi_show_cursor, 27, "[?25h"
STR ansi_dec_save, 27, "7"
STR ansi_dec_restore, 27, "8"
STR ansi_clear_to_end, 27, "[0J"
newline: db 10

section .bss
alignb 8
request:            resq 1              ; persists: engine_fail needs it
fail_rsp:           resq 1

section .tstate
alignb 8
effect_build:       resq 1
effect_next_frame:  resq 1
effect_config:      resq 1
input_ptr:          resq 1
input_len:          resq 1
last_frame_ns:      resq 1
clock_start_ns:     resq 1
clock_wall_start:   resq 1
clock_now:          resq 1
clock_dt:           resq 1
cfg_tab_width:      resq 1
cfg_frame_rate:     resq 1
cfg_canvas_width:   resq 1
cfg_canvas_height:  resq 1
cfg_anchor_canvas:  resq 1
cfg_anchor_text:    resq 1
cfg_existing_colors: resq 1
cfg_max_frames:     resq 1
move_to_top:        resb 32
move_to_top_len:    resd 1
clock_is_virtual:   resb 1
; RQ_FLAGS, one byte per bit, in FL_* order
cfg_flag_bytes:
cfg_xterm_colors:       resb 1
cfg_no_color:           resb 1
cfg_wrap_text:          resb 1
cfg_ignore_dims:        resb 1
cfg_reuse_canvas:       resb 1
cfg_no_eol:             resb 1
cfg_no_restore_cursor:  resb 1
cfg_parity_dump:        resb 1
cfg_virtual_clock:      resb 1
cfg_tty_output:         resb 1
                        resb 6

section .tstate
alignb 64
tstate_end:
