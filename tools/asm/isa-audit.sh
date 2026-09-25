#!/usr/bin/env bash
# isa-audit.sh - check that each CPU tier's object uses only its tier's
# instructions (asm/PORTING.md "CPU tiers"): x86-64 v1 (SSE2), v2, v3, v4.
#
#   tools/asm/isa-audit.sh              assemble asm/lib.asm at TIER 1-4 (and
#                                       asm/tier.asm at the baseline) with line
#                                       info, list every instruction above its
#                                       tier as file:line, summarize per file
#   tools/asm/isa-audit.sh -q TIER OBJ  audit one built object (build.rs);
#                                       prints one summary line on failure
#
# Classification goes by encoding first (EVEX = v4, VEX = v3, VEX opmask = v4,
# REX2 = APX, legacy 0F 38 / 0F 3A maps = v2+), then by mnemonic for the
# legacy-encoded extensions (POPCNT, SSE3, LAHF, CMPXCHG16B = v2; LZCNT,
# TZCNT, MOVBE = v3) and by register class (ymm = v3; zmm, xmm16+, k = v4).
# FMA is rejected at every tier: its fused rounding breaks bit parity.
# Exit status 1 when anything is above its tier.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OBJDUMP=${OBJDUMP:-objdump}
NASM=${NASM:-nasm}

audit() {                               # audit TIER OBJECT QUIET
    "$OBJDUMP" -d -l -w -M intel "$2" | python3 -c '
import re, sys
tier, obj, quiet = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
PREFIXES = {0x66, 0x67, 0xf2, 0xf3, 0x2e, 0x3e, 0x26, 0x36, 0x64, 0x65, 0xf0}
V2 = {"popcnt", "crc32", "lahf", "sahf", "cmpxchg16b", "addsubpd", "addsubps",
      "haddpd", "haddps", "hsubpd", "hsubps", "lddqu", "movddup", "movshdup",
      "movsldup", "fisttp", "monitor", "mwait"}
V3 = {"lzcnt", "tzcnt", "movbe"}
BEYOND = re.compile(r"^(adcx|adox|aes|vaes|pclmul|vpclmul|sha|gf2p8|vgf2p8|rdrand|rdseed|"
                    r"prefetchw|vpdp|vcvtne|tile|ld|vp2intersect|xsave|xrstor|clflushopt|clwb)")
FMA = re.compile(r"^v?f(n)?m(add|sub|addsub|subadd)\d{3}")
NAMES = {1: "v1", 2: "v2", 3: "v3", 4: "v4", 99: "beyond v4"}

def need(raw, mnem, ops):
    """(level, reason) for one instruction."""
    i = 0
    while i < len(raw) and raw[i] in PREFIXES:
        i += 1
    if i < len(raw) and 0x40 <= raw[i] <= 0x4f:
        i += 1
    if i >= len(raw):
        return 1, ""
    op = raw[i]
    if FMA.match(mnem):
        return 99, "FMA (fused rounding breaks bit parity)"
    if BEYOND.match(mnem) and mnem != "lddqu":
        return 99, "not in x86-64-v4"
    if op == 0xd5:
        return 99, "REX2 (APX)"
    if op == 0x62:
        return 4, "EVEX"
    if op in (0xc4, 0xc5):
        if mnem.startswith("k"):
            return 4, "opmask"
        if re.search(r"\bzmm|\b[xy]mm(1[6-9]|2\d|3[01])\b", ops):
            return 4, "EVEX register"
        return 3, "VEX"
    if re.search(r"\bzmm\d|\b[xy]mm(1[6-9]|2\d|3[01])\b|\{k[0-7]\}", ops):
        return 4, "AVX-512 register"
    if re.search(r"\bymm\d", ops):
        return 3, "ymm register"
    if mnem in V3:
        return 3, mnem
    if mnem in V2:
        return 2, mnem
    if op == 0x0f and i + 1 < len(raw) and raw[i + 1] in (0x38, 0x3a):
        return 2, "SSSE3/SSE4 opcode map"
    return 1, ""

where = "?"
fn = "?"
bad = []
for line in sys.stdin:
    line = line.rstrip("\n")
    m = re.search(r"(\S*asm/[\w/]+\.(?:asm|inc)):(\d+)", line)
    if m and not line.startswith(" "):
        where = re.sub(r".*asm//", "", m.group(1)) + ":" + m.group(2)
        continue
    m = re.match(r"^\s+[0-9a-f]+:\t([0-9a-f ]+)\t(\S+)\s*(.*)$", line)
    if not m:
        m2 = re.match(r"^[0-9a-f]+ <(.*)>:$", line)
        if m2:
            fn = m2.group(1)
        continue
    raw = bytes(int(b, 16) for b in m.group(1).split())
    mnem, ops = m.group(2), m.group(3)
    if mnem in ("rep", "repz", "repnz", "lock", "data16", "notrack", "bnd") and ops:
        mnem, _, ops = ops.partition(" ")
    level, reason = need(raw, mnem, ops)
    if level > tier:
        bad.append((where, fn, mnem, ops.strip(), level, reason))

if not bad:
    sys.exit(0)
files = {}
for where, fn, *_ in bad:
    # objects without line info (build.rs) are summarized by function
    f = where.rsplit(":", 1)[0] if where != "?" else fn.split(".")[0]
    files[f] = files.get(f, 0) + 1
summary = ", ".join(f"{f} {n}" for f, n in sorted(files.items())[:12])
if len(files) > 12:
    summary += f", ... ({len(files)} in all)"
if quiet:
    print(f"{len(bad)} instruction(s) above tier {tier}: {summary}")
    sys.exit(1)
print(f"== tier {tier} ({obj}): {len(bad)} instruction(s) above x86-64-{NAMES[tier]}")
for where, fn, mnem, ops, level, reason in bad:
    print(f"  {where}: {mnem} {ops}   [{NAMES[level]}: {reason}; in {fn}]")
print(f"  per file: {summary}")
sys.exit(1)
' "$1" "$2" "$3"
}

if [ "${1:-}" = "-q" ]; then
    audit "$2" "$3" 1
    exit
fi

OUT="$ROOT/target/isa-audit"
mkdir -p "$OUT"
cd "$ROOT"
: > "$OUT/test_thunks.inc"
status=0
for t in 1 2 3 4; do
    if ! "$NASM" -f elf64 -O3 -g -F dwarf -I asm/ -DTIER=$t -DTTFX_NO_CPU_CHECK \
        -o "$OUT/lib-v$t.o" asm/lib.asm 2> "$OUT/nasm-v$t.log"; then
        echo "== tier $t: NASM failed"; grep error "$OUT/nasm-v$t.log" | head -20
        status=1
        continue
    fi
    if audit $t "$OUT/lib-v$t.o" 0; then
        echo "== tier $t: clean"
    else
        status=1
    fi
done
"$NASM" -f elf64 -O3 -g -F dwarf -I asm/ -I "$OUT/" -DTIER=1 -o "$OUT/tier.o" asm/tier.asm
if audit 1 "$OUT/tier.o" 0; then echo "== tier.asm (baseline): clean"; else status=1; fi
exit $status
