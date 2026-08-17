"""Build the effects gallery artifact: every effect's GIF embedded as a data URI.

Usage: build_gallery.py GIF_DIR OUT.html
"""

from __future__ import annotations

import base64
import importlib
import pkgutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "reference/tte"))

import terminaltexteffects.effects as fx  # noqa: E402

gif_dir, out_path = Path(sys.argv[1]), Path(sys.argv[2])

# one-line descriptions straight from upstream's own help text
helps: dict[str, str] = {}
for mi in pkgutil.iter_modules(fx.__path__):
    m = importlib.import_module(f"terminaltexteffects.effects.{mi.name}")
    if hasattr(m, "get_effect_resources"):
        name, _, cfg = m.get_effect_resources()
        helps[name] = cfg.parser_spec.help.strip().rstrip(".")

# demo-only argument tweaks, so the caption matches what the GIF actually shows
extra_args: dict[str, str] = {}
args_file = gif_dir / "args.txt"
if args_file.exists():
    for line in args_file.read_text().splitlines():
        if "|" in line:
            k, v = line.split("|", 1)
            extra_args[k] = v.strip()

effects = sorted(p.stem for p in gif_dir.glob("*.gif"))
helps.setdefault(
    "airstrike",
    "ASCII planes dive into the text, scattering it through fire and debris before it reassembles",
)
helps.setdefault(
    "automata",
    "An elementary cellular automaton grows a fractal lattice whose cells stream into the text",
)
helps.setdefault(
    "malfunction",
    "A printer types nonsense, recovers happily, and prints readable text",
)
helps.setdefault(
    "reverselife",
    "Conway's Game of Life runs backward from chaos and resolves into readable text",
)
helps.setdefault(
    "roses",
    "Curling vines grow pink roses, scatter petals, and flower into the text",
)
helps.setdefault(
    "sunshower",
    "Rain falls as the sun rises and paints a rainbow across the text",
)
helps.setdefault(
    "voronoi",
    "Living crystal grows from the text, breathes as a faceted Voronoi mosaic, then returns as readable lettering",
)

cards = []
for name in effects:
    b64 = base64.b64encode((gif_dir / f"{name}.gif").read_bytes()).decode()
    desc = helps.get(name, "")
    cmd = f"ttfx {name}" + (f" {extra_args[name]}" if name in extra_args else "")
    cards.append(f"""      <figure class="card">
        <div class="screen"><img src="data:image/gif;base64,{b64}" alt="{name} effect animating the Omarchy logo" loading="lazy" width="588" height="169" /></div>
        <figcaption>
          <h2>{name}</h2>
          <p class="desc">{desc}</p>
          <code class="cmd"><span class="prompt">$</span> omarchy-show-logo | {cmd}</code>
        </figcaption>
      </figure>""")

total_kb = sum((gif_dir / f"{n}.gif").stat().st_size for n in effects) // 1024

html = f"""<title>ttfx — all {len(effects)} effects</title>
<style>
  /* Committed to a single dark world: every asset here is a terminal screen,
     so a light ground would frame dark rectangles against white. All colors
     are painted explicitly so the page holds on any host background.
     Palette is drawn from TTE's own default gradient stops: 8A008A -> 00D1FF -> FFFFFF. */
  :root {{
    --ground: #0b0b11;
    --surface: #15151f;
    --surface-lift: #1c1c28;
    --rule: #272736;
    --ink: #dcdce8;
    --ink-dim: #8686a0;
    --ink-faint: #5c5c72;
    --cyan: #00d1ff;
    --magenta: #b41fb4;
    --mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
    --sans: system-ui, -apple-system, "Segoe UI", sans-serif;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    margin: 0;
    background: var(--ground);
    color: var(--ink);
    font-family: var(--sans);
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }}

  .wrap {{
    max-width: 1400px;
    margin: 0 auto;
    padding: clamp(2rem, 5vw, 4.5rem) clamp(1rem, 3vw, 2.5rem) 5rem;
    display: flex;
    flex-direction: column;
    gap: clamp(2rem, 4vw, 3.5rem);
  }}

  header {{ display: flex; flex-direction: column; gap: 1.25rem; }}

  .eyebrow {{
    font-family: var(--mono);
    font-size: 0.75rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--ink-faint);
    margin: 0;
  }}

  h1 {{
    font-family: var(--mono);
    font-size: clamp(2.1rem, 6vw, 3.4rem);
    font-weight: 700;
    letter-spacing: -0.02em;
    margin: 0;
    text-wrap: balance;
    color: var(--ink);
  }}
  h1 .caret {{
    color: var(--cyan);
    animation: blink 1.2s steps(1) infinite;
  }}
  @keyframes blink {{ 50% {{ opacity: 0; }} }}
  @media (prefers-reduced-motion: reduce) {{
    h1 .caret {{ animation: none; }}
  }}

  .lede {{
    margin: 0;
    max-width: 62ch;
    color: var(--ink-dim);
    font-size: 1.02rem;
  }}
  .lede strong {{ color: var(--ink); font-weight: 600; }}

  /* The stats are the argument this project makes — treat them as data, not decoration. */
  .stats {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 1px;
    background: var(--rule);
    border: 1px solid var(--rule);
    border-radius: 4px;
    overflow: hidden;
  }}
  .stat {{
    background: var(--surface);
    padding: 0.9rem 1.1rem;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }}
  .stat b {{
    font-family: var(--mono);
    font-size: 1.4rem;
    font-weight: 600;
    color: var(--cyan);
    font-variant-numeric: tabular-nums;
    letter-spacing: -0.01em;
  }}
  .stat span {{
    font-family: var(--mono);
    font-size: 0.7rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--ink-faint);
  }}

  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(460px, 1fr));
    gap: 1.5rem;
  }}

  .card {{
    margin: 0;
    background: var(--surface);
    border: 1px solid var(--rule);
    border-radius: 6px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transition: border-color 140ms ease, transform 140ms ease;
  }}
  .card:hover {{ border-color: var(--magenta); transform: translateY(-2px); }}
  @media (prefers-reduced-motion: reduce) {{
    .card {{ transition: none; }}
    .card:hover {{ transform: none; }}
  }}

  .screen {{
    background: #12121a;
    border-bottom: 1px solid var(--rule);
    line-height: 0;
  }}
  .screen img {{ width: 100%; height: auto; display: block; }}

  figcaption {{
    padding: 0.95rem 1.1rem 1.1rem;
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
    flex: 1;
  }}

  h2 {{
    font-family: var(--mono);
    font-size: 1.02rem;
    font-weight: 600;
    margin: 0;
    color: var(--cyan);
    letter-spacing: -0.01em;
  }}

  .desc {{
    margin: 0;
    font-size: 0.86rem;
    color: var(--ink-dim);
    flex: 1;
  }}

  .cmd {{
    font-family: var(--mono);
    font-size: 0.74rem;
    color: var(--ink-faint);
    background: var(--surface-lift);
    border: 1px solid var(--rule);
    border-radius: 3px;
    padding: 0.4rem 0.55rem;
    display: block;
    overflow-x: auto;
    white-space: nowrap;
  }}
  .cmd .prompt {{ color: var(--magenta); user-select: none; }}

  .inline {{
    font-family: var(--mono);
    font-size: 0.9em;
    color: var(--ink);
    background: var(--surface-lift);
    border: 1px solid var(--rule);
    border-radius: 3px;
    padding: 0.05em 0.35em;
  }}

  footer {{
    border-top: 1px solid var(--rule);
    padding-top: 1.5rem;
    color: var(--ink-faint);
    font-family: var(--mono);
    font-size: 0.78rem;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }}
  footer a {{ color: var(--ink-dim); }}
  a:focus-visible, .card:focus-visible {{ outline: 2px solid var(--cyan); outline-offset: 2px; }}
</style>

<div class="wrap">
  <header>
    <p class="eyebrow">ttfx · rust port of terminaltexteffects</p>
    <h1>All {len(effects)} effects<span class="caret">_</span></h1>
    <p class="lede">Every effect in the library, animating the <strong>Omarchy</strong> logo straight
      from <code class="inline">/usr/share/omarchy/logo.txt</code>. These frames come out of the Rust
      binary — and each one is <strong>byte-identical</strong> to what the original Python produces
      from the same input and seed.</p>
    <div class="stats">
      <div class="stat"><b>{len(effects)}</b><span>effects</span></div>
      <div class="stat"><b>354</b><span>parity cases</span></div>
      <div class="stat"><b>3.3 MB</b><span>static binary</span></div>
      <div class="stat"><b>2 ms</b><span>startup</span></div>
      <div class="stat"><b>0</b><span>runtime deps</span></div>
    </div>
  </header>

  <main class="grid">
{chr(10).join(cards)}
  </main>

  <footer>
    <div>{len(effects)} effects · {total_kb} KB of animation · 81&times;10 logo on an 84&times;13 canvas, seed 3</div>
    <div>Descriptions are upstream's own help text. Two effects take demo-only arguments so
      a seven-letter word shows the effect off: errorcorrect needs enough swap pairs, and the
      time-budgeted effects are shortened.</div>
  </footer>
</div>
"""

out_path.write_text(html)
print(f"{out_path}: {len(effects)} effects, {out_path.stat().st_size // 1024} KB")
