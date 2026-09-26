; utils/spanning_tree.asm - spanning-tree generators (src/utils/spanning_tree.rs):
; PrimsSimple, PrimsWeighted, RecursiveBacktracker and BreadthFirst.
;
; EffectCharacter.links: 16 bytes per slot in [st_links], up to four linked
; slots (a character only links to its grid neighbors) kept ascending, each
; stored as slot + 1 so a zero word ends the list. Ascending slot order is
; ascending character_id, the canonical order BreadthFirst walks.
;
; Each generator is a single instance in .tstate (no effect runs two of the
; same kind). Every constructor draws its starting character exactly like
; default_starting_char when none is given.

%define ST_WEIGHTS          100         ; randint(0, 99)

section .text

; st_init: allocate the links table once per run. Only characters that
; exist when a generator starts (the input and fill characters, which carry
; the neighbor records) are ever linked.
st_init:
    cmp     qword [st_links], 0
    jne     .done
    mov     edi, [char_count]
    shl     rdi, 4
    call    alloc
    mov     [st_links], rax
.done:
    ret

; st_insert(edi=slot, esi=other): add other to slot's ascending link list,
; unless present. Clobbers rax, rcx, rdx, r8.
st_insert:
    mov     r8, [st_links]
    mov     eax, edi
    shl     rax, 4
    add     r8, rax
    lea     edx, [esi + 1]              ; the stored word
    xor     ecx, ecx
.find:
    cmp     ecx, 4
    jae     .done                       ; full (cannot happen for grid links)
    mov     eax, [r8 + rcx * 4]
    test    eax, eax
    jz      .put
    cmp     eax, edx
    je      .done
    ja      .shift
    inc     ecx
    jmp     .find
.shift:
    ; insert at ecx: swap the new word through the tail
    mov     [r8 + rcx * 4], edx
    mov     edx, eax
    inc     ecx
    cmp     ecx, 4
    jae     .done
    mov     eax, [r8 + rcx * 4]
    test    eax, eax
    jnz     .shift
.put:
    mov     [r8 + rcx * 4], edx
.done:
    ret

; link_characters(edi=a, esi=b): EffectCharacter._link, both directions.
; Clobbers rax, rcx, rdx, r8.
link_characters:
    call    st_insert
    xchg    edi, esi
    call    st_insert
    xchg    edi, esi
    ret

; st_has_links(edi=slot) -> eax nonzero when the character has links.
st_has_links:
    mov     rax, [st_links]
    mov     ecx, edi
    shl     rcx, 4
    mov     eax, [rax + rcx]
    ret

; st_neighbors(edi=slot, esi=limit to text, rdx=u32 out[4]) -> eax = count.
; SpanningTreeGenerator.get_neighbors with unlinked_only: north, east, south,
; west, kept when inside the text boundary (if limited) and unlinked.
; Clobbers rax, rcx, rdx, rsi, r8-r11.
st_neighbors:
    mov     r8, [ch_nbr]
    mov     eax, edi
    shl     rax, 4
    add     r8, rax
    xor     eax, eax                    ; count
    xor     r9d, r9d                    ; direction
.next:
    cmp     r9d, 4
    jae     .done
    mov     ecx, [r8 + r9 * 4]
    inc     r9d
    cmp     ecx, NONE
    je      .next
    test    esi, esi
    jz      .links
    mov     r10, [ch_irow]
    movsxd  r10, dword [r10 + rcx * 4]
    cmp     r10, [text_bottom]
    jl      .next
    cmp     r10, [text_top]
    jg      .next
    mov     r10, [ch_icol]
    movsxd  r10, dword [r10 + rcx * 4]
    cmp     r10, [text_left]
    jl      .next
    cmp     r10, [text_right]
    jg      .next
.links:
    mov     r10, [st_links]
    mov     r11d, ecx
    shl     r11, 4
    cmp     dword [r10 + r11], 0
    jne     .next
    mov     [rdx + rax * 4], ecx
    inc     eax
    jmp     .next
.done:
    ret

; st_starting_char(edi=within text) -> eax = slot: default_starting_char.
st_starting_char:
    mov     esi, edi
    xor     edi, edi
    call    canvas_random_coord
    mov     rsi, rax
    call    char_at_input_coord
    cmp     eax, NONE
    je      .missing
    ret
.missing:
    FAIL    msg_no_starting_char

; st_start(edi=starting slot or NONE, esi=within text) -> eax = slot.
st_start:
    cmp     edi, NONE
    jne     .given
    mov     edi, esi
    jmp     st_starting_char
.given:
    mov     eax, edi
    ret

; st_array(rdi=entries per character) -> rax: a zeroed u32 array sized for
; every current character slot times the factor.
st_array:
    mov     eax, [char_count]
    imul    rdi, rax
    lea     rdi, [rdi * 4 + 64]
    jmp     alloc

; ------------------------------------------------------------ PrimsSimple

; ps_new(edi=limit to text): PrimsSimple::new(None, limit).
ps_new:
    push    rbx
    mov     ebx, edi
    mov     [ps_limit], edi
    call    st_init
    mov     edi, NONE
    mov     esi, ebx
    call    st_start
    mov     ebx, eax
    mov     edi, 1
    call    st_array
    mov     [ps_order], rax
    mov     [rax], ebx
    mov     qword [ps_order_count], 1
    mov     edi, 2
    call    st_array
    mov     [ps_edges], rax
    mov     [rax], ebx
    mov     qword [ps_edge_count], 1
    mov     byte [ps_complete], 0
    pop     rbx
    ret

; ps_step: PrimsSimple.step (complete flips only when the edge list is
; already empty on entry).
ps_step:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rsi, [ps_edge_count]
    test    rsi, rsi
    jz      .complete
    xor     edi, edi
    call    rng_randrange
    ; current = edge_chars.remove(idx)
    mov     rcx, [ps_edges]
    mov     ebx, [rcx + rax * 4]
    mov     rdx, [ps_edge_count]
    dec     rdx
    mov     [ps_edge_count], rdx
.shift:
    cmp     rax, rdx
    jae     .shifted
    mov     r8d, [rcx + rax * 4 + 4]
    mov     [rcx + rax * 4], r8d
    inc     rax
    jmp     .shift
.shifted:
    mov     edi, ebx
    mov     esi, [ps_limit]
    mov     rdx, rsp
    call    st_neighbors
    test    eax, eax
    jz      .done
    mov     r13d, eax                   ; unlinked neighbor count
    xor     edi, edi
    mov     esi, eax
    call    rng_randrange
    mov     r12d, [rsp + rax * 4]       ; next_char
    dec     r13d                        ; one removed
    mov     edi, ebx
    mov     esi, r12d
    call    link_characters
    mov     rax, [ps_order_count]
    mov     rcx, [ps_order]
    mov     [rcx + rax * 4], r12d
    inc     qword [ps_order_count]
    test    r13d, r13d
    jz      .next_neighbors
    mov     rax, [ps_edge_count]
    mov     rcx, [ps_edges]
    mov     [rcx + rax * 4], ebx
    inc     qword [ps_edge_count]
.next_neighbors:
    mov     edi, r12d
    mov     esi, [ps_limit]
    lea     rdx, [rsp + 16]
    call    st_neighbors
    test    eax, eax
    jz      .done
    mov     rax, [ps_edge_count]
    mov     rcx, [ps_edges]
    mov     [rcx + rax * 4], r12d
    inc     qword [ps_edge_count]
    jmp     .done
.complete:
    mov     byte [ps_complete], 1
.done:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

; ps_run -> rax = char_link_order (u32 slots), rdx = count: step until
; complete.
ps_run:
    cmp     byte [ps_complete], 0
    jne     .done
    call    ps_step
    jmp     ps_run
.done:
    mov     rax, [ps_order]
    mov     rdx, [ps_order_count]
    ret

; ---------------------------------------------------------- PrimsWeighted

; pw_new(edi=limit to text): PrimsWeighted::new(None, limit) - the starting
; character, one randint(0, 99) weight per input and fill character from top
; to bottom, left to right, then the starting character's weighted links.
pw_new:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     [pw_limit], edi
    call    st_init
    mov     edi, NONE
    mov     esi, ebx
    call    st_start
    mov     ebx, eax                    ; starting char
    mov     edi, [char_count]
    call    alloc
    mov     [pw_weights], rax
    mov     edi, FILTER_INPUT | FILTER_INNER_FILL | FILTER_OUTER_FILL
    mov     esi, SORT_TOP_TO_BOTTOM_L2R
    call    get_characters
    mov     r12, rax
    mov     r13, rdx
.weigh:
    test    r13, r13
    jz      .weighed
    xor     edi, edi
    mov     esi, ST_WEIGHTS - 1
    call    rng_randint
    mov     ecx, [r12]
    mov     rdx, [pw_weights]
    mov     [rdx + rcx], al
    add     r12, 4
    dec     r13
    jmp     .weigh
.weighed:
    ; bucket w holds up to 4 links per character: [pw_buckets] + w * cap * 8
    mov     eax, [char_count]
    lea     rax, [rax * 4 + 4]
    shl     rax, 3
    mov     [pw_bucket_bytes], rax
    imul    rdi, rax, ST_WEIGHTS
    call    alloc
    mov     [pw_buckets], rax
    mov     edi, 1
    call    st_array
    mov     [pw_order], rax
    mov     [rax], ebx
    mov     qword [pw_order_count], 1
    mov     byte [pw_complete], 0
    mov     edi, ebx
    call    pw_add_links
    pop     r13
    pop     r12
    pop     rbx
    ret

; pw_bucket(ecx=weight) -> rax = the bucket's base. Clobbers rax.
%macro PW_BUCKET 0
    mov     eax, ecx
    imul    rax, [pw_bucket_bytes]
    add     rax, [pw_buckets]
%endmacro

; pw_add_links(edi=slot): add_weighted_links - one (slot, neighbor) link per
; unlinked neighbor into the neighbor's weight bucket.
pw_add_links:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     esi, [pw_limit]
    mov     rdx, rsp
    call    st_neighbors
    mov     r12d, eax
    xor     r13d, r13d
.next:
    cmp     r13d, r12d
    jae     .done
    mov     r8d, [rsp + r13 * 4]        ; neighbor
    mov     rcx, [pw_weights]
    movzx   ecx, byte [rcx + r8]
    PW_BUCKET
    lea     rdx, [pw_counts]
    mov     r9, [rdx + rcx * 8]
    shl     r8, 32
    or      r8, rbx                     ; char_a low, char_b high
    mov     [rax + r9 * 8], r8
    inc     qword [rdx + rcx * 8]
    bts     [pw_nonempty], rcx
    inc     r13d
    jmp     .next
.done:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

; pw_lowest -> rcx = the lowest nonempty weight, or ZF set when none.
pw_lowest:
    mov     rax, [pw_nonempty]
%if TIER >= 3
    tzcnt   rcx, rax
    jnc     .found
    mov     rax, [pw_nonempty + 8]
    tzcnt   rcx, rax
    jc      .none
%else
    bsf     rcx, rax                    ; ZF (not CF) flags an empty word
    jnz     .found
    mov     rax, [pw_nonempty + 8]
    bsf     rcx, rax
    jz      .none
%endif
    add     ecx, 64
.found:
    or      eax, 1                      ; ZF clear
    ret
.none:
    xor     eax, eax                    ; ZF set
    ret

; pw_step: PrimsWeighted.step with get_lowest_weight_link inlined: pop a
; random link of the lowest weight until one reaches an unlinked character.
pw_step:
    push    rbx
    push    r12
    push    r13
    call    pw_lowest
    jz      .complete
.pop:
    mov     r12d, ecx                   ; weight
    lea     rdx, [pw_counts]
    mov     rsi, [rdx + rcx * 8]
    xor     edi, edi
    call    rng_randrange
    mov     r9, rax                     ; idx
    mov     ecx, r12d
    PW_BUCKET
    mov     r13, [rax + r9 * 8]         ; the link: char_a low, char_b high
    lea     rdx, [pw_counts]
    mov     r8, [rdx + rcx * 8]
    dec     r8
    mov     [rdx + rcx * 8], r8
    jnz     .remove
    btr     [pw_nonempty], rcx
.remove:
    ; links_at_weight.remove(idx)
    cmp     r9, r8
    jae     .removed
    mov     r10, [rax + r9 * 8 + 8]
    mov     [rax + r9 * 8], r10
    inc     r9
    jmp     .remove
.removed:
    mov     rdi, r13
    shr     rdi, 32
    call    st_has_links
    test    eax, eax
    jz      .found
    call    pw_lowest
    jnz     .pop
    jmp     .complete
.found:
    mov     edi, r13d
    mov     rsi, r13
    shr     rsi, 32
    mov     ebx, esi
    call    link_characters
    mov     rax, [pw_order_count]
    mov     rcx, [pw_order]
    mov     [rcx + rax * 4], ebx
    inc     qword [pw_order_count]
    mov     edi, ebx
    call    pw_add_links
    pop     r13
    pop     r12
    pop     rbx
    ret
.complete:
    mov     byte [pw_complete], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

; pw_run: step until complete.
pw_run:
    cmp     byte [pw_complete], 0
    jne     .done
    call    pw_step
    jmp     pw_run
.done:
    ret

; --------------------------------------------------- RecursiveBacktracker

; rb_new(edi=limit to text): RecursiveBacktracker::new(None, limit).
rb_new:
    push    rbx
    mov     ebx, edi
    mov     [rb_limit], edi
    call    st_init
    mov     edi, NONE
    mov     esi, ebx
    call    st_start
    mov     ebx, eax
    mov     [rb_current], eax
    mov     edi, 1
    call    st_array
    mov     [rb_order], rax
    mov     [rax], ebx
    mov     qword [rb_order_count], 1
    mov     edi, 1
    call    st_array
    mov     [rb_stack], rax
    mov     [rax], ebx
    mov     qword [rb_stack_count], 1
    mov     byte [rb_complete], 0
    pop     rbx
    ret

; rb_step: RecursiveBacktracker.step - link a random unvisited neighbor of
; the current character and push it, or pop back.
rb_step:
    push    rbx
    push    r12
    sub     rsp, 24
    cmp     qword [rb_stack_count], 0
    je      .complete
    mov     ebx, [rb_current]
    mov     edi, ebx
    mov     esi, [rb_limit]
    mov     rdx, rsp
    call    st_neighbors
    test    eax, eax
    jz      .backtrack
    mov     edi, eax
    call    rng_below                   ; choice
    mov     r12d, [rsp + rax * 4]
    mov     edi, ebx
    mov     esi, r12d
    call    link_characters
    mov     rax, [rb_order_count]
    mov     rcx, [rb_order]
    mov     [rcx + rax * 4], r12d
    inc     qword [rb_order_count]
    mov     rax, [rb_stack_count]
    mov     rcx, [rb_stack]
    mov     [rcx + rax * 4], r12d
    inc     qword [rb_stack_count]
    mov     [rb_current], r12d
    jmp     .done
.backtrack:
    mov     rax, [rb_stack_count]
    dec     rax
    mov     [rb_stack_count], rax
    jz      .done
    mov     rcx, [rb_stack]
    mov     ecx, [rcx + rax * 4 - 4]
    mov     [rb_current], ecx
    jmp     .done
.complete:
    mov     byte [rb_complete], 1
.done:
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

; rb_run -> rax = char_link_order, rdx = count: step until complete.
rb_run:
    cmp     byte [rb_complete], 0
    jne     .done
    call    rb_step
    jmp     rb_run
.done:
    mov     rax, [rb_order]
    mov     rdx, [rb_order_count]
    ret

; ----------------------------------------------------------- BreadthFirst

; bf_new(edi=starting slot or NONE, esi=limit to text) -> eax = the
; starting character. BreadthFirst::new. The frontier and every later layer
; live in one queue: the frontier is [bf_head, bf_tail).
bf_new:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    st_init
    mov     edi, r12d
    mov     esi, r13d
    call    st_start
    mov     ebx, eax
    mov     [bf_start], eax
    mov     edi, [char_count]
    call    alloc
    mov     [bf_explored], rax
    mov     byte [rax + rbx], 1
    mov     edi, 1
    call    st_array
    mov     [bf_queue], rax
    mov     [rax], ebx
    mov     qword [bf_head], 0
    mov     qword [bf_tail], 1
    mov     byte [bf_complete], 0
    mov     eax, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

; bf_step -> rax = explored_last_step (u32 slots), rdx = count.
; BreadthFirst.step: every frontier character's unexplored links, in
; frontier order and ascending id within each, become the next frontier.
; (Anything in the frontier or in new_edges is already explored, so the
; explored test covers Rust's three membership checks.)
bf_step:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [bf_head]
    mov     r12, [bf_tail]              ; end of the frontier
    cmp     rbx, r12
    je      .complete
    mov     r13, r12                    ; new tail
    mov     r8, [bf_queue]
    mov     r9, [bf_explored]
.position:
    cmp     rbx, r12
    jae     .layered
    mov     eax, [r8 + rbx * 4]
    inc     rbx
    shl     rax, 4
    add     rax, [st_links]
    xor     ecx, ecx
.link:
    cmp     ecx, 4
    jae     .position
    mov     edx, [rax + rcx * 4]
    inc     ecx
    test    edx, edx
    jz      .position
    dec     edx
    cmp     byte [r9 + rdx], 0
    jne     .link
    mov     byte [r9 + rdx], 1
    mov     [r8 + r13 * 4], edx
    inc     r13
    jmp     .link
.layered:
    mov     [bf_head], r12
    mov     [bf_tail], r13
    lea     rax, [r8 + r12 * 4]
    mov     rdx, r13
    sub     rdx, r12
    jmp     .done
.complete:
    mov     byte [bf_complete], 1
    xor     edx, edx
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
STR msg_no_starting_char, "Unable to find a starting character."

section .tstate
alignb 8
st_links:           resq 1
ps_order:           resq 1
ps_order_count:     resq 1
ps_edges:           resq 1
ps_edge_count:      resq 1
ps_limit:           resd 1
ps_complete:        resb 1
alignb 8
rb_order:           resq 1
rb_order_count:     resq 1
rb_stack:           resq 1
rb_stack_count:     resq 1
rb_current:         resd 1
rb_limit:           resd 1
rb_complete:        resb 1
alignb 8
bf_queue:           resq 1
bf_explored:        resq 1
bf_head:            resq 1
bf_tail:            resq 1
bf_start:           resd 1
bf_complete:        resb 1
alignb 8
pw_weights:         resq 1
pw_buckets:         resq 1
pw_bucket_bytes:    resq 1
pw_counts:          resq ST_WEIGHTS
pw_nonempty:        resq 2
pw_order:           resq 1
pw_order_count:     resq 1
pw_limit:           resd 1
pw_complete:        resb 1
