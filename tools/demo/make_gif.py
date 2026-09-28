"""Render an effect's frame dump to an animated GIF.

Parses ttfx --parity-dump output (length-prefixed frames), converts each
frame's ANSI grid into an SVG, and pipes the sequence through ImageMagick.
No Python dependencies beyond the stdlib.

Usage: make_gif.py OUT.gif EFFECT [effect args...]
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "target/release/ttfx"

import os

# Overridable so the same renderer handles a short word or the full ASCII logo.
TEXT_FILE = os.environ.get("TTFX_DEMO_TEXT_FILE")
TEXT = Path(TEXT_FILE).read_text().rstrip("\n") if TEXT_FILE else "Omarchy"
COLS = int(os.environ.get("TTFX_DEMO_COLS", 44))
ROWS = int(os.environ.get("TTFX_DEMO_ROWS", 13))
CELL_W = float(os.environ.get("TTFX_DEMO_CELL_W", 11))
CELL_H = float(os.environ.get("TTFX_DEMO_CELL_H", 20))
FONT_SIZE = float(os.environ.get("TTFX_DEMO_FONT_SIZE", 16))
MAX_FRAMES = int(os.environ.get("TTFX_DEMO_MAX_FRAMES", 70))
BG = "#12121a"

SGR = re.compile(r"\x1b\[([0-9;]*)m")


def parse_frame(frame: str) -> list[list[tuple[str, str, str | None, bool]]]:
    """-> rows of (char, fg, bg, bold)."""
    rows = []
    for line in frame.split("\n"):
        cells = []
        fg, bg, bold = "#c8c8d0", None, False
        i = 0
        while i < len(line):
            m = SGR.match(line, i)
            if m:
                params = [p for p in m.group(1).split(";") if p != ""] or ["0"]
                j = 0
                while j < len(params):
                    p = int(params[j])
                    if p == 0:
                        fg, bg, bold = "#c8c8d0", None, False
                    elif p == 1:
                        bold = True
                    elif p in (38, 48) and j + 1 < len(params):
                        mode = int(params[j + 1])
                        if mode == 2 and j + 4 < len(params):
                            c = "#%02x%02x%02x" % tuple(int(params[j + k]) for k in (2, 3, 4))
                            j += 4
                        elif mode == 5 and j + 2 < len(params):
                            c = xterm_hex(int(params[j + 2]))
                            j += 2
                        else:
                            j += 1
                            continue
                        if p == 38:
                            fg = c
                        else:
                            bg = c
                    j += 1
                i = m.end()
                continue
            cells.append((line[i], fg, bg, bold))
            i += 1
        rows.append(cells)
    return rows


_XTERM = None


def xterm_hex(n: int) -> str:
    global _XTERM
    if _XTERM is None:
        table = ROOT / "src/utils/hexterm_table.rs"
        _XTERM = re.findall(r'"([0-9a-f]{6})"', table.read_text())
    return "#" + _XTERM[n] if n < len(_XTERM) else "#000000"


# Block-drawing glyphs are drawn as rects, not text: font glyphs don't tile
# seamlessly at arbitrary cell sizes, which would put seams through solid areas
# of the logo. Values are (y_fraction, height_fraction, opacity) within the cell.
BLOCKS = {
    "█": (0.0, 1.0, 1.0),    # █ full
    "▄": (0.5, 0.5, 1.0),    # ▄ lower half
    "▀": (0.0, 0.5, 1.0),    # ▀ upper half
    "▓": (0.0, 1.0, 0.75),   # ▓ dark shade
    "▒": (0.0, 1.0, 0.5),    # ▒ medium shade
    "░": (0.0, 1.0, 0.25),   # ░ light shade
}
# half-width blocks need an x offset too: (x_frac, w_frac)
HALF_BLOCKS = {"▌": (0.0, 0.5), "▐": (0.5, 0.5)}  # ▌ ▐

# Box-drawing font glyphs do not reliably meet at small demo cell sizes. Draw
# their strokes to the exact cell edges so terminal-perfect diagrams remain
# mechanically aligned in the GIF. Values are directions from cell center.
BOX_SEGMENTS = {
    "─": "lr", "—": "lr", "│": "ud",
    "╭": "rd", "╮": "ld", "╰": "ru", "╯": "lu",
    "├": "urd", "┤": "uld", "┬": "lrd", "┴": "lru", "┼": "lrud",
}


def svg_for(frame: str) -> str:
    rows = parse_frame(frame)
    w, h = COLS * CELL_W, ROWS * CELL_H
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h:g}">',
        f'<rect width="{w:g}" height="{h:g}" fill="{BG}"/>',
    ]
    # backgrounds first
    for r, cells in enumerate(rows[:ROWS]):
        for c, (_, _, bg, _) in enumerate(cells[:COLS]):
            if bg:
                out.append(
                    f'<rect x="{c*CELL_W:g}" y="{r*CELL_H:g}" width="{CELL_W:g}" height="{CELL_H:g}" fill="{bg}"/>'
                )
    # block glyphs as rects, so solid areas tile without seams
    for r, cells in enumerate(rows[:ROWS]):
        for c, (ch, fg, _, _) in enumerate(cells[:COLS]):
            if ch in BLOCKS:
                yf, hf, op = BLOCKS[ch]
                alpha = f' opacity="{op}"' if op < 1.0 else ""
                out.append(
                    f'<rect x="{c*CELL_W:g}" y="{r*CELL_H + yf*CELL_H:g}" '
                    f'width="{CELL_W:g}" height="{hf*CELL_H:g}" fill="{fg}"{alpha}/>'
                )
            elif ch in HALF_BLOCKS:
                xf, wf = HALF_BLOCKS[ch]
                out.append(
                    f'<rect x="{c*CELL_W + xf*CELL_W:g}" y="{r*CELL_H:g}" '
                    f'width="{wf*CELL_W:g}" height="{CELL_H:g}" fill="{fg}"/>'
                )
            elif ch == "═":
                x0, x1 = c * CELL_W, (c + 1) * CELL_W
                cy = (r + 0.5) * CELL_H
                out.append(
                    f'<path d="M{x0:g},{cy-1.35:g}H{x1:g} M{x0:g},{cy+1.35:g}H{x1:g}" '
                    f'fill="none" stroke="{fg}" stroke-width="1" shape-rendering="crispEdges"/>'
                )
            elif ch in BOX_SEGMENTS:
                x0, x1 = c * CELL_W, (c + 1) * CELL_W
                y0, y1 = r * CELL_H, (r + 1) * CELL_H
                cx, cy = (c + 0.5) * CELL_W, (r + 0.5) * CELL_H
                directions = BOX_SEGMENTS[ch]
                strokes = []
                if "l" in directions:
                    strokes.append(f"M{cx:g},{cy:g}H{x0:g}")
                if "r" in directions:
                    strokes.append(f"M{cx:g},{cy:g}H{x1:g}")
                if "u" in directions:
                    strokes.append(f"M{cx:g},{cy:g}V{y0:g}")
                if "d" in directions:
                    strokes.append(f"M{cx:g},{cy:g}V{y1:g}")
                path_data = " ".join(strokes)
                out.append(
                    f'<path d="{path_data}" fill="none" stroke="{fg}" stroke-width="1.15" '
                    f'stroke-linecap="square" shape-rendering="crispEdges"/>'
                )
    # then glyphs, grouped into runs of identical style. textLength pins each
    # run to an exact multiple of the cell width so long rows can't drift out
    # of their columns when font metrics don't match the cell size.
    for r, cells in enumerate(rows[:ROWS]):
        y = r * CELL_H + FONT_SIZE * 0.8
        run, run_fg, run_bold, run_start = [], None, False, 0

        def flush():
            if run and "".join(run).strip():
                text = "".join(run).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                weight = ' font-weight="bold"' if run_bold else ""
                out.append(
                    f'<text x="{run_start*CELL_W:g}" y="{y:g}" fill="{run_fg}"{weight} '
                    f'font-family="DejaVu Sans Mono,monospace" font-size="{FONT_SIZE:g}" '
                    f'textLength="{len(run)*CELL_W:g}" lengthAdjust="spacingAndGlyphs" '
                    f'xml:space="preserve">{text}</text>'
                )

        for c, (ch, fg, _, bold) in enumerate(cells[:COLS]):
            is_graphic = ch in BLOCKS or ch in HALF_BLOCKS or ch in BOX_SEGMENTS or ch == "═"
            if is_graphic or fg != run_fg or bold != run_bold:
                flush()
                run, run_fg, run_bold, run_start = [], fg, bold, c
            # native graphics were already drawn; keep them out of the text run
            if not is_graphic:
                run.append(ch)
            else:
                run_start = c + 1
        flush()
    out.append("</svg>")
    return "".join(out)


def read_frames(effect_args: list[str]) -> list[str]:
    cmd = [
        str(BIN), "--seed", "3", "--frame-rate", "0", "--virtual-clock", "--parity-dump",
        "--canvas-width", str(COLS), "--canvas-height", str(ROWS),
        "--anchor-canvas", "c", "--anchor-text", "c", "--ignore-terminal-dimensions",
        *effect_args,
    ]
    proc = subprocess.run(cmd, input=TEXT.encode(), capture_output=True)
    data, frames, i = proc.stdout, [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        n = int(data[i:nl])
        i = nl + 1
        frames.append(data[i : i + n].decode())
        i += n + 1
    return frames


def main() -> int:
    out_path, effect_args = sys.argv[1], sys.argv[2:]
    frames = read_frames(effect_args)
    if not frames:
        print(f"no frames for {effect_args}", file=sys.stderr)
        return 1
    # sample evenly, always keeping the final frame, and hold the last one
    if len(frames) > MAX_FRAMES:
        step = len(frames) / MAX_FRAMES
        picked = [frames[min(int(i * step), len(frames) - 1)] for i in range(MAX_FRAMES)]
        picked[-1] = frames[-1]
    else:
        picked = frames
    picked += [frames[-1]] * 8  # hold the finished text

    # per-output temp dir so parallel invocations don't clobber each other
    tmp = Path(out_path).parent / f"_svg_{Path(out_path).stem}"
    tmp.mkdir(parents=True, exist_ok=True)
    paths = []
    for idx, frame in enumerate(picked):
        p = tmp / f"f{idx:04d}.svg"
        p.write_text(svg_for(frame))
        paths.append(str(p))

    subprocess.run(
        ["magick", "-delay", "6", "-loop", "0", *paths, "-layers", "optimize", out_path],
        check=True,
    )
    for p in paths:
        Path(p).unlink()
    print(f"{out_path}: {len(picked)} frames, {Path(out_path).stat().st_size//1024}KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
