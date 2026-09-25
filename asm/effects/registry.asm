; effects/registry.asm - the effects this build implements.
;
; effect_table[id] = (build, next_frame); a zero entry means "not ported",
; and Rust keeps that effect. Ids are the EffectCommand variants in
; alphabetical order (src/asm/mod.rs EFFECT_IDS must match).
;
; build: DecryptIterator.__init__ + build(), reading its config through
;        [effect_config]. May FAIL.
; next_frame -> eax = 1 when the effect produced a frame, 0 when done
;        (the effect's next_frame without ctx.frame(); the engine paces,
;        advances the clock and renders).


%include "effects/blackhole.asm"
%include "effects/decrypt.asm"
%include "effects/rain.asm"
%include "effects/synthgrid.asm"
%include "effects/vhstape.asm"

section .data.rel.ro progbits alloc write noexec align=8
align 8
effect_table:
%assign id 0
%rep EFFECT_COUNT
  %if id == EFFECT_BLACKHOLE
    dq blackhole_build, blackhole_next_frame
  %elif id == EFFECT_DECRYPT
    dq decrypt_build, decrypt_next_frame
  %elif id == EFFECT_RAIN
    dq rain_build, rain_next_frame
  %elif id == EFFECT_SYNTHGRID
    dq synthgrid_build, synthgrid_next_frame
  %elif id == EFFECT_VHSTAPE
    dq vhstape_build, vhstape_next_frame
  %else
    dq 0, 0
  %endif
  %assign id id + 1
%endrep
