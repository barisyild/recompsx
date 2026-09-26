#!/usr/bin/env python3
"""scripts/dc-prof.py <prof.txt> <recompsx.elf> [--top N] [--hot FUNC] [--nm PATH]

Reads a guest profile written by the profiling Flycast build (branch `recompsx-prof` of a local
Flycast clone: every SH4 timeslice records the PC it resumes at) and names where the cycles went,
with the ELF's own symbols.

The Dreamcast side asks for it: `--dc-bench=FROM:TO` with `--dc-rxprof` in recompsx.cfg prints
"@@rxprof start" / "@@rxprof stop" / "@@rxprof exit" on the serial port around that range of
presents, and the Flycast build records between the first two and quits at the third.

    --top N      functions to list (default 40)
    --hot FUNC   also list FUNC's hottest addresses (substring of the demangled name), with
                 the instruction at each — disassembled from the ELF
"""
import bisect
import os
import subprocess
import sys


def load_profile(path):
    meta, samples = {}, []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                meta["kind"] = line.split()[-1]
                continue
            a, b = line.split()
            if a in ("samples", "other", "timeslice", "cycles"):
                meta[a] = int(b)
            elif a == "wall_s":
                meta[a] = float(b)
            else:
                samples.append((int(a, 16), int(b)))
    return meta, samples


def load_symbols(nm, elf):
    out = subprocess.run([nm, "-n", "-S", "-C", elf], check=True, capture_output=True, text=True).stdout
    starts, ends, names = [], [], []
    for line in out.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) < 4 or parts[2] not in ("t", "T", "w", "W"):
            continue
        start, size = int(parts[0], 16), int(parts[1], 16)
        if size == 0:
            continue
        starts.append(start)
        ends.append(start + size)
        names.append(parts[3])
    return starts, ends, names


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    top, hot, nm = 40, None, None
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--top":
            top = int(args[i + 1]); i += 2
        elif args[i] == "--hot":
            hot = args[i + 1]; i += 2
        elif args[i] == "--nm":
            nm = args[i + 1]; i += 2
        else:
            rest.append(args[i]); i += 1
    prof, elf = rest[0], rest[1]
    tools = os.path.expanduser("~/toolchains/dc/sh-elf/bin/")
    nm = nm or os.path.join(tools, "sh-elf-nm")
    meta, samples = load_profile(prof)
    starts, ends, names = load_symbols(nm, elf)
    slice_ = meta.get("timeslice", 448)
    total = sum(c for _, c in samples) + meta.get("other", 0)
    if total == 0:
        sys.exit("no samples")
    per_fn, unknown = {}, 0
    for addr, count in samples:
        k = bisect.bisect_right(starts, addr) - 1
        if k >= 0 and addr < ends[k]:
            per_fn[k] = per_fn.get(k, 0) + count
        else:
            unknown += count
    cycles = meta.get("cycles", total * slice_)
    frames = None
    print(f"{meta.get('kind', '?')}: {total} samples x {slice_} cycles = {total * slice_ / 1e6:.1f} M cycles "
          f"({cycles / 200e6 * 1000:.0f} ms of a 200 MHz SH-4), host {meta.get('wall_s', 0):.1f} s")
    print(f"outside RAM {meta.get('other', 0)}, outside any symbol {unknown}")
    print(f"{'share':>6} {'ms@200MHz':>9}  function")
    for k, count in sorted(per_fn.items(), key=lambda kv: -kv[1])[:top]:
        print(f"{100.0 * count / total:5.1f}% {count * slice_ / 200e3:9.1f}  {names[k]}")
    if hot:
        matches = [k for k in per_fn if hot in names[k]]
        if not matches:
            sys.exit(f"no sampled function matches {hot!r}")
        k = max(matches, key=lambda m: per_fn[m])
        print(f"\nhottest addresses in {names[k]} ({per_fn[k]} samples):")
        objdump = os.path.join(tools, "sh-elf-objdump")
        dis = subprocess.run([objdump, "-d", "--no-show-raw-insn", f"--start-address={starts[k]:#x}",
                              f"--stop-address={ends[k]:#x}", elf], capture_output=True, text=True).stdout
        text = {}
        for line in dis.splitlines():
            head, _, ins = line.partition(":\t")
            try:
                text[int(head.strip(), 16)] = ins.strip()
            except ValueError:
                pass
        inside = sorted(((a, c) for a, c in samples if starts[k] <= a < ends[k]), key=lambda ac: -ac[1])
        for a, c in inside[:30]:
            print(f"  {a:08x} +{a - starts[k]:#06x} {100.0 * c / per_fn[k]:5.1f}%  {text.get(a, '')}")


main()
