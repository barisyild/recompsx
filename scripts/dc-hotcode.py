#!/usr/bin/env python3
"""scripts/dc-hotcode.py <recompsx.elf> <recompsx.map> <HOTCODE.BIN> — the table the Dreamcast backend
lays its hot code out by at run time (ADR-0063, src/backend/dreamcast/dc_hotcode.c).

The backend samples where the emulation thread spends its time, and copies the hottest functions into an
arena of its own, each at the place in the 8 KB instruction cache where it meets least of what runs beside
it — what a JIT's code cache does by construction, done here for statically compiled code. A function can be
copied when nothing in it reaches outside it relative to the PC, and every word that holds its address can
then be pointed at the copy. Both come from the link's own relocations, which build-dc.sh keeps
(-Wl,-q, --emit-relocs):

  * a section is movable when it is ours (not KallistiOS's, the C or C++ library's, libgcc's, the startup or
    the placement's padding), and no PC-relative relocation in it reaches another section — a branch or a
    literal load the assembler could not resolve inside the function would point at the wrong place from a
    copy. The assembler resolves every PC-relative reference within a section itself, so a PC-relative
    relocation that survives is exactly such a reach;
  * a reference is the address of every 32-bit absolute relocation (R_SH_DIR32) in a loaded section whose
    target lies inside a movable section: the literal pools' call targets, the function tables' entries.
    The backend reads each such word when it moves code, and rewrites it when it points into a function it
    moved — the word's current value, so a pointer the program changed since the link is judged as it is.

The file: "RHC1", the anchor (the address of hotcode_anchor, so a table from another build is refused), the
section count, the reference count, the site cache's address and entry count (recompsx_fnsite: the generated
code's per-site answers, pointers the program fills at run time, rewritten too), then (start, size) per
movable section by start, then the references by address. Little-endian 32-bit words throughout.
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import importlib.util
_spec = importlib.util.spec_from_file_location("dclayout", os.path.join(HERE, "dc-layout.py"))
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)

R_SH_DIR32 = 1
# Relocations that are not addresses: none, alignment/relaxation markers, vtable bookkeeping.
NOT_A_REACH = {0, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35}
SHF_ALLOC, SHF_EXECINSTR = 0x2, 0x4
SHT_SYMTAB, SHT_RELA = 2, 4

# Objects whose code is not ours to move: KallistiOS and the libraries it links, the startup, the padding.
FOREIGN = re.compile(r"(libkallisti|kallistios|/kos/|libc\.a|libg\.a|libm\.a|libgcc|libstdc\+\+|libsupc\+\+|crt\w*\.o"
                     r"|_kos_startup\.o|pad\.s)", re.I)
# The relocator itself stays where the link put it (it rewrites the words its own code reads).
OWN = re.compile(r"\.text\.(hotcode_|hc_)")


def elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        sys.exit("not a 32-bit little-endian ELF")
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
    secs = []
    for i in range(shnum):
        name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from("<10I", data, shoff + i * shentsize)
        secs.append(dict(name=name, type=typ, flags=flags, addr=addr, off=off, size=size, link=link, info=info, entsize=entsize))
    strtab = secs[shstrndx]
    for s in secs:
        end = data.index(b"\0", strtab["off"] + s["name"])
        s["sname"] = data[strtab["off"] + s["name"]:end].decode()
    return secs


def symbols(data, sec, secs):
    strtab = secs[sec["link"]]
    out = []
    for k in range(sec["size"] // 16):
        name, value, size, info, other, shndx = struct.unpack_from("<IIIBBH", data, sec["off"] + k * 16)
        end = data.index(b"\0", strtab["off"] + name)
        out.append((data[strtab["off"] + name:end].decode(errors="replace"), value, size, shndx))
    return out


def main():
    elf_path, map_path, out_path = sys.argv[1:4]
    data = open(elf_path, "rb").read()
    secs = elf_sections(data)
    rela = [s for s in secs if s["type"] == SHT_RELA]
    if not rela:
        sys.exit(f"{elf_path} has no relocations: link it with -Wl,-q (build-dc.sh does)")
    symtab = next(s for s in secs if s["type"] == SHT_SYMTAB)
    syms = symbols(data, symtab, secs)
    by_name = {}
    for name, value, size, shndx in syms:
        by_name.setdefault(name, (value, size))
    anchor = by_name.get("hotcode_anchor", by_name.get("_hotcode_anchor"))
    if anchor is None and "--any" in sys.argv:
        anchor = (0, 0)
    elif anchor is None:
        sys.exit("no hotcode_anchor in the ELF: a build without the run-time layout (RECOMPSX_HOTCODE)")
    site = by_name.get("recompsx_fnsite", by_name.get("_recompsx_fnsite", (0, 0)))

    start, text = L.parse_map(map_path)
    starts = [s[1] for s in text]
    import bisect

    def input_section(addr):
        k = bisect.bisect_right(starts, addr) - 1
        if k >= 0 and addr < text[k][1] + text[k][2]:
            return k
        return -1

    movable = [not FOREIGN.search(obj) and not OWN.match(name) and not name.startswith(".text.rxpad")
               for name, addr, size, obj in text]
    # The loaded sections' address ranges, for the references (debug sections hold addresses too).
    loaded = sorted((s["addr"], s["addr"] + s["size"]) for s in secs if s["flags"] & SHF_ALLOC and s["size"])
    lstarts = [a for a, b in loaded]

    def is_loaded(addr):
        k = bisect.bisect_right(lstarts, addr) - 1
        return k >= 0 and addr < loaded[k][1]

    reaches = 0
    absolute = []
    for rs in rela:
        target_sec = secs[rs["info"]]
        if not target_sec["flags"] & SHF_ALLOC:
            continue

        for k in range(rs["size"] // 12):
            off, info, addend = struct.unpack_from("<IIi", data, rs["off"] + k * 12)
            typ, sym = info & 0xFF, info >> 8
            if typ == R_SH_DIR32:
                # SH ELF keeps the addend in place (the linked word is the target, the RELA addend 0), so
                # the target is the word itself — what the backend reads too.
                at = off - target_sec["addr"]
                if target_sec["type"] != 8 and 0 <= at <= target_sec["size"] - 4:
                    absolute.append((off, struct.unpack_from("<I", data, target_sec["off"] + at)[0]))
                continue
            if typ not in NOT_A_REACH and target_sec["flags"] & SHF_EXECINSTR:
                # Any other relocation in code is a PC-relative reach the assembler left to the linker:
                # one that crosses into another section (within one it resolves them itself). Its
                # target is in place too, so the whole section is kept where it is, without asking.
                a = input_section(off)
                if a >= 0 and movable[a]:
                    movable[a] = False
                    reaches += 1
            else:
                pass
    moved = [k for k in range(len(text)) if movable[k]]
    refs = sorted(off for off, value in absolute
                  if is_loaded(off) and (lambda k: k >= 0 and movable[k])(input_section(value)))
    with open(out_path, "wb") as f:
        f.write(b"RHC1")
        f.write(struct.pack("<5I", anchor[0], len(moved), len(refs), site[0], site[1] // 8))
        for k in moved:
            f.write(struct.pack("<II", text[k][1], text[k][2]))
        for off in refs:
            f.write(struct.pack("<I", off))
    print(f"hotcode: {len(moved)} of {len(text)} code sections movable ({reaches} reach outside themselves "
          f"PC-relatively), {len(refs)} references, site cache {site[1] // 8} entries -> {out_path} "
          f"({os.path.getsize(out_path) // 1024} KB)")


if __name__ == "__main__":
    main()
