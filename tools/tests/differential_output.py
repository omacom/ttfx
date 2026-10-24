"""Compare every visible frame in full and differential output. Requires pyte.

Usage: python3 tools/tests/differential_output.py [path-to-ttfx]
"""
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import pyte
from pathlib import Path
root = Path(__file__).resolve().parents[2]
binary = sys.argv[1] if len(sys.argv) > 1 else str(root / 'target/release/ttfx')
artifacts = Path(tempfile.mkdtemp(prefix='ttfx-differential-test-'))
pattern = re.compile(b'\x1b8\x1b7\x1b\\[[0-9]+A')

def run(args, engine='force', rows=8, cols=32, text='Hello, World!\nOmarchy M3', binary=binary):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    env = {k: v for k, v in os.environ.items() if k not in ('COLUMNS', 'LINES')}
    env['TTFX_FX'] = engine
    p = subprocess.Popen([binary, *args], stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE, env=env)
    os.close(slave)
    p.stdin.write(text.encode())
    p.stdin.close()
    out = bytearray()
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out.extend(chunk)
        if len(out) > 60 * 1024 * 1024:
            raise RuntimeError('excessive output')
    else:
        p.kill()
        raise RuntimeError('timeout ' + repr(args))
    os.close(master)
    code = p.wait()
    err = p.stderr.read()
    if code:
        raise RuntimeError((args, code, err))
    return bytes(out)

def snapshots(data, cols, rows):
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)
    offsets = sorted(set([m.start() for m in pattern.finditer(data)] + ([data.rfind(bytes([27]) + b'[?25h')] if bytes([27]) + b'[?25h' in data else []) + [len(data)]))
    states = []

    def state():
        return tuple((tuple((screen.buffer[y][x] for x in range(cols))) for y in range(rows)))
    begin = 0
    for end in offsets:
        stream.feed(data[begin:end].decode())
        s = state()
        if not states or s != states[-1]:
            states.append(s)
        begin = end
    return (states, (screen.cursor.x, screen.cursor.y, screen.cursor.hidden))
help = subprocess.check_output([binary, '--help'], text=True)
effects = re.findall('^  ([a-z][a-z0-9-]+)\\s{2,}', help, re.M)
effects = [e for e in effects if e != 'help']
results = []
for engine in ['force', '0']:
    for effect in effects:
        args = ['--frame-rate', '0', '--virtual-clock', '--seed', '42', '--canvas-width', '0', '--canvas-height', '0', effect]
        a = run(args, engine)
        b = run(['--differential-output', *args], engine)
        sa, ca = snapshots(a, 32, 8)
        sb, cb = snapshots(b, 32, 8)
        ok = sa == sb and ca == cb
        row = {'engine': engine, 'effect': effect, 'passed': ok, 'baseline_bytes': len(a), 'patched_bytes': len(b), 'baseline_states': len(sa), 'patched_states': len(sb), 'cursor': [ca, cb]}
        results.append(row)
        print(json.dumps(row), flush=True)
        if not ok:
            (artifacts / 'failed-full.tty').write_bytes(a)
            (artifacts / 'failed-diff.tty').write_bytes(b)
            (artifacts / 'results.json').write_text(json.dumps(results, indent=2))
            sys.exit(1)
for engine in ['force', '0']:
    for cols, rows, text, extra in [(1, 1, 'X', []), (12, 3, '123456789012\nLast row', []), (32, 8, '界\né\n█', []), (32, 8, '\x1b[31mRed\x1b[0m\nGreen', ['--existing-color-handling', 'always']), (32, 8, 'Hello', ['--canvas-width', '18', '--canvas-height', '4', '--anchor-canvas', 'c', '--anchor-text', 'c']), (32, 8, 'Hello', ['--no-eol', '--no-restore-cursor']), (32, 8, 'Reuse', ['--reuse-canvas'])]:
        args = ['--frame-rate', '0', '--virtual-clock', '--seed', '7', *extra, 'decrypt']
        a = run(args, engine, rows, cols, text)
        b = run(['--differential-output', *args], engine, rows, cols, text)
        sa, ca = snapshots(a, cols, rows)
        sb, cb = snapshots(b, cols, rows)
        row = {'engine': engine, 'edge': [cols, rows, text, extra], 'passed': sa == sb and ca == cb, 'cursor': [ca, cb]}
        results.append(row)
        print(json.dumps(row), flush=True)
        if not row['passed']:
            sys.exit(1)
(artifacts / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
for engine in ['force', '0']:
    env = {**os.environ, 'TTFX_FX': engine, 'COLUMNS': '32', 'LINES': '8'}
    for extra in [[], ['--parity-dump', '--max-frames', '10']]:
        args = ['--frame-rate', '0', '--virtual-clock', '--seed', '42', *extra, 'decrypt']
        full = subprocess.check_output([binary, *args], input=b'Hello', env=env)
        diff = subprocess.check_output([binary, '--differential-output', *args], input=b'Hello', env=env)
        assert full == diff, 'redirected output changed'
print('PASS', len(results), 'terminal comparisons and four redirected stream comparisons')
print('Results:', artifacts / 'results.json')
