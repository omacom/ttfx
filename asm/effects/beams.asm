; effects/beams.asm - src/effects/beams.rs.
; Groups keep a cursor and remaining count; pending/active arrays hold pointers.
struc BEAMS
    .final_stops: resq 1
    .final_stop_count: resq 1
    .final_steps: resq 1
    .final_step_count: resq 1
    .final_direction: resq 1
    .row_symbols: resq 1
    .row_count: resq 1
    .column_symbols: resq 1
    .column_count: resq 1
    .delay: resq 1
    .row_min: resq 1
    .row_max: resq 1
    .column_min: resq 1
    .column_max: resq 1
    .stops: resq 1
    .stop_count: resq 1
    .steps: resq 1
    .step_count: resq 1
    .frames: resq 1
    .final_frames: resq 1
    .wipe_speed: resq 1
endstruc
struc BEAM_GROUP
    .chars: resq 1
    .count: resq 1
    .speed: resq 1
    .counter: resq 1
    .direction: resq 1
endstruc
%define BEAM_ROW (NAME_LITERAL + 0)
%define BEAM_COLUMN (NAME_LITERAL + 1)
%define BEAM_BRIGHTEN (NAME_LITERAL + 2)
%define BEAM_ALL (FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL)

section .text
; Beams::build. Clobbers C.
beams_build:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov edi, FILTER_INPUT
    mov esi, GROUP_DIAG_TL_TO_BR
    call get_characters_grouped
    mov [beams_wipe], rax
    mov [beams_wipe_count], rdx
    call beams_color_map
    cmp qword [cfg_existing_colors], 0
    je .no_cache                    ; input colors enter the frames
    call beams_cache_init
.no_cache:
    mov rbx, [effect_config]
    mov rdi, [rbx + BEAMS.steps]
    mov rcx, [rbx + BEAMS.step_count]
    mov rsi, [rbx + BEAMS.stop_count]
    call gradient_capacity
    lea rdi, [rax*8]
    call alloc
    mov [beams_spectrum], rax
    mov r8, rax
    mov rdi, [rbx + BEAMS.stops]
    mov rsi, [rbx + BEAMS.stop_count]
    mov rdx, [rbx + BEAMS.steps]
    mov rcx, [rbx + BEAMS.step_count]
    call gradient_new
    mov [beams_spectrum_count], rax
    ; At most canvas rows + columns groups.
    mov rdi, [canvas_top]
    add rdi, [canvas_right]
    shl rdi, 3
    call alloc
    mov [beams_pending], rax
    mov rdi, [canvas_top]
    add rdi, [canvas_right]
    shl rdi, 3
    call alloc
    mov [beams_active], rax
    xor ebp, ebp
.direction:
    mov edi, BEAM_ALL
    mov esi, GROUP_ROW_TOP_TO_BOTTOM
    test ebp, ebp
    jz .group
    mov esi, GROUP_COLUMN_L2R
.group:
    call get_characters_grouped
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
.make:
    cmp r14, r13
    jae .next_direction
    mov edi, BEAM_GROUP_size
    call alloc
    mov r15, rax
    mov rax, r14
    shl rax, 4
    mov rcx, [r12 + rax]
    mov rdx, [r12 + rax + 8]
    mov [r15 + BEAM_GROUP.chars], rcx
    mov [r15 + BEAM_GROUP.count], rdx
    mov [r15 + BEAM_GROUP.direction], rbp
    mov rdi, [rbx + BEAMS.row_min]
    mov rsi, [rbx + BEAMS.row_max]
    test ebp, ebp
    jz .speed
    mov rdi, [rbx + BEAMS.column_min]
    mov rsi, [rbx + BEAMS.column_max]
.speed:
    call rng_randint
    cvtsi2sd xmm0, rax
    mulsd xmm0, [beams_tenth]
    movsd [r15 + BEAM_GROUP.speed], xmm0
    mov edi, 2
    call rng_below
    test eax, eax
    jnz .append
    mov rcx, [r15 + BEAM_GROUP.chars]
    mov rdx, [r15 + BEAM_GROUP.count]
    lea rdx, [rcx + rdx*4 - 4]
.reverse:
    cmp rcx, rdx
    jae .append
    mov eax, [rcx]
    mov esi, [rdx]
    mov [rcx], esi
    mov [rdx], eax
    add rcx, 4
    sub rdx, 4
    jmp .reverse
.append:
    mov rax, [beams_pending]
    mov rcx, [beams_pending_count]
    mov [rax + rcx*8], r15
    inc qword [beams_pending_count]
    inc r14
    jmp .make
.next_direction:
    inc ebp
    cmp ebp, 2
    jb .direction
    ; Scene construction consumes no RNG. Each character appears once here.
    mov edi, BEAM_ALL
    mov esi, SORT_TOP_TO_BOTTOM_L2R
    call get_characters
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
.scenes:
    cmp r14, r13
    jae .shuffle
    mov edi, [r12 + r14*4]
    call beams_scenes
    inc r14
    jmp .scenes
.shuffle:
    mov rdi, [beams_pending]
    mov rsi, [beams_pending_count]
    call rng_shuffle64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Beams::build: one character's beam and brighten scenes. Clobbers C.
beams_scenes:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov rbx, [effect_config]
    ; the character's symbol and colors, which with the (shared) beam
    ; gradients determine all three scenes
    mov rax, [ch_sym]
    mov rax, [rax + r12*8]
    mov [beams_symbol], rax
    xor r13d, r13d
    mov r14, NONE
    mov rax, [ch_flags]
    test word [rax + r12*2], CF_FILL
    jnz .keyed
    cmp qword [cfg_existing_colors], 1
    jne .mapped
    mov rax, [ch_fg]
    mov r13, [rax + r12*8]
    mov rax, [ch_bg]
    mov r14, [rax + r12*8]
    jmp .keyed
.mapped:
    mov rax, [ch_irow]
    movsxd rax, dword [rax + r12*4]
    sub rax, [text_bottom]
    imul rax, [beams_map_width]
    mov rcx, [ch_icol]
    movsxd rcx, dword [rcx + r12*4]
    add rax, rcx
    sub rax, [text_left]
    mov rcx, [beams_map]
    mov r13, [rcx + rax*8]
.keyed:
    ; a character with the same (symbol, fg, bg) as an earlier one gets
    ; clones of that one's scenes
    xor r15d, r15d                  ; cache entry to fill, 0 = none
    mov rsi, [beams_cache]
    test rsi, rsi
    jz .new_scenes
    mov rdi, [beams_symbol]
    mov rax, r13
    mov rcx, 0x9E3779B97F4A7C15
    imul rax, rcx
    xor rax, rdi
    mov rcx, 0xBF58476D1CE4E5B9
    imul rax, rcx
    xor rax, r14
    imul rax, rcx
    mov rcx, [beams_cache_shift]
    shr rax, cl
.probe:
    mov rdx, rax
    shl rdx, 5
    add rdx, rsi
    cmp qword [rdx], 0
    je .miss
    cmp [rdx], rdi
    jne .probe_next
    cmp [rdx + 8], r13
    jne .probe_next
    cmp [rdx + 16], r14
    je .hit
.probe_next:
    inc rax
    and rax, [beams_cache_mask]
    jmp .probe
.miss:
    mov [rdx], rdi
    mov [rdx + 8], r13
    mov [rdx + 16], r14
    mov r15, rdx
    jmp .new_scenes
.hit:
    mov r15d, [rdx + 24]            ; the earlier character
    xor ebp, ebp
.copy:
    mov edi, r15d
    lea esi, [BEAM_ROW + rbp]
    call scene_find
    mov esi, eax
    mov edi, r12d
    lea edx, [BEAM_ROW + rbp]
    call scene_copy
    inc ebp
    cmp ebp, 3
    jb .copy
    jmp .out
.new_scenes:
    test r15, r15
    jz .fresh
    mov [r15 + 24], r12d
.fresh:
    xor ebp, ebp
.new:
    mov edi, r12d
    lea esi, [BEAM_ROW + rbp]
    xor edx, edx
    mov ecx, NONE
    call scene_new
    lea rcx, [beams_scene_ids]
    mov [rcx + rbp*4], eax
    inc ebp
    cmp ebp, 3
    jb .new
    xor ebp, ebp
.beam:
    lea rax, [beams_scene_ids]
    mov edi, [rax + rbp*4]
    mov rax, rbp
    shl rax, 4
    mov rsi, [rbx + BEAMS.row_symbols + rax]
    mov rdx, [rbx + BEAMS.row_count + rax]
    mov rcx, [rbx + BEAMS.frames]
    mov r8, [beams_spectrum]
    mov r9, [beams_spectrum_count]
    push 0
    push 0
    call scene_apply_gradient
    add rsp, 16
    inc ebp
    cmp ebp, 2
    jb .beam
.colors:
    mov qword [beams_fg_count], 0
    mov qword [beams_bg_count], 0
    cmp r13, NONE
    je .bg
    mov rdi, r13
    lea rsi, [beams_fg_fade]
    lea rdx, [beams_fg_bright]
    call beams_fades
    mov qword [beams_fg_count], 11
.bg:
    cmp r14, NONE
    je .fades
    mov rdi, r14
    lea rsi, [beams_bg_fade]
    lea rdx, [beams_bg_bright]
    call beams_fades
    mov qword [beams_bg_count], 11
.fades:
    xor ebp, ebp
.fade:
    lea rax, [beams_scene_ids]
    mov edi, [rax + rbp*4]
    lea rsi, [beams_symbol]
    mov edx, 1
    mov ecx, 2
    lea r8, [beams_fg_fade]
    lea rax, [beams_bg_fade]
    cmp ebp, 2
    jne .apply
    mov rcx, [rbx + BEAMS.final_frames]
    lea r8, [beams_fg_bright]
    lea rax, [beams_bg_bright]
.apply:
    mov r9, [beams_fg_count]
    cmp qword [beams_bg_count], 0
    jne .has_bg
    xor eax, eax
.has_bg:
    test r9, r9
    jnz .gradient
    xor r8d, r8d
    test rax, rax
    jnz .gradient
    mov edx, ecx
    mov rsi, [beams_symbol]
    mov rcx, NONE
    mov r8, NONE
    xor r9d, r9d
    call scene_add_frame
    jmp .added
.gradient:
    push qword [beams_bg_count]
    push rax
    call scene_apply_gradient
    add rsp, 16
.added:
    inc ebp
    cmp ebp, 3
    jb .fade
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Beams::build: fg/bg fade and brighten gradients (not a reversed spectrum:
; integer interpolation rounds down in each direction). Clobbers C.
; rdi=color, rsi=fade output, rdx=brighten output.
beams_fades:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    movsd xmm0, [beams_dim]
    call adjust_color_brightness
    mov [beams_pair], rbx
    mov [beams_pair + 8], rax
    lea rdi, [beams_pair]
    mov esi, 2
    lea rdx, [beams_ten]
    mov ecx, 1
    mov r8, r12
    call gradient_new
    mov rax, [beams_pair + 8]
    mov [beams_pair], rax
    mov [beams_pair + 8], rbx
    lea rdi, [beams_pair]
    mov esi, 2
    lea rdx, [beams_ten]
    mov ecx, 1
    mov r8, r13
    call gradient_new
    pop r13
    pop r12
    pop rbx
    ret

; Beams::next_frame + Group::get_next_character. Clobbers C.
beams_next_frame:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    cmp qword [beams_phase], 2
    jne .phase
    call active_empty
    test eax, eax
    jnz .done
.phase:
    cmp qword [beams_phase], 0
    jne .wipe
    cmp qword [beams_delay], 0
    jne .delay
    cmp qword [beams_pending_count], 0
    je .reset_delay
    mov edi, 1
    mov esi, 5
    call rng_randint
    mov rcx, [beams_pending_count]
    cmp rax, rcx
    cmova rax, rcx
    sub [beams_pending_count], rax
    mov rdx, [beams_pending]
    mov rsi, [beams_active]
    mov rcx, [beams_active_count]
.activate:
    mov rdi, [rdx]
    mov [rsi + rcx*8], rdi
    inc rcx
    add rdx, 8
    dec rax
    jnz .activate
    mov [beams_pending], rdx
    mov [beams_active_count], rcx
.reset_delay:
    mov rax, [effect_config]
    mov rax, [rax + BEAMS.delay]
    mov [beams_delay], rax
    jmp .groups
.delay:
    dec qword [beams_delay]
.groups:
    xor r12d, r12d
    xor r13d, r13d
    mov r14, [beams_active]
.group:
    cmp r12, [beams_active_count]
    jae .pruned
    mov rbx, [r14 + r12*8]
    movsd xmm0, [rbx + BEAM_GROUP.counter]
    addsd xmm0, [rbx + BEAM_GROUP.speed]
    movsd [rbx + BEAM_GROUP.counter], xmm0
    call f64_to_i64
    mov rbp, rax
    cmp rbp, 1
    jle .keep
    ; Empty-group iterations do nothing in Rust.
    cmp rbp, [rbx + BEAM_GROUP.count]
    cmova rbp, [rbx + BEAM_GROUP.count]
.character:
    test rbp, rbp
    jz .keep
    movsd xmm0, [rbx + BEAM_GROUP.counter]
    subsd xmm0, [beams_one]
    movsd [rbx + BEAM_GROUP.counter], xmm0
    mov rax, [rbx + BEAM_GROUP.chars]
    mov r15d, [rax]
    add qword [rbx + BEAM_GROUP.chars], 4
    dec qword [rbx + BEAM_GROUP.count]
    mov rax, [ch_scene]
    mov edi, [rax + r15*4]
    cmp edi, NONE
    je .visible
    call scene_reset
    jmp .start_scene
.visible:
    mov edi, r15d
    call set_visible
    mov edi, r15d
    call active_insert
.start_scene:
    mov edi, r15d
    mov esi, [rbx + BEAM_GROUP.direction]
    add esi, BEAM_ROW
    call scene_activate_name
    dec rbp
    jmp .character
.keep:
    cmp qword [rbx + BEAM_GROUP.count], 0
    je .next
    mov [r14 + r13*8], rbx
    inc r13
.next:
    inc r12
    jmp .group
.pruned:
    mov [beams_active_count], r13
    or r13, [beams_pending_count]
    jnz .tick
    call active_empty
    test eax, eax
    jz .tick
    mov qword [beams_phase], 1
    jmp .tick
.wipe:
    cmp qword [beams_phase], 1
    jne .tick
    cmp qword [beams_wipe_count], 0
    jne .wipe_groups
    mov qword [beams_phase], 2
    jmp .tick
.wipe_groups:
    mov rax, [effect_config]
    mov rbp, [rax + BEAMS.wipe_speed]
.wipe_group:
    test rbp, rbp
    jz .tick
    cmp qword [beams_wipe_count], 0
    je .tick
    mov rax, [beams_wipe]
    mov r12, [rax]
    mov r13, [rax + 8]
    add qword [beams_wipe], 16
    dec qword [beams_wipe_count]
.wipe_character:
    mov ebx, [r12]
    mov edi, ebx
    mov esi, BEAM_BRIGHTEN
    call scene_activate_name
    mov edi, ebx
    call set_visible
    mov edi, ebx
    call active_insert
    add r12, 4
    dec r13
    jnz .wipe_character
    dec rbp
    jmp .wipe_group
.tick:
    call update
    mov eax, 1
    jmp .return
.done:
    xor eax, eax
.return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; beams_cache_init: the (symbol, fg, bg) -> character table of beams_scenes,
; 32-byte entries (symbol 0 = empty), at least twice the character count.
beams_cache_init:
    mov eax, [char_count]
    add rax, rax
    mov ecx, 16
    xor edx, edx
.size:
    cmp rcx, rax
    jae .sized
    add rcx, rcx
    inc edx
    jmp .size
.sized:
    lea rax, [rcx - 1]
    mov [beams_cache_mask], rax
    add edx, 4
    mov eax, 64
    sub eax, edx
    mov [beams_cache_shift], rax
    shl rcx, 5
    lea rdi, [rcx + 64]
    call alloc
    mov [beams_cache], rax
    ret

; beams_color_map: Gradient::new(final stops, final steps) and its
; coordinate mapping over the text rectangle.
beams_color_map:
    push    rbx
    mov     rbx, [effect_config]
    ; spectrum capacity: sum over pairs of the step counts, plus one per pair
    mov     rdi, [rbx + BEAMS.final_steps]
    mov     rcx, [rbx + BEAMS.final_step_count]
    mov     rsi, [rbx + BEAMS.final_stop_count]
    call    gradient_capacity
    lea     rdi, [rax * 8]
    call    alloc
    mov     [beams_final_spectrum], rax
    mov     rdi, [rbx + BEAMS.final_stops]
    mov     rsi, [rbx + BEAMS.final_stop_count]
    mov     rdx, [rbx + BEAMS.final_steps]
    mov     rcx, [rbx + BEAMS.final_step_count]
    mov     r8, [beams_final_spectrum]
    call    gradient_new
    mov     rdi, [beams_final_spectrum]
    mov     esi, eax
    mov     rdx, [text_bottom]
    mov     rcx, [text_top]
    mov     r8, [text_left]
    mov     r9, [text_right]
    mov     rax, r9
    sub     rax, r8
    inc     rax
    mov     [beams_map_width], rax
    push    qword [rbx + BEAMS.final_direction]
    call    gradient_map
    add     rsp, 8
    mov     [beams_map], rax
    pop     rbx
    ret


section .rodata
align 8
beams_tenth: dq 0.1
beams_dim: dq 0.3
beams_one: dq 1.0
beams_ten: dq 10
section .tstate
alignb 8
beams_wipe: resq 1
beams_wipe_count: resq 1
beams_pending: resq 1
beams_pending_count: resq 1
beams_active: resq 1
beams_active_count: resq 1
beams_delay: resq 1
beams_phase: resq 1
beams_spectrum: resq 1
beams_spectrum_count: resq 1
beams_final_spectrum: resq 1
beams_map: resq 1
beams_map_width: resq 1
beams_scene_ids: resd 3
alignb 8
beams_cache: resq 1
beams_cache_mask: resq 1
beams_cache_shift: resq 1
beams_symbol: resq 1
beams_pair: resq 2
beams_fg_count: resq 1
beams_bg_count: resq 1
beams_fg_fade: resq 11
beams_fg_bright: resq 11
beams_bg_fade: resq 11
beams_bg_bright: resq 11
