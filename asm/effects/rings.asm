; effects/rings.asm - "Characters are dispersed and form into spinning rings"
; (src/effects/rings.rs).
;
; Config (src/asm/effects.rs, the Rings arm).
;
; Rust gives every ring character one single-waypoint path per ring
; coordinate ("0", "1", ...), chained in a loop. Here one engine path (RING)
; stands in for all of them: activating ring path k points its waypoint at
; the k-th rotated coordinate and swaps in path k's own total and origin
; distance (a path's total drifts by rounding across activations, so each
; keeps its history), then stores them back. The chain event becomes a
; callback that activates k + 1. Condense paths are ordinary engine paths.
;
; The "disperse" path is removed and recreated each cycle upstream; here it
; is emptied in place (path_reset), which is the same path afterwards.

struc RINGS
    .ring_colors:       resq 1          ; *const u64
    .ring_color_count:  resq 1
    .ring_gap:          resq 1          ; f64
    .spin_duration:     resq 1
    .spin_speed_lo:     resq 1          ; f64
    .spin_speed_hi:     resq 1          ; f64
    .disperse_duration: resq 1
    .cycles:            resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; RingsIterator.Ring
struc RING
    .ccw:       resq 1                  ; counter-clockwise coordinates
    .cw:        resq 1                  ; the same, reversed
    .n:         resq 1
    .color:     resq 1
    .speed:     resq 1                  ; f64 rotation_speed
endstruc

; per ring character (ch_user0 points here)
struc RINGCH
    .coords:    resq 1                  ; the ring's coordinates in its direction
    .n:         resq 1
    .start:     resq 1                  ; character_starting_index
    .cur:       resq 1                  ; the ring path RING stands for now
    .last:      resq 1                  ; character_last_ring_path: >= 0 a ring
                                        ; path, < 0 the engine path ~last
    .dist:      resq 1                  ; n x (total_distance, origin distance)
    .rpath:     resd 1                  ; RING
    .dpath:     resd 1                  ; DISPERSE
    .gscene:    resd 1
    .dscene:    resd 1
endstruc

; ch_user1: the home path (low half); EXTERNAL_BIT marks non-ring characters
%define EXTERNAL_BIT        32

; scene names
%define SCN_GRADIENT        NAME_LITERAL + 0
%define SCN_DISPERSE        NAME_LITERAL + 1
; path names
%define PATH_HOME           NAME_LITERAL + 0
%define PATH_EXTERNAL       NAME_LITERAL + 1
%define PATH_RING           NAME_LITERAL + 2
%define PATH_DISPERSE       NAME_LITERAL + 3

%define EASE_OUT_SINE       2
%define EASE_OUT_QUAD       5
%define EASE_OUT_CUBIC      8

%define PH_START            0
%define PH_DISPERSE         1
%define PH_SPIN             2
%define PH_FINAL            3
%define PH_COMPLETE         4

section .text

; rings_build: Rings::build.
rings_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    ; ring_gap = max(round(min(top, right) * ring_gap), 1)
    mov     rax, [canvas_top]
    cmp     rax, [canvas_right]
    cmovg   rax, [canvas_right]
    cvtsi2sd xmm0, rax
    mulsd   xmm0, [rbx + RINGS.ring_gap]
    call    round_half_even
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [ring_gap], rax
    call    rings_final_map
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [rings_dynamic], al
    ; every input character: start scene, home path, visible
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax                    ; becomes pending_chars
    mov     r13, rdx
    xor     r14d, r14d
.start_char:
    cmp     r14, r13
    jae     .shuffle
    mov     r15d, [r12 + r14 * 4]
    mov     edi, r15d
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     ebp, eax
    mov     edi, r15d
    call    rings_final_colors          ; rax = fg, rdx = bg
    mov     rcx, rax
    mov     r8, rdx
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r15 * 8]
    mov     edi, ebp
    mov     edx, 1
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, r15d
    movsd   xmm0, [rings_speed_home]
    mov     esi, EASE_OUT_QUAD
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, PATH_HOME
    call    path_new
    mov     rcx, [ch_user1]
    mov     eax, eax
    mov     [rcx + r15 * 8], rax        ; home path, not external
    mov     [rsp], eax
    mov     edi, r15d
    call    char_input_coord
    mov     rsi, rax
    mov     edi, [rsp]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, r15d
    mov     esi, ebp
    call    scene_activate
    mov     edi, r15d
    call    set_visible
    inc     r14
    jmp     .start_char
.shuffle:
    mov     rdi, r12
    mov     rsi, r13
    call    rng_shuffle32
    call    rings_make
    ; assign characters to rings, alternating directions
    lea     rdi, [r13 * 4 + 64]
    call    alloc
    mov     [ring_list], rax
    xor     r14d, r14d                  ; pending index
    xor     r15d, r15d                  ; ring index
.ring:
    cmp     r15, [ring_count]
    jae     .external
    xor     ebp, ebp                    ; position on the ring
.ring_slot:
    imul    rax, r15, RING_size
    add     rax, [rings_array]
    cmp     rbp, [rax + RING.n]
    jae     .next_ring
    cmp     r14, r13
    jae     .next_ring                  ; (the remaining pops find nothing)
    mov     edi, [r12 + r14 * 4]
    inc     r14
    mov     rsi, rax
    mov     edx, r15d
    and     edx, 1                      ; clockwise on odd rings
    mov     rcx, rbp
    call    ring_add_character
    inc     rbp
    jmp     .ring_slot
.next_ring:
    inc     r15
    jmp     .ring
.external:
    ; characters not in rings leave the canvas
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    lea     rdi, [r13 * 4 + 64]
    call    alloc
    mov     [rings_ext_list], rax
    xor     r14d, r14d
.ext_char:
    cmp     r14, r13
    jae     .state
    mov     r15d, [r12 + r14 * 4]
    inc     r14
    mov     rax, [ch_user0]
    cmp     qword [rax + r15 * 8], 0
    jne     .ext_char
    mov     edi, 1
    xor     esi, esi
    call    canvas_random_coord
    mov     rbp, rax
    mov     edi, r15d
    movsd   xmm0, [rings_speed_home]
    mov     esi, EASE_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, PATH_EXTERNAL
    call    path_new
    mov     edi, eax
    mov     rsi, rbp
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     rax, [ch_user1]
    bts     qword [rax + r15 * 8], EXTERNAL_BIT
    mov     rax, [rings_ext_list]
    mov     rcx, [rings_ext_count]
    mov     [rax + rcx * 4], r15d
    inc     qword [rings_ext_count]
    push    0
    push    0
    mov     edi, r15d
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, PATH_EXTERNAL
    mov     r8d, ACT_CALLBACK
    lea     r9, [rings_set_invisible]
    call    event_register
    add     rsp, 16
    jmp     .ext_char
.state:
    mov     byte [rings_phase], PH_START
    mov     byte [rings_initial_done], 0
    mov     rax, [rbx + RINGS.spin_duration]
    mov     [rings_spin_left], rax
    mov     rax, [rbx + RINGS.disperse_duration]
    mov     [rings_disperse_left], rax
    mov     rax, [rbx + RINGS.cycles]
    mov     [rings_cycles_left], rax
    mov     qword [rings_initial_left], 100
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rings_make: rings from radius 1 outward by ring_gap until less than a
; quarter of a ring's coordinates are on the canvas. Ring.__init__ draws
; the rotation speed.
rings_make:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r14, [canvas_right]
    cmp     r14, [canvas_top]
    cmovl   r14, [canvas_top]           ; radius limit
    ; at most one ring per radius below the limit
    lea     rdi, [r14 + 1]
    imul    rdi, rdi, RING_size
    call    alloc
    mov     [rings_array], rax
    mov     r15d, 1                     ; radius
.radius:
    cmp     r15, r14
    jge     .done
    mov     rdi, [center_row]
    shl     rdi, 32
    mov     eax, [center_col]
    or      rdi, rax
    mov     rsi, r15
    imul    rdx, r15, 7
    mov     ecx, 1
    call    find_coords_on_circle
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx                    ; coordinates in the canvas
    xor     ebp, ebp
.count:
    cmp     rbp, r13
    jae     .counted
    mov     rsi, [r12 + rbp * 8]
    call    coord_in_canvas
    add     ebx, eax
    inc     rbp
    jmp     .count
.counted:
    cvtsi2sd xmm0, rbx
    cvtsi2sd xmm1, r13
    divsd   xmm0, xmm1
    movsd   xmm1, [rings_quarter]
    ucomisd xmm1, xmm0
    ja      .done                       ; ratio < 0.25 (NaN is not)
    mov     rbx, [ring_count]
    imul    rbp, rbx, RING_size
    add     rbp, [rings_array]
    mov     [rbp + RING.ccw], r12
    mov     [rbp + RING.n], r13
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, [effect_config]
    div     qword [rcx + RINGS.ring_color_count]
    mov     rax, [rcx + RINGS.ring_colors]
    mov     rax, [rax + rdx * 8]
    mov     [rbp + RING.color], rax
    lea     rdi, [r13 * 8]
    call    alloc
    mov     [rbp + RING.cw], rax
    lea     rcx, [r12 + r13 * 8 - 8]
    xor     edx, edx
.reverse:
    cmp     rdx, r13
    jae     .speed
    mov     rsi, [rcx]
    mov     [rax + rdx * 8], rsi
    sub     rcx, 8
    inc     rdx
    jmp     .reverse
.speed:
    mov     rcx, [effect_config]
    movsd   xmm0, [rcx + RINGS.spin_speed_lo]
    movsd   xmm1, [rcx + RINGS.spin_speed_hi]
    call    rng_uniform
    movsd   [rbp + RING.speed], xmm0
    inc     qword [ring_count]
    add     r15, [ring_gap]
    jmp     .radius
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ring_add_character(edi=slot, rsi=ring, edx=clockwise, rcx=starting index):
; Ring.add_character - gradient scene, the ring paths (RING) and their
; chain, disperse scene.
ring_add_character:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14, rcx
    mov     edi, RINGCH_size
    call    alloc
    mov     rbp, rax
    mov     rcx, [ch_user0]
    mov     [rcx + rbx * 8], rbp
    mov     rax, [r12 + RING.ccw]
    test    r13d, r13d
    cmovnz  rax, [r12 + RING.cw]
    mov     [rbp + RINGCH.coords], rax
    mov     rax, [r12 + RING.n]
    mov     [rbp + RINGCH.n], rax
    mov     [rbp + RINGCH.start], r14
    mov     rdi, rax
    shl     rdi, 4
    call    alloc
    mov     [rbp + RINGCH.dist], rax
    ; gradient: final color -> ring color, 3 ticks per color
    mov     edi, ebx
    mov     esi, SCN_GRADIENT
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rbp + RINGCH.gscene], eax
    mov     edi, eax
    mov     esi, ebx
    mov     rdx, r12
    xor     ecx, ecx                    ; final color first
    mov     r8d, 3
    call    ring_scene_frames
    ; the ring paths: RING, first at rotated[0]
    mov     edi, ebx
    movsd   xmm0, [r12 + RING.speed]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, PATH_RING
    call    path_new
    mov     [rbp + RINGCH.rpath], eax
    mov     edi, eax
    mov     rsi, [rbp + RINGCH.coords]
    mov     rsi, [rsi + r14 * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    ; disperse: ring color -> final color, 10 ticks per color
    mov     edi, ebx
    mov     esi, SCN_DISPERSE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rbp + RINGCH.dscene], eax
    mov     edi, eax
    mov     esi, ebx
    mov     rdx, r12
    mov     ecx, 1                      ; ring color first
    mov     r8d, 10
    call    ring_scene_frames
    ; the disperse path, filled by make_disperse_waypoints
    mov     edi, ebx
    movsd   xmm0, [rings_speed_disperse]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    mov     r8d, 1
    mov     r9d, PATH_DISPERSE
    call    path_new
    mov     [rbp + RINGCH.dpath], eax
    ; chain_paths(ring_paths, loop): each completion activates the next
    cmp     qword [rbp + RINGCH.n], 2
    jb      .chained
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, PATH_RING
    mov     r8d, ACT_CALLBACK
    lea     r9, [ring_advance]
    call    event_register
    add     rsp, 16
.chained:
    mov     rax, [ring_list]
    mov     rcx, [ring_list_count]
    mov     [rax + rcx * 4], ebx
    inc     qword [ring_list_count]
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ring_scene_frames(edi=scene, esi=slot, rdx=ring, ecx=ring color first,
; r8d=duration): the input colors for one tick when dynamic, otherwise the
; 8-step gradient between the final color and the ring color.
ring_scene_frames:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15d, r8d
    mov     edi, esi
    call    rings_final_colors
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + r12 * 8]
    cmp     byte [rings_dynamic], 0
    je      .gradient
    mov     rcx, rax
    mov     r8, rdx
    mov     edi, ebx
    mov     edx, 1
    xor     r9d, r9d
    call    scene_add_frame
    jmp     .done
.gradient:
    mov     [rings_sym], rsi
    mov     rcx, [r13 + RING.color]
    test    r14d, r14d
    jz      .order
    xchg    rax, rcx
.order:
    mov     [rings_pair_stops], rax
    mov     [rings_pair_stops + 8], rcx
    lea     rdi, [rings_pair_stops]
    mov     esi, 2
    lea     rdx, [rings_eight_steps]
    mov     ecx, 1
    lea     r8, [rings_pair_spectrum]
    call    gradient_new
    push    0
    push    0
    mov     edi, ebx
    lea     rsi, [rings_sym]
    mov     edx, 1
    mov     ecx, r15d
    lea     r8, [rings_pair_spectrum]
    mov     r9d, eax
    call    scene_apply_gradient
    add     rsp, 16
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; final colors(edi=slot) -> rax = fg, rdx = bg: character_final_color_map -
; the input colors when dynamic, else the final gradient at the input
; coordinate over no background.
rings_final_colors:
    cmp     byte [rings_dynamic], 0
    je      .mapped
    mov     rax, [ch_fg]
    mov     rax, [rax + rdi * 8]
    mov     rdx, [ch_bg]
    mov     rdx, [rdx + rdi * 8]
    ret
.mapped:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rdi * 4]
    sub     rax, [text_bottom]
    imul    rax, [rings_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rdi * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [rings_final_map_ptr]
    mov     rax, [rcx + rax * 8]
    mov     rdx, NONE
    ret

; rings_final_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
rings_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + RINGS.final_steps]
    mov     rcx, [rbx + RINGS.final_step_count]
    mov     rsi, [rbx + RINGS.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [rings_final_spectrum], rax
    mov     rdi, [rbx + RINGS.final_stops]
    mov     rsi, [rbx + RINGS.final_stop_count]
    mov     rdx, [rbx + RINGS.final_steps]
    mov     rcx, [rbx + RINGS.final_step_count]
    mov     r8, [rings_final_spectrum]
    call    gradient_new
    mov     rdi, [rings_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [rings_final_map_width], rax
    push    qword [rbx + RINGS.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [rings_final_map_ptr], rax
    pop     rbx
    ret

; ------------------------------------------------------------ ring paths

; ring_activate(edi=slot, rsi=k): activate_path(ring path "k") through RING:
; its waypoint becomes rotated[k] and it carries path k's distances.
ring_activate:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, [ch_user0]
    mov     r12, [r12 + rbx * 8]
    mov     [r12 + RINGCH.cur], rsi
    mov     r13, rsi
    shl     r13, 4
    add     r13, [r12 + RINGCH.dist]    ; (total, origin distance) of path k
    mov     rax, [r12 + RINGCH.start]
    add     rax, rsi
    xor     edx, edx
    div     qword [r12 + RINGCH.n]
    mov     rax, [r12 + RINGCH.coords]
    mov     rcx, [rax + rdx * 8]
    mov     esi, [r12 + RINGCH.rpath]
    PATH_PTR rax, rsi
    mov     rdx, [rax + PA_WPS]
    mov     [rdx + WP_COORD], rcx
    movsd   xmm0, [r13]
    movsd   [rax + PA_TOTAL], xmm0
    movsd   xmm0, [r13 + 8]
    movsd   [rax + PA_ORIGIN_DIST], xmm0
    mov     edi, ebx
    call    path_activate
    mov     esi, [r12 + RINGCH.rpath]
    PATH_PTR rax, rsi
    movsd   xmm0, [rax + PA_TOTAL]
    movsd   [r13], xmm0
    movsd   xmm0, [rax + PA_ORIGIN_DIST]
    movsd   [r13 + 8], xmm0
    pop     r13
    pop     r12
    pop     rbx
    ret

; ring_advance(edi=slot): the chain event - ring path k completed, k + 1
; (wrapping) activates.
ring_advance:
    mov     rax, [ch_user0]
    mov     rax, [rax + rdi * 8]
    mov     rsi, [rax + RINGCH.cur]
    inc     rsi
    xor     ecx, ecx
    cmp     rsi, [rax + RINGCH.n]
    cmovae  rsi, rcx
    jmp     ring_activate

; rings_set_invisible(edi=slot): CB_SET_INVISIBLE.
rings_set_invisible:
    xor     esi, esi
    jmp     set_visibility

; make_disperse_waypoints(edi=slot, rsi=origin): five random coordinates of
; find_coords_in_rect(origin, ring_gap), then the disperse path is made
; afresh with them.
ring_make_disperse:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, [ring_gap]
    lea     r14, [r13 * 2 + 1]          ; side
    xor     r15d, r15d
.draw:
    xor     edi, edi
    mov     rsi, r14
    imul    rsi, r14
    call    rng_randrange
    cqo
    idiv    r14                         ; column index, row index
    movsxd  rcx, r12d
    sub     rcx, r13
    add     rax, rcx                    ; column
    mov     rcx, r12
    sar     rcx, 32
    sub     rcx, r13
    add     rdx, rcx                    ; row
    shl     rdx, 32
    mov     eax, eax
    or      rax, rdx
    mov     [rsp + r15 * 8], rax
    inc     r15d
    cmp     r15d, 5
    jb      .draw
    mov     rax, [ch_user0]
    mov     rax, [rax + rbx * 8]
    mov     ebp, [rax + RINGCH.dpath]
    mov     edi, ebp
    call    path_reset
    xor     r15d, r15d
.waypoint:
    mov     edi, ebp
    mov     rsi, [rsp + r15 * 8]
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    inc     r15d
    cmp     r15d, 5
    jb      .waypoint
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ------------------------------------------------------------ phases

; initial disperse: every ring character heads (eased) to the first
; waypoint of a fresh disperse path around its ring start, which then loops;
; the other characters leave the canvas.
rings_initial_disperse:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    xor     r12d, r12d
.ring_char:
    cmp     r12, [ring_list_count]
    jae     .external
    mov     rax, [ring_list]
    mov     ebx, [rax + r12 * 4]
    inc     r12
    mov     rbp, [ch_user0]
    mov     rbp, [rbp + rbx * 8]
    mov     rax, [rbp + RINGCH.coords]
    mov     rcx, [rbp + RINGCH.start]
    mov     rsi, [rax + rcx * 8]        ; ring path "0"'s waypoint
    mov     edi, ebx
    call    ring_make_disperse
    mov     esi, [rbp + RINGCH.dpath]
    PATH_PTR rax, rsi
    mov     rax, [rax + PA_WPS]
    mov     r13, [rax + WP_COORD]
    mov     edi, ebx
    movsd   xmm0, [rings_speed_initial]
    mov     esi, EASE_OUT_CUBIC
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r14d, eax
    mov     edi, eax
    mov     rsi, r13
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    PATH_PTR rax, r14
    push    0
    push    0
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    mov     ecx, [rax + PA_NAME]
    mov     r8d, ACT_ACTIVATE_PATH
    mov     r9d, PATH_DISPERSE
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    mov     esi, [rbp + RINGCH.dscene]
    call    scene_activate
    mov     edi, ebx
    mov     esi, r14d
    call    path_activate
    mov     edi, ebx
    call    active_insert
    jmp     .ring_char
.external:
    xor     r12d, r12d
.ext_char:
    cmp     r12, [rings_ext_count]
    jae     .done
    mov     rax, [rings_ext_list]
    mov     ebx, [rax + r12 * 4]
    inc     r12
    mov     edi, ebx
    mov     esi, PATH_EXTERNAL
    call    path_activate_name
    mov     edi, ebx
    call    active_insert
    jmp     .ext_char
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rings_spin: Ring.spin for every ring - a condense path back to the first
; waypoint of the character's last ring path, which resumes on arrival.
rings_spin:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    xor     r12d, r12d
.char:
    cmp     r12, [ring_list_count]
    jae     .done
    mov     rax, [ring_list]
    mov     ebx, [rax + r12 * 4]
    inc     r12
    mov     rbp, [ch_user0]
    mov     rbp, [rbp + rbx * 8]
    mov     r15, [rbp + RINGCH.last]
    test    r15, r15
    js      .engine_path
    mov     rax, [rbp + RINGCH.start]
    add     rax, r15
    xor     edx, edx
    div     qword [rbp + RINGCH.n]
    mov     rax, [rbp + RINGCH.coords]
    mov     r13, [rax + rdx * 8]
    jmp     .condense
.engine_path:
    mov     rax, r15
    not     rax
    PATH_PTR rcx, rax
    mov     rax, [rcx + PA_WPS]
    mov     r13, [rax + WP_COORD]
.condense:
    mov     edi, ebx
    movsd   xmm0, [rings_speed_condense]
    mov     esi, NONE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, AUTO
    call    path_new
    mov     r14d, eax
    mov     edi, eax
    mov     rsi, r13
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    PATH_PTR rax, r14
    mov     ecx, [rax + PA_NAME]
    mov     edi, ebx
    mov     esi, EV_PATH_COMPLETE
    mov     edx, CALLER_PATH
    test    r15, r15
    js      .to_engine_path
    push    0
    push    r15
    mov     r8d, ACT_CALLBACK
    lea     r9, [ring_activate]
    jmp     .register
.to_engine_path:
    push    0
    push    0
    mov     rax, r15
    not     rax
    PATH_PTR r9, rax
    mov     r9d, [r9 + PA_NAME]
    mov     r8d, ACT_ACTIVATE_PATH
.register:
    call    event_register
    add     rsp, 16
    mov     edi, ebx
    mov     esi, r14d
    call    path_activate
    mov     edi, ebx
    mov     esi, [rbp + RINGCH.gscene]
    call    scene_activate
    jmp     .char
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rings_disperse: Ring.disperse for every ring - remember the active ring
; path, then loop around a fresh disperse path.
rings_disperse:
    push    rbx
    push    rbp
    push    r12
    xor     r12d, r12d
.char:
    cmp     r12, [ring_list_count]
    jae     .done
    mov     rax, [ring_list]
    mov     ebx, [rax + r12 * 4]
    inc     r12
    mov     rbp, [ch_user0]
    mov     rbp, [rbp + rbx * 8]
    mov     rax, [ch_path]
    mov     eax, [rax + rbx * 4]
    xor     ecx, ecx                    ; no active path: "0"
    cmp     eax, NONE
    je      .last
    mov     rcx, [rbp + RINGCH.cur]
    cmp     eax, [rbp + RINGCH.rpath]
    je      .last
    not     rax                         ; another path (a condense path)
    mov     rcx, rax
.last:
    mov     [rbp + RINGCH.last], rcx
    mov     edi, ebx
    call    char_coord
    mov     rsi, rax
    mov     edi, ebx
    call    ring_make_disperse
    mov     edi, ebx
    mov     esi, [rbp + RINGCH.dpath]
    call    path_activate
    mov     edi, ebx
    mov     esi, [rbp + RINGCH.dscene]
    call    scene_activate
    jmp     .char
.done:
    pop     r12
    pop     rbp
    pop     rbx
    ret

; rings_final: everyone visible and home; ring characters fade back.
rings_final:
    push    rbx
    push    r12
    push    r13
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
.char:
    test    r13, r13
    jz      .done
    mov     ebx, [r12]
    add     r12, 4
    dec     r13
    mov     edi, ebx
    call    set_visible
    mov     rax, [ch_user1]
    mov     esi, [rax + rbx * 8]
    mov     edi, ebx
    call    path_activate
    mov     edi, ebx
    call    active_insert
    mov     rax, [ch_user1]
    bt      qword [rax + rbx * 8], EXTERNAL_BIT
    jc      .char
    mov     rax, [ch_user0]
    mov     rax, [rax + rbx * 8]
    mov     esi, [rax + RINGCH.dscene]
    mov     edi, ebx
    call    scene_activate
    jmp     .char
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rings_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
rings_next_frame:
    push    rbx
    mov     rbx, [effect_config]
    movzx   eax, byte [rings_phase]
    cmp     eax, PH_START
    je      .start
    cmp     eax, PH_DISPERSE
    je      .disperse
    cmp     eax, PH_SPIN
    je      .spin
    cmp     eax, PH_FINAL
    je      .final
    xor     eax, eax                    ; complete
    pop     rbx
    ret
.start:
    cmp     qword [rings_initial_left], 0
    jne     .start_wait
    mov     byte [rings_phase], PH_DISPERSE
    jmp     .update
.start_wait:
    dec     qword [rings_initial_left]
    jmp     .update
.disperse:
    cmp     byte [rings_initial_done], 0
    jne     .dispersed
    mov     byte [rings_initial_done], 1
    call    rings_initial_disperse
    jmp     .update
.dispersed:
    cmp     qword [rings_disperse_left], 0
    jne     .disperse_wait
    mov     byte [rings_phase], PH_SPIN
    dec     qword [rings_cycles_left]
    mov     rax, [rbx + RINGS.spin_duration]
    mov     [rings_spin_left], rax
    call    rings_spin
    jmp     .update
.disperse_wait:
    dec     qword [rings_disperse_left]
    jmp     .update
.spin:
    cmp     qword [rings_spin_left], 0
    jne     .spin_wait
    cmp     qword [rings_cycles_left], 0
    jne     .again
    mov     byte [rings_phase], PH_FINAL
    call    rings_final
    jmp     .update
.again:
    mov     rax, [rbx + RINGS.disperse_duration]
    mov     [rings_disperse_left], rax
    call    rings_disperse
    mov     byte [rings_phase], PH_DISPERSE
    jmp     .update
.spin_wait:
    dec     qword [rings_spin_left]
    jmp     .update
.final:
    call    active_empty
    test    eax, eax
    jz      .update
    mov     byte [rings_phase], PH_COMPLETE
.update:
    call    update
    mov     eax, 1
    pop     rbx
    ret

section .rodata
align 8
rings_eight_steps:      dq 8
rings_quarter:          dq 0.25
rings_speed_home:       dq 0.8
rings_speed_disperse:   dq 0.14
rings_speed_initial:    dq 0.3
rings_speed_condense:   dq 0.1

section .tstate
alignb 8
ring_gap:               resq 1
rings_array:            resq 1
ring_count:             resq 1
ring_list:              resq 1          ; ring characters, ring by ring
ring_list_count:        resq 1
rings_ext_list:         resq 1          ; non_ring_chars
rings_ext_count:        resq 1
rings_spin_left:        resq 1
rings_disperse_left:    resq 1
rings_cycles_left:      resq 1
rings_initial_left:     resq 1
rings_sym:              resq 1
rings_final_spectrum:   resq 1
rings_final_map_ptr:    resq 1
rings_final_map_width:  resq 1
rings_pair_stops:       resq 2
rings_pair_spectrum:    resq 16
rings_dynamic:          resb 1
rings_phase:            resb 1
rings_initial_done:     resb 1
