#!/usr/bin/env python3
# An unpaced tty run resized mid-way: whole frames of the uninterrupted run,
# the resize wipe, then a complete rerun. Usage: resizetest.py effect [delays]
import os, pty, struct, sys, fcntl, termios, time, re
BIN = os.path.abspath(os.environ.get("BIN", "target/release/ttfx"))
EFFECT = sys.argv[1]
DELAYS = [float(x) for x in sys.argv[2:]] or [0.03, 0.1]
# speed.py's input: 46 lines of 190 columns
INPUT = "\n".join([("The quick brown fox jumps over the lazy dog 0123456789 " * 4)[:190]] * 46).encode()
MOVE = b"\x1b8\x1b7"


def run(engine, resize_after=None, cols=220, rows=60):
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.dup2(r_in, 0)
        os.close(w_in)
        env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "LINES")}
        env["TTFX_ASM"] = engine
        os.execve(BIN, [BIN, "--seed", "1", "--frame-rate", "0", EFFECT], env)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.close(r_in)
    os.write(w_in, INPUT)
    os.close(w_in)
    start = time.monotonic()
    out = bytearray()
    done = resize_after is None
    while True:
        if not done and time.monotonic() - start >= resize_after:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows - 20, cols - 40, 0, 0))
            done = True
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    _, status = os.waitpid(pid, 0)
    os.close(master)
    return bytes(out), status


full, _ = run("force")
fails = 0
for d in DELAYS:
    o, s = run("force", d)
    m = re.search(rb"\x1b8\x1b\[\d+A\x1b\[0J", o)
    ok = s == 0 and m is not None and o.endswith(b"\x1b[?25h\r\n")
    frames = None
    if ok:
        b = o[:m.start()]
        frames = b.count(MOVE)
        ok = full.startswith(b) and full[len(b):].startswith(MOVE)
    print("ok  " if ok else "FAIL", d, f"{len(o)}B status {s}, {frames} frames before the resize")
    fails += not ok
sys.exit(1 if fails else 0)
