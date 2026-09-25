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
%include "effects/bouncyballs.asm"
%include "effects/colorshift.asm"
%include "effects/decrypt.asm"
%include "effects/highlight.asm"
%include "effects/middleout.asm"
%include "effects/pour.asm"
%include "effects/sweep.asm"
%include "effects/randomsequence.asm"
%include "effects/expand.asm"
%include "effects/spray.asm"
%include "effects/scattered.asm"
%include "effects/rain.asm"
%include "effects/synthgrid.asm"
%include "effects/vhstape.asm"
%include "effects/wipe.asm"
%include "effects/rings.asm"
%include "effects/matrix.asm"
%include "effects/thunderstorm.asm"
%include "effects/slice.asm"
%include "effects/beams.asm"
%include "effects/binarypath.asm"
%include "effects/crumble.asm"
%include "effects/overflow.asm"
%include "effects/waves.asm"
%include "effects/fireworks.asm"
%include "effects/errorcorrect.asm"
%include "effects/unstable.asm"
%include "effects/print.asm"
%include "effects/bubbles.asm"
%include "effects/orbittingvolley.asm"

section .data.rel.ro progbits alloc write noexec align=8
align 8
effect_table:
%assign id 0
%rep EFFECT_COUNT
  %if id == EFFECT_BLACKHOLE
    dq blackhole_build, blackhole_next_frame
  %elif id == EFFECT_BOUNCYBALLS
    dq bouncyballs_build, bouncyballs_next_frame
  %elif id == EFFECT_COLORSHIFT
    dq colorshift_build, colorshift_next_frame
  %elif id == EFFECT_DECRYPT
    dq decrypt_build, decrypt_next_frame
  %elif id == EFFECT_HIGHLIGHT
    dq highlight_build, highlight_next_frame
  %elif id == EFFECT_MIDDLEOUT
    dq middleout_build, middleout_next_frame
  %elif id == EFFECT_POUR
    dq pour_build, pour_next_frame
  %elif id == EFFECT_SWEEP
    dq sweep_build, sweep_next_frame
  %elif id == EFFECT_RANDOMSEQUENCE
    dq randomsequence_build, randomsequence_next_frame
  %elif id == EFFECT_EXPAND
    dq expand_build, expand_next_frame
  %elif id == EFFECT_SPRAY
    dq spray_build, spray_next_frame
  %elif id == EFFECT_SCATTERED
    dq scattered_build, scattered_next_frame
  %elif id == EFFECT_RAIN
    dq rain_build, rain_next_frame
  %elif id == EFFECT_SYNTHGRID
    dq synthgrid_build, synthgrid_next_frame
  %elif id == EFFECT_VHSTAPE
    dq vhstape_build, vhstape_next_frame
  %elif id == EFFECT_WIPE
    dq wipe_build, wipe_next_frame
  %elif id == EFFECT_RINGS
    dq rings_build, rings_next_frame
  %elif id == EFFECT_MATRIX
    dq matrix_build, matrix_next_frame
  %elif id == EFFECT_THUNDERSTORM
    dq thunderstorm_build, thunderstorm_next_frame
  %elif id == EFFECT_SLICE
    dq slice_build, slice_next_frame
  %elif id == EFFECT_BEAMS
    dq beams_build, beams_next_frame
  %elif id == EFFECT_BINARYPATH
    dq binarypath_build, binarypath_next_frame
  %elif id == EFFECT_CRUMBLE
    dq crumble_build, crumble_next_frame
  %elif id == EFFECT_OVERFLOW
    dq overflow_build, overflow_next_frame
  %elif id == EFFECT_WAVES
    dq waves_build, waves_next_frame
  %elif id == EFFECT_FIREWORKS
    dq fireworks_build, fireworks_next_frame
  %elif id == EFFECT_ERRORCORRECT
    dq errorcorrect_build, errorcorrect_next_frame
  %elif id == EFFECT_UNSTABLE
    dq unstable_build, unstable_next_frame
  %elif id == EFFECT_PRINT
    dq print_build, print_next_frame
  %elif id == EFFECT_BUBBLES
    dq bubbles_build, bubbles_next_frame
  %elif id == EFFECT_ORBITTINGVOLLEY
    dq orbittingvolley_build, orbittingvolley_next_frame
  %else
    dq 0, 0
  %endif
  %assign id id + 1
%endrep
