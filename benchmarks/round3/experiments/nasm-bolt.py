#!/usr/bin/env python3
"""Experimental NASM wrapper: give text entry labels ELF function metadata."""
import os
import struct
import subprocess
import sys
from pathlib import Path

nasm = os.environ.get('NASM_REAL', 'nasm')
subprocess.run([nasm, *sys.argv[1:]], check=True)
if '-o' not in sys.argv:
    sys.exit(0)
path = Path(sys.argv[sys.argv.index('-o') + 1])
data = bytearray(path.read_bytes())
assert data[:6] == b'\x7fELF\x02\x01'
shoff = struct.unpack_from('<Q', data, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 58)
sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize) for i in range(shnum)]
for section in sections:
    if section[1] != 2:  # SHT_SYMTAB
        continue
    strings = sections[section[6]]
    names = data[strings[4]:strings[4] + strings[5]]
    functions = {}
    for offset in range(section[4], section[4] + section[5], section[9]):
        name, info, other, index, value, size = struct.unpack_from('<IBBHQQ', data, offset)
        name = names[name:names.index(0, name)].decode()
        if index >= len(sections) or not sections[index][2] & 4:
            continue
        if info & 15 not in (0, 2) or not name or '.' in name:
            continue
        functions.setdefault(index, []).append((value, offset, info))
    for index, entries in functions.items():
        entries.sort()
        for i, (value, offset, info) in enumerate(entries):
            end = entries[i + 1][0] if i + 1 < len(entries) else sections[index][5]
            data[offset + 4] = (info & 0xf0) | 2
            struct.pack_into('<Q', data, offset + 16, end - value)
path.write_bytes(data)
