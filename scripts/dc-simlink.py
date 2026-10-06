#!/usr/bin/env python3
"""scripts/dc-simlink.py <link.map> <placement|-> [<sections-out>] — where a placement would put every .text
input section of a link, without linking: KallistiOS's startup first, the placed sections at their colours in
dc-layout.py place's order (its padding included), then every other section in the order the link had them,
each at its alignment. Writes dc-icache-sim's sections file ("oldstart size newstart", hex, by oldstart), so a
trace of <link.map>'s build judges the placement in seconds (ADR-0063: traces judge layouts, never make them).

A placement of "-" is the link itself (newstart = oldstart).
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dclayout", os.path.join(HERE, "dc-layout.py"))
L = importlib.util.module_from_spec(spec)
spec.loader.exec_module(L)


def simulate(map_path, placement_path):
    start, secs = L.parse_map(map_path)
    if placement_path == "-":
        return [(addr, size, addr) for _, addr, size, _ in secs]
    startup = next((s for s in secs if s[3].endswith("_kos_startup.o")), None)
    named = L.by_pattern(secs)
    aliases = L.generated_aliases(named)
    wanted = []
    for line in open(placement_path):
        if line.startswith("#") or not line.strip():
            continue
        colour, pat = line.split(None, 1)
        pat = pat.strip()
        if colour.startswith("="):
            w = (int(colour[1:]) % (L.OCACHE // L.LINE), L.OCACHE // L.LINE, pat)
        else:
            w = (int(colour), L.COLOURS, pat)
        if pat not in named:
            alt = aliases.get(L.generated_key(pat))
            if alt is not None:
                w = (w[0], w[1], alt)
        if w[2] in named:
            wanted.append(w)
    at = start + startup[2]
    new = {}
    todo = list(wanted)
    placed = set()

    def gap(w):
        colour, modulus, pat = w
        addr = named[pat][1]
        lead = addr % L.LINE
        first = (at - lead + L.LINE - 1) // L.LINE * L.LINE
        here = (first // L.LINE) % modulus
        return first + ((colour - here) % modulus) * L.LINE + lead - at

    grown = 0
    while todo:
        k = min(range(len(todo)), key=lambda i: gap(todo[i]))
        colour, modulus, pat = todo.pop(k)
        name, addr, size, obj = named[pat]
        lead = addr % L.LINE
        first = (at - lead + L.LINE - 1) // L.LINE * L.LINE
        here = (first // L.LINE) % modulus
        target = first + ((colour - here) % modulus) * L.LINE + lead
        grown += target - at
        new[addr] = target
        placed.add(addr)
        at = target + size
    # The tail pad: the growth of .text a multiple of 16 KB (dc-layout.py place), then the rest.
    at += (-grown) % L.OCACHE
    out = []
    for name, addr, size, obj in secs:
        if addr == startup[1]:
            out.append((addr, size, addr))
            continue
        if addr in placed:
            out.append((addr, size, new[addr]))
            continue
        align = L.section_align(obj, name, addr)
        at = (at + align - 1) // align * align
        out.append((addr, size, at))
        at += size
    return out


def main():
    map_path, placement = sys.argv[1], sys.argv[2]
    rows = simulate(map_path, placement)
    rows.sort()
    text = "".join(f"{a:x} {s:x} {n:x}\n" for a, s, n in rows)
    if len(sys.argv) > 3:
        open(sys.argv[3], "w").write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
