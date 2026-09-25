; utils/color.asm - Color arithmetic on the u64 color format of ttfx.inc:
; Animation::adjust_color_brightness (src/engine/animation.rs) and
; graphics::shift_color_towards / random_color (src/utils/graphics.rs).
; Inputs may carry an xterm code; results are plain RGB colors, as Rust's
; Color::from_rgb makes them.
;
; Every comparison, select and expression is in the oracle's order. The
; oracle keeps f64::max/min as maxsd/minsd with NaN fix-ups that never
; trigger here (channels are finite), so plain maxsd/minsd in the same
; operand order are bit-identical.

section .text

; adjust_color_brightness(rdi=color, xmm0=brightness) -> rax = color.
; RGB -> HLS, lightness scaled by brightness and clamped to [0, 1], back to
; RGB with hue_to_rgb, channels rounded half-even and truncated to u8.
; Clobbers rcx, rdx, xmm0-xmm15.
adjust_color_brightness:
    push    rbx
    mov     eax, edi
    shr     eax, 16
    and     eax, 255
    cvtsi2sd xmm10, eax
    divsd   xmm10, [col_255]            ; normalized_red
    mov     eax, edi
    shr     eax, 8
    and     eax, 255
    cvtsi2sd xmm2, eax
    divsd   xmm2, [col_255]             ; normalized_green
    movzx   eax, dil
    cvtsi2sd xmm3, eax
    divsd   xmm3, [col_255]             ; normalized_blue
    movapd  xmm5, xmm10
    maxsd   xmm5, xmm2
    maxsd   xmm5, xmm3                  ; max_val
    movapd  xmm1, xmm10
    minsd   xmm1, xmm2
    minsd   xmm1, xmm3                  ; min_val
    movapd  xmm4, xmm5
    addsd   xmm4, xmm1                  ; max + min
    movsd   xmm7, [col_half]
    mulsd   xmm7, xmm4                  ; lightness
    mulsd   xmm0, xmm7                  ; lightness * brightness
    ucomisd xmm5, xmm1
    jne     .chroma
    jp      .chroma
    ; max == min: hue and saturation are 0, so the result is gray
    minsd   xmm0, [col_one]
    xorpd   xmm2, xmm2
    maxsd   xmm0, xmm2
    jmp     .gray
.chroma:
    movapd  xmm6, xmm5
    subsd   xmm6, xmm1                  ; diff
    movsd   xmm8, [col_two]
    subsd   xmm8, xmm5
    subsd   xmm8, xmm1                  ; 2 - max - min
    ucomisd xmm7, [col_half]
    ja      .saturation
    movapd  xmm8, xmm4                  ; lightness <= 0.5: max + min
.saturation:
    movapd  xmm4, xmm6
    divsd   xmm4, xmm8                  ; saturation
    ucomisd xmm5, xmm10
    jne     .not_red
    jp      .not_red
    ; (green - blue) / diff + (green < blue ? 6 : 0)
    movapd  xmm9, xmm2
    subsd   xmm9, xmm3
    divsd   xmm9, xmm6
    xorpd   xmm11, xmm11
    ucomisd xmm2, xmm3
    jae     .wrap
    movsd   xmm11, [col_six]
.wrap:
    addsd   xmm9, xmm11
    jmp     .hue
.not_red:
    ucomisd xmm5, xmm2
    jne     .blue_max
    jp      .blue_max
    movapd  xmm9, xmm3
    subsd   xmm9, xmm10
    divsd   xmm9, xmm6
    addsd   xmm9, [col_two]
    jmp     .hue
.blue_max:
    movapd  xmm9, xmm10
    subsd   xmm9, xmm2
    divsd   xmm9, xmm6
    addsd   xmm9, [col_four]
.hue:
    divsd   xmm9, [col_six]             ; hue_value
    minsd   xmm0, [col_one]
    xorpd   xmm2, xmm2
    maxsd   xmm0, xmm2                  ; lightness, clamped
    ucomisd xmm4, xmm2
    jne     .colored
    jp      .colored
.gray:
    movapd  xmm12, xmm0
    movapd  xmm13, xmm0
    movapd  xmm14, xmm0
    jmp     .channels
.colored:
    ucomisd xmm0, [col_half]
    jb      .dark
    movapd  xmm8, xmm0
    addsd   xmm8, xmm4
    movapd  xmm1, xmm4
    mulsd   xmm1, xmm0
    subsd   xmm8, xmm1                  ; lightness + saturation - lightness * saturation
    jmp     .intensity
.dark:
    movapd  xmm8, xmm4
    addsd   xmm8, [col_one]
    mulsd   xmm8, xmm0                  ; lightness * (1 + saturation)
.intensity:
    movapd  xmm2, xmm0
    addsd   xmm2, xmm0
    subsd   xmm2, xmm8                  ; lightness_scaled = 2 * lightness - intensity
    movapd  xmm0, xmm9
    addsd   xmm0, [col_third]
    call    hue_to_rgb
    movapd  xmm12, xmm0                 ; red
    movapd  xmm0, xmm9
    call    hue_to_rgb
    movapd  xmm13, xmm0                 ; green
    movapd  xmm0, xmm9
    addsd   xmm0, [col_neg_third]
    call    hue_to_rgb
    movapd  xmm14, xmm0                 ; blue
.channels:
    movapd  xmm0, xmm12
    mulsd   xmm0, [col_255]
    call    round_half_even
    movzx   ebx, al
    shl     ebx, 16
    movapd  xmm0, xmm13
    mulsd   xmm0, [col_255]
    call    round_half_even
    movzx   eax, al
    shl     eax, 8
    or      ebx, eax
    movapd  xmm0, xmm14
    mulsd   xmm0, [col_255]
    call    round_half_even
    movzx   eax, al
    or      eax, ebx
    pop     rbx
    ret

; hue_to_rgb(xmm2=lightness_scaled, xmm8=color_intensity, xmm0=hue_value)
; -> xmm0. Clobbers xmm1, xmm3.
hue_to_rgb:
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jae     .positive
    addsd   xmm0, [col_one]
.positive:
    ucomisd xmm0, [col_one]
    jbe     .unit
    addsd   xmm0, [col_neg_one]
.unit:
    ucomisd xmm0, [col_sixth]
    jae     .second
    movapd  xmm1, xmm8
    subsd   xmm1, xmm2
    mulsd   xmm1, [col_six]
    mulsd   xmm1, xmm0
    addsd   xmm1, xmm2                  ; scaled + (intensity - scaled) * 6 * hue
    movapd  xmm0, xmm1
    ret
.second:
    ucomisd xmm0, [col_half]
    jae     .third
    movapd  xmm0, xmm8
    ret
.third:
    ucomisd xmm0, [col_two_thirds]
    jae     .last
    movapd  xmm1, xmm8
    subsd   xmm1, xmm2
    movsd   xmm3, [col_two_thirds]
    subsd   xmm3, xmm0
    mulsd   xmm3, xmm1
    mulsd   xmm3, [col_six]
    addsd   xmm3, xmm2                  ; scaled + (intensity - scaled) * (2/3 - hue) * 6
    movapd  xmm0, xmm3
    ret
.last:
    movapd  xmm0, xmm2
    ret

; shift_color_towards(rdi=color, rsi=target_color, xmm0=factor)
; -> rax = color, edx = 1. Each channel is start + (end - start) * factor
; on the [0, 1] scale, times 255, truncated. When a channel leaves 0..=255
; the result is edx = 0 (rax = 0): Rust then formats the channels as hex,
; where a negative channel makes Color::from_hex panic on the '-' and a
; wide channel gives either a 7-digit pseudo-color or the Err carried by
; msg_invalid_color_value. No effect calls this function, and with a
; factor in [0, 1] the channels always stay in range, so callers can treat
; edx = 0 as unreachable.
; Clobbers rcx, xmm0-xmm4.
shift_color_towards:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rdi
    mov     r13, rsi
    movapd  xmm4, xmm0
    xor     ebx, ebx
    mov     r14d, 16                    ; channel shift: red, green, blue
.channel:
    mov     ecx, r14d
    mov     eax, r12d
    shr     eax, cl
    movzx   eax, al
    cvtsi2sd xmm0, eax
    divsd   xmm0, [col_255]             ; start
    mov     eax, r13d
    shr     eax, cl
    movzx   eax, al
    cvtsi2sd xmm1, eax
    divsd   xmm1, [col_255]             ; end
    subsd   xmm1, xmm0
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1                  ; start + (end - start) * factor
    mulsd   xmm0, [col_255]
    call    f64_to_i64
    cmp     rax, 255
    ja      .outside
    mov     ecx, r14d
    shl     eax, cl
    or      ebx, eax
    sub     r14d, 8
    jns     .channel
    mov     eax, ebx
    mov     edx, 1
    jmp     .done
.outside:
    xor     eax, eax
    xor     edx, edx
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; random_color -> rax = a color from randint(0, 0xFFFFFF): one RNG draw
; (plus rejections), whose value is the RGB word itself.
random_color:
    xor     edi, edi
    mov     esi, 0xFFFFFF
    jmp     rng_randint

section .rodata
align 8
col_255:        dq 255.0
col_half:       dq 0.5
col_one:        dq 1.0
col_neg_one:    dq -1.0
col_two:        dq 2.0
col_four:       dq 4.0
col_six:        dq 6.0
col_third:      dq 0x3fd5555555555555   ; 1.0 / 3.0
col_neg_third:  dq 0xbfd5555555555555   ; -(1.0 / 3.0), the oracle's hue - 1/3
col_sixth:      dq 0x3fc5555555555555   ; 1.0 / 6.0
col_two_thirds: dq 0x3fe5555555555555   ; 2.0 / 3.0
STR msg_invalid_color_value, "Invalid color value. Color must be an XTerm-256 color code or an RGB hex color string. Example: 255 or 'ffffff' or '#ffffff'"
