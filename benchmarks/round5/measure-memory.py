#!/usr/bin/env python3
"""Peak RSS through the native wait4 sampler, with a small parent process."""
import argparse
import hashlib
import json
import os
import statistics
import subprocess
import tempfile
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('candidate', type=Path)
p.add_argument('--sampler', type=Path, required=True)
p.add_argument('--cpus', type=int, nargs='+', default=[2, 4])
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
os.sched_setaffinity(0, a.cpus)
binaries = {'baseline': a.baseline.resolve(), 'candidate': a.candidate.resolve()}
line = ('The quick brown fox jumps over the lazy dog 0123456789 ' * 4)[:190]
data = '\n'.join([line] * 46).encode()
result = {'method': 'Native fork/exec/wait4 ru_maxrss in KiB; five alternating samples',
          'cpus': a.cpus, 'input_sha256': hashlib.sha256(data).hexdigest(),
          'thp_policy': Path('/sys/kernel/mm/transparent_hugepage/enabled').read_text().strip(),
          'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                       for name, path in binaries.items()}, 'results': []}
for threads in ('1', 'auto'):
    env = {**os.environ, 'TTFX_ASM': 'force', 'TTFX_ASM_THREADS': threads, 'COLUMNS': '200', 'LINES': '50'}
    for effect in ('waves', 'highlight', 'binarypath', 'matrix'):
        args = ['--seed', '1', '--frame-rate', '0', '--canvas-width', '200',
                '--canvas-height', '50', '--ignore-terminal-dimensions']
        if effect == 'matrix':
            args.append('--virtual-clock')
        args.append(effect)
        samples = {name: [] for name in binaries}
        with tempfile.TemporaryFile() as source:
            source.write(data)
            for iteration in range(5):
                order = list(binaries)
                if iteration % 2:
                    order.reverse()
                for name in order:
                    source.seek(0)
                    proc = subprocess.run([str(a.sampler.resolve()), str(binaries[name]), *args],
                                          stdin=source, capture_output=True, env=env, check=True, timeout=120)
                    samples[name].append(int(proc.stdout))
        row = {'effect': effect, 'TTFX_ASM_THREADS': threads, 'args': args, **{
            name: {'peak_rss_kib': values, 'median_mib': statistics.median(values)/1024}
            for name, values in samples.items()}}
        result['results'].append(row)
        print(threads, effect, {name: row[name]['median_mib'] for name in binaries}, flush=True)
        a.output.write_text(json.dumps(result, indent=2) + '\n')
