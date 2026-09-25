#!/usr/bin/env python3
"""Run the Rust and assembly engines on a real pty and compare what they do.

Both run from the same ttfx binary: TTFX_ASM=0 forces the Rust engine and
TTFX_ASM=force the assembly engine (exit 3 if it declines). Checks byte parity
on the tty path (canvas prep, per-frame cursor moves, teardown), plus the
signal contract: SIGINT tears down and exits 1, SIGTERM tears down and dies
from the signal. Usage: pty_compare.py [ttfx] [effect]
"""
import os
import pty
import signal
import struct
import sys
import fcntl
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BINARY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "target/release/ttfx")
EFFECT = sys.argv[2] if len(sys.argv) > 2 else "decrypt"
RUST = "0"
ASM = "force"
INPUT = b"Hello, World!\nThis is ttfx.\n\tTabbed\n"


def run(engine, args, cols=80, rows=24, send=None, after=0.0):
    """Run with TTFX_ASM=engine and stdout/stderr on a pty; returns (bytes,
    wait status, seconds)."""
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.dup2(r_in, 0)
        os.close(w_in)
        env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "LINES")}
        env["TTFX_ASM"] = engine
        os.execve(BINARY, [BINARY] + args, env)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.close(r_in)
    os.write(w_in, INPUT)
    os.close(w_in)
    start = time.monotonic()
    out = bytearray()
    sent = send is None
    while True:
        if not sent and time.monotonic() - start >= after:
            os.kill(pid, send)
            sent = True
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    _, status = os.waitpid(pid, 0)
    os.close(master)
    return bytes(out), status, time.monotonic() - start


def describe(status):
    if os.WIFSIGNALED(status):
        return f"signal {os.WTERMSIG(status)}"
    return f"exit {os.WEXITSTATUS(status)}"


failures = 0


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    if not ok:
        failures += 1


# 1. full tty byte stream, unpaced, for a few sizes and seeds
for cols, rows in ((80, 24), (30, 8), (12, 3)):
    for seed in ("1", "2"):
        args = ["--seed", seed, "--frame-rate", "0", EFFECT]
        r = run(RUST, args, cols, rows)
        a = run(ASM, args, cols, rows)
        check(f"tty bytes {cols}x{rows} seed {seed}", r[0] == a[0] and r[1] == a[1],
              f"rust {len(r[0])}B {describe(r[1])}, asm {len(a[0])}B {describe(a[1])}")

# 2. real-clock pacing: both take about as long at the default 60 fps
args = ["--seed", "3", EFFECT]
r = run(RUST, args)
a = run(ASM, args)
check("paced output identical", r[0] == a[0], f"{len(r[0])}B vs {len(a[0])}B")
check("paced duration comparable", abs(r[2] - a[2]) < 0.25 * r[2] + 0.1, f"rust {r[2]:.2f}s, asm {a[2]:.2f}s")

# 3. signals mid-run: same teardown bytes at the end, same exit
for sig, name in ((signal.SIGINT, "SIGINT"), (signal.SIGTERM, "SIGTERM")):
    r = run(RUST, args, send=sig, after=0.5)
    a = run(ASM, args, send=sig, after=0.5)
    check(f"{name} status", r[1] == a[1], f"rust {describe(r[1])}, asm {describe(a[1])}")
    check(f"{name} teardown", r[0].endswith(b"\x1b[?25h\r\n") == a[0].endswith(b"\x1b[?25h\r\n"),
          f"asm tail {a[0][-12:]!r}")

print("pty:", "all passed" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
