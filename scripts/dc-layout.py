#!/usr/bin/env python3
"""scripts/dc-layout.py — places a Dreamcast build's hot code for the SH-4's instruction cache.

The instruction cache is 8 KB, direct-mapped, 32-byte lines: which functions evict each other is
decided by where the linker puts them. The link keeps one input section per function after LTO
(-ffunction-sections), the map names them, and binutils 2.45's --section-ordering-file puts named
sections first in .text, in order. The colours come from scripts/dc-icache-sim.c, which replays a
cache-model trace (scripts/dc-flycast-model.sh with RXTRACE) against candidate placements:

  dc-layout.py sections <link.map> [<new.map>]
      the simulator's sections file: "oldstart size newstart" for every .text input section of
      <link.map>, sorted by address; newstart is the same section's address in <new.map> (matched
      by name, and by object where a name repeats), or oldstart without one
  dc-layout.py export <link.map> <colours>
      a placement: dc-icache-sim opt's "index colour" lines (indexes into the sections file of
      <link.map>) as "colour pattern" lines, the section named the way order.ld names it; hottest
      first. What games/<SERIAL>/dc-placement.txt holds.
  dc-layout.py place <link.map> <placement> <out-dir>
      the link that puts each section of a placement at its colour, from the sizes in <link.map>:
      <out-dir>/order.ld for -Wl,--section-ordering-file, <out-dir>/pad.s the padding sections
      between them (assemble and link it; -Wl,-u on the symbols in <out-dir>/keep.txt keeps them
      through --gc-sections), and <out-dir>/plan.txt, each section's intended address. A section
      the link does not have (the code changed) is left where the linker puts it.
  dc-layout.py check <new.map> <plan.txt>
      whether the new link put every placed section at its planned address; exits 1 if not

KallistiOS's startup stays first: its entry is the load address. A section keeps its offset into
its first line, so any alignment up to a line holds. The growth of .text is rounded up to a
multiple of 16 KB, so every later section, the data included, keeps its colour in the 16 KB
operand cache.
"""
import os
import re
import sys

LINE = 32
ICACHE = 8192
OCACHE = 16384
COLOURS = ICACHE // LINE


def parse_map(path):
    """The .text output section's start and its input sections: (name, address, size, object)."""
    sections, start, inside, pending = [], None, False, None
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith(".text") and not line.startswith(".text."):
                p = line.split()
                if len(p) >= 3:
                    start = int(p[1], 16)
                    inside = True
                continue
            if inside and line and not line.startswith(" "):
                break
            if not inside:
                continue
            m = re.match(r"^ (\.text\S*)(?:\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+))?", line)
            if m:
                if m.group(2):
                    sections.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16), m.group(4)))
                    pending = None
                else:
                    pending = m.group(1)
                continue
            if pending:
                m2 = re.match(r"^\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+)", line)
                if m2:
                    sections.append((pending, int(m2.group(1), 16), int(m2.group(2), 16), m2.group(3)))
                pending = None
    sections = [s for s in sections if s[2] > 0]
    sections.sort(key=lambda s: s[1])
    return start, sections


def identity(name, obj):
    """What names a section across two links: an LTO partition's object is a new temporary at
    every link, so its sections go by name alone; the rest by name and object."""
    if "ltrans" in obj:
        return name
    m = re.match(r"^(.*/)?([^/(]+\.a)\(([^)]+)\)$", obj)
    return (name, f"{m.group(2)}:{m.group(3)}" if m else os.path.basename(obj))


def pattern(name, obj, unique):
    """How order.ld names one input section. A name unique in the link is enough. Otherwise the
    object qualifies it: an archive member as `*libX.a:member.o(name)`, a plain object by its file
    name. None for an LTO partition's own object, whose name is a new temporary at every link."""
    if unique:
        return f"*({name})"
    m = re.match(r"^(.*/)?([^/(]+\.a)\(([^)]+)\)$", obj)
    if m:
        return f"*{m.group(2)}:{m.group(3)}({name})"
    if "ltrans" in obj:
        return None
    return f"*{os.path.basename(obj)}({name})"


def cmd_sections(args):
    start, secs = parse_map(args[0])
    moved = {}
    if len(args) > 1:
        _, new = parse_map(args[1])
        for name, addr, size, obj in new:
            moved.setdefault(identity(name, obj), addr)
    for name, addr, size, obj in secs:
        print(f"{addr:08x} {size:x} {moved.get(identity(name, obj), addr):08x}")


def by_pattern(secs):
    """Each section of a link under the name order.ld gives it; LTO partitions' repeats left out."""
    uses = {}
    for name, addr, size, obj in secs:
        uses[name] = uses.get(name, 0) + 1
    named = {}
    for sec in secs:
        pat = pattern(sec[0], sec[3], uses[sec[0]] == 1)
        if pat is not None and not sec[3].endswith("_kos_startup.o"):
            named[pat] = sec
    return named


def cmd_export(args):
    map_path, colours_path = args
    start, secs = parse_map(map_path)
    uses = {}
    for name, addr, size, obj in secs:
        uses[name] = uses.get(name, 0) + 1
    print("# colour pattern — scripts/dc-layout.py (hottest first; a colour is a line index mod 256)")
    with open(colours_path) as f:
        for line in f:
            p = line.split()
            if len(p) != 2:
                continue
            name, addr, size, obj = secs[int(p[0])]
            pat = pattern(name, obj, uses[name] == 1)
            if pat is not None and not obj.endswith("_kos_startup.o"):
                print(f"{int(p[1])} {pat}")


def cmd_check(args):
    map_path, plan_path = args
    start, secs = parse_map(map_path)
    named = by_pattern(secs)
    plan = [l.split() for l in open(plan_path) if l.strip()]
    off = [(pat, t) for t, pat in plan if pat not in named or named[pat][1] != int(t, 16)]
    print(f"{len(plan) - len(off)} of {len(plan)} placed sections at their planned address")
    for pat, t in off[:5]:
        print(f"  not at {t}: {pat}")
    sys.exit(1 if off else 0)


def cmd_place(args):
    map_path, placement_path, out = args
    start, secs = parse_map(map_path)
    startup = next((s for s in secs if s[3].endswith("_kos_startup.o")), None)
    if startup is None:
        sys.exit("no _kos_startup.o .text in the map: its entry must stay at the load address")
    named = by_pattern(secs)
    wanted = []
    with open(placement_path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            colour, pat = line.split(None, 1)
            wanted.append((int(colour), pat.strip()))
    at = start + startup[2]
    order, pads, plan, grown, skipped = [], [], [], 0, 0
    for colour, pat in wanted:
        if pat not in named:
            skipped += 1
            continue
        name, addr, size, obj = named[pat]
        lead = addr % LINE
        first = (at - lead + LINE - 1) // LINE * LINE
        here = (first // LINE) % COLOURS
        target = first + ((colour - here) % COLOURS) * LINE + lead
        pad = target - at
        if pad:
            pads.append(pad)
            order.append(("pad", len(pads) - 1))
            grown += pad
        order.append(("fn", pat))
        plan.append((target, pat))
        at = target + size
    tail = (-grown) % OCACHE
    if tail:
        pads.append(tail)
        order.append(("pad", len(pads) - 1))
        grown += tail
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "order.ld"), "w") as f:
        f.write(".text : {\n  *_kos_startup.o(.text)\n")
        for kind, what in order:
            f.write(f"  KEEP(*(.text.rxpad.{what}))\n" if kind == "pad" else f"  {what}\n")
        f.write("}\n")
    with open(os.path.join(out, "pad.s"), "w") as f:
        f.write("! Padding for scripts/dc-layout.py's order.ld: never executed.\n")
        for k, n in enumerate(pads):
            f.write(f"\t.section .text.rxpad.{k},\"ax\",@progbits\n\t.p2align 0\n"
                    f"\t.globl rxpad_{k}\nrxpad_{k}:\n\t.space {n}\n")
    with open(os.path.join(out, "keep.txt"), "w") as f:
        f.write(" ".join(f"-Wl,-u,rxpad_{k}" for k in range(len(pads))) + "\n")
    with open(os.path.join(out, "plan.txt"), "w") as f:
        for target, pat in plan:
            f.write(f"{target:08x} {pat}\n")
    print(f"{len(plan)} sections placed ({skipped} not in this link), {len(pads)} pads, "
          f".text grows {grown} bytes")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "sections" and len(args) in (1, 2):
        cmd_sections(args)
    elif cmd == "export" and len(args) == 2:
        cmd_export(args)
    elif cmd == "place" and len(args) == 3:
        cmd_place(args)
    elif cmd == "check" and len(args) == 2:
        cmd_check(args)
    else:
        sys.exit(__doc__)


main()
