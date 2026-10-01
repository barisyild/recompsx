#!/usr/bin/env python3
"""scripts/dc-cmp.py <exp> [<exp-b>] [--top N] — one dc-exp experiment by part, or two compared.

Reads out/_x_<exp>/model (scripts/dc-exp.sh) through scripts/dc-prof.py and puts each function's
time into ms a frame, the frames taken from the bench line in prof.log. What it compares is the
conflict-free time (the function's time less its instruction, operand and write-back conflicts):
how code changes are judged (docs/perf/dreamcast-ledger.md, How to measure), since the conflicts
move with the placement and not with the code.

  one experiment:   conflict-free ms a frame by part (generated code, backend, GTE, the GPU's
                    runtime, the DMA, the rest of the runtime, SPU and audio) and the top functions
  two experiments:  the change from the first to the second, by part — conflict-free, issue,
                    dependency stalls, and the fills that were not conflicts — and the functions
                    that changed most
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def part(name):
    if name.startswith(("Fns_", "FnTable", "Ovl_", "Rel_")):
        return "gen"
    if name.startswith("gte::"):
        return "gte"
    if name.startswith("gpu::"):
        return "gpu-rt"
    if name.startswith("dma::"):
        return "dma"
    if name.startswith("spu::") or name.startswith(("snd_", "samp_", "bp_spu", "aica")):
        return "spu/audio"
    if name.startswith(("core::", "mem::", "kernel::", "timers::", "cd::", "sio::", "mdec::",
                        "mod::", "__")):
        return "runtime"
    return "backend"


def load(exp):
    """{function: [ms, issue, dep, conflict-free, ifill less conflicts, ofill less conflicts]}, a frame."""
    model = os.path.join(ROOT, "out", "_x_" + exp, "model")
    log = open(os.path.join(model, "prof.log"), errors="replace").read()
    bench = re.findall(r"bench (\d+)\.\.(\d+)", log)
    if not bench:
        sys.exit(f"{exp}: no bench line in prof.log")
    frames = int(bench[-1][1]) - int(bench[-1][0])
    out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "dc-prof.py"),
                          os.path.join(model, "prof.txt"), os.path.join(model, "traced.elf"),
                          "--top", "100000"], capture_output=True, text=True).stdout
    fns = {}
    for line in out.splitlines():
        if not re.match(r"^\s*[0-9.]+%", line):
            continue
        p = line.split()
        nums, i = [], 1
        while i < len(p):
            try:
                nums.append(float(p[i]))
                i += 1
            except ValueError:
                break
        if len(nums) < 7:
            continue
        name = " ".join(p[i:]).replace(" [clone .part.0]", "").replace(" [clone .constprop.0]", "")
        ms, fi, fo, dep, ext, ic, oc = nums[:7]
        wb, wbc, sq = (nums[7], nums[8], nums[9]) if len(nums) >= 10 else (0, 0, 0)
        v = [ms, ms - fi - fo - dep - ext - wb - sq, dep, ms - ic - oc - wbc, fi - ic, fo - oc]
        o = fns.get(name, [0.0] * 6)
        fns[name] = [o[k] + v[k] / frames for k in range(6)]
    return fns


def main():
    args, top = [], 20
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--top":
            top = int(next(it))
        else:
            args.append(a)
    if not args:
        sys.exit(__doc__)
    a = load(args[0])
    if len(args) == 1:
        parts = {}
        for name, v in a.items():
            parts[part(name)] = parts.get(part(name), 0.0) + v[3]
        for p, v in sorted(parts.items(), key=lambda kv: -kv[1]):
            print(f"{p:10s} {v:6.2f}")
        print(f"{'sum':10s} {sum(parts.values()):6.2f}  (conflict-free ms a frame)")
        for name, v in sorted(a.items(), key=lambda kv: -kv[1][3])[:top]:
            print(f"{v[3]:6.3f} {part(name):10s} {name}")
        return
    b = load(args[1])
    rows = []
    for name in set(a) | set(b):
        x, y = a.get(name, [0.0] * 6), b.get(name, [0.0] * 6)
        rows.append((name, [y[k] - x[k] for k in range(6)], x[3], y[3]))
    parts = {}
    for name, d, _, _ in rows:
        s = parts.setdefault(part(name), [0.0] * 6)
        for k in range(6):
            s[k] += d[k]
    print(f"{'part':10s} {'cf':>7} {'issue':>7} {'dep':>7} {'ifill-nc':>8} {'ofill-nc':>8}")
    for p in sorted(parts):
        d = parts[p]
        print(f"{p:10s} {d[3]:+7.3f} {d[1]:+7.3f} {d[2]:+7.3f} {d[4]:+8.3f} {d[5]:+8.3f}")
    print(f"{'total':10s} {sum(d[3] for d in parts.values()):+7.3f}")
    for name, d, x, y in sorted(rows, key=lambda r: -abs(r[1][3]))[:top]:
        print(f"{d[3]:+.3f} cf (issue {d[1]:+.3f} dep {d[2]:+.3f} ifnc {d[4]:+.3f} ofnc {d[5]:+.3f})"
              f"  {x:.3f}->{y:.3f}  {name}")


main()
