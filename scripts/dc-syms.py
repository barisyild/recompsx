#!/usr/bin/env python3
"""scripts/dc-syms.py <nm> <elf> <out> — the function table the Dreamcast overlay names hot code with.

The backend's 1 kHz sampler (dc_prof.c, samp_tick) knows only program counters. With this file
on the disc it can say which function each sample landed in, and the overlay prints the top few by
name — a profile read off a screenshot, on a console that has no other way to show one.

Written next to the ELF by build-dc.sh; copy it to the disc's root as SYMS.BIN with the rest of the
data. Little-endian, like the SH-4:

    "RSY1"  u32 count  u32 anchor
    count x (u32 start, u32 end)      sorted by start, non-overlapping
    count x char[12]                  short name, NUL-padded

`anchor` is samp_tick's address in this ELF — a function whose address the backend takes (it is the
sampler's interrupt handler), so link-time optimisation can neither rename nor clone it. The backend
compares it with its own and ignores a file from another build, whose names would all be wrong.
"""
import struct
import subprocess
import sys

NAME = 12


def short(name):
    """`gte::Gte::rtps(int, bool, int, bool) [clone .constprop.0]` -> `rtps`: what fits a column."""
    name = name.split(" [clone")[0]
    if "(" in name and not name.startswith("operator"):
        name = name.split("(")[0]
    flat, depth = "", 0          # template arguments out: they hold `::` of their own
    for ch in name:
        depth += ch == "<"
        if depth == 0:
            flat += ch
        depth -= ch == ">" and depth > 0
    name = flat.split("::")[-1] or name
    return name[:NAME - 1]


def main():
    nm, elf, out = sys.argv[1], sys.argv[2], sys.argv[3]
    text = subprocess.run([nm, "-n", "-S", "-C", elf], check=True, capture_output=True, text=True).stdout
    funcs, anchor = [], None
    for line in text.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) < 4 or parts[2] not in ("t", "T", "w", "W"):
            continue
        start, size, name = int(parts[0], 16), int(parts[1], 16), parts[3]
        if name == "samp_tick":
            anchor = start
        if size > 0:
            funcs.append((start, start + size, short(name)))
    if anchor is None:
        sys.exit("dc-syms: no samp_tick in " + elf)
    # Aliases share an address; keep the first, and clip any overlap so a binary search is exact.
    table = []
    for start, end, name in sorted(funcs):
        if table and start < table[-1][1]:
            if start == table[-1][0]:
                continue
            table[-1] = (table[-1][0], start, table[-1][2])
        table.append((start, end, name))
    with open(out, "wb") as f:
        f.write(b"RSY1" + struct.pack("<II", len(table), anchor))
        for start, end, _ in table:
            f.write(struct.pack("<II", start, end))
        for _, _, name in table:
            f.write(name.encode("ascii", "replace")[:NAME - 1].ljust(NAME, b"\0"))
    print(f"dc-syms: {len(table)} functions -> {out}")


main()
