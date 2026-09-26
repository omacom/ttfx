; effects/swarm.asm - "Characters are grouped into swarms and move around the
; terminal before settling into position" (src/effects/swarm.rs).
;
; Config (src/asm/effects.rs, the Swarm arm).
;
; Path names: swarm area a ("{a}_swarm_area") is NAME_LITERAL + a; the inner
; paths are Rust's decimal ids (the path count when made: 3a + 1, 3a + 2) and
; the landing path is the auto id 3k. So "contains swarm_area" is "name >=
; NAME_LITERAL", and int(s[0]) is the leading decimal digit of a.
; Scene names: the flash scene is auto id "0", the landing scene "1".
;
; Upstream's find_coords_on_circle is lru_cached and swarm shuffles the list
; it returns in place, so a later call with the same focus coordinate sees
; the shuffled list. swm_cache keeps one list per coordinate for the run, the
; same as Rust's effect-level circle_cache. find_coords_in_circle is pure, so
; it is cached alongside.

struc SWARM
    .base_colors:       resq 1          ; *const u64
    .base_count:        resq 1
    .flash_color:       resq 1
    .swarm_size:        resq 1          ; f64
    .coordination:      resq 1          ; f64
    .area_lo:           resq 1
    .area_hi:           resq 1
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; circle cache entry (32 bytes); an empty slot has on_count 0
%define SWM_CE_KEY          0
%define SWM_CE_ON           8           ; find_coords_on_circle list
%define SWM_CE_ON_N         16          ; u32
%define SWM_CE_IN_N         20          ; u32
%define SWM_CE_IN           24          ; find_coords_in_circle list

; a swarm's area map entry (32 bytes): key coordinate, in-circle list, count
%define SWM_AR_KEY          0
%define SWM_AR_IN           8
%define SWM_AR_IN_N         16

%define SWM_FLASH_SCENE     0
%define SWM_LAND_SCENE      1

%define SWM_EASE_OUT_SINE       2
%define SWM_EASE_IN_OUT_SINE    3
%define SWM_EASE_IN_OUT_QUAD    6

; SWM_EVENT slot, event, caller path name, action, arg0 (no arg1)
%macro SWM_EVENT 5
    push    0
    push    0
    mov     edi, %1
    mov     esi, %2
    mov     edx, CALLER_PATH
    mov     ecx, %3
    mov     r8d, %4
    mov     r9, %5
    call    event_register
    add     rsp, 16
%endmacro

section .text

; swarm_build: Swarm::build.
swarm_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [effect_config]
    xor     eax, eax
    cmp     qword [cfg_existing_colors], 1
    sete    al
    mov     [swm_dynamic], al
    ; swarm_size = max(round(len(characters) * swarm_size), 1)
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    cvtsi2sd xmm0, rdx
    mulsd   xmm0, [rbx + SWARM.swarm_size]
    call    round_half_even
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [swm_size], rax
    call    swm_make_swarms
    call    swm_make_final_map
    ; radius = max(min(right, top) // 2, 1); area diameter max(.. // 6, 1) * 2
    mov     r12, [canvas_right]
    cmp     r12, [canvas_top]
    cmovg   r12, [canvas_top]
    mov     rdi, r12
    mov     esi, 2
    call    floor_div
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    mov     [swm_radius], rax
    mov     rdi, r12
    mov     esi, 6
    call    floor_div
    mov     ecx, 1
    cmp     rax, 1
    cmovl   rax, rcx
    add     rax, rax
    mov     [swm_diameter], rax
    ; the circle cache
    mov     qword [swm_cache_mask], 63
    mov     edi, 64 * 32
    call    alloc
    mov     [swm_cache], rax
    ; a swarm's area keys are distinct coordinates in [0, right + 1] x
    ; [0, top + 1] (spawns sit one outside the canvas), and at most area_hi
    mov     rax, [canvas_right]
    add     rax, 2
    mov     rcx, [canvas_top]
    add     rcx, 2
    imul    rax, rcx
    cmp     rax, [rbx + SWARM.area_hi]
    cmovg   rax, [rbx + SWARM.area_hi]
    mov     r12, rax
    mov     rdi, rax
    shl     rdi, 5
    call    alloc
    mov     [swm_areas], rax
    lea     rdi, [r12 * 3 + 1]
    shl     rdi, 2
    call    alloc
    mov     [swm_names], rax
    xor     r12d, r12d                  ; swarm index
.swarm:
    cmp     r12, [swm_nswarms]
    jae     .built
    ; swarm gradient: base -> flash in 7 steps, mirrored around 10 flashes
    mov     rdi, [rbx + SWARM.base_count]
    call    rng_below
    mov     rcx, [rbx + SWARM.base_colors]
    mov     rax, [rcx + rax * 8]
    mov     [swm_pair], rax
    mov     rax, [rbx + SWARM.flash_color]
    mov     [swm_pair + 8], rax
    lea     rdi, [swm_pair]
    mov     esi, 2
    lea     rdx, [swm_seven]
    mov     ecx, 1
    lea     r8, [swm_spectrum]
    call    gradient_new
    lea     rsi, [swm_spectrum]
    lea     rdi, [swm_mirror]
    xor     ecx, ecx
.up:
    mov     rdx, [rsi + rcx * 8]
    mov     [rdi], rdx
    add     rdi, 8
    inc     ecx
    cmp     ecx, eax
    jb      .up
    mov     rdx, [rbx + SWARM.flash_color]
    mov     ecx, 10
.flash:
    mov     [rdi], rdx
    add     rdi, 8
    dec     ecx
    jnz     .flash
    mov     ecx, eax
.down:
    dec     ecx
    mov     rdx, [rsi + rcx * 8]
    mov     [rdi], rdx
    add     rdi, 8
    test    ecx, ecx
    jnz     .down
    lea     eax, [rax * 2 + 10]
    mov     [swm_mirror_len], rax
    ; spawn and the swarm areas
    mov     edi, 1
    xor     esi, esi
    call    canvas_random_coord
    mov     [swm_spawn], rax
    mov     rdi, [rbx + SWARM.area_lo]
    mov     rsi, [rbx + SWARM.area_hi]
    call    rng_randint
    mov     r13, rax                    ; swarm_area_count
    xor     r14d, r14d                  ; len(swarm_areas)
    mov     r15, [swm_spawn]            ; last_focus_coord
    mov     qword [swm_k], 0
.area:
    cmp     r14, r13
    jge     .areas_done
    mov     rdi, r15
    call    swm_cache_get
    mov     rbp, rax
    mov     rdi, [rbp + SWM_CE_ON]
    mov     esi, [rbp + SWM_CE_ON_N]
    call    rng_shuffle64
    ; the first shuffled coordinate on the canvas, else a random one
    mov     rcx, [rbp + SWM_CE_ON]
    mov     edx, [rbp + SWM_CE_ON_N]
.scan:
    test    edx, edx
    jz      .random
    mov     rsi, [rcx]
    call    coord_in_canvas
    test    eax, eax
    jnz     .next_focus
    add     rcx, 8
    dec     edx
    jmp     .scan
.random:
    xor     edi, edi
    xor     esi, esi
    call    canvas_random_coord
    mov     rsi, rax
.next_focus:
    mov     [rsp], rsi
    inc     r14
    ; swarm_area_coordinate_map[last_focus_coord] = find_coords_in_circle(..)
    ; (a repeated key keeps its position and gets the same list)
    mov     rax, [swm_areas]
    mov     rcx, [swm_k]
.find_key:
    test    rcx, rcx
    jz      .new_key
    cmp     [rax + SWM_AR_KEY], r15
    je      .keyed
    add     rax, 32
    dec     rcx
    jmp     .find_key
.new_key:
    mov     [rax + SWM_AR_KEY], r15
    mov     rcx, [rbp + SWM_CE_IN]
    mov     [rax + SWM_AR_IN], rcx
    mov     ecx, [rbp + SWM_CE_IN_N]
    mov     [rax + SWM_AR_IN_N], rcx
    inc     qword [swm_k]
.keyed:
    mov     r15, [rsp]
    jmp     .area
.areas_done:
    ; path names in insertion order, for chain_paths
    mov     rdi, [swm_names]
    xor     ecx, ecx
    xor     edx, edx                    ; path count
.name:
    cmp     rcx, [swm_k]
    jae     .names_done
    mov     eax, ecx
    or      eax, NAME_LITERAL
    mov     [rdi + rdx * 4], eax
    lea     eax, [rdx + 1]
    mov     [rdi + rdx * 4 + 4], eax
    lea     eax, [rdx + 2]
    mov     [rdi + rdx * 4 + 8], eax
    add     edx, 3
    inc     ecx
    jmp     .name
.names_done:
    mov     [rdi + rdx * 4], edx        ; the landing path
    ; every character of the swarm
    mov     rax, r12
    shl     rax, 4
    add     rax, [swm_bounds]
    mov     r14, [rax]
    mov     r15, [rax + 8]
.char:
    cmp     r14, r15
    jae     .next_swarm
    mov     rax, [swm_order]
    mov     edi, [rax + r14 * 4]
    call    swm_build_char
    inc     r14
    jmp     .char
.next_swarm:
    inc     r12
    jmp     .swarm
.built:
    mov     byte [swm_call_next], 1
    mov     dword [swm_active_area], NAME_LITERAL
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; swm_make_swarms: SwarmIterator.make_swarms. Swarms pop from the end of
; the bottom-to-top, right-to-left list, so swm_order is that list reversed
; and swarm j is the range [j * size, (j + 1) * size) of it; a final swarm
; smaller than size // 2 joins the one before.
swm_make_swarms:
    push    rbx
    push    r12
    push    r13
    mov     edi, FILTER_INPUT
    mov     esi, SORT_BOTTOM_TO_TOP_R2L
    call    get_characters
    mov     rbx, rax
    mov     r12, rdx
    lea     rdi, [rdx * 4]
    call    alloc
    mov     [swm_order], rax
    lea     rcx, [rbx + r12 * 4 - 4]
    xor     edx, edx
.reverse:
    cmp     rdx, r12
    jae     .ranges
    mov     esi, [rcx]
    mov     [rax + rdx * 4], esi
    sub     rcx, 4
    inc     rdx
    jmp     .reverse
.ranges:
    mov     r13, [swm_size]
    mov     rax, r12
    add     rax, r13
    dec     rax
    xor     edx, edx
    div     r13                         ; ceil(count / size)
    mov     [swm_nswarms], rax
    lea     rdi, [rax * 8 + 8]
    shl     rdi, 1
    call    alloc
    mov     [swm_bounds], rax
    xor     ecx, ecx
    xor     edx, edx
.range:
    cmp     rcx, [swm_nswarms]
    jae     .final
    mov     [rax], rdx
    add     rdx, r13
    cmp     rdx, r12
    cmova   rdx, r12
    mov     [rax + 8], rdx
    add     rax, 16
    inc     rcx
    jmp     .range
.final:
    ; rax = past the last range
    mov     rcx, [rax - 8]
    sub     rcx, [rax - 16]             ; len(final_swarm)
    mov     rdx, r13
    shr     rdx, 1                      ; size // 2 (size >= 1)
    cmp     rcx, rdx
    jge     .done
    cmp     qword [swm_nswarms], 1
    jbe     .done                       ; (Rust panics; unreachable for ratios <= 1)
    mov     [rax - 24], r12
    dec     qword [swm_nswarms]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; swm_build_char(edi=slot): one swarm character's flash scene, swarm area
; and inner paths, landing path and scene, events and chain.
swm_build_char:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     rsi, [swm_spawn]
    call    set_coordinate
    mov     edi, ebx
    mov     esi, AUTO
    mov     edx, SCF_SYNC_DISTANCE
    mov     ecx, NONE
    call    scene_new
    mov     r12d, eax
    xor     ebp, ebp
.flash:
    cmp     rbp, [swm_mirror_len]
    jae     .areas
    lea     rax, [swm_mirror]
    mov     rcx, [rax + rbp * 8]
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbx * 8]
    mov     edi, r12d
    mov     edx, 1
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     rbp
    jmp     .flash
.areas:
    xor     r13d, r13d                  ; area index
.area:
    cmp     r13, [swm_k]
    jae     .landing
    mov     rbp, r13
    shl     rbp, 5
    add     rbp, [swm_areas]
    mov     rdi, [rbp + SWM_AR_IN_N]
    call    rng_below
    mov     rcx, [rbp + SWM_AR_IN]
    mov     r14, [rcx + rax * 8]
    mov     r15d, r13d
    or      r15d, NAME_LITERAL
    mov     edi, ebx
    movsd   xmm0, [swm_speed_area]
    mov     esi, SWM_EASE_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, r15d
    call    path_new
    mov     edi, eax
    mov     rsi, r14
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    SWM_EVENT ebx, EV_PATH_ACTIVATED, r15d, ACT_ACTIVATE_SCENE, SWM_FLASH_SCENE
    SWM_EVENT ebx, EV_PATH_ACTIVATED, r15d, ACT_SET_LAYER, 1
    SWM_EVENT ebx, EV_PATH_COMPLETE, r15d, ACT_DEACTIVATE_SCENE, NONE
    ; two inner paths, named by the path count
    lea     r15d, [r13 + r13 * 2 + 1]
    call    swm_inner_path
    inc     r15d
    call    swm_inner_path
    inc     r13
    jmp     .area
.landing:
    mov     r15, [swm_k]
    lea     r15d, [r15 + r15 * 2]       ; the landing path's auto id
    mov     edi, ebx
    movsd   xmm0, [swm_speed_land]
    mov     esi, SWM_EASE_IN_OUT_QUAD
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, r15d
    call    path_new
    mov     r14d, eax
    mov     edi, ebx
    call    char_input_coord
    mov     rsi, rax
    mov     edi, r14d
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    call    path_new_waypoint
    mov     edi, ebx
    mov     esi, AUTO
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     edi, eax
    mov     esi, ebx
    call    swm_landing_frames
    SWM_EVENT ebx, EV_PATH_COMPLETE, r15d, ACT_ACTIVATE_SCENE, SWM_LAND_SCENE
    SWM_EVENT ebx, EV_PATH_COMPLETE, r15d, ACT_SET_LAYER, 0
    SWM_EVENT ebx, EV_PATH_ACTIVATED, r15d, ACT_ACTIVATE_SCENE, SWM_FLASH_SCENE
    mov     edi, ebx
    mov     rsi, [swm_names]
    lea     edx, [r15 + 1]
    xor     ecx, ecx
    call    chain_paths
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; swm_inner_path: in swm_build_char's frame (ebx = slot, rbp = area entry,
; r15d = name) - choose a coordinate of the area, then the path to it.
swm_inner_path:
    mov     rdi, [rbp + SWM_AR_IN_N]
    call    rng_below
    mov     rcx, [rbp + SWM_AR_IN]
    push    qword [rcx + rax * 8]
    mov     edi, ebx
    movsd   xmm0, [swm_speed_inner]
    mov     esi, SWM_EASE_IN_OUT_SINE
    mov     rdx, NONE_I64
    xor     ecx, ecx
    xor     r8d, r8d
    mov     r9d, r15d
    call    path_new
    mov     edi, eax
    pop     rsi
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, AUTO
    jmp     path_new_waypoint

; swm_landing_frames(edi=scene, esi=slot): the landing scene - flash to the
; final color in 10 steps (3 ticks each); when dynamic, flash to the input
; colors, or to white and then no color when the character has none.
swm_landing_frames:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     rax, [ch_sym]
    mov     rax, [rax + r12 * 8]
    mov     [swm_sym], rax
    mov     rax, [effect_config]
    mov     rax, [rax + SWARM.flash_color]
    mov     [swm_pair], rax
    cmp     byte [swm_dynamic], 0
    jne     .dynamic
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + r12 * 4]
    sub     rax, [text_bottom]
    imul    rax, [swm_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + r12 * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [swm_final_map]
    mov     rax, [rcx + rax * 8]
    call    swm_to_color                ; eax = 11
    mov     r13d, eax
    xor     r14d, r14d
.plain:
    cmp     r14d, r13d
    jae     .done
    lea     rax, [swm_spectrum]
    mov     rcx, [rax + r14 * 8]
    mov     rsi, [swm_sym]
    mov     edi, ebx
    mov     edx, 3
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14d
    jmp     .plain
.dynamic:
    mov     r13, [ch_fg]
    mov     r13, [r13 + r12 * 8]
    mov     r14, [ch_bg]
    mov     r14, [r14 + r12 * 8]
    cmp     r13, NONE
    jne     .gradients
    cmp     r14, NONE
    jne     .gradients
    mov     eax, 0xffffff               ; DYNAMIC_CLEAR_COLOR
    call    swm_to_color
    mov     r13d, eax
    jmp     .plain_then_clear
.gradients:
    ; fg into swm_spectrum, bg into swm_spectrum2 (either may be absent)
    xor     r15d, r15d                  ; fg count
    cmp     r13, NONE
    je      .bg
    mov     rax, r13
    call    swm_to_color
    mov     r15d, eax
.bg:
    xor     r12d, r12d                  ; bg count
    cmp     r14, NONE
    je      .apply
    mov     [swm_pair + 8], r14
    lea     rdi, [swm_pair]
    mov     esi, 2
    lea     rdx, [swm_ten]
    mov     ecx, 1
    lea     r8, [swm_spectrum2]
    call    gradient_new
    mov     r12d, eax
.apply:
    xor     eax, eax
    lea     rcx, [swm_spectrum2]
    test    r12d, r12d
    cmovz   rcx, rax
    push    r12
    push    rcx
    mov     edi, ebx
    lea     rsi, [swm_sym]
    mov     edx, 1
    mov     ecx, 3
    lea     r8, [swm_spectrum]
    test    r15d, r15d
    cmovz   r8, rax
    mov     r9d, r15d
    call    scene_apply_gradient
    add     rsp, 16
    jmp     .done
.plain_then_clear:
    xor     r14d, r14d
.clear:
    cmp     r14d, r13d
    jae     .no_color
    lea     rax, [swm_spectrum]
    mov     rcx, [rax + r14 * 8]
    mov     rsi, [swm_sym]
    mov     edi, ebx
    mov     edx, 3
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
    inc     r14d
    jmp     .clear
.no_color:
    mov     rsi, [swm_sym]
    mov     edi, ebx
    mov     edx, 3
    mov     rcx, NONE
    mov     r8, NONE
    xor     r9d, r9d
    call    scene_add_frame
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; swm_to_color(rax=color) -> eax = length: Gradient::with_steps([flash
; (already in swm_pair), color], 10) into swm_spectrum.
swm_to_color:
    mov     [swm_pair + 8], rax
    lea     rdi, [swm_pair]
    mov     esi, 2
    lea     rdx, [swm_ten]
    mov     ecx, 1
    lea     r8, [swm_spectrum]
    jmp     gradient_new

; swm_make_final_map: Gradient::new(final stops, final steps) and its coordinate
; mapping over the text rectangle.
swm_make_final_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + SWARM.final_steps]
    mov     rcx, [rbx + SWARM.final_step_count]
    mov     rsi, [rbx + SWARM.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [swm_final_spectrum], rax
    mov     rdi, [rbx + SWARM.final_stops]
    mov     rsi, [rbx + SWARM.final_stop_count]
    mov     rdx, [rbx + SWARM.final_steps]
    mov     rcx, [rbx + SWARM.final_step_count]
    mov     r8, [swm_final_spectrum]
    call    gradient_new
    mov     rdi, [swm_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [swm_final_map_width], rax
    push    qword [rbx + SWARM.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [swm_final_map], rax
    pop     rbx
    ret

; ------------------------------------------------------------ circle cache

; swm_cache_get(rdi=coord) -> rax = the cache entry for the coordinate (valid
; until the next call), made on first use: find_coords_on_circle(coord,
; radius, 0, unique) and find_coords_in_circle(coord, diameter).
swm_cache_get:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
.probe:
    mov     rax, rbx
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rax, rcx
    shr     rax, 32
    mov     rdx, [swm_cache_mask]
.slot:
    and     rax, rdx
    mov     r12, rax
    shl     r12, 5
    add     r12, [swm_cache]
    cmp     dword [r12 + SWM_CE_ON_N], 0
    je      .miss
    cmp     [r12 + SWM_CE_KEY], rbx
    je      .hit
    inc     rax
    jmp     .slot
.miss:
    ; keep the table at most half full
    mov     rax, [swm_cache_used]
    inc     rax
    add     rax, rax
    mov     rcx, [swm_cache_mask]
    inc     rcx
    cmp     rax, rcx
    jbe     .insert
    call    swm_cache_grow
    jmp     .probe
.insert:
    inc     qword [swm_cache_used]
    mov     [r12 + SWM_CE_KEY], rbx
    mov     rdi, rbx
    mov     rsi, [swm_radius]
    xor     edx, edx
    mov     ecx, 1
    call    find_coords_on_circle
    mov     [r12 + SWM_CE_ON], rax
    mov     [r12 + SWM_CE_ON_N], edx
    mov     rdi, rbx
    mov     rsi, [swm_diameter]
    call    find_coords_in_circle
    mov     [r12 + SWM_CE_IN], rax
    mov     [r12 + SWM_CE_IN_N], edx
.hit:
    mov     rax, r12
    pop     r13
    pop     r12
    pop     rbx
    ret

; swm_cache_grow: double the table and rehash.
swm_cache_grow:
    push    rbx
    push    r12
    push    r13
    mov     r12, [swm_cache]
    mov     r13, [swm_cache_mask]
    lea     rdi, [r13 + 1]
    shl     rdi, 6
    call    alloc
    mov     [swm_cache], rax
    lea     rax, [r13 * 2 + 1]
    mov     [swm_cache_mask], rax
    lea     rbx, [r13 + 1]              ; old slots
.entry:
    test    rbx, rbx
    jz      .done
    dec     rbx
    mov     rsi, rbx
    shl     rsi, 5
    add     rsi, r12
    cmp     dword [rsi + SWM_CE_ON_N], 0
    je      .entry
    mov     rax, [rsi + SWM_CE_KEY]
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rax, rcx
    shr     rax, 32
    mov     rdx, [swm_cache_mask]
.slot:
    and     rax, rdx
    mov     rdi, rax
    shl     rdi, 5
    add     rdi, [swm_cache]
    cmp     dword [rdi + SWM_CE_ON_N], 0
    je      .move
    inc     rax
    jmp     .slot
.move:
%if TIER >= 3
    vmovdqu ymm0, [rsi]
    vmovdqu [rdi], ymm0
    vzeroupper
%else
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rsi + 16]
    movdqu  [rdi], xmm0
    movdqu  [rdi + 16], xmm1
%endif
    jmp     .entry
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------ frames

; swm_first_digit(eax=n >= 0) -> eax = the leading decimal digit of n.
; Clobbers rcx, rdx.
swm_first_digit:
    mov     ecx, 10
.loop:
    cmp     eax, 10
    jb      .done
    xor     edx, edx
    div     ecx
    jmp     .loop
.done:
    ret

; swarm_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
swarm_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     qword [swm_nswarms], 0
    jne     .running
    call    active_empty
    test    eax, eax
    jnz     .finished
.running:
    cmp     qword [swm_nswarms], 0
    je      .landed
    cmp     byte [swm_call_next], 0
    je      .landed
    ; the next swarm (from the end) takes off for its first area
    mov     byte [swm_call_next], 0
    dec     qword [swm_nswarms]
    mov     rax, [swm_nswarms]
    shl     rax, 4
    add     rax, [swm_bounds]
    mov     rcx, [rax]
    mov     [swm_cur_start], rcx
    mov     rcx, [rax + 8]
    mov     [swm_cur_end], rcx
    mov     dword [swm_active_area], NAME_LITERAL
    mov     r12, [swm_cur_start]
.launch:
    cmp     r12, [swm_cur_end]
    jae     .landed
    mov     rax, [swm_order]
    mov     ebx, [rax + r12 * 4]
    mov     edi, ebx
    mov     esi, NAME_LITERAL
    call    path_activate_name
    mov     edi, ebx
    call    set_visible
    mov     edi, ebx
    call    active_insert
    inc     r12
    jmp     .launch
.landed:
    ; some of the characters have landed
    call    active_count
    mov     rcx, [swm_cur_end]
    sub     rcx, [swm_cur_start]
    cmp     rax, rcx
    jae     .follow
    mov     byte [swm_call_next], 1
.follow:
    ; the first character to reach a later swarm area leads the others there
    mov     r12, [swm_cur_start]
.lead:
    cmp     r12, [swm_cur_end]
    jae     .update
    mov     rax, [swm_order]
    mov     ebx, [rax + r12 * 4]
    inc     r12
    mov     rax, [ch_path]
    mov     eax, [rax + rbx * 4]
    cmp     eax, NONE
    je      .lead
    PATH_PTR rcx, rax
    mov     ebp, [rcx + PA_NAME]
    cmp     ebp, [swm_active_area]
    je      .lead
    cmp     ebp, NAME_LITERAL
    jb      .lead                       ; not a swarm area
    mov     eax, [swm_active_area]
    and     eax, 0x7fffffff
    call    swm_first_digit
    mov     r13d, eax
    mov     eax, ebp
    and     eax, 0x7fffffff
    call    swm_first_digit
    cmp     eax, r13d
    jbe     .lead
    mov     [swm_active_area], ebp
    mov     r14, [effect_config]
    mov     r13, [swm_cur_start]
.coordinate:
    cmp     r13, [swm_cur_end]
    jae     .update
    mov     rax, [swm_order]
    mov     r15d, [rax + r13 * 4]
    inc     r13
    cmp     r15d, ebx
    je      .coordinate
    call    rng_random
    movsd   xmm1, [r14 + SWARM.coordination]
    ucomisd xmm1, xmm0
    jbe     .coordinate
    mov     edi, r15d
    mov     esi, ebp
    call    path_activate_name
    jmp     .coordinate
.update:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
swm_seven:          dq 7
swm_ten:            dq 10
swm_speed_area:     dq 0.4
swm_speed_inner:    dq 0.18
swm_speed_land:     dq 0.45

section .tstate
alignb 8
swm_size:           resq 1
swm_order:          resq 1          ; u32 slots, in swarm order
swm_bounds:         resq 1          ; (start, end) per swarm
swm_nswarms:        resq 1          ; swarms not yet launched
swm_radius:         resq 1
swm_diameter:       resq 1
swm_cache:          resq 1
swm_cache_mask:     resq 1
swm_cache_used:     resq 1
swm_areas:          resq 1
swm_k:              resq 1          ; entries of the current area map
swm_names:          resq 1
swm_spawn:          resq 1
swm_mirror_len:     resq 1
swm_sym:            resq 1
swm_final_spectrum: resq 1
swm_final_map:      resq 1
swm_final_map_width: resq 1
swm_cur_start:      resq 1
swm_cur_end:        resq 1
swm_pair:           resq 2
swm_spectrum:       resq 16
swm_spectrum2:      resq 16
swm_mirror:         resq 32
swm_active_area:    resd 1
swm_dynamic:        resb 1
swm_call_next:      resb 1
