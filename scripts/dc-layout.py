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
      through --gc-sections), and <out-dir>/plan.txt, each section's intended address. A generated
      function the link has under another chunk's name (the generator cuts chunks by size, so a
      change renames neighbours) is placed under its new name; a section the link does not have at
      all (the code changed) is left where the linker puts it. A placement's
      colour may be written "=c" (0..511): the section's colour in the 16 KB operand cache as
      well, which fixes the half of it the section's literal pools are read from (dc-ocache-sim
      dopt "~c" chooses it); a plain colour is the 8 KB instruction cache's only.
  dc-layout.py check <new.map> <plan.txt>
      whether the new link put every placed section at its planned address; exits 1 if not
  dc-layout.py objects <link.map>
      every input section of the loaded image, code and data, as "start size name" sorted by
      start: what scripts/dc-ocache-sim.c counts operand-cache misses by. The name is the output
      section, the input section and its object, "|"-separated.
  dc-layout.py halves-items <placement> <data-placement>
      the items for dc-ocache-sim dopt that choose each placed function's half of the operand
      cache: every placed variable at its colour ("=c"), every placed function at its colour in
      the instruction cache ("~c", so dopt decides only the half its literal pools are read from)
  dc-layout.py halves-apply <placement> <dopt-out>
      <placement> again, each function dopt gave a colour written "=c" with it; the rest as they
      were. Made from traces of a build that already has <placement>'s instruction colours.

KallistiOS's startup stays first: its entry is the load address. A section keeps its offset into
its first line, so any alignment up to a line holds. The growth of .text is rounded up to a
multiple of 16 KB, so every later section, the data included, keeps its colour in the 16 KB
operand cache.
"""
import os
import re
import subprocess
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


LOADED = (".text", ".rodata", ".data", ".bss", ".ctors", ".dtors", ".eh_frame", ".gcc_except_table",
          ".data.rel.ro", ".sdata", ".sbss", ".tdata", ".tbss", ".init", ".fini", ".init_array",
          ".fini_array")


def parse_all(path):
    """Every input section of the loaded output sections: (output, name, address, size, object)."""
    out, pending, secs, started = None, None, [], False
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("Linker script and memory map"):
                started = True
                continue
            if not started:
                continue
            if line and not line.startswith(" "):
                name = line.split()[0]
                out = name if name in LOADED else None
                pending = None
                continue
            if out is None:
                continue
            m = re.match(r"^ (\.\S+|COMMON)(?:\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+))?", line)
            if m:
                if m.group(2):
                    secs.append((out, m.group(1), int(m.group(2), 16), int(m.group(3), 16), m.group(4)))
                    pending = None
                else:
                    pending = m.group(1)
                continue
            if pending:
                m2 = re.match(r"^\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+)", line)
                if m2:
                    secs.append((out, pending, int(m2.group(1), 16), int(m2.group(2), 16), m2.group(3)))
                pending = None
    return sorted((s for s in secs if s[3] > 0 and s[2] >= 0x8c000000), key=lambda s: s[2])


def cmd_objects(args):
    for out, name, addr, size, obj in parse_all(args[0]):
        m = re.match(r"^(.*/)?([^/(]+\.a)\(([^)]+)\)$", obj)
        where = f"{m.group(2)}:{m.group(3)}" if m else os.path.basename(obj)
        print(f"{addr:08x} {size:x} {out}|{name}|{where}")


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
    data = [s for s in parse_all(map_path) if s[0] in (".data", ".bss")]
    uses = {}
    for out, name, addr, size, obj in data:
        uses[name] = uses.get(name, 0) + 1
    for out, name, addr, size, obj in data:
        pat = pattern(name, obj, uses[name] == 1)
        if pat is not None:
            named.setdefault(pat, (name, addr, size, obj))
    data_pats = set()
    for out, name, addr, size, obj in data:
        pat = pattern(name, obj, uses[name] == 1)
        if pat is not None:
            data_pats.add(pat)

    def placed(pat, t):
        if pat not in named:
            return False
        if pat in data_pats:
            # The data follow .text, which a code placement grows by 16 KB at a time: what the plan
            # fixes is the colour and the offset into the line, not the address.
            return named[pat][1] % OCACHE == int(t, 16) % OCACHE
        return named[pat][1] == int(t, 16)
    plan = [l.split() for l in open(plan_path) if l.strip()]
    off = [(pat, t) for t, pat in plan if not placed(pat, t)]
    print(f"{len(plan) - len(off)} of {len(plan)} placed sections at their planned address")
    for pat, t in off[:5]:
        print(f"  not at {t}: {pat}")
    sys.exit(1 if off else 0)


READELF = os.path.expanduser("~/toolchains/dc/sh-elf/bin/sh-elf-readelf")
_aligns = {}


def section_align(obj, name, addr):
    """An input section's alignment, from its object's section headers (an archive's by member);
    when they cannot be read, the largest power of two its linked address allows, up to a line."""
    m = re.match(r"^(.*\.a)\(([^)]+)\)$", obj)
    path, member = (m.group(1), m.group(2)) if m else (obj, None)
    if path not in _aligns:
        table, cur = {}, None
        try:
            out = subprocess.run([READELF, "-S", "-W", path], capture_output=True, text=True).stdout
        except OSError:
            out = ""
        for line in out.splitlines():
            f = re.match(r"^File: .*\(([^)]+)\)$", line)
            if f:
                cur = f.group(1)
                continue
            r = re.match(r"^\s*\[\s*\d+\]\s+(\S+)\s+(.*)$", line)
            if r and r.group(2).split() and r.group(2).split()[-1].isdigit():
                table[(cur, r.group(1))] = int(r.group(2).split()[-1])
        _aligns[path] = table
    a = _aligns[path].get((member, name))
    if a:
        return a
    return min(LINE, addr & -addr) if addr else 4


def place_data(map_path, data_path, pads, plan):
    """The .data and .bss orders that put each variable of a data placement at its colour (a line
    index mod 512, the 16 KB operand cache). Each section's list starts at a 16 KB boundary
    (`. = ALIGN(0x4000)`), so a colour is an offset from it whatever came before; the placed
    variables come first, by colour, then every other input section in the order it had. .bss also
    takes COMMON and ends at a 16 KB boundary, so the heap after it starts at the same colour in
    every game; the rest starts at a boundary of its own, so its colours do not depend on what was
    placed. Every address is known here, from the sizes and alignments; the plan holds each
    placed variable's offset from its boundary, which is its address mod 16 KB."""
    wanted = []
    with open(data_path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            colour, name = line.split(None, 1)
            wanted.append((int(colour), name.strip()))
    secs = [s for s in parse_all(map_path) if s[0] in (".data", ".bss") and ".rxpad." not in s[1]]
    uses = {}
    for out, name, addr, size, obj in secs:
        uses[name] = uses.get(name, 0) + 1
    blocks, skipped, leftovers = {}, 0, 0
    for out in (".data", ".bss"):
        mine = [s for s in secs if s[0] == out]
        if not mine:
            continue
        colour_of = {}
        for colour, name in wanted:
            if uses.get(name) == 1 and any(s[1] == name for s in mine):
                colour_of[name] = colour
        first_named, rest = [], []
        for sec in mine:
            if sec[1] == "COMMON":
                continue
            pat = pattern(sec[1], sec[4], uses[sec[1]] == 1)
            if sec[1] in colour_of:
                first_named.append((colour_of[sec[1]], pat, sec))
            elif pat is not None:
                rest.append((pat, sec))
            else:
                leftovers += 1
        # By colour, the arrays of 16 KB and more last: one of them in the middle would push every
        # variable after it into the next 16 KB, a pad each.
        first_named.sort(key=lambda x: (x[2][3] >= OCACHE, x[0]))
        entries, at = [], 0
        for colour, pat, (o, name, addr, size, obj) in first_named:
            align = section_align(obj, name, addr)
            step = max(1, align // LINE)
            colour -= colour % step
            here_at = (at // LINE) % (OCACHE // LINE)
            aligned = (at + align - 1) // align * align
            if here_at == colour and aligned // LINE == at // LINE:
                # The line `at` is in has the colour asked for: share it.
                target = aligned
            else:
                first = (at + LINE - 1) // LINE * LINE
                here = (first // LINE) % (OCACHE // LINE)
                target = first + ((colour - here) % (OCACHE // LINE)) * LINE
                target = (target + align - 1) // align * align
            # The gap before it takes cold sections that fit, in their order, and a pad the rest.
            k = 0
            while k < len(rest) and at < target:
                rpat, (ro, rname, raddr, rsize, robj) = rest[k]
                ralign = section_align(robj, rname, raddr)
                rat = (at + ralign - 1) // ralign * ralign
                if rat + rsize <= target:
                    if rat > at:
                        pads.append((out[1:], rat - at))
                        entries.append(("pad", len(pads) - 1))
                    entries.append(("sec", rpat))
                    at = rat + rsize
                    del rest[k]
                else:
                    k += 1
            if target > at:
                pads.append((out[1:], target - at))
                entries.append(("pad", len(pads) - 1))
            entries.append(("sec", pat))
            plan.append((target, pat))
            at = target + size
        blocks[out] = (entries, rest)
        skipped += sum(1 for c, n in wanted if n not in colour_of and any(s[1] == n for s in mine))
    if leftovers:
        print(f"note: {leftovers} data sections cannot be named and follow the list")
    return blocks, len(wanted), skipped


def cmd_place(args):
    map_path, placement_path, out = args[:3]
    data_path = args[3] if len(args) > 3 else None
    order, pads, plan, grown, skipped = [], [], [], 0, 0
    if placement_path != "-":
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
                # "=c": the colour in the 16 KB operand cache too (0..511), which also fixes the
                # half of it the section's literal pools are read from (dc-ocache-sim dopt "~c").
                if colour.startswith("="):
                    wanted.append((int(colour[1:]) % (OCACHE // LINE), OCACHE // LINE, pat.strip()))
                else:
                    wanted.append((int(colour), COLOURS, pat.strip()))
        at = start + startup[2]
        # A generated function's section is named by the chunk its class is (`Fns_08_8003b874::
        # f_8003d0fc`), and the chunks are cut by size: a change in one function moves the cut
        # and renames its neighbours. A placement made before such a change names them as they
        # were, so a section it names that this link lacks is looked for again by what it is —
        # the chunk's kind, the function and its signature — and placed under its new name.
        aliases = generated_aliases(named)
        renamed = 0
        for k, (colour, modulus, pat) in enumerate(wanted):
            if pat not in named:
                alt = aliases.get(generated_key(pat))
                if alt is not None:
                    wanted[k] = (colour, modulus, alt)
                    renamed += 1
                else:
                    pass
        skipped = sum(1 for _, _, pat in wanted if pat not in named)
        todo = [w for w in wanted if w[2] in named]
        # In the order that pads least: each time, the section whose colour comes soonest after
        # where the last one ended. A colour is all that decides a section's lines, so the order
        # is free; hottest first, as the file lists them, "=c" sections padded most of 16 KB each.
        def gap(w):
            colour, modulus, pat = w
            addr = named[pat][1]
            lead = addr % LINE
            first = (at - lead + LINE - 1) // LINE * LINE
            here = (first // LINE) % modulus
            return first + ((colour - here) % modulus) * LINE + lead - at
        while todo:
            k = min(range(len(todo)), key=lambda i: gap(todo[i]))
            colour, modulus, pat = todo.pop(k)
            name, addr, size, obj = named[pat]
            lead = addr % LINE
            first = (at - lead + LINE - 1) // LINE * LINE
            here = (first // LINE) % modulus
            target = first + ((colour - here) % modulus) * LINE + lead
            pad = target - at
            if pad:
                pads.append(("text", pad))
                order.append(("pad", len(pads) - 1))
                grown += pad
            order.append(("fn", pat))
            plan.append((target, pat))
            at = target + size
        tail = (-grown) % OCACHE
        if tail:
            pads.append(("text", tail))
            order.append(("pad", len(pads) - 1))
            grown += tail
    blocks = {}
    if data_path:
        before = len(plan)
        blocks, nwanted, dskipped = place_data(map_path, data_path, pads, plan)
        dplaced = len(plan) - before
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "order.ld"), "w") as f:
        if placement_path != "-":
            f.write(".text : {\n  *_kos_startup.o(.text)\n")
            for kind, what in order:
                f.write(f"  KEEP(*(.text.rxpad.{what}))\n" if kind == "pad" else f"  {what}\n")
            f.write("}\n")
        for sec in (".data", ".bss"):
            if sec not in blocks:
                continue
            entries, rest = blocks[sec]
            f.write(f"{sec} : {{\n  . = ALIGN(0x4000);\n")
            for kind, what in entries:
                f.write(f"  KEEP(*({sec}.rxpad.{what}))\n" if kind == "pad" else f"  {what}\n")
            # The rest from a boundary of its own too, so the colours it has do not depend on the
            # placed variables before it.
            f.write("  . = ALIGN(0x4000);\n")
            for pat, _ in rest:
                f.write(f"  {pat}\n")
            if sec == ".bss":
                f.write("  *(COMMON)\n  . = ALIGN(0x4000);\n")
            f.write("}\n")
    with open(os.path.join(out, "pad.s"), "w") as f:
        f.write("! Padding for scripts/dc-layout.py's order.ld: never executed, never read.\n")
        for k, (kind, n) in enumerate(pads):
            flags = '"ax",@progbits' if kind == "text" else ('"aw",@progbits' if kind == "data" else '"aw",@nobits')
            f.write(f"\t.section .{kind}.rxpad.{k},{flags}\n\t.p2align 0\n"
                    f"\t.globl rxpad_{k}\nrxpad_{k}:\n\t.space {n}\n")
    with open(os.path.join(out, "keep.txt"), "w") as f:
        f.write(" ".join(f"-Wl,-u,rxpad_{k}" for k in range(len(pads))) + "\n")
    with open(os.path.join(out, "plan.txt"), "w") as f:
        for target, pat in plan:
            f.write(f"{target:08x} {pat}\n")
    if placement_path != "-":
        print(f"{len(plan) - (dplaced if data_path else 0)} sections placed ({renamed} under a new chunk's "
              f"name, {skipped} not in this link), .text grows {grown} bytes")
    if data_path:
        print(f"{dplaced} of {nwanted} variables placed ({dskipped} not unique or not in this link), "
              f"{sum(n for k, n in pads if k != 'text')} bytes of data padding")


def generated_key(pat):
    """What a generated function's section is, whichever chunk holds it: the chunk's kind (`Fns`, an
    overlay's `Ovl_<id>`, a relocatable group's `Rel_<id>`), the function and its signature, read
    from the Itanium name's length-prefixed parts (hex chunk names make a pattern ambiguous); None
    for any other section."""
    m = re.match(r"^\*\(\.text\._ZN(.*)\)$", pat or "")
    if m is None:
        return None
    s, i, parts = m.group(1), 0, []
    while len(parts) < 2 and i < len(s) and s[i].isdigit():
        j = i
        while j < len(s) and s[j].isdigit():
            j += 1
        n = int(s[i:j])
        parts.append(s[j:j + n])
        i = j + n
    if len(parts) != 2 or i >= len(s) or s[i] != "E":
        return None
    cls, fn = parts
    if not re.match(r"^(Fns|Ovl_\w+|Rel_\w+)_\d+_[0-9a-f]+$", cls) or not fn.startswith("f_"):
        return None
    return (re.sub(r"_\d+_[0-9a-f]+$", "", cls), fn, s[i:])


def generated_aliases(named):
    """generated_key -> this link's pattern, for each generated function the link has once."""
    seen = {}
    for pat in named:
        key = generated_key(pat)
        if key is not None:
            seen.setdefault(key, []).append(pat)
    return {k: v[0] for k, v in seen.items() if len(v) == 1}


def section_of(pat):
    """The input section a placement's pattern names when the name alone names it (`*(name)`), or
    None: dc-ocache-sim matches items by name, so a name qualified by its object (`.text` of a
    library member, `*lib.a:member.o(.text)`) would stand for every section of that name."""
    m = re.match(r"^\*\(([^()]+)\)$", pat)
    return m.group(1) if m else None


def cmd_halves_items(args):
    placement, data = args
    with open(data) as f:
        for line in f:
            p = line.split()
            if len(p) == 2 and not line.startswith("#"):
                print(f"{p[1]} ={int(p[0]) % 512}")
    with open(placement) as f:
        for line in f:
            p = line.split()
            if len(p) != 2 or line.startswith("#"):
                continue
            sec = section_of(p[1])
            if sec:
                print(f"{sec} ~{int(p[0].lstrip('=')) % 256}")


def cmd_halves_apply(args):
    placement, dopt = args
    chosen = {}
    with open(dopt) as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                chosen[p[1]] = int(p[0])
    with open(placement) as f:
        for line in f:
            p = line.split()
            if len(p) == 2 and not line.startswith("#"):
                sec = section_of(p[1])
                if sec in chosen:
                    c = chosen[sec]
                    if c % 256 != int(p[0].lstrip("=")) % 256:
                        sys.exit(f"{sec}: dopt's colour {c} is not the instruction cache's {p[0]}")
                    print(f"={c} {p[1]}")
                    continue
                print(f"{p[0].lstrip('=')} {p[1]}" if p[0].startswith("=") else line.rstrip("\n"))
                continue
            print(line.rstrip("\n"))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "sections" and len(args) in (1, 2):
        cmd_sections(args)
    elif cmd == "export" and len(args) == 2:
        cmd_export(args)
    elif cmd == "place" and len(args) in (3, 4):
        cmd_place(args)
    elif cmd == "check" and len(args) == 2:
        cmd_check(args)
    elif cmd == "objects" and len(args) == 1:
        cmd_objects(args)
    elif cmd == "halves-items" and len(args) == 2:
        cmd_halves_items(args)
    elif cmd == "halves-apply" and len(args) == 2:
        cmd_halves_apply(args)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
