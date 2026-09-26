; effects/vhstape.asm - "Lines of characters glitch left and right and lose
; detail like an old VHS tape" (src/effects/vhstape.rs).
;
; Config (src/asm/effects.rs, EffectCommand::Vhstape). --glitch-wave-colors
; is accepted by the CLI but never read by the effect, so it is not passed.
;
; Lines are the row groups of get_characters_grouped (bottom to top); a line
; index is a group index. The glitch wave and glitch line lists hold at most
; three indices each.

struc VHSTAPE
    .line_colors:       resq 1          ; *const u64 glitch_line_colors
    .line_count:        resq 1
    .noise_colors:      resq 1          ; *const u64
    .noise_count:       resq 1
    .line_chance:       resq 1          ; f64 glitch_line_chance
    .noise_chance:      resq 1          ; f64
    .total_time:        resq 1          ; total_glitch_time (frames)
    .final_stops:       resq 1          ; *const u64
    .final_stop_count:  resq 1
    .final_steps:       resq 1          ; *const i64
    .final_step_count:  resq 1
    .final_direction:   resq 1
endstruc

; path names (each path's single waypoint shares its path's name)
%define GLITCH          NAME_LITERAL + 0
%define RESTORE         NAME_LITERAL + 1
%define WAVE_MID        NAME_LITERAL + 2
%define WAVE_END        NAME_LITERAL + 3
; scene names
%define BASE            NAME_LITERAL + 4
%define GLITCH_FWD      NAME_LITERAL + 5
%define GLITCH_BWD      NAME_LITERAL + 6
%define SNOW            NAME_LITERAL + 7
%define FINAL_SNOW      NAME_LITERAL + 8
%define FINAL_REDRAW    NAME_LITERAL + 9

; ch_user0: the glitch path index (low half) and the base scene index (high
; half). A character's paths and scenes are created back to back, so the
; others follow at fixed distances.
%define P_RESTORE       1
%define P_MID           2
%define P_END           3
%define S_SNOW          3
%define S_FINAL_SNOW    4
%define S_FINAL_REDRAW  5

%define PH_GLITCHING    0
%define PH_NOISE        1
%define PH_REDRAW       2
%define PH_COMPLETE     3

section .text

; vhstape_build: VhsTape::build.
vhstape_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    vhs_final_color_map
    mov     rbx, [effect_config]
    ; memo of (noise color, snow symbol) -> handle
    mov     rdi, [rbx + VHSTAPE.noise_count]
    shl     rdi, 4
    call    alloc
    mov     [vhs_snow_memo], rax
    ; the glitch line colors, reversed (GLITCH_BWD's frames)
    mov     rdi, [rbx + VHSTAPE.line_count]
    lea     rdi, [rdi * 8 + 8]
    call    alloc
    mov     [vhs_line_colors_rev], rax
    mov     rcx, [rbx + VHSTAPE.line_count]
    mov     rsi, [rbx + VHSTAPE.line_colors]
    xor     edx, edx
.reverse:
    test    rcx, rcx
    jz      .reversed
    dec     rcx
    mov     r8, [rsi + rcx * 8]
    mov     [rax + rdx * 8], r8
    inc     rdx
    jmp     .reverse
.reversed:
    xor     r12d, r12d
.snow_memo:
    cmp     r12, [rbx + VHSTAPE.noise_count]
    jae     .snow_memo_done
    xor     r13d, r13d
.snow_memo_symbol:
    mov     rax, [rbx + VHSTAPE.noise_colors]
    mov     rdi, [rax + r12 * 8]
    mov     rsi, NONE
    lea     rax, [vhs_snow_symbols]
    movzx   edx, byte [rax + r13]
    bts     rdx, 32                     ; one byte long
    xor     ecx, ecx
    call    visual_make
    lea     rcx, [r12 * 4 + r13]
    mov     rdx, [vhs_snow_memo]
    mov     [rdx + rcx * 4], eax
    inc     r13d
    cmp     r13d, 4
    jb      .snow_memo_symbol
    inc     r12
    jmp     .snow_memo
.snow_memo_done:
    ; choice(noise_colors)'s draw: the top max(bit_length(n - 1), 1) bits
    mov     rax, [rbx + VHSTAPE.noise_count]
    dec     rax
    xor     ecx, ecx
    bsr     rax, rax
    jz      .noise_bits
    lea     ecx, [rax + 1]
.noise_bits:
    mov     eax, 1
    cmp     ecx, eax
    cmovb   ecx, eax
    neg     ecx
    add     ecx, 64
    mov     [vhs_noise_shift], cl
    ; the redraw block: "█" in white
    mov     edi, 0x2588
    call    utf8_pack
    mov     rdx, rax
    mov     edi, 0xffffff
    mov     rsi, NONE
    xor     ecx, ecx
    call    visual_make
    mov     [vhs_block_visual], eax
    ; one Line per row, bottom to top
    mov     edi, FILTER_INPUT
    mov     esi, GROUP_ROW_BOTTOM_TO_TOP
    call    get_characters_grouped
    mov     [vhs_lines], rax
    mov     [vhs_line_count], rdx
    xor     ebx, ebx
.line:
    cmp     rbx, [vhs_line_count]
    jae     .lines_built
    mov     rdi, rbx
    call    vhs_line_slots
    mov     rdi, rax
    mov     rsi, rdx
    call    vhs_build_line_effects
    inc     rbx
    jmp     .line
.lines_built:
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.show:
    cmp     rbx, r13
    jae     .shown
    mov     edi, [r12 + rbx * 4]
    mov     ebp, edi
    call    set_visible
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8 + 4]    ; base
    call    scene_activate
    inc     rbx
    jmp     .show
.shown:
    mov     byte [vhs_phase], PH_GLITCHING
    mov     rax, NONE_I64
    mov     [vhs_wave_top], rax
    mov     rax, [vhs_line_count]
    mov     [vhs_to_redraw], rax
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; vhs_build_line_effects(rdi=slots, rsi=count): Line.build_line_effects - the
; offset, direction and hold time draws, then per character its paths,
; scenes (snow draws 25 x 2, final_snow 30 x 2) and events.
%define L_DX        0                   ; offset * direction
%define L_HOLD      8
%define L_STABLE_FG 16
%define L_STABLE_BG 24
%define L_FINAL_FG  32
%define L_FINAL_BG  40
%define L_COORD     48                  ; input coordinate
%define L_FINAL_SNOW 56
%define L_SIZE      72                  ; (keeps the stack aligned)

; SHIFTED delta: rsi = the input coordinate moved delta columns. Clobbers rax.
%macro SHIFTED 1
    mov     rsi, [rsp + L_COORD]
    mov     eax, esi
    add     eax, %1
    shr     rsi, 32
    shl     rsi, 32
    or      rsi, rax
%endmacro

; NEW_PATH name, hold: path_new with speed 2.0 and no easing or layer.
%macro NEW_PATH 2
    mov     edi, ebp
    movsd   xmm0, [vhs_two]
    mov     esi, NONE
    mov     rdx, NONE_I64
    mov     rcx, %2
    xor     r8d, r8d
    mov     r9d, %1
    call    path_new
%endmacro

; ADD_WAYPOINT name: path eax gets its waypoint at rsi.
%macro ADD_WAYPOINT 1
    mov     edi, eax
    xor     edx, edx
    xor     ecx, ecx
    mov     r8d, %1
    call    path_new_waypoint
%endmacro

; EVENT event, caller kind, caller name, action, target (arg1 is on the stack)
%macro EVENT 5
    mov     edi, ebp
    mov     esi, %1
    mov     edx, %2
    mov     ecx, %3
    mov     r8d, %4
    mov     r9d, %5
    call    event_register
%endmacro

vhs_build_line_effects:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, L_SIZE
    mov     r12, rdi
    mov     r13, rsi
    mov     edi, 4
    mov     esi, 25
    call    rng_randint
    mov     rbx, rax                    ; offset
    mov     edi, 2
    call    rng_below                   ; choice([-1, 1])
    lea     rax, [rax * 2 - 1]
    imul    rbx, rax
    mov     [rsp + L_DX], rbx
    mov     edi, 1
    mov     esi, 50
    call    rng_randint
    mov     [rsp + L_HOLD], rax
    xor     ebx, ebx
.char:
    cmp     rbx, r13
    jae     .done
    mov     ebp, [r12 + rbx * 4]
    ; stable and final colors
    cmp     qword [cfg_existing_colors], 1
    jne     .gradient
    ; dynamic: the input colors, fg falling back to DYNAMIC_NEUTRAL_GRAY
    mov     rax, [ch_fg]
    mov     rax, [rax + rbp * 8]
    mov     rcx, [ch_bg]
    mov     rcx, [rcx + rbp * 8]
    mov     [rsp + L_FINAL_FG], rax
    mov     [rsp + L_FINAL_BG], rcx
    mov     [rsp + L_STABLE_BG], rcx
    cmp     rax, NONE
    jne     .dynamic_fg
    mov     eax, 0x808080
.dynamic_fg:
    mov     [rsp + L_STABLE_FG], rax
    jmp     .coord
.gradient:
    mov     rax, [ch_irow]
    movsxd  rax, dword [rax + rbp * 4]
    sub     rax, [text_bottom]
    imul    rax, [vhs_final_map_width]
    mov     rcx, [ch_icol]
    movsxd  rcx, dword [rcx + rbp * 4]
    add     rax, rcx
    sub     rax, [text_left]
    mov     rcx, [vhs_final_map]
    mov     rax, [rcx + rax * 8]
    mov     [rsp + L_STABLE_FG], rax
    mov     [rsp + L_FINAL_FG], rax
    mov     qword [rsp + L_STABLE_BG], NONE
    mov     qword [rsp + L_FINAL_BG], NONE
.coord:
    mov     rax, [ch_irow]
    mov     eax, [rax + rbp * 4]
    shl     rax, 32
    mov     rcx, [ch_icol]
    mov     ecx, [rcx + rbp * 4]
    or      rax, rcx
    mov     [rsp + L_COORD], rax
    ; --- paths: glitch, restore, glitch_wave_mid, glitch_wave_end
    NEW_PATH GLITCH, [rsp + L_HOLD]
    mov     rcx, [ch_user0]
    mov     [rcx + rbp * 8], eax
    mov     r14d, eax
    SHIFTED dword [rsp + L_DX]
    mov     eax, r14d
    ADD_WAYPOINT GLITCH
    NEW_PATH RESTORE, 0
    mov     rsi, [rsp + L_COORD]
    ADD_WAYPOINT RESTORE
    NEW_PATH WAVE_MID, 0
    mov     r14d, eax
    SHIFTED 8
    mov     eax, r14d
    ADD_WAYPOINT WAVE_MID
    NEW_PATH WAVE_END, 0
    mov     r14d, eax
    SHIFTED 14
    mov     eax, r14d
    ADD_WAYPOINT WAVE_END
    ; --- scenes
    mov     edi, ebp
    mov     esi, BASE
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     rcx, [ch_user0]
    mov     [rcx + rbp * 8 + 4], eax
    mov     edi, eax
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     rcx, [rsp + L_STABLE_FG]
    mov     r8, [rsp + L_STABLE_BG]
    xor     r9d, r9d
    call    scene_add_frame
    ; the input symbol in each glitch line color
    mov     rax, [effect_config]
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbp * 8]
    mov     rsi, [rax + VHSTAPE.line_colors]
    mov     rdx, [rax + VHSTAPE.line_count]
    mov     rcx, NONE
    xor     r8d, r8d                    ; one color list
    call    visual_run
    mov     [vhs_line_handles], rax
    mov     edi, ebp
    mov     esi, GLITCH_FWD
    mov     edx, SCF_SYNC_STEP
    mov     ecx, NONE
    call    scene_new
    mov     edi, eax
    mov     rsi, [vhs_line_handles]
    mov     rax, [effect_config]
    mov     rdx, [rax + VHSTAPE.line_count]
    mov     ecx, 1
    call    visual_frames
    ; backward: the same visuals in reverse
    mov     edi, ebp
    mov     esi, GLITCH_BWD
    mov     edx, SCF_SYNC_STEP
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     rax, [effect_config]
    mov     rdi, [ch_sym]
    mov     rdi, [rdi + rbp * 8]
    mov     rsi, [vhs_line_colors_rev]
    mov     rdx, [rax + VHSTAPE.line_count]
    mov     rcx, NONE
    mov     r8d, 1                      ; the reversed list
    call    visual_run
    mov     edi, r15d
    mov     rsi, rax
    mov     ecx, 1
    call    visual_frames
    mov     edi, ebp
    mov     esi, SNOW
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     edi, eax
    mov     esi, 25
    call    vhs_snow_frames
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     rcx, [rsp + L_STABLE_FG]
    mov     r8, [rsp + L_STABLE_BG]
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, ebp
    mov     esi, FINAL_SNOW
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     [rsp + L_FINAL_SNOW], rax
    mov     edi, ebp
    mov     esi, FINAL_REDRAW
    xor     edx, edx
    mov     ecx, NONE
    call    scene_new
    mov     r15d, eax
    mov     edi, eax
    mov     esi, [vhs_block_visual]
    mov     edx, 6
    call    scene_add_frame_visual
    mov     edi, r15d
    mov     rsi, [ch_sym]
    mov     rsi, [rsi + rbp * 8]
    mov     edx, 1
    mov     rcx, [rsp + L_FINAL_FG]
    mov     r8, [rsp + L_FINAL_BG]
    xor     r9d, r9d
    call    scene_add_frame
    mov     edi, [rsp + L_FINAL_SNOW]
    mov     esi, 30
    call    vhs_snow_frames
    ; --- events
    push    0
    push    0
    EVENT   EV_PATH_COMPLETE, CALLER_PATH, GLITCH, ACT_ACTIVATE_PATH, RESTORE
    EVENT   EV_PATH_ACTIVATED, CALLER_PATH, GLITCH, ACT_ACTIVATE_SCENE, GLITCH_FWD
    EVENT   EV_PATH_ACTIVATED, CALLER_PATH, RESTORE, ACT_ACTIVATE_SCENE, GLITCH_BWD
    EVENT   EV_PATH_ACTIVATED, CALLER_PATH, WAVE_MID, ACT_ACTIVATE_SCENE, GLITCH_FWD
    EVENT   EV_PATH_ACTIVATED, CALLER_PATH, WAVE_END, ACT_ACTIVATE_SCENE, GLITCH_FWD
    EVENT   EV_SCENE_COMPLETE, CALLER_SCENE, GLITCH_BWD, ACT_ACTIVATE_SCENE, BASE
    add     rsp, 16
    inc     rbx
    jmp     .char
.done:
    add     rsp, L_SIZE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; vhs_snow_frames(edi=scene, esi=count <= 32): count frames of 2 ticks,
; each choice(snow_chars) then choice(noise_colors), drawn in that order
; (vhs_snow_memo holds every pair's visual). snow_chars has four
; symbols, so its draw is the top two bits and never rejects.
vhs_snow_frames:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 136
    mov     ebp, edi
    mov     r14d, esi
    mov     rax, [effect_config]
    mov     r15, [rax + VHSTAPE.noise_count]
    mov     r8, [vhs_snow_memo]
    movzx   ecx, byte [vhs_noise_shift]
    RNG_OPEN r12, r13
    xor     ebx, ebx
.draw:
    RNG_TAKE rax, r12, r13
    shr     rax, 62                     ; symbol index
.color:
    RNG_TAKE rdx, r12, r13
    shr     rdx, cl
    cmp     rdx, r15
    jae     .color
    lea     rax, [rdx * 4 + rax]
    mov     eax, [r8 + rax * 4]
    mov     [rsp + rbx * 4], eax
    inc     ebx
    cmp     ebx, r14d
    jb      .draw
    RNG_CLOSE r12
    mov     edi, ebp
    mov     rsi, rsp
    mov     edx, r14d
    mov     ecx, 2
    call    visual_frames
    add     rsp, 136
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; vhs_final_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
vhs_final_color_map:
    push    rbx
    mov     rbx, [effect_config]
    mov     rdi, [rbx + VHSTAPE.final_steps]
    mov     rcx, [rbx + VHSTAPE.final_step_count]
    mov     rsi, [rbx + VHSTAPE.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [vhs_final_spectrum], rax
    mov     rdi, [rbx + VHSTAPE.final_stops]
    mov     rsi, [rbx + VHSTAPE.final_stop_count]
    mov     rdx, [rbx + VHSTAPE.final_steps]
    mov     rcx, [rbx + VHSTAPE.final_step_count]
    mov     r8, [vhs_final_spectrum]
    call    gradient_new
    mov     rdi, [vhs_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [vhs_final_map_width], rax
    push    qword [rbx + VHSTAPE.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [vhs_final_map], rax
    pop     rbx
    ret

; ------------------------------------------------------------ vhs_lines

; vhs_line_slots(rdi=line) -> rax = slots, rdx = count. Clobbers rdi.
vhs_line_slots:
    shl     rdi, 4
    add     rdi, [vhs_lines]
    mov     rax, [rdi]
    mov     rdx, [rdi + 8]
    ret

; vhs_line_complete(rdi=line) -> eax = 1 when no character of the line has an
; active path (Line.line_movement_complete). Clobbers rcx, rdx, rdi, r8.
vhs_line_complete:
    call    vhs_line_slots
    mov     rcx, [ch_path]
.next:
    test    rdx, rdx
    jz      .yes
    dec     rdx
    mov     r8d, [rax + rdx * 4]
    cmp     dword [rcx + r8 * 4], NONE
    je      .next
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

; vhs_lines_complete(rdi=line list, rsi=count) -> eax = 1 when every listed line
; has completed its movement (vacuously for none). Clobbers C.
vhs_lines_complete:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
.next:
    cmp     rbx, r13
    jae     .yes
    mov     rdi, [r12 + rbx * 8]
    call    vhs_line_complete
    test    eax, eax
    jz      .done
    inc     rbx
    jmp     .next
.yes:
    mov     eax, 1
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; vhs_list_contains(rdi=line list, rsi=count, rdx=line) -> eax = 1 when listed.
; Clobbers rsi.
vhs_list_contains:
    xor     eax, eax
.next:
    test    rsi, rsi
    jz      .done
    dec     rsi
    cmp     [rdi + rsi * 8], rdx
    jne     .next
    mov     eax, 1
.done:
    ret

; vhs_line_insert(rdi=line): every character of the line joins the active set.
; Clobbers rax, rcx, rdx, rdi, r8, r9.
vhs_line_insert:
    call    vhs_line_slots
    mov     r8, rax
    mov     r9, rdx
.next:
    test    r9, r9
    jz      .done
    dec     r9
    mov     edi, [r8 + r9 * 4]
    call    active_insert               ; clobbers rax, rcx, rdx only
    jmp     .next
.done:
    ret

; vhs_line_set_hold(rdi=line, rsi=hold): Line.set_hold_time on the glitch paths.
vhs_line_set_hold:
    call    vhs_line_slots
    mov     rcx, [ch_user0]
.next:
    test    rdx, rdx
    jz      .done
    dec     rdx
    mov     edi, [rax + rdx * 4]
    mov     edi, [rcx + rdi * 8]        ; glitch path
    shl     rdi, 7                      ; PATH_SIZE
    add     rdi, [paths]
    mov     [rdi + PA_HOLD], rsi
    jmp     .next
.done:
    ret

; RANDOM_SPEED path offset: the path at that distance from the glitch path
; of slot ebp gets speed 40 / randint(20, 40). Clobbers C except callee-saved.
%macro RANDOM_SPEED 1
    mov     edi, 20
    mov     esi, 40
    call    rng_randint
    cvtsi2sd xmm1, rax
    movsd   xmm0, [vhs_forty]
    divsd   xmm0, xmm1
    mov     rax, [ch_user0]
    mov     eax, [rax + rbp * 8]
    add     eax, %1
    shl     rax, 7
    add     rax, [paths]
    movsd   [rax + PA_SPEED], xmm0
%endmacro

; LINE_LOOP / LINE_NEXT: walk line rdi's characters in order with ebp = slot
; (rbx, r12, r13 hold the walk), through the function's .next/.done labels.
; The caller has pushed rbx, rbp, r12, r13.
%macro LINE_LOOP 0
    call    vhs_line_slots
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.next:
    cmp     rbx, r13
    jae     .done
    mov     ebp, [r12 + rbx * 4]
%endmacro

%macro LINE_NEXT 0
    inc     rbx
    jmp     .next
.done:
%endmacro

%macro LINE_PROLOGUE 0
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
%endmacro

%macro LINE_EPILOGUE 0
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
%endmacro

; vhs_line_glitch(rdi=line): Line.glitch(final=False) - new glitch and restore
; speeds (drawn in that order), then the glitch path.
vhs_line_glitch:
    LINE_PROLOGUE
    LINE_LOOP
    RANDOM_SPEED 0
    RANDOM_SPEED P_RESTORE
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8]
    call    path_activate
    LINE_NEXT
    LINE_EPILOGUE

; vhs_line_restore(rdi=line): Line.restore - a new restore speed, then the
; restore path.
vhs_line_restore:
    LINE_PROLOGUE
    LINE_LOOP
    RANDOM_SPEED P_RESTORE
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8]
    add     esi, P_RESTORE
    call    path_activate
    LINE_NEXT
    LINE_EPILOGUE

; vhs_line_activate_path(rdi=line, esi=path offset from the glitch path):
; Line.activate_path.
vhs_line_activate_path:
    LINE_PROLOGUE
    mov     r14d, esi
    LINE_LOOP
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8]
    add     esi, r14d
    call    path_activate
    LINE_NEXT
    LINE_EPILOGUE

; vhs_line_scene(rdi=line, esi=scene offset from the base scene): activate that
; scene for every character (Line.snow, and the redraw phase).
vhs_line_scene:
    LINE_PROLOGUE
    mov     r14d, esi
    LINE_LOOP
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8 + 4]
    add     esi, r14d
    call    scene_activate
    LINE_NEXT
    LINE_EPILOGUE

; vhs_glitch_wave: VHSTapeIterator.glitch_wave. The caller has established that
; every wave line completed its movement, which is the only other condition.
vhs_glitch_wave:
    push    rbx
    push    r12
    push    r13
    mov     rax, [vhs_wave_top]
    mov     rcx, NONE_I64
    cmp     rax, rcx
    je      .choose
    test    rax, rax
    jnz     .have_top
.choose:
    ; a wave top in the top half of the text, or at least 3 rows up
    mov     rbx, [text_top]
    sub     rbx, [text_bottom]
    inc     rbx                         ; text_height
    cmp     rbx, 3
    jl      .out
    cvtsi2sd xmm0, rbx
    mulsd   xmm0, [vhs_half]
    call    round_half_even
    mov     ecx, 3
    cmp     rax, rcx
    cmovl   rax, rcx
    mov     rdi, rax
    mov     rsi, rbx
    call    rng_randint
    add     rax, [text_bottom]
    mov     [vhs_wave_top], rax
.have_top:
    cmp     qword [vhs_wave_count], 0
    je      .lines
    ; move 30% of the time, up 30% of those
    call    rng_random
    xor     ebx, ebx
    comisd  xmm0, [vhs_point3]
    jae     .clamp
    call    rng_random
    mov     rbx, -1
    mov     ecx, 1
    comisd  xmm0, [vhs_point3]
    cmovb   rbx, rcx
.clamp:
    add     rbx, [vhs_wave_top]
    cmp     rbx, [text_top]
    cmovg   rbx, [text_top]
    mov     ecx, 2
    cmp     rbx, rcx
    cmovl   rbx, rcx
    mov     [vhs_wave_top], rbx
.lines:
    ; the vhs_lines of rows vhs_wave_top - 2 ..= vhs_wave_top
    xor     r12d, r12d
    mov     rbx, [vhs_wave_top]
    sub     rbx, 2
.row:
    cmp     rbx, [vhs_wave_top]
    jg      .old
    mov     rax, rbx
    sub     rax, [text_bottom]
    inc     rax
    js      .skip
    cmp     rax, [vhs_line_count]
    jae     .skip
    lea     rcx, [vhs_new_lines]
    mov     [rcx + r12 * 8], rax
    inc     r12
.skip:
    inc     rbx
    jmp     .row
.old:
    ; restore the vhs_lines that left the wave
    xor     ebx, ebx
.old_line:
    cmp     rbx, [vhs_wave_count]
    jae     .replace
    lea     rax, [vhs_wave_lines]
    mov     r13, [rax + rbx * 8]
    lea     rdi, [vhs_new_lines]
    mov     rsi, r12
    mov     rdx, r13
    call    vhs_list_contains
    test    eax, eax
    jnz     .kept
    mov     rdi, r13
    call    vhs_line_restore
    mov     rdi, r13
    call    vhs_line_insert
.kept:
    inc     rbx
    jmp     .old_line
.replace:
    mov     [vhs_wave_count], r12
    lea     rax, [vhs_new_lines]
    lea     rcx, [vhs_wave_lines]
%if TIER >= 3
    vmovdqu ymm0, [rax]
    vmovdqu [rcx], ymm0
    vzeroupper
%else
    movdqu  xmm0, [rax]
    movdqu  xmm1, [rax + 16]
    movdqu  [rcx], xmm0
    movdqu  [rcx + 16], xmm1
%endif
    mov     rax, [text_bottom]
    add     rax, 2
    cmp     [vhs_wave_top], rax
    jge     .advance
    ; the wave reached the bottom: restore its vhs_lines
    xor     ebx, ebx
.bottom:
    cmp     rbx, [vhs_wave_count]
    jae     .ended
    lea     rax, [vhs_wave_lines]
    mov     r13, [rax + rbx * 8]
    mov     rdi, r13
    call    vhs_line_restore
    mov     rdi, r13
    call    vhs_line_insert
    inc     rbx
    jmp     .bottom
.ended:
    mov     qword [vhs_wave_count], 0
    mov     rax, NONE_I64
    mov     [vhs_wave_top], rax
    jmp     .out
.advance:
    ; mid, end, mid
    xor     ebx, ebx
.wave_line:
    cmp     rbx, [vhs_wave_count]
    jae     .out
    lea     rax, [vhs_wave_lines]
    mov     r13, [rax + rbx * 8]
    lea     rax, [vhs_wave_paths]
    movzx   esi, byte [rax + rbx]
    mov     rdi, r13
    call    vhs_line_activate_path
    mov     rdi, r13
    call    vhs_line_insert
    inc     rbx
    jmp     .wave_line
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

; vhstape_next_frame -> eax = 1 when a frame should be rendered, 0 when done.
vhstape_next_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    movzx   eax, byte [vhs_phase]
    cmp     eax, PH_GLITCHING
    je      .glitching
    cmp     eax, PH_NOISE
    je      .noise
    cmp     eax, PH_REDRAW
    je      .redraw
    call    active_empty
    test    eax, eax
    jnz     .finished
    jmp     .update
.glitching:
    ; move the wave once its vhs_lines have settled
    lea     rdi, [vhs_wave_lines]
    mov     rsi, [vhs_wave_count]
    call    vhs_lines_complete
    test    eax, eax
    jz      .prune
    call    vhs_glitch_wave
.prune:
    ; drop glitch vhs_lines that completed their movement (order kept)
    xor     ebx, ebx
    xor     r12d, r12d
.keep:
    cmp     rbx, [vhs_glitch_count]
    jae     .kept
    lea     rax, [vhs_glitch_lines]
    mov     rdi, [rax + rbx * 8]
    call    vhs_line_complete
    test    eax, eax
    jnz     .drop
    lea     rax, [vhs_glitch_lines]
    mov     rcx, [rax + rbx * 8]
    mov     [rax + r12 * 8], rcx
    inc     r12
.drop:
    inc     rbx
    jmp     .keep
.kept:
    mov     [vhs_glitch_count], r12
    ; randomly glitch a new line
    call    rng_random
    mov     rax, [effect_config]
    comisd  xmm0, [rax + VHSTAPE.line_chance]
    jae     .noise_roll
    cmp     qword [vhs_glitch_count], 3
    jae     .noise_roll
    mov     rdi, [vhs_line_count]
    call    rng_below
    mov     rbx, rax
    lea     rdi, [vhs_wave_lines]
    mov     rsi, [vhs_wave_count]
    mov     rdx, rbx
    call    vhs_list_contains
    test    eax, eax
    jnz     .noise_roll
    lea     rdi, [vhs_glitch_lines]
    mov     rsi, [vhs_glitch_count]
    mov     rdx, rbx
    call    vhs_list_contains
    test    eax, eax
    jnz     .noise_roll
    mov     edi, 20
    mov     esi, 75
    call    rng_randint
    mov     rdi, rbx
    mov     rsi, rax
    call    vhs_line_set_hold
    mov     rax, [vhs_glitch_count]
    lea     rcx, [vhs_glitch_lines]
    mov     [rcx + rax * 8], rbx
    inc     qword [vhs_glitch_count]
    mov     rdi, rbx
    call    vhs_line_glitch
    mov     rdi, rbx
    call    vhs_line_insert
.noise_roll:
    ; randomly add noise to all vhs_lines
    call    rng_random
    mov     rax, [effect_config]
    comisd  xmm0, [rax + VHSTAPE.noise_chance]
    jae     .elapsed
    xor     ebx, ebx
.snow:
    cmp     rbx, [vhs_line_count]
    jae     .elapsed
    mov     rdi, rbx
    mov     esi, S_SNOW
    call    vhs_line_scene
    lea     rdi, [vhs_wave_lines]
    mov     rsi, [vhs_wave_count]
    mov     rdx, rbx
    call    vhs_list_contains
    test    eax, eax
    jnz     .snowed
    lea     rdi, [vhs_glitch_lines]
    mov     rsi, [vhs_glitch_count]
    mov     rdx, rbx
    call    vhs_list_contains
    test    eax, eax
    jnz     .snowed
    mov     rdi, rbx
    call    vhs_line_insert
.snowed:
    inc     rbx
    jmp     .snow
.elapsed:
    inc     qword [vhs_elapsed]
    mov     rax, [vhs_elapsed]
    mov     rcx, [effect_config]
    cmp     rax, [rcx + VHSTAPE.total_time]
    jl      .update
    ; time is up: restore the wave vhs_lines, then the glitch vhs_lines
    xor     ebx, ebx
.restore_wave:
    cmp     rbx, [vhs_wave_count]
    jae     .restore_glitch
    lea     rax, [vhs_wave_lines]
    mov     rdi, [rax + rbx * 8]
    call    vhs_line_restore
    inc     rbx
    jmp     .restore_wave
.restore_glitch:
    xor     ebx, ebx
.restore_line:
    cmp     rbx, [vhs_glitch_count]
    jae     .to_noise
    lea     rax, [vhs_glitch_lines]
    mov     rdi, [rax + rbx * 8]
    call    vhs_line_restore
    inc     rbx
    jmp     .restore_line
.to_noise:
    mov     byte [vhs_phase], PH_NOISE
    jmp     .update
.noise:
    ; once everything settled, final snow for every character
    call    active_empty
    test    eax, eax
    jz      .update
    mov     edi, FILTER_INPUT
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
    xor     ebx, ebx
.final_snow:
    cmp     rbx, r13
    jae     .to_redraw
    mov     ebp, [r12 + rbx * 4]
    mov     edi, ebp
    mov     rax, [ch_user0]
    mov     esi, [rax + rbp * 8 + 4]
    add     esi, S_FINAL_SNOW
    call    scene_activate
    mov     edi, ebp
    call    active_insert
    inc     rbx
    jmp     .final_snow
.to_redraw:
    mov     byte [vhs_phase], PH_REDRAW
    jmp     .update
.redraw:
    ; redraw vhs_lines one by one, top line first
    cmp     byte [vhs_redrawing], 0
    jne     .draw
    call    active_empty
    test    eax, eax
    jz      .update
.draw:
    mov     byte [vhs_redrawing], 1
    mov     rbx, [vhs_to_redraw]
    test    rbx, rbx
    jz      .complete
    dec     rbx
    mov     [vhs_to_redraw], rbx
    mov     rdi, rbx
    mov     esi, S_FINAL_REDRAW
    call    vhs_line_scene
    mov     rdi, rbx
    call    vhs_line_insert
    jmp     .update
.complete:
    mov     byte [vhs_phase], PH_COMPLETE
.update:
    call    update
    mov     eax, 1
    jmp     .out
.finished:
    xor     eax, eax
.out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
align 8
vhs_two:        dq 2.0
vhs_forty:      dq 40.0
vhs_half:       dq 0.5
vhs_point3:     dq 0.3
vhs_snow_symbols:   db "#*.:"
vhs_wave_paths:     db P_MID, P_END, P_MID

section .tstate
alignb 8
vhs_lines:          resq 1                  ; groups: (u32 *slots, u64 count)
vhs_line_count:     resq 1
vhs_snow_memo:      resq 1
vhs_line_handles:   resq 1
vhs_line_colors_rev: resq 1
vhs_final_spectrum: resq 1
vhs_final_map:      resq 1
vhs_final_map_width: resq 1
vhs_wave_top:       resq 1                  ; NONE_I64 = None
vhs_wave_count:     resq 1
vhs_wave_lines:     resq 4
vhs_new_lines:      resq 4
vhs_glitch_count:   resq 1
vhs_glitch_lines:   resq 3
vhs_elapsed:        resq 1
vhs_to_redraw:      resq 1
vhs_block_visual:   resd 1
vhs_noise_shift:    resb 1
vhs_phase:      resb 1
vhs_redrawing:      resb 1
