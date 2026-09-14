# ttfx

Terminal text effects as a single static binary. Pipe text in, pick an effect:

```sh
ls -la | ttfx decrypt
cat banner.txt | ttfx beams
fortune | ttfx --random-effect
git log --oneline -10 | ttfx matrix
```

<img src="docs/effects/decrypt.gif" width="588" alt="the decrypt effect resolving the Omarchy logo">

## Credit where it's due

**This is a port of [TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects)
(TTE) by [ChrisBuilds](https://github.com/ChrisBuilds).** Every effect, the animation engine,
and the command-line interface are their design — this project translates that work to Rust
and adds nothing of its own to the art. If you like what you see here, star the original.

TTE is MIT licensed and so is this port; the original copyright is preserved in
[LICENSE](LICENSE) and [NOTICE](NOTICE). Please file *effect* ideas upstream, where they belong.

## Why a port

TTE is a Python package. That's the right call for a library, but for a shell toy that lives in
your prompt pipeline it means an interpreter, an install step, and ~65 ms of import before the
first frame. ttfx is one dependency-free binary that starts in half a millisecond.

That difference is the whole reason this exists. On a fullscreen canvas the heavier effects run
out of headroom under Python. Time to render a whole animation, pacing disabled so this measures
throughput rather than `sleep()`:

| At 200×50 cells | frames | ttfx | Python TTE | ttfx fps |
|---|---|---|---|---|
| slide | 375 | 76 ms | 2,203 ms | 4,930 |
| beams | 732 | 181 ms | 5,564 ms | 4,050 |
| rings | 1,566 | 521 ms | 10,439 ms | 3,004 |
| waves | 633 | 374 ms | 8,745 ms | 1,693 |
| startup | — | 0.5 ms | 64 ms | — |

Across the 35 effects that aren't gated on wall-clock time, the median speedup is **27.5×**
(range 17.1×–47.4×). The two that are gated — `matrix` and `thunderstorm` — spend most of their
runtime in a fixed animation duration that no implementation can shorten, so they come in at
1.9× and 1.3×; what ttfx buys there is a far higher frame rate inside that window, not a shorter
one.

Reproduce it with `python3 tools/tests/bench_full.py`, or set `TTFX_BENCH_COLS`, `TTFX_BENCH_LINES`
and `TTFX_BENCH_FILL=1` for the fullscreen numbers above. Both sides run their real user-facing
command, best of five.

## The effects

All 37, each animating the Omarchy logo. Every frame below came out of the Rust binary — and is
byte-identical to what the Python original produces from the same input and seed.

|     |     |
|:---:|:---:|
| <b>beams</b><br><img src="docs/effects/beams.gif" width="400" alt="beams"><br><sub>Create beams which travel over the canvas illuminating the characters behind them</sub> | <b>binarypath</b><br><img src="docs/effects/binarypath.gif" width="400" alt="binarypath"><br><sub>Binary representations of each character move towards the home coordinate of the character</sub> |
| <b>blackhole</b><br><img src="docs/effects/blackhole.gif" width="400" alt="blackhole"><br><sub>Characters are consumed by a black hole and explode outwards</sub> | <b>bouncyballs</b><br><img src="docs/effects/bouncyballs.gif" width="400" alt="bouncyballs"><br><sub>Characters are bouncy balls falling from the top of the canvas</sub> |
| <b>bubbles</b><br><img src="docs/effects/bubbles.gif" width="400" alt="bubbles"><br><sub>Characters are formed into bubbles that float down and pop</sub> | <b>burn</b><br><img src="docs/effects/burn.gif" width="400" alt="burn"><br><sub>Burns vertically in the canvas</sub> |
| <b>colorshift</b><br><img src="docs/effects/colorshift.gif" width="400" alt="colorshift"><br><sub>Display a gradient that shifts colors across the terminal</sub> | <b>crumble</b><br><img src="docs/effects/crumble.gif" width="400" alt="crumble"><br><sub>Characters lose color and crumble into dust, vacuumed up, and reformed</sub> |
| <b>decrypt</b><br><img src="docs/effects/decrypt.gif" width="400" alt="decrypt"><br><sub>Display a movie style decryption effect</sub> | <b>errorcorrect</b><br><img src="docs/effects/errorcorrect.gif" width="400" alt="errorcorrect"><br><sub>Some characters start in the wrong position and are corrected in sequence</sub> |
| <b>expand</b><br><img src="docs/effects/expand.gif" width="400" alt="expand"><br><sub>Expands the text from a single point</sub> | <b>fireworks</b><br><img src="docs/effects/fireworks.gif" width="400" alt="fireworks"><br><sub>Characters launch and explode like fireworks and fall into place</sub> |
| <b>highlight</b><br><img src="docs/effects/highlight.gif" width="400" alt="highlight"><br><sub>Run a specular highlight across the text</sub> | <b>laseretch</b><br><img src="docs/effects/laseretch.gif" width="400" alt="laseretch"><br><sub>A laser etches characters onto the terminal</sub> |
| <b>matrix</b><br><img src="docs/effects/matrix.gif" width="400" alt="matrix"><br><sub>Matrix digital rain effect</sub> | <b>middleout</b><br><img src="docs/effects/middleout.gif" width="400" alt="middleout"><br><sub>Text expands in a single row or column in the middle of the canvas then out</sub> |
| <b>orbittingvolley</b><br><img src="docs/effects/orbittingvolley.gif" width="400" alt="orbittingvolley"><br><sub>Four launchers orbit the canvas firing volleys of characters inward to build the input text from the center out</sub> | <b>overflow</b><br><img src="docs/effects/overflow.gif" width="400" alt="overflow"><br><sub>Input text overflows and scrolls the terminal in a random order until eventually appearing ordered</sub> |
| <b>pour</b><br><img src="docs/effects/pour.gif" width="400" alt="pour"><br><sub>Pours the characters into position from the given direction</sub> | <b>print</b><br><img src="docs/effects/print.gif" width="400" alt="print"><br><sub>Lines are printed one at a time following a print head. Print head performs line feed, carriage return</sub> |
| <b>rain</b><br><img src="docs/effects/rain.gif" width="400" alt="rain"><br><sub>Rain characters from the top of the canvas</sub> | <b>randomsequence</b><br><img src="docs/effects/randomsequence.gif" width="400" alt="randomsequence"><br><sub>Prints the input data in a random sequence</sub> |
| <b>rings</b><br><img src="docs/effects/rings.gif" width="400" alt="rings"><br><sub>Characters are dispersed and form into spinning rings</sub> | <b>scattered</b><br><img src="docs/effects/scattered.gif" width="400" alt="scattered"><br><sub>Text is scattered across the canvas and moves into position</sub> |
| <b>slice</b><br><img src="docs/effects/slice.gif" width="400" alt="slice"><br><sub>Slices the input in half and slides it into place from opposite directions</sub> | <b>slide</b><br><img src="docs/effects/slide.gif" width="400" alt="slide"><br><sub>Slide characters into view from outside the terminal</sub> |
| <b>smoke</b><br><img src="docs/effects/smoke.gif" width="400" alt="smoke"><br><sub>Smoke floods the canvas colorizing any characters it crosses</sub> | <b>spotlights</b><br><img src="docs/effects/spotlights.gif" width="400" alt="spotlights"><br><sub>Spotlights search the text area, illuminating characters, before converging in the center and expanding</sub> |
| <b>spray</b><br><img src="docs/effects/spray.gif" width="400" alt="spray"><br><sub>Draws the characters spawning at varying rates from a single point</sub> | <b>swarm</b><br><img src="docs/effects/swarm.gif" width="400" alt="swarm"><br><sub>Characters are grouped into swarms and move around the terminal before settling into position</sub> |
| <b>sweep</b><br><img src="docs/effects/sweep.gif" width="400" alt="sweep"><br><sub>Sweep across the canvas to reveal uncolored text, reverse sweep to color the text</sub> | <b>synthgrid</b><br><img src="docs/effects/synthgrid.gif" width="400" alt="synthgrid"><br><sub>Create a grid which fills with characters dissolving into the final text</sub> |
| <b>thunderstorm</b><br><img src="docs/effects/thunderstorm.gif" width="400" alt="thunderstorm"><br><sub>Create a thunderstorm in the terminal</sub> | <b>unstable</b><br><img src="docs/effects/unstable.gif" width="400" alt="unstable"><br><sub>Spawn characters jumbled, explode them to the edge of the canvas, then reassemble them in the correct layout</sub> |
| <b>vhstape</b><br><img src="docs/effects/vhstape.gif" width="400" alt="vhstape"><br><sub>Lines of characters glitch left and right and lose detail like an old VHS tape</sub> | <b>waves</b><br><img src="docs/effects/waves.gif" width="400" alt="waves"><br><sub>Waves travel across the terminal leaving behind the characters</sub> |
| <b>wipe</b><br><img src="docs/effects/wipe.gif" width="400" alt="wipe"><br><sub>Wipes the text across the terminal to reveal characters</sub> |  |

Every effect takes its own options — `ttfx <effect> --help`. A few of the GIFs above shorten a
timed phase so the loop stays watchable (`matrix --rain-time 3`, `thunderstorm --storm-time 3`,
`vhstape --total-glitch-time 250`, `spotlights --search-duration 80`, `errorcorrect
--error-pairs 0.5`); everything else is stock.

## Fidelity

This is a *parity port*, not a reimplementation-in-spirit. Given the same input, config, and
random draws, ttfx produces **byte-identical frames** to the Python original — verified
mechanically in CI against a pinned upstream checkout (v0.15.0), not by eyeballing.

| Suite | Checks | What it proves |
|---|---|---|
| `tools/parity/run_suite.sh` | 354 | every effect's frame stream, byte for byte, across configs and seeds |
| `tools/parity/tty_compare.sh` | 41 | the full terminal byte stream — canvas prep, cursor moves, teardown |
| `tools/tests/cli_corpus.sh` | 19 | exit codes and stdout/stderr routing |
| `tools/tests/*_behavior.py` | pty | what only a real terminal shows: resize restarts, signal teardown |
| `cargo test` | goldens + traces | easing/geometry/gradient values and engine state machines |

`./bin/test` runs the lot, which is all CI does.

Making that possible meant reproducing upstream's quirks deliberately, not "fixing" them:
Python's banker's rounding, gradients built from integer floor division rather than float
interpolation, a bezier arc-length approximation that drops its final segment, and looping
scenes that report themselves complete on every tick. They're catalogued in
[`plan.md`](plan.md); the places where Python's unordered iteration had to be pinned down are
in [`docs/ordering-inventory.md`](docs/ordering-inventory.md).

**Two deliberate differences.** Random number generation is not bit-compatible with CPython —
ttfx uses xoshiro256++, so `--seed` is reproducible within ttfx but won't match Python's
Mersenne Twister. (The parity harness swaps a shared PRNG into both sides, which is what makes
frame comparison possible at all.) And Python plugin effects aren't supported, since there's
no interpreter to load them.

## Usage

```
<producer> | ttfx [terminal options] <effect> [effect options]

ttfx --help                 # all 37 effects and the terminal options
ttfx <effect> --help        # options for one effect
ttfx --random-effect        # surprise me (--include-effects / --exclude-effects to filter)
ttfx --print-completion bash|zsh
ttfx --palette 7aa2f7,c0caf5,f7768e decrypt
ttfx --palette aa0000,00aa00,0000aa,aaaa00,00aaaa --bands decrypt
```

`--palette` takes hex colors (`#7aa2f7` or `7aa2f7`). Repeat the flag or separate
colors with commas. Those colors replace each effect's default color arguments;
color flags you pass on the effect still apply.

`--bands` colors the input word in five vertical field bands: 4, 3, 4, 3, 5
units from the top (crest, hover, lit, mid, dim). The field is 19 units tall,
one per wordmark bitmap row. Requires `--palette` with five colors in that
order. The wasm `Session` constructor takes the same palette, background, and
`bands` arguments.

Terminal options (canvas size and anchoring, color handling, frame rate, text wrapping) go
before the effect name; effect options after it. Option names and defaults match `tte`, so
existing invocations work with the binary name swapped.

## Building

```sh
cargo build --release
cargo build --release --target x86_64-unknown-linux-musl   # static, ~3.3 MB
```

The default build compiles all 37 effects. To ship one, pass its CLI name as a Cargo feature:

```sh
./bin/build --effect decrypt
cargo build --release --no-default-features --features decrypt
cargo build --release --target wasm32-unknown-unknown --lib --no-default-features --features decrypt
```

`--help`, shell completions, `--random-effect`, and the wasm `effect_catalog()` then list only the effects compiled in. Several can be selected the same way (`--features decrypt,matrix`).

`./bin/test` runs every suite. It needs python3, and the parity half needs a copy of
upstream, which it clones at the pinned commit on first run:

```sh
./tools/parity/fetch_reference.sh   # what bin/test calls; safe to run by hand
```

Upstream is not vendored here — the harness fetches it, because it's their code.

## Scope

Linux and macOS. Built for [Omarchy](https://omarchy.org) originally; nothing targets a
specific libc, and CI runs the tests and CLI corpus on both platforms. The byte-exact
parity suites stay pinned to Linux/glibc — Apple's libm rounds a few transcendentals a
last-ulp differently, which quantization hides in real frames but a bit-exact comparison
would surface.

## License

MIT — see [LICENSE](LICENSE), which carries both this project's copyright and the original
TerminalTextEffects copyright, and [NOTICE](NOTICE) for the attribution in full.
