#!/usr/bin/env python3
# The reader goes away mid-run: a pipe (SIGPIPE) and a pty (EIO). Status and
# the bytes read before must match the Rust engine's. Usage: closetest.py effect
import os, pty, struct, sys, fcntl, termios, signal, subprocess
BIN = os.path.abspath(os.environ.get("BIN", "target/release/ttfx"))
EFFECT = sys.argv[1]
# speed.py's input: 46 lines of 190 columns
INPUT = "\n".join([("The quick brown fox jumps over the lazy dog 0123456789 " * 4)[:190]] * 46).encode()
ARGS = [BIN, "--seed", "1", "--frame-rate", "0", "--canvas-width", "200", "--canvas-height", "50",
        "--ignore-terminal-dimensions", EFFECT]


def pipe_run(engine, keep):
    env = dict(os.environ, TTFX_ASM=engine)
    p = subprocess.Popen(ARGS, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    p.stdin.write(INPUT)
    p.stdin.close()
    got = p.stdout.read(keep)
    p.stdout.close()
    err = p.stderr.read()
    return got, p.wait(), err


def pty_run(engine, keep):
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.dup2(r_in, 0)
        os.close(w_in)
        env = dict(os.environ, TTFX_ASM=engine)
        os.execve(BIN, ARGS, env)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 220, 0, 0))
    os.close(r_in)
    os.write(w_in, INPUT)
    os.close(w_in)
    got = bytearray()
    while len(got) < keep:
        got += os.read(master, keep - len(got))
    os.close(master)
    _, status = os.waitpid(pid, 0)
    return bytes(got), status


fails = 0
for keep in (100, 100000, 3000000):
    r = pipe_run("0", keep)
    a = pipe_run("force", keep)
    ok = r == a
    print("ok  " if ok else "FAIL", "pipe", keep, r[1], a[1], r[2][:60], a[2][:60])
    fails += not ok
    r = pty_run("0", keep)
    a = pty_run("force", keep)
    ok = r[0] == a[0] and r[1] == a[1]
    print("ok  " if ok else "FAIL", "pty", keep, r[1], a[1])
    fails += not ok
sys.exit(1 if fails else 0)
