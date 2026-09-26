; tier.asm - the tier-independent part of the engine, assembled once at the
; x86-64 baseline (build.rs passes -DTIER=1): CPU tier detection, and the
; unsuffixed test thunks that dispatch to one tier's copy of tests.asm.
;
; build.rs defines TIERS_BUILT (bit n set when tier n's object is linked) and
; includes test_thunks.inc, its list of tests.asm's EXPORTs.

%include "ttfx.inc"

section .text
global ttfx_asm_tier

extern getenv

; ttfx_asm_tier() -> eax = the best x86-64 level (1-4) this CPU and OS
; support (plans/asm-x86.md §5.2). Baseline instructions only.
;   v2: SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT, CX16, LAHF/SAHF
;   v3: AVX, AVX2, BMI1, BMI2, LZCNT, MOVBE, F16C, FMA, OS-enabled YMM state
;   v4: AVX-512 F, DQ, CD, BW, VL, OS-enabled opmask and ZMM state
; Clobbers rcx, rdx, r8-r11.
%define CPUID1_ECX_V2   (1 << 0) | (1 << 9) | (1 << 13) | (1 << 19) | (1 << 20) | (1 << 23)
%define CPUID1_ECX_V3   (1 << 12) | (1 << 22) | (1 << 27) | (1 << 28) | (1 << 29)
%define CPUID7_EBX_V3   (1 << 3) | (1 << 5) | (1 << 8)
%define CPUID7_EBX_V4   (1 << 16) | (1 << 17) | (1 << 28) | (1 << 30) | (1 << 31)
ttfx_asm_tier:
    push    rbx
    mov     r10d, 1                     ; the tier found so far
    xor     eax, eax
    cpuid
    mov     r8d, eax                    ; highest standard leaf
    mov     eax, 0x80000000
    cpuid
    xor     r9d, r9d                    ; extended leaf 1's ecx, or 0
    cmp     eax, 0x80000001
    jb      .leaf1
    mov     eax, 0x80000001
    cpuid
    mov     r9d, ecx
.leaf1:
    mov     eax, 1
    cpuid
    mov     r11d, ecx                   ; leaf 1's ecx
    ; v2
    mov     eax, r11d
    and     eax, CPUID1_ECX_V2
    cmp     eax, CPUID1_ECX_V2
    jne     .done
    test    r9d, 1 << 0                 ; LAHF/SAHF in 64-bit mode
    jz      .done
    mov     r10d, 2
    ; v3
    mov     eax, r11d
    and     eax, CPUID1_ECX_V3
    cmp     eax, CPUID1_ECX_V3
    jne     .done
    test    r9d, 1 << 5                 ; LZCNT (ABM)
    jz      .done
    cmp     r8d, 7
    jb      .done
    xor     ecx, ecx
    db      0x0f, 0x01, 0xd0            ; xgetbv (OSXSAVE is set, so it exists;
                                        ; spelled out for the baseline CPU level)
    mov     r8d, eax                    ; XCR0
    and     eax, 0x06                   ; XMM and YMM state
    cmp     eax, 0x06
    jne     .done
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    mov     eax, ebx
    and     eax, CPUID7_EBX_V3
    cmp     eax, CPUID7_EBX_V3
    jne     .done
    mov     r10d, 3
    ; v4
    mov     eax, ebx
    and     eax, CPUID7_EBX_V4
    cmp     eax, CPUID7_EBX_V4
    jne     .done
    and     r8d, 0xe6                   ; + opmask, ZMM_Hi256, Hi16_ZMM
    cmp     r8d, 0xe6
    jne     .done
    mov     r10d, 4
.done:
    mov     eax, r10d
    pop     rbx
    ret

; ------------------------------------------------------------ test thunks
; tests/asm_diff.rs calls ttfx_test_*; each thunk jumps to the copy in the
; tier TTFX_ASM_TIER names, or else the best linked tier the CPU runs. A
; tier that is not linked or not supported stops the test with SIGILL after
; a message on stderr.

%ifndef TIERS_BUILT
%define TIERS_BUILT 0
%endif

%macro TIER_ENTRY 2                     ; name, tier
%if TIERS_BUILT & (1 << %2)
extern %1_v%2
    dq      %1_v%2
%else
    dq      0
%endif
%endmacro

%macro TEST_THUNK 1
section .data.rel.ro progbits alloc write noexec
align 8
%%table:
    TIER_ENTRY %1, 1
    TIER_ENTRY %1, 2
    TIER_ENTRY %1, 3
    TIER_ENTRY %1, 4
section .text
global %1
%1:
    lea     r11, [%%table]
    jmp     test_dispatch
%endmacro

; test_dispatch(r11=table): jump to the selected tier's entry with every
; argument register intact.
test_dispatch:
    movzx   eax, byte [test_tier]
    test    eax, eax
    jz      .select
    jmp     [r11 + rax * 8 - 8]
.select:
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    push    r8
    push    r9
    push    r11
    sub     rsp, 8 * 16
    movdqu  [rsp], xmm0
    movdqu  [rsp + 16], xmm1
    movdqu  [rsp + 32], xmm2
    movdqu  [rsp + 48], xmm3
    movdqu  [rsp + 64], xmm4
    movdqu  [rsp + 80], xmm5
    movdqu  [rsp + 96], xmm6
    movdqu  [rsp + 112], xmm7
    call    test_select_tier
    mov     [test_tier], al
    movdqu  xmm0, [rsp]
    movdqu  xmm1, [rsp + 16]
    movdqu  xmm2, [rsp + 32]
    movdqu  xmm3, [rsp + 48]
    movdqu  xmm4, [rsp + 64]
    movdqu  xmm5, [rsp + 80]
    movdqu  xmm6, [rsp + 96]
    movdqu  xmm7, [rsp + 112]
    add     rsp, 8 * 16
    pop     r11
    pop     r9
    pop     r8
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    jmp     test_dispatch

; test_select_tier -> eax = the tier the test thunks use (src/asm/ffi.rs
; select_tier's rules). Clobbers C.
test_select_tier:
    push    rbx
    call    ttfx_asm_tier
    mov     ebx, eax                    ; the CPU's tier
    lea     rdi, [env_name]
    CCALL   getenv
    test    rax, rax
    jz      .best
    movzx   ecx, byte [rax]
    test    ecx, ecx
    jz      .best
    cmp     byte [rax + 1], 0
    jne     .refuse
    sub     ecx, '0'
    cmp     ecx, 1
    jb      .refuse
    cmp     ecx, 4
    ja      .refuse
    cmp     ecx, ebx
    ja      .refuse
    mov     eax, TIERS_BUILT
    bt      eax, ecx
    jnc     .refuse
    mov     eax, ecx
    pop     rbx
    ret
.best:
    mov     eax, TIERS_BUILT
.down:
    bt      eax, ebx
    jc      .found
    dec     ebx
    jnz     .down
    jmp     .refuse
.found:
    mov     eax, ebx
    pop     rbx
    ret
.refuse:
    mov     edi, 2
    lea     rsi, [msg_refuse]
    mov     edx, msg_refuse_len
    SYSCALL SYS_write
    ud2

%include "test_thunks.inc"

section .rodata
env_name: db "TTFX_ASM_TIER", 0
STR msg_refuse, "ttfx asm tests: TTFX_ASM_TIER names a tier this CPU or build lacks", 10

section .bss
test_tier:  resb 1                      ; 0 until the first thunk call
