#!/usr/bin/env python3
"""Measure per-process peak RSS for two assembly engines on the standard input."""
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
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
binaries = {'baseline': a.baseline.resolve(), 'candidate': a.candidate.resolve()}
line = ('The quick brown fox jumps over the lazy dog 0123456789 ' * 4)[:190]
data = '\n'.join([line] * 46).encode()
result = {
    'method': 'Linux wait4 / ru_maxrss, KiB; median of five interleaved samples',
    'input_sha256': hashlib.sha256(data).hexdigest(),
    'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                 for name, path in binaries.items()},
    'effects': {},
}
env = {**os.environ, 'TTFX_ASM': 'force', 'COLUMNS': '200', 'LINES': '50'}
for effect in ('waves', 'highlight', 'binarypath', 'matrix'):
    args = ['--seed', '1', '--frame-rate', '0', '--canvas-width', '200',
            '--canvas-height', '50', '--ignore-terminal-dimensions']
    if effect == 'matrix':
        args.append('--virtual-clock')
    args.append(effect)
    samples = {name: [] for name in binaries}
    for iteration in range(5):
        order = list(binaries)
        if iteration % 2:
            order.reverse()
        for name in order:
            with tempfile.TemporaryFile() as source, tempfile.TemporaryFile() as err:
                source.write(data)
                source.seek(0)
                child = subprocess.Popen([str(binaries[name]), *args], env=env,
                                         stdin=source, stdout=subprocess.DEVNULL, stderr=err)
                _, status, usage = os.wait4(child.pid, 0)
                child.returncode = os.waitstatus_to_exitcode(status)
                err.seek(0)
                if child.returncode:
                    raise RuntimeError((name, effect, child.returncode, err.read()))
                samples[name].append(usage.ru_maxrss)
    result['effects'][effect] = {'args': args, **{
        name: {'peak_rss_kib': values, 'median_mib': statistics.median(values)/1024}
        for name, values in samples.items()}}
    print(effect, {name: result['effects'][effect][name]['median_mib'] for name in binaries}, flush=True)
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(result, indent=2)+'\n')
