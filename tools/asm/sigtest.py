#!/usr/bin/env python3
# Unpaced tty runs interrupted by SIGINT/SIGTERM: the output must be whole
# frames of the uninterrupted run, in order, then the teardown; the exit must
# match the Rust engine's. Usage: sigtest.py effect [delays...]
import os, pty, signal, struct, sys, fcntl, termios, time
BIN = os.path.abspath(os.environ.get("BIN", "target/release/ttfx"))
EFFECT = sys.argv[1]
DELAYS = [float(x) for x in sys.argv[2:]] or [0.02, 0.05, 0.1, 0.2]
# speed.py's input: 46 lines of 190 columns
INPUT = "\n".join([("The quick brown fox jumps over the lazy dog 0123456789 " * 4)[:190]] * 46).encode()
MOVE = b"\x1b8\x1b7"


def run(engine, args, send=None, after=0.0, cols=220, rows=60):
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.dup2(r_in, 0)
        os.close(w_in)
        env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "LINES")}
        env["TTFX_ASM"] = engine
        os.execve(BIN, [BIN] + args, env)
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
    return bytes(out), status


args = ["--seed", "1", "--frame-rate", "0", EFFECT]
full, st = run("force", args)
tail = b"\x1b[?25h\r\n"
assert full.endswith(tail), full[-20:]
body = full[:-len(tail)]
total = body.count(MOVE)
fails = 0
for sig in (signal.SIGINT, signal.SIGTERM):
    r = run("0", args, send=sig, after=0.05)
    for d in DELAYS:
        o, s = run("force", args, send=sig, after=d)
        if o == full and s == st:
            # the run finished before the signal arrived: nothing to compare
            print("skip", sig.name, d, f"finished all {total} frames before the signal")
            continue
        b = o[:-len(tail)]
        ok = o.endswith(tail) and s == r[1] and full.startswith(b)
        ok = ok and (len(b) == len(body) or body[len(b):].startswith(MOVE))
        print("ok  " if ok else "FAIL", sig.name, d,
              f"{len(o)}B {b.count(MOVE)} of {total} frames, status {s} (rust {r[1]})")
        fails += not ok
sys.exit(1 if fails else 0)
