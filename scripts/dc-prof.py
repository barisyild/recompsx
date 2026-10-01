#!/usr/bin/env python3
"""scripts/dc-prof.py <prof.txt> <recompsx.elf> [--top N] [--hot FUNC] [--lines FUNC] [--annotate FUNC]
                     [--nm PATH] [--frames N]

Reads a guest profile written by the profiling Flycast build (branch `recompsx-prof` of a local
Flycast clone: every SH4 timeslice records the PC it resumes at) and names where the cycles went,
with the ELF's own symbols.

The Dreamcast side asks for it: `--dc-bench=FROM:TO` with `--dc-rxprof` in recompsx.cfg prints
"@@rxprof start" / "@@rxprof stop" / "@@rxprof exit" on the serial port around that range of
presents, and the Flycast build records between the first two and quits at the third.

    --top N      functions to list (default 40)
    --hot FUNC   also list FUNC's hottest addresses (substring of the demangled name), with
                 the instruction at each — disassembled from the ELF
    --lines FUNC FUNC's samples by source line (addr2line over every sampled address), the
                 generated C++, runtime or backend line each came from, with its text
    --annotate FUNC  FUNC's whole disassembly, each instruction with its samples: the path a call
                 takes is the run of instructions with about the same count, and a wait shows as
                 a count several times its neighbours'
    --frames N   the recording's N frames (the bench range's length) as one line of ms a frame:
                 total, the conflict-free time (total less the conflict columns: what the frame
                 would be with every cache conflict placed away), issue, and each wait. How code
                 changes are compared (docs/perf/dreamcast-ledger.md, How to measure)

A profile recorded with RXPROF_CALLERS (scripts/dc-flycast-prof.sh --callers) also lists, for
each watched function, its callers by the return address.

A profile recorded under the cache model (scripts/dc-flycast-model.sh) has <prof.txt>.cache beside
it, and each function's time is then split into what it waited for: instruction-cache fills,
operand-cache fills, operand dependencies and uncached accesses (the rest is issue). With
<prof.txt>.cache.fa as well, the misses fully associative caches of the same sizes would have had,
two more columns give the fills that were conflicts (direct-mapped minus fully associative): the
part of each fill column that placing code and data decides.

A v2 model (rx_cache.cpp, 2026-09-30) also charges each instruction its operand write-backs and
store-queue bursts, and the fully associative cache its own write-backs: three more columns, wb,
wbc (write-backs that were conflicts) and sq, after oconf. Before v2 those were inside `issue`,
where a write-back a conflict caused made identical code look slower from one link to the next.
"""
import bisect
import os
import re
import subprocess
import sys


def load_profile(path):
    meta, samples = {}, []
    meta["callers"] = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                meta["kind"] = line.split()[-1]
                continue
            if line.startswith("caller "):
                _, lo, pr, n = line.split()
                meta["callers"].append((int(lo, 16), int(pr, 16), int(n)))
                continue
            a, b = line.split()
            if a in ("samples", "other", "timeslice", "cycles"):
                meta[a] = int(b)
            elif a == "wall_s":
                meta[a] = float(b)
            else:
                samples.append((int(a, 16), int(b)))
    return meta, samples


def load_costs(path):
    """<prof.txt>.cache from the cache model: per instruction address, in cycles, instruction
    fills, operand fills, dependency stalls, uncached accesses, and (v2) write-backs and
    store-queue bursts; None without one."""
    if not os.path.exists(path):
        return None
    costs, fill, wb, sq = {}, (0, 0), 0, 0
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                m = re.search(r"ifill (\d+) ofill (\d+) wb (\d+) sq (\d+)", line)
                if m:
                    fill = (int(m.group(1)), int(m.group(2)))
                    wb, sq = int(m.group(3)), int(m.group(4))
                continue
            p = line.split()
            w, q = (int(p[5]), int(p[6])) if len(p) >= 7 else (0, 0)
            costs[int(p[0], 16)] = (int(p[1]) * fill[0], int(p[2]) * fill[1], int(p[3]), int(p[4]),
                                    w * wb, q * sq)
    return costs


def load_fa(path):
    """<prof.txt>.cache.fa: per instruction address, in cycles, the instruction and operand fills
    fully associative LRU caches of the same sizes had, and (v2) the operand write-backs; None
    without one."""
    if not os.path.exists(path):
        return None
    fa, fill, wb = {}, (0, 0), 0
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                m = re.search(r"ifill (\d+) ofill (\d+)(?: wb (\d+))?", line)
                if m:
                    fill = (int(m.group(1)), int(m.group(2)))
                    wb = int(m.group(3)) if m.group(3) else 0
                continue
            p = line.split()
            fa[int(p[0], 16)] = (int(p[1]) * fill[0], int(p[2]) * fill[1], (int(p[3]) if len(p) >= 4 else 0) * wb)
    return fa


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
    top, hot, nm, nframes, lines, annotate = 40, None, None, None, None, None
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--top":
            top = int(args[i + 1]); i += 2
        elif args[i] == "--hot":
            hot = args[i + 1]; i += 2
        elif args[i] == "--lines":
            lines = args[i + 1]; i += 2
        elif args[i] == "--annotate":
            annotate = args[i + 1]; i += 2
        elif args[i] == "--nm":
            nm = args[i + 1]; i += 2
        elif args[i] == "--frames":
            nframes = int(args[i + 1]); i += 2
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
    costs = load_costs(prof + ".cache")
    fa = load_fa(prof + ".cache.fa") if costs is not None else None
    per_cost = {}
    if costs is not None:
        # per function: ifill ofill dep ext iconf oconf wb wbconf sq, in cycles
        for addr, c in costs.items():
            k = bisect.bisect_right(starts, addr) - 1
            if k >= 0 and addr < ends[k]:
                p = per_cost.setdefault(k, [0] * 9)
                for i in range(4):
                    p[i] += c[i]
                p[4] += c[0]
                p[5] += c[1]
                p[6] += c[4]
                p[7] += c[4]
                p[8] += c[5]
        for addr, c in (fa or {}).items():
            k = bisect.bisect_right(starts, addr) - 1
            if k >= 0 and addr < ends[k]:
                p = per_cost.setdefault(k, [0] * 9)
                p[4] -= c[0]
                p[5] -= c[1]
                p[7] -= c[2]
        if fa is None:
            for p in per_cost.values():
                p[4] = p[5] = p[7] = 0
        sums = [sum(p[i] for p in per_cost.values()) / 200e3 for i in range(9)]
        conf = f" (conflicts: ifill {sums[4]:.0f} ofill {sums[5]:.0f} wb {sums[7]:.0f})" if fa is not None else ""
        print(f"cache model: ifill {sums[0]:.0f} ofill {sums[1]:.0f} dep {sums[2]:.0f} ext {sums[3]:.0f} "
              f"wb {sums[6]:.0f} sq {sums[8]:.0f} ms{conf}")
        if nframes:
            tot = cycles / 200e3
            fa_ms = tot - (sums[4] + sums[5] + sums[7] if fa is not None else 0)
            waits = sums[0] + sums[1] + sums[2] + sums[3] + sums[6] + sums[8]
            # Time nothing was run for: KOS's idle thread, where bp_pace_frame sleeps when a present
            # is ahead of its vblank. Not the emulator's work; `work` is the conflict-free time less it.
            idle = sum(c for k, c in per_fn.items() if names[k] in ("thd_idle_task", "_thd_idle_task")) \
                * slice_ / 200e3
            print(f"a frame ({nframes}): total {tot / nframes:.2f}  conflict-free {fa_ms / nframes:.2f}  "
                  f"issue {(tot - waits) / nframes:.2f}  ifill {sums[0] / nframes:.2f} "
                  f"(conf {sums[4] / nframes:.2f})  ofill {sums[1] / nframes:.2f} (conf {sums[5] / nframes:.2f})  "
                  f"dep {sums[2] / nframes:.2f}  ext {sums[3] / nframes:.2f}  wb {sums[6] / nframes:.2f} "
                  f"(conf {sums[7] / nframes:.2f})  sq {sums[8] / nframes:.2f}  idle {idle / nframes:.2f}  "
                  f"work {(fa_ms - idle) / nframes:.2f} ms")
        extra = f" {'iconf':>6} {'oconf':>6}" if fa is not None else ""
        print(f"{'share':>6} {'ms@200MHz':>9} {'ifill':>6} {'ofill':>6} {'dep':>6} {'ext':>5}{extra} "
              f"{'wb':>5} {'wbc':>5} {'sq':>5}  function")
    else:
        print(f"{'share':>6} {'ms@200MHz':>9}  function")
    for k, count in sorted(per_fn.items(), key=lambda kv: -kv[1])[:top]:
        split = ""
        if costs is not None:
            p = per_cost.get(k, [0] * 9)
            cols = (p if fa is not None else p[:4] + p[6:])
            widths = (6, 6, 6, 5, 6, 6, 5, 5, 5) if fa is not None else (6, 6, 6, 5, 5, 5, 5)
            split = " " + " ".join(f"{v / 200e3:{w}.1f}" for v, w in zip(cols, widths))
        print(f"{100.0 * count / total:5.1f}% {count * slice_ / 200e3:9.1f}{split}  {names[k]}")
    def name_of(addr):
        k = bisect.bisect_right(starts, addr) - 1
        return names[k] if k >= 0 and addr < ends[k] else f"{addr:08x}"
    by_callee = {}
    for lo, pr, n in meta["callers"]:
        by_callee.setdefault(lo, {})
        caller = name_of(pr)
        by_callee[lo][caller] = by_callee[lo].get(caller, 0) + n
    for lo, callers in by_callee.items():
        n_all = sum(callers.values())
        print(f"\ncallers of {name_of(lo)} ({n_all} samples, by the return address):")
        for caller, n in sorted(callers.items(), key=lambda kv: -kv[1])[:12]:
            print(f"  {100.0 * n / n_all:5.1f}%  {caller}")
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
    def pick(sub):
        matches = [k for k in per_fn if sub in names[k]]
        if not matches:
            sys.exit(f"no sampled function matches {sub!r}")
        return max(matches, key=lambda m: per_fn[m])
    if lines:
        k = pick(lines)
        inside = [(a, c) for a, c in samples if starts[k] <= a < ends[k]]
        where = subprocess.run([os.path.join(tools, "sh-elf-addr2line"), "-e", elf]
                               + [f"{a:x}" for a, _ in inside], capture_output=True, text=True).stdout.split("\n")
        by, files = {}, {}
        for (a, c), loc in zip(inside, where):
            by[loc] = by.get(loc, 0) + c
        print(f"\n{names[k]} by source line ({per_fn[k]} samples):")
        for loc, c in sorted(by.items(), key=lambda kv: -kv[1])[:top]:
            f, _, ln = loc.rpartition(":")
            ln = re.sub(r"\D.*", "", ln)
            src = ""
            try:
                if f not in files:
                    files[f] = open(f, errors="replace").read().split("\n")
                src = files[f][int(ln) - 1].strip()[:100]
            except (OSError, ValueError, IndexError):
                pass
            print(f"  {100.0 * c / per_fn[k]:5.1f}%  {os.path.basename(f)}:{ln}  {src}")
    if annotate:
        k = pick(annotate)
        dis = subprocess.run([os.path.join(tools, "sh-elf-objdump"), "-d", "--no-show-raw-insn",
                              f"--start-address={starts[k]:#x}", f"--stop-address={ends[k]:#x}", elf],
                             capture_output=True, text=True).stdout
        count = dict((a, c) for a, c in samples if starts[k] <= a < ends[k])
        peak = max(count.values()) if count else 1
        print(f"\n{names[k]}, every instruction ({per_fn[k]} samples):")
        for line in dis.splitlines():
            head, _, ins = line.partition(":\t")
            try:
                a = int(head.strip(), 16)
            except ValueError:
                continue
            c = count.get(a, 0)
            print(f"  {a:08x} {c:8d} {'#' * (c * 30 // peak):30s} {ins.strip()[:80]}")


main()
