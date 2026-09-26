#!/usr/bin/env python3
"""Stream oracle output to SHA-256 digests and byte counts, keeping exit status.

Use as oracle.sh's BIN, with TTFX_ORACLE_REAL_BIN pointing to the actual binary.
The oracle compares both streams and status as usual, without storing multi-GB
frame dumps. This wrapper is for correctness checks, never for benchmarking.
"""

import hashlib
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def digest(stream):
    checksum = hashlib.sha256()
    length = 0
    while data := stream.read(1 << 20):
        checksum.update(data)
        length += len(data)
    return f"{length} {checksum.hexdigest()}\n"


def main():
    command = [os.environ["TTFX_ORACLE_REAL_BIN"], *sys.argv[1:]]
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        # Drain both pipes concurrently so large diagnostics cannot deadlock.
        with ThreadPoolExecutor(max_workers=2) as pool:
            stdout = pool.submit(digest, process.stdout)
            stderr = pool.submit(digest, process.stderr)
            sys.stdout.write(stdout.result())
            sys.stderr.write(stderr.result())
        code = process.wait()
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
