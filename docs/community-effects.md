# Community effects

Thirteen original effects that people wrote for ttfx or TerminalTextEffects
and that never got merged, rebuilt on the fx engine. They are ttfx-only: there
is no Python reference to check them against, so the parity suites skip them.
Each one lives in `src/community/<name>.rs` (CLI config + fx implementation)
with its tests in `tests/community_*.rs`.

## Why they live in ttfx

The route suggested in #22 was to land original effects in TerminalTextEffects
first and port them from there. TTE no longer takes them: since October 2026
"community effects are now hosted and maintained by their authors rather than
added to the TTE package" (ChrisBuilds/terminaltexteffects#73-76), loaded from
`~/.config/terminaltexteffects/effects`. ttfx has no such loader, so a home in
ttfx is the way they reach the Omarchy screensaver.

## Credits

| Effect | Original author | Original source | License |
|---|---|---|---|
| airstrike, automata, bubblepop, malfunction, reverselife, roses, sunshower, voronoi | Lukas Innig (@derluke) | https://github.com/derluke/ttfx (#22, original engine) | MIT |
| elephantsplash, fireflies, fishing, snake | Tushar Malpani (@tusharmalpani20) | https://github.com/tusharmalpani20/tte-community-effects (Python TTE) | MIT |
| factorio | Chris AtLee (@catlee) | https://github.com/catlee/ttfx `plugins/ttfx-effect-factorio` (Python frame-protocol plugin) | MIT |

These are rewrites, not straight ports: each keeps its original's idea, option
names and look, then reworks the pacing for a fullscreen screensaver and ends
with a closing flourish of its own once the text has landed.

## What every effect guarantees

- Runs on the fx engine only (`TTFX_FX=0` reports that instead of running).
- The last frame is exactly the input text, in the final gradient or, with
  `--existing-color-handling dynamic`, the input's own colours; everything the
  effect added is hidden.
- Deterministic for a given `--seed`; every timing option changes the run
  length.
- No panics or hangs on one character, a 500-character line, 1x1, 10x3 and
  300x90 canvases, wide characters, or ANSI-coloured input.
- 8 to 20 seconds on the Omarchy logo at 120 fps; a whole 300x90 run computes
  in well under a second.
