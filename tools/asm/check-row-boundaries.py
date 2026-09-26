#!/usr/bin/env python3
"""Compare short frames around SIMD/chunk boundaries with the Rust engine."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('binary', type=Path)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--cpus', type=int, nargs='+', default=sorted(os.sched_getaffinity(0))[:2])
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
binary = a.binary.resolve()
wrapper = root / 'target/hash-output'
os.sched_setaffinity(0, a.cpus)
data = ('\x1b[31mab界\x1b[0m .   z\n\n row  three  \n' * 3).encode()
result = {'cpus': a.cpus, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'input_sha256': hashlib.sha256(data).hexdigest(), 'results': []}
for tier in (1, 2, 3, 4):
    for threads in ('1', 'auto'):
        for width in (1, 3, 4, 5, 63, 64, 65, 127, 128, 129, 255, 256, 257):
            for effect in ('print', 'waves', 'bouncyballs', 'colorshift', 'matrix'):
                args = ['--seed', '17', '--frame-rate', '0', '--max-frames', '25',
                        '--canvas-width', str(width), '--canvas-height', '7',
                        '--ignore-terminal-dimensions', '--virtual-clock', effect]
                env = {**os.environ, 'TTFX_ORACLE_REAL_BIN': str(binary),
                       'TTFX_ASM_TIER': str(tier), 'TTFX_ASM_THREADS': threads}
                values = []
                for mode in ('0', 'force'):
                    r = subprocess.run([str(wrapper), *args], input=data, capture_output=True,
                                       env={**env, 'TTFX_ASM': mode}, timeout=30)
                    values.append({'exit': r.returncode, 'stdout': r.stdout.decode(),
                                   'stderr': r.stderr.decode()})
                equal = values[0] == values[1] and values[0]['exit'] == 0
                result['results'].append({'tier': tier, 'threads': threads, 'width': width,
                                          'effect': effect, 'equal': equal, 'outputs': values})
                if not equal:
                    print('FAIL', tier, threads, width, effect, values, flush=True)
        a.output.write_text(json.dumps(result, indent=2) + '\n')
        print(tier, threads, sum(r['equal'] for r in result['results']), len(result['results']), flush=True)
assert all(r['equal'] for r in result['results'])
