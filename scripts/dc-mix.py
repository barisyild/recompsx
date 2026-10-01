#!/usr/bin/env python3
"""scripts/dc-mix.py <prof.txt> <recompsx.elf> [regex] [--pool]

Where the sampled time of a set of functions goes, by kind of SH-4 instruction: the profile's
samples (scripts/dc-flycast-model.sh; a sample is a timeslice, so a PC's count is time, stalls and
misses included) summed over each instruction of every function whose demangled name matches
`regex` (default "Fns_": the generated code). With --pool, the literal-pool loads are broken down
by the constant they load.

The kinds: pool load (mov.l/mov.w/mova from a literal pool), field access (@(disp,Rn): CpuState
and other structures), indexed access (@(r0,Rn): the guest memory itself), stack slot, push, pop,
pointer access (@Rn), branch/call, compare, mov, and the ALU by mnemonic.
"""
import collections
import os
import re
import subprocess
import sys

TOOLS = os.path.expanduser("~/toolchains/dc/sh-elf/bin/")


def classify(ins, ops):
    if ins in ("mov.l", "mov.w") and re.match(r"^[0-9a-f]{8} <", ops) or ins == "mova":
        return "pool load"
    if ins.startswith("mov") and re.search(r"@\(r0,r\d+\)", ops):
        return "indexed access"
    if ins.startswith("mov") and "@-r15" in ops or ins == "sts.l" and "@-r15" in ops:
        return "push"
    if ins.startswith("mov") and "@r15+" in ops or ins == "lds.l":
        return "pop"
    if ins.startswith("mov") and re.search(r"@\(\d+,r15\)|@r15\b", ops):
        return "stack slot"
    if ins.startswith("mov") and re.search(r"@\(\d+,r\d+\)", ops):
        return "field access"
    if ins.startswith("mov") and re.search(r"@r\d+", ops):
        return "pointer access"
    if ins in ("jsr", "bsr", "bsrf", "jmp", "rts", "braf", "bra", "bt", "bf", "bt.s", "bf.s"):
        return "branch/call"
    if ins in ("cmp/eq", "cmp/hi", "cmp/hs", "cmp/gt", "cmp/ge", "cmp/pz", "cmp/pl", "tst"):
        return "compare"
    if ins == "mov":
        return "mov #imm" if "#" in ops else "mov reg"
    if ins == "nop":
        return "nop"
    return "alu:" + ins


def main():
    args = [a for a in sys.argv[1:] if a != "--pool"]
    pool = "--pool" in sys.argv
    if len(args) < 2:
        sys.exit(__doc__)
    prof, elf = args[0], args[1]
    flt = re.compile(args[2] if len(args) > 2 else r"Fns_")
    samples = {}
    for line in open(prof):
        p = line.split()
        if len(p) == 2 and re.fullmatch(r"[0-9a-f]{8}", p[0]):
            samples[int(p[0], 16)] = int(p[1])
    syms = []
    out = subprocess.run([TOOLS + "sh-elf-nm", "-S", "-C", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]{8}) ([0-9a-f]{8}) [tTwW] (.*)$", line)
        if m and flt.search(m.group(3)):
            syms.append((int(m.group(1), 16), int(m.group(2), 16)))
    kinds, consts = collections.Counter(), collections.Counter()
    for start, size in sorted(syms):
        if not any(samples.get(a, 0) for a in range(start, start + size, 2)):
            continue
        dis = subprocess.run([TOOLS + "sh-elf-objdump", "-d", "--no-show-raw-insn", f"--start-address={start:#x}",
                              f"--stop-address={start + size:#x}", elf], capture_output=True, text=True).stdout
        for line in dis.splitlines():
            m = re.match(r"^([0-9a-f]{8}):\s+(\S+)\s*(.*)$", line)
            if not m:
                continue
            w = samples.get(int(m.group(1), 16), 0)
            if not w:
                continue
            kind = classify(m.group(2), m.group(3))
            kinds[kind] += w
            if pool and kind == "pool load":
                c = re.search(r"!\s*(\S+)(.*)$", m.group(3))
                consts[(c.group(1) + " " + c.group(2).strip()[:40]) if c else "?"] += w
    total = sum(kinds.values())
    if not total:
        sys.exit("no samples in the matching functions")
    print(f"{len(syms)} functions match, {total} samples in them")
    grouped = collections.Counter()
    for k, w in kinds.items():
        grouped["alu" if k.startswith("alu:") else k] += w
    for k, w in grouped.most_common():
        print(f"{100.0 * w / total:6.1f} %  {k}")
    print("  alu: " + ", ".join(f"{k[4:]} {100.0 * w / total:.1f}" for k, w in kinds.most_common()
                                if k.startswith("alu:"))[:400])
    if pool:
        pt = sum(consts.values())
        print(f"\npool loads by constant ({100.0 * pt / total:.1f} % of the time):")
        for c, w in consts.most_common(16):
            print(f"{100.0 * w / pt:6.1f} %  {c}")


main()
