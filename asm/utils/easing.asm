; utils/easing.asm - src/utils/easing.rs, named easings and step trackers.
; The release oracle uses pow for exponents 3/4/5, mulsd for squares,
; sqrtsd for roots and exp2 for powers of two. Preserve its operand order:
; InElastic negates the sine argument; InBack multiplies by negative c1;
; InOutSine and the high polynomial branches multiply by -0.5.
; No sincos call occurs in these arms.

section .text

; ease(edi=Easing id 0..30, xmm0=t) -> xmm0.
; All real inputs are accepted, including extrapolation. CubicBezier is absent.
; Clobbers all caller-saved registers (libm through CCALL).
ease:
    mov     edi, edi                    ; id is a 32-bit argument
    sub     rsp, 40
    movapd  xmm5, xmm0
    lea     rcx, [ease_table]
    movsxd  rax, [rcx + rdi * 4]
    add     rax, rcx
    jmp     rax
.in_sine:
    mulsd   xmm5, [ease_pi]
    mulsd   xmm5, [ease_half]
    movapd  xmm0, xmm5
    CCALL   cos
    jmp     .complement
.in_out_elastic:
    xorpd   xmm2, xmm2
    ucomisd xmm5, xmm2
    jne     .elastic_mid_one
    jnp     .done
.elastic_mid_one:
    movsd   xmm2, [ease_one]
    ucomisd xmm5, xmm2
    jne     .elastic_mid
    jnp     .done
.elastic_mid:
    movsd   xmm1, [ease_twenty]
    mulsd   xmm1, xmm5
    movsd   xmm0, [ease_neg_eleven_eighth]
    movsd   [rsp + 16], xmm1
    addsd   xmm0, xmm1
    mulsd   xmm0, [ease_elastic_c5]
    movsd   [rsp], xmm5
    CCALL   sin
    movsd   [rsp + 32], xmm0
    movsd   xmm0, [ease_half]
    ucomisd xmm0, [rsp]
    jbe     .elastic_high
    movsd   xmm0, [rsp + 16]
    addsd   xmm0, [ease_neg_ten]
    CCALL   exp2
    movapd  xmm2, xmm0
    mulsd   xmm2, [rsp + 32]
    mulsd   xmm2, [ease_neg_half]
    jmp     .done
.in_expo:
    xorpd   xmm2, xmm2
    ucomisd xmm5, xmm2
    jne     .expo_in
    jnp     .done
.expo_in:
    mulsd   xmm5, [ease_ten]
    addsd   xmm5, [ease_neg_ten]
    movapd  xmm0, xmm5
    add     rsp, 40
    CCALL   exp2
    ret
.out_quint:
    movsd   xmm0, [ease_one]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_five]
    jmp     .power_complement
.out_quart:
    movsd   xmm0, [ease_one]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_four]
    jmp     .power_complement
.in_quad:
    mulsd   xmm5, xmm5
    jmp     .linear
.in_out_quart:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    jbe     .quart_high
    movsd   xmm1, [ease_four]
    movapd  xmm0, xmm5
    CCALL   pow
    movapd  xmm2, xmm0
    mulsd   xmm2, [ease_eight]
    jmp     .done
.in_out_cubic:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    jbe     .cubic_high
    movsd   xmm1, [ease_three]
    movapd  xmm0, xmm5
    CCALL   pow
    movapd  xmm2, xmm0
    mulsd   xmm2, [ease_four]
    jmp     .done
.in_elastic:
    xorpd   xmm2, xmm2
    ucomisd xmm5, xmm2
    jne     .elastic_in_one
    jnp     .done
.elastic_in_one:
    movsd   xmm2, [ease_one]
    ucomisd xmm5, xmm2
    jne     .elastic_in
    jnp     .done
.elastic_in:
    mulsd   xmm5, [ease_ten]
    movsd   [rsp], xmm5
    movsd   xmm0, [ease_neg_ten]
    addsd   xmm0, xmm5
    CCALL   exp2
    movsd   [rsp + 16], xmm0
    movsd   xmm0, [rsp]
    addsd   xmm0, [ease_neg_ten_three_quarters]
    mulsd   xmm0, [ease_neg_elastic_c4]
    CCALL   sin
    movapd  xmm2, xmm0
    mulsd   xmm2, [rsp + 16]
    jmp     .done
.in_out_back:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    movapd  xmm2, xmm5
    addsd   xmm2, xmm5
    jbe     .back_high
    mulsd   xmm2, xmm2
    mulsd   xmm5, [ease_back_twice_c2_plus_one]
    addsd   xmm5, [ease_neg_back_c2]
    mulsd   xmm5, xmm2
    mulsd   xmm5, [ease_half]
    jmp     .linear
.out_sine:
    mulsd   xmm5, [ease_pi]
    mulsd   xmm5, [ease_half]
    movapd  xmm0, xmm5
    add     rsp, 40
    CCALL   sin
    ret
.in_out_quint:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    jbe     .quint_high
    movsd   xmm1, [ease_five]
    movapd  xmm0, xmm5
    CCALL   pow
    movapd  xmm2, xmm0
    mulsd   xmm2, [ease_sixteen]
    jmp     .done
.in_out_sine:
    mulsd   xmm5, [ease_pi]
    movapd  xmm0, xmm5
    CCALL   cos
    movapd  xmm2, xmm0
    addsd   xmm2, [ease_neg_one]
    mulsd   xmm2, [ease_neg_half]
    jmp     .done
.in_cubic:
    movsd   xmm1, [ease_three]
    jmp     .power
.out_expo:
    movsd   xmm2, [ease_one]
    ucomisd xmm5, xmm2
    jne     .expo_out
    jnp     .done
.expo_out:
    mulsd   xmm5, [ease_neg_ten]
    movapd  xmm0, xmm5
    CCALL   exp2
    jmp     .complement
.out_circ:
    addsd   xmm5, [ease_neg_one]
    mulsd   xmm5, xmm5
    movsd   xmm0, [ease_one]
    subsd   xmm0, xmm5
    sqrtsd  xmm0, xmm0
    add     rsp, 40
    ret
.out_quad:
    movsd   xmm2, [ease_one]
    movapd  xmm0, xmm2
    subsd   xmm0, xmm5
    mulsd   xmm0, xmm0
    subsd   xmm2, xmm0
    jmp     .done
.in_out_circ:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    addsd   xmm5, xmm5
    jbe     .circ_high
    mulsd   xmm5, xmm5
    movsd   xmm2, [ease_one]
    movapd  xmm0, xmm2
    subsd   xmm0, xmm5
    sqrtsd  xmm0, xmm0
    jmp     .complement_half
.in_quint:
    movsd   xmm1, [ease_five]
    jmp     .power
.in_out_quad:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    jbe     .quad_high
    mulsd   xmm5, xmm5
    addsd   xmm5, xmm5
    jmp     .linear
.in_out_expo:
    xorpd   xmm2, xmm2
    ucomisd xmm5, xmm2
    jne     .expo_mid_one
    jnp     .done
.expo_mid_one:
    movsd   xmm2, [ease_one]
    ucomisd xmm5, xmm2
    jne     .expo_mid
    jnp     .done
.expo_mid:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    mulsd   xmm5, [ease_twenty]
    jbe     .expo_high
    addsd   xmm5, [ease_neg_ten]
    movapd  xmm0, xmm5
    CCALL   exp2
    movapd  xmm2, xmm0
    jmp     .half
.in_quart:
    movsd   xmm1, [ease_four]
.power:
    movapd  xmm0, xmm5
    add     rsp, 40
    CCALL   pow
    ret
.out_cubic:
    movsd   xmm0, [ease_one]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_three]
.power_complement:
    CCALL   pow
.complement:
    movsd   xmm2, [ease_one]
    subsd   xmm2, xmm0
    jmp     .done
.in_out_bounce:
    movsd   xmm0, [ease_half]
    ucomisd xmm0, xmm5
    addsd   xmm5, xmm5
    jbe     .bounce_high
    movsd   xmm2, [ease_one]
    movapd  xmm0, xmm2
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_bounce_threshold_a]
    ucomisd xmm1, xmm0
    jbe     .bounce_low_second
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    jmp     .complement_half
.in_back:
    movsd   xmm1, [ease_three]
    movapd  xmm0, xmm5
    movsd   [rsp], xmm5
    CCALL   pow
    mulsd   xmm0, [ease_back_c3]
    movsd   xmm2, [rsp]
    mulsd   xmm2, xmm2
    mulsd   xmm2, [ease_neg_back_c1]
    addsd   xmm2, xmm0
    jmp     .done
.in_circ:
    mulsd   xmm5, xmm5
    movsd   xmm2, [ease_one]
    movapd  xmm0, xmm2
    subsd   xmm0, xmm5
    sqrtsd  xmm0, xmm0
    subsd   xmm2, xmm0
    jmp     .done
.out_back:
    addsd   xmm5, [ease_neg_one]
    movsd   [rsp], xmm5
    movsd   xmm1, [ease_three]
    movapd  xmm0, xmm5
    CCALL   pow
    mulsd   xmm0, [ease_back_c3]
    addsd   xmm0, [ease_one]
    movsd   xmm2, [rsp]
    mulsd   xmm2, xmm2
    mulsd   xmm2, [ease_back_c1]
    addsd   xmm2, xmm0
    jmp     .done
.in_bounce:
    movsd   xmm2, [ease_one]
    movapd  xmm0, xmm2
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_bounce_threshold_a]
    ucomisd xmm1, xmm0
    jbe     .bounce_in_second
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    subsd   xmm2, xmm0
    jmp     .done
.out_bounce:
    movsd   xmm0, [ease_bounce_threshold_a]
    ucomisd xmm0, xmm5
    jbe     .bounce_out_second
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    jmp     .linear
.out_elastic:
    xorpd   xmm2, xmm2
    ucomisd xmm5, xmm2
    jne     .elastic_out_one
    jnp     .done
.elastic_out_one:
    movsd   xmm2, [ease_one]
    ucomisd xmm5, xmm2
    jne     .elastic_out
    jnp     .done
.elastic_out:
    movsd   xmm0, [ease_neg_ten]
    mulsd   xmm0, xmm5
    movsd   [rsp], xmm5
    CCALL   exp2
    movsd   [rsp + 16], xmm0
    movsd   xmm0, [rsp]
    mulsd   xmm0, [ease_ten]
    addsd   xmm0, [ease_neg_three_quarters]
    mulsd   xmm0, [ease_elastic_c4]
    CCALL   sin
    movapd  xmm2, xmm0
    mulsd   xmm2, [rsp + 16]
    addsd   xmm2, [ease_one]
    jmp     .done
.quart_high:
    addsd   xmm5, xmm5
    movsd   xmm0, [ease_two]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_four]
    jmp     .power_high
.cubic_high:
    addsd   xmm5, xmm5
    movsd   xmm0, [ease_two]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_three]
    jmp     .power_high
.back_high:
    addsd   xmm2, [ease_neg_two]
    movapd  xmm0, xmm2
    mulsd   xmm2, [ease_back_c2_plus_one]
    mulsd   xmm0, xmm0
    addsd   xmm2, [ease_back_c2]
    mulsd   xmm2, xmm0
    addsd   xmm2, [ease_two]
    jmp     .half
.quint_high:
    addsd   xmm5, xmm5
    movsd   xmm0, [ease_two]
    subsd   xmm0, xmm5
    movsd   xmm1, [ease_five]
.power_high:
    CCALL   pow
    movapd  xmm2, xmm0
    jmp     .negative_half_plus_one
.circ_high:
    movsd   xmm0, [ease_two]
    subsd   xmm0, xmm5
    mulsd   xmm0, xmm0
    movsd   xmm1, [ease_one]
    movapd  xmm2, xmm1
    subsd   xmm2, xmm0
    sqrtsd  xmm2, xmm2
    addsd   xmm2, xmm1
    jmp     .half
.quad_high:
    addsd   xmm5, xmm5
    movsd   xmm2, [ease_two]
    subsd   xmm2, xmm5
    mulsd   xmm2, xmm2
.negative_half_plus_one:
    mulsd   xmm2, [ease_neg_half]
    addsd   xmm2, [ease_one]
    jmp     .done
.bounce_high:
    addsd   xmm5, [ease_neg_one]
    movsd   xmm0, [ease_bounce_threshold_a]
    ucomisd xmm0, xmm5
    jbe     .bounce_high_second
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    jmp     .plus_one_half
.bounce_in_second:
    movsd   xmm1, [ease_bounce_threshold_b]
    ucomisd xmm1, xmm0
    jbe     .bounce_in_third
    addsd   xmm0, [ease_bounce_shift_b]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_b]
    subsd   xmm2, xmm0
    jmp     .done
.bounce_out_second:
    movsd   xmm0, [ease_bounce_threshold_b]
    ucomisd xmm0, xmm5
    jbe     .bounce_out_third
    addsd   xmm5, [ease_bounce_shift_b]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_b]
    jmp     .linear
.bounce_low_second:
    movsd   xmm1, [ease_bounce_threshold_b]
    ucomisd xmm1, xmm0
    jbe     .bounce_low_third
    addsd   xmm0, [ease_bounce_shift_b]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_b]
    jmp     .complement_half
.bounce_high_second:
    movsd   xmm0, [ease_bounce_threshold_b]
    ucomisd xmm0, xmm5
    jbe     .bounce_high_third
    addsd   xmm5, [ease_bounce_shift_b]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_b]
    jmp     .plus_one_half
.bounce_in_third:
    movsd   xmm1, [ease_bounce_threshold_c]
    ucomisd xmm1, xmm0
    jbe     .bounce_in_last
    addsd   xmm0, [ease_bounce_shift_c]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_c]
    subsd   xmm2, xmm0
    jmp     .done
.bounce_out_third:
    movsd   xmm0, [ease_bounce_threshold_c]
    ucomisd xmm0, xmm5
    jbe     .bounce_out_last
    addsd   xmm5, [ease_bounce_shift_c]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_c]
    jmp     .linear
.bounce_low_third:
    movsd   xmm1, [ease_bounce_threshold_c]
    ucomisd xmm1, xmm0
    jbe     .bounce_low_last
    addsd   xmm0, [ease_bounce_shift_c]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_c]
    jmp     .complement_half
.bounce_high_third:
    movsd   xmm0, [ease_bounce_threshold_c]
    ucomisd xmm0, xmm5
    jbe     .bounce_high_last
    addsd   xmm5, [ease_bounce_shift_c]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_c]
    jmp     .plus_one_half
.bounce_in_last:
    addsd   xmm0, [ease_bounce_shift_d]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_d]
    subsd   xmm2, xmm0
    jmp     .done
.bounce_out_last:
    addsd   xmm5, [ease_bounce_shift_d]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_d]
.linear:
    movapd  xmm2, xmm5
    jmp     .done
.elastic_high:
    movsd   xmm0, [ease_ten]
    subsd   xmm0, [rsp + 16]
    CCALL   exp2
    movapd  xmm2, xmm0
    mulsd   xmm2, [rsp + 32]
    mulsd   xmm2, [ease_half]
    addsd   xmm2, [ease_one]
    jmp     .done
.expo_high:
    movsd   xmm0, [ease_ten]
    subsd   xmm0, xmm5
    CCALL   exp2
    movsd   xmm2, [ease_two]
    jmp     .complement_half
.bounce_low_last:
    addsd   xmm0, [ease_bounce_shift_d]
    mulsd   xmm0, xmm0
    mulsd   xmm0, [ease_bounce_n]
    addsd   xmm0, [ease_bounce_d]
.complement_half:
    subsd   xmm2, xmm0
    jmp     .half
.bounce_high_last:
    addsd   xmm5, [ease_bounce_shift_d]
    mulsd   xmm5, xmm5
    mulsd   xmm5, [ease_bounce_n]
    addsd   xmm5, [ease_bounce_d]
.plus_one_half:
    movapd  xmm2, xmm5
    addsd   xmm2, [ease_one]
.half:
    mulsd   xmm2, [ease_half]
.done:
    movapd  xmm0, xmm2
    add     rsp, 40
    ret

section .rodata
align 8
ease_table:
    dd ease.linear - ease_table
    dd ease.in_sine - ease_table
    dd ease.out_sine - ease_table
    dd ease.in_out_sine - ease_table
    dd ease.in_quad - ease_table
    dd ease.out_quad - ease_table
    dd ease.in_out_quad - ease_table
    dd ease.in_cubic - ease_table
    dd ease.out_cubic - ease_table
    dd ease.in_out_cubic - ease_table
    dd ease.in_quart - ease_table
    dd ease.out_quart - ease_table
    dd ease.in_out_quart - ease_table
    dd ease.in_quint - ease_table
    dd ease.out_quint - ease_table
    dd ease.in_out_quint - ease_table
    dd ease.in_expo - ease_table
    dd ease.out_expo - ease_table
    dd ease.in_out_expo - ease_table
    dd ease.in_circ - ease_table
    dd ease.out_circ - ease_table
    dd ease.in_out_circ - ease_table
    dd ease.in_back - ease_table
    dd ease.out_back - ease_table
    dd ease.in_out_back - ease_table
    dd ease.in_elastic - ease_table
    dd ease.out_elastic - ease_table
    dd ease.in_out_elastic - ease_table
    dd ease.in_bounce - ease_table
    dd ease.out_bounce - ease_table
    dd ease.in_out_bounce - ease_table
ease_bounce_d: dq 0x3fef800000000000 ; 0.984375
ease_neg_one: dq 0xbff0000000000000 ; -1.0
ease_back_c2: dq 0x4004c25fe974a340 ; 2.5949095
ease_four: dq 0x4010000000000000 ; 4.0
ease_two: dq 0x4000000000000000 ; 2.0
ease_back_twice_c2_plus_one: dq 0x401cc25fe974a340 ; 7.189819
ease_bounce_threshold_c: dq 0x3fed1745d1745d17 ; 0.9090909090909091
ease_bounce_shift_d: dq 0xbfee8ba2e8ba2e8c ; -0.9545454545454546
ease_back_c3: dq 0x40059cd5f99c38b0 ; 2.70158
ease_neg_ten: dq 0xc024000000000000 ; -10.0
ease_bounce_shift_c: dq 0xbfea2e8ba2e8ba2f ; -0.8181818181818182
ease_sixteen: dq 0x4030000000000000 ; 16.0
ease_eight: dq 0x4020000000000000 ; 8.0
ease_one: dq 0x3ff0000000000000 ; 1.0
ease_neg_two: dq 0xc000000000000000 ; -2.0
ease_bounce_threshold_a: dq 0x3fd745d1745d1746 ; 0.36363636363636365
ease_bounce_b: dq 0x3fe8000000000000 ; 0.75
ease_ten: dq 0x4024000000000000 ; 10.0
ease_neg_half: dq 0xbfe0000000000000 ; -0.5
ease_back_c1: dq 0x3ffb39abf3387161 ; 1.70158
ease_five: dq 0x4014000000000000 ; 5.0
ease_half: dq 0x3fe0000000000000 ; 0.5
ease_elastic_c5: dq 0x3ff657184ae74487 ; 1.3962634015954636
ease_neg_elastic_c4: dq 0xc000c152382d7365 ; -2.0943951023931953
ease_bounce_threshold_b: dq 0x3fe745d1745d1746 ; 0.7272727272727273
ease_back_c2_plus_one: dq 0x400cc25fe974a340 ; 3.5949095
ease_three: dq 0x4008000000000000 ; 3.0
ease_bounce_n: dq 0x401e400000000000 ; 7.5625
ease_neg_three_quarters: dq 0xbfe8000000000000 ; -0.75
ease_bounce_c: dq 0x3fee000000000000 ; 0.9375
ease_neg_ten_three_quarters: dq 0xc025800000000000 ; -10.75
ease_bounce_shift_b: dq 0xbfe1745d1745d174 ; -0.5454545454545454
ease_elastic_c4: dq 0x4000c152382d7365 ; 2.0943951023931953
ease_neg_back_c1: dq 0xbffb39abf3387161 ; -1.70158
ease_twenty: dq 0x4034000000000000 ; 20.0
ease_neg_eleven_eighth: dq 0xc026400000000000 ; -11.125
ease_neg_back_c2: dq 0xc004c25fe974a340 ; -2.5949095
ease_pi: dq 0x400921fb54442d18 ; 3.141592653589793

; Caller-owned storage (alloc or embedded in an effect's state).
struc EasingTracker
    .easing:           resq 1           ; id 0..30
    .total_steps:      resq 1           ; signed i64, including zero/negative
    .clamp:            resq 1           ; 0 or 1
    .current_step:     resq 1
    .progress_ratio:   resq 1           ; f64 fields from here onward
    .step_delta:       resq 1
    .eased_value:      resq 1
    .last_eased_value: resq 1
endstruc

struc SequenceStep
    .added:            resq 1           ; borrowed u64 slice (pointer, count)
    .added_count:      resq 1
    .removed:          resq 1           ; always in original sequence order
    .removed_count:    resq 1
    .current:          resq 1           ; current prefix (pointer, count)
    .current_count:    resq 1
endstruc

struc SequenceEaser
    .tracker:          resb EasingTracker_size
    .sequence:         resq 1           ; borrowed immutable u64 array
    .length:           resq 1
    .result:           resb SequenceStep_size
endstruc

section .text

; easing_tracker_new(rdi=storage, esi=id, rdx=total_steps, ecx=clamp)
; -> rax=storage. EasingTracker::new; clobbers rax, xmm0.
easing_tracker_new:
    mov     eax, esi
    mov     [rdi + EasingTracker.easing], rax
    mov     [rdi + EasingTracker.total_steps], rdx
    mov     eax, ecx
    mov     [rdi + EasingTracker.clamp], rax
    jmp     easing_tracker_reset

; easing_tracker_reset(rdi=tracker) -> rax=tracker.
; EasingTracker::reset; clobbers rax, xmm0.
easing_tracker_reset:
    mov     qword [rdi + EasingTracker.current_step], 0
    xorpd   xmm0, xmm0
    movsd   [rdi + EasingTracker.progress_ratio], xmm0
    movsd   [rdi + EasingTracker.step_delta], xmm0
    movsd   [rdi + EasingTracker.eased_value], xmm0
    movsd   [rdi + EasingTracker.last_eased_value], xmm0
    mov     rax, rdi
    ret

; easing_tracker_is_complete(rdi=tracker) -> eax=0/1.
; EasingTracker::is_complete; clobbers rax.
easing_tracker_is_complete:
    mov     rax, [rdi + EasingTracker.current_step]
    cmp     rax, [rdi + EasingTracker.total_steps]
    setge   al
    movzx   eax, al
    ret

; easing_tracker_step(rdi=tracker) -> xmm0=eased value.
; EasingTracker::step; clobbers all caller-saved registers.
; Completed trackers retain their last delta, ratio and value.
easing_tracker_step:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + EasingTracker.current_step]
    cmp     rax, [rbx + EasingTracker.total_steps]
    jge     .done
    inc     rax
    mov     [rbx + EasingTracker.current_step], rax
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [rbx + EasingTracker.total_steps]
    divsd   xmm0, xmm1
    movsd   [rbx + EasingTracker.progress_ratio], xmm0
    mov     edi, [rbx + EasingTracker.easing]
    call    ease
    cmp     qword [rbx + EasingTracker.clamp], 0
    je      .value
    minsd   xmm0, [ease_one]            ; NaN -> 1, like min(1).max(0)
    xorpd   xmm1, xmm1
    maxsd   xmm0, xmm1
.value:
    movsd   [rbx + EasingTracker.eased_value], xmm0
    movapd  xmm1, xmm0
    subsd   xmm1, [rbx + EasingTracker.last_eased_value]
    movsd   [rbx + EasingTracker.step_delta], xmm1
    movsd   [rbx + EasingTracker.last_eased_value], xmm0
.done:
    movsd   xmm0, [rbx + EasingTracker.eased_value]
    pop     rbx
    ret

; sequence_easer_new(rdi=storage, rsi=u64 array, rdx=count, ecx=id,
;                    r8=total_steps) -> rax=storage.
; SequenceEaser::new. The array must outlive the easer; no allocation/copy.
; Clobbers rax, rcx, rdx, rsi, xmm0. Array/count may be replaced before reset
; (Sweep's second phase). Counts must describe a valid u64 array.
sequence_easer_new:
    mov     [rdi + SequenceEaser.sequence], rsi
    mov     [rdi + SequenceEaser.length], rdx
    mov     esi, ecx
    mov     rdx, r8
    mov     ecx, 1
    call    easing_tracker_new
    jmp     sequence_easer_clear_result

; sequence_easer_reset(rdi=easer) -> rax=easer.
; SequenceEaser::reset; clears the borrowed result, retaining array/config.
; Clobbers rax, rcx, xmm0.
sequence_easer_reset:
    call    easing_tracker_reset
sequence_easer_clear_result:
    mov     rcx, [rdi + SequenceEaser.sequence]
    mov     [rdi + SequenceEaser.result + SequenceStep.added], rcx
    mov     [rdi + SequenceEaser.result + SequenceStep.removed], rcx
    mov     [rdi + SequenceEaser.result + SequenceStep.current], rcx
    mov     qword [rdi + SequenceEaser.result + SequenceStep.added_count], 0
    mov     qword [rdi + SequenceEaser.result + SequenceStep.removed_count], 0
    mov     qword [rdi + SequenceEaser.result + SequenceStep.current_count], 0
    ret

; sequence_easer_is_complete(rdi=easer) -> eax=0/1; clobbers rax.
sequence_easer_is_complete:
    jmp     easing_tracker_is_complete

; sequence_easer_step(rdi=easer) -> rax=&easer.result (SequenceStep).
; SequenceEaser::step, plus the current prefix for effect consumers.
; Result is valid until the next step/reset. Slices borrow the input array;
; a zero count means empty (including when the array pointer is null).
; Clobbers all caller-saved registers. No per-frame allocation.
sequence_easer_step:
    push    rbx
    sub     rsp, 8
    mov     rbx, rdi
    movsd   xmm0, [rbx + EasingTracker.eased_value]
    movsd   [rsp], xmm0
    call    easing_tracker_step
    ; A valid u64 array is at most isize::MAX / 8 elements, so its length
    ; fits i64. Clamp ensures products are finite and in [0, length],
    ; hence cvttsd2si exactly implements Rust's saturating cast here.
    cvtsi2sd xmm1, qword [rbx + SequenceEaser.length]
    mulsd   xmm0, xmm1
    cvttsd2si rdx, xmm0                 ; new prefix length
    mulsd   xmm1, [rsp]
    cvttsd2si rcx, xmm1                 ; previous prefix length
    mov     rsi, [rbx + SequenceEaser.sequence]
    lea     rax, [rbx + SequenceEaser.result]
    mov     [rax + SequenceStep.current], rsi
    mov     [rax + SequenceStep.current_count], rdx
    mov     [rax + SequenceStep.added], rsi
    mov     [rax + SequenceStep.removed], rsi
    mov     qword [rax + SequenceStep.added_count], 0
    mov     qword [rax + SequenceStep.removed_count], 0
    cmp     rdx, rcx
    je      .done
    jb      .removed
    lea     rsi, [rsi + rcx * 8]
    sub     rdx, rcx
    mov     [rax + SequenceStep.added], rsi
    mov     [rax + SequenceStep.added_count], rdx
    jmp     .done
.removed:
    lea     rsi, [rsi + rdx * 8]
    sub     rcx, rdx
    mov     [rax + SequenceStep.removed], rsi
    mov     [rax + SequenceStep.removed_count], rcx
.done:
    add     rsp, 8
    pop     rbx
    ret
