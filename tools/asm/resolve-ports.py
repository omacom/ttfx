#!/usr/bin/env python3
"""Resolve the conflicts two effect-port merges always produce.

Both sides append: an %include and a table row to asm/effects/registry.asm,
tests and thunks to the shared test files, and a match arm (plus sometimes a
Words helper) to src/asm/effects.rs. Line-based merging goes wrong on the
latter when two arms end in identical lines, so effects.rs is rebuilt from
both sides' complete files: the union of their match arms and Words helpers.
Exits 1 if anything else is still conflicted."""
import re
import subprocess
import sys

HUNK = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
ARM = re.compile(r"^        (?://[^\n]*\n        )*EffectCommand::(\w+)\(c\) => \{\n.*?^        \}\n", re.S | re.M)
HELPER = re.compile(r"^    (?:///[^\n]*\n    )*fn (\w+)\(&mut self.*?^    \}\n", re.S | re.M)

def show(stage, path):
    return subprocess.run(["git", "show", f":{stage}:{path}"], capture_output=True, text=True).stdout

def union(pattern, ours, theirs):
    seen = {m.group(1): m.group(0) for m in pattern.finditer(ours)}
    extra = [m.group(0) for m in pattern.finditer(theirs) if m.group(1) not in seen]
    return extra

def effects_rs(path):
    ours, theirs = show(2, path), show(3, path)
    text = ours
    arms = union(ARM, ours, theirs)
    if arms:
        marker = '        _ => return Err("this effect is not ported yet"),\n'
        assert marker in text, "match fallback arm not found"
        text = text.replace(marker, "".join(arms) + marker)
    helpers = union(HELPER, ours, theirs)
    if helpers:
        anchor = text.index("\n}\n", text.index("impl Words {"))
        text = text[:anchor + 1] + "\n" + "\n".join(helpers) + text[anchor + 1:]
    open(path, "w").write(text)

files = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                       capture_output=True, text=True).stdout.split()
for path in files:
    if path == "src/asm/effects.rs":
        effects_rs(path)
    elif path in ("asm/effects/registry.asm", "asm/tests.asm", "tests/asm_diff.rs"):
        text = open(path).read()
        open(path, "w").write(HUNK.sub(lambda m: m.group(1) + m.group(2), text))
    else:
        continue
    subprocess.run(["git", "add", path], check=True)

left = subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                      capture_output=True, text=True).stdout.split()
if left:
    print("unresolved:", " ".join(left))
    sys.exit(1)
