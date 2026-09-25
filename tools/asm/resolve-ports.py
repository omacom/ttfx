#!/usr/bin/env python3
"""Resolve the conflicts two effect ports always produce when merged: both
append an %include and a table row to asm/effects/registry.asm, a match arm
to src/asm/effects.rs, and tests/thunks to the shared test files. Keeps both
sides in order. Exits 1 if any other file still has conflict markers."""
import re
import subprocess
import sys

HUNK = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)

def resolve(path, join):
    text = open(path).read()
    text = HUNK.sub(lambda m: join(m.group(1), m.group(2)), text)
    open(path, "w").write(text)

def arms(ours, theirs):
    # each side is a whole match arm minus the closing brace they share
    return ours + "        }\n" + theirs

files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()
for path in files:
    if path == "src/asm/effects.rs":
        resolve(path, arms)
    elif path in ("asm/effects/registry.asm", "asm/tests.asm", "tests/asm_diff.rs"):
        resolve(path, lambda a, b: a + b)
    else:
        continue
    subprocess.run(["git", "add", path], check=True)

left = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                      capture_output=True, text=True).stdout.split()
if left:
    print("unresolved:", " ".join(left))
    sys.exit(1)
