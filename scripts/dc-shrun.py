#!/usr/bin/env python3
"""scripts/dc-shrun.py — the GTE's SH-4 RTPS core (ADR-0046) run on recorded vertices.

    scripts/dc-shrun.py <object> <symbol> <samples>... [--max N] [--last 0|1]

Runs the core (its ABI: r4 the vertex's VXY word, r5 bit 0 lm, r6 the register file, r0 out) in a
small SH-4 interpreter over vertices recorded from the JavaScript build — Gte.project's inputs and
outputs, built with `-D recompsx_rtp_capture` (tests/spike/RtpCapture.hx) — and checks every word of
the register file against the reference: the outputs where the core returns 0, the inputs (but MAC1-3
and IR1-3, which the C form writes again) where it declines. Each path is timed with the cache
model's issue rules (scripts/dc-issue-sim.py). `--last` keeps the vertices with or without the depth
cue (the two entries, rtp1 and rtp1n). The object comes from assembling scripts/dc-sched.py's output:
    scripts/dc-sched.py scripts/sh4/rtp1.blk rtp1.s && sh-elf-as -little -isa=sh4 rtp1.s -o rtp1.o
"""
import importlib.util, re, struct, subprocess, sys, collections

import os
spec = importlib.util.spec_from_file_location('sim', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dc-issue-sim.py'))
sim = importlib.util.module_from_spec(spec); spec.loader.exec_module(sim)
OD = os.path.expanduser('~/toolchains/dc/sh-elf/bin/sh-elf-objdump')
M32 = 0xFFFFFFFF

def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v

# ---- the object: code by address, and section bytes for PC-relative loads ------------------------
def load_object(path, symbol):
    out = subprocess.run([OD, '-d', '--no-show-raw-insn', path], capture_output=True, text=True).stdout
    code, entry, section, cur = {}, None, None, None
    bysec = {}
    for line in out.split('\n'):
        m = re.match(r'^Disassembly of section (\S+):', line)
        if m: section = m.group(1); bysec.setdefault(section, {}); continue
        m = re.match(r'^([0-9a-f]{8}) <(.*)>:$', line)
        if m:
            if m.group(2) == symbol: entry = int(m.group(1), 16); cur = section
            continue
        m = re.match(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$', line)
        if m and section is not None:
            bysec[section][int(m.group(1), 16)] = (m.group(2), m.group(3).split('!')[0].strip())
    code = bysec.get(cur, {})
    raw = subprocess.run([OD, '-s', '-j', cur, path], capture_output=True, text=True).stdout
    data = {}
    for line in raw.split('\n'):
        m = re.match(r'^\s+([0-9a-f]+)\s+((?:[0-9a-f]{2,8}\s?)+)', line)
        if not m: continue
        a = int(m.group(1), 16)
        for word in m.group(2).split()[:4]:
            for k in range(0, len(word), 2):
                data[a] = int(word[k:k + 2], 16); a += 1
    return code, entry, data

class Machine:
    def __init__(self, code, data):
        self.code, self.cdata = code, data
        self.mem = {}
        self.r = [0] * 16
        self.T = 0; self.MACH = 0; self.MACL = 0; self.PR = 0
        self.FPUL = 0; self.FR = [0] * 16
    # memory: little-endian bytes in a dict; code bytes for PC-relative reads
    def rd(self, a, n, code=False):
        src = self.cdata if code else self.mem
        v = 0
        for k in range(n): v |= src.get(a + k, 0) << (8 * k)
        return v
    def wr(self, a, n, v):
        for k in range(n): self.mem[a + k] = (v >> (8 * k)) & 0xFF
    def reg(self, s): return int(s[1:])

    def run(self, entry, stop=0xDEAD0000, limit=5000):
        pc, pending, path = entry, None, []
        self.PR = stop
        for _ in range(limit):
            if pc == stop: return path
            mn, ops = self.code[pc]
            path.append((pc, mn, ops))
            nxt = pc + 2
            jump = self.step(pc, mn, ops)
            if pending is not None:
                nxt, pending = pending, None
            elif jump is not None:
                kind, tgt = jump
                if kind == 'delayed': pending = tgt
                else: nxt = tgt
            pc = nxt
        raise RuntimeError('no return')

    def step(self, pc, mn, ops):
        r = self.r
        src, dst = sim.split_ops(ops)
        src, dst = src.strip(), dst.strip()
        def val(s):
            return r[self.reg(s)]
        def setr(s, v): r[self.reg(s)] = v & M32
        def addr(s, size, write):
            s = s.strip()
            if s.startswith('@('):
                inner = s[2:-1]
                a_, b_ = [x.strip() for x in inner.split(',')]
                if a_ == 'r0': return (r[0] + val(b_)) & M32
                return (int(a_, 0) + val(b_)) & M32
            if s.startswith('@-'):
                n = self.reg(s[2:]); r[n] = (r[n] - size) & M32; return r[n]
            if s.endswith('+'):
                n = self.reg(s[1:-1]); a = r[n]; r[n] = (r[n] + size) & M32; return a
            return val(s[1:])
        if mn in ('mov.l', 'mov.w', 'mov.b'):
            size = {'mov.l': 4, 'mov.w': 2, 'mov.b': 1}[mn]
            m = re.match(r'^([0-9a-f]+) <', src)
            if m:   # PC-relative constant
                v = self.rd(int(m.group(1), 16), size, code=True)
                if size == 2 and v & 0x8000: v -= 0x10000
                setr(dst, v); return None
            if src.startswith('@'):
                a = addr(src, size, False)
                v = self.rd(a, size)
                if size == 2 and v & 0x8000: v -= 0x10000
                if size == 1 and v & 0x80: v -= 0x100
                setr(dst, v); return None
            v = val(src); a = addr(dst, size, True)
            self.wr(a, size, v); return None
        if mn == 'mova':
            setr(dst, int(src.split()[0], 16)); return None
        if mn == 'mov':
            setr(dst, int(src[1:], 0) if src.startswith('#') else val(src)); return None
        if mn in ('add', 'sub', 'and', 'or', 'xor'):
            a = int(src[1:], 0) if src.startswith('#') else val(src)
            b = val(dst)
            res = {'add': b + a, 'sub': b - a, 'and': b & a, 'or': b | a, 'xor': b ^ a}[mn]
            setr(dst, res); return None
        if mn == 'addv':
            t = s32(val(dst)) + s32(val(src))
            self.T = 1 if t > 0x7FFFFFFF or t < -0x80000000 else 0; setr(dst, t); return None
        if mn == 'lds' and dst == 'fpul': self.FPUL = val(src); return None
        if mn == 'sts' and src == 'fpul': setr(dst, self.FPUL); return None
        if mn == 'float':
            import struct as _st
            self.FR[int(dst[2:])] = _st.unpack('<I', _st.pack('<f', float(s32(self.FPUL))))[0]; return None
        if mn == 'flds': self.FPUL = self.FR[int(src[2:])]; return None
        if mn == 'fsts': self.FR[int(dst[2:])] = self.FPUL; return None
        if mn == 'addc':
            t = val(dst) + val(src) + self.T
            self.T = 1 if t > M32 else 0; setr(dst, t); return None
        if mn == 'subc':
            t = val(dst) - val(src) - self.T
            self.T = 1 if t < 0 else 0; setr(dst, t); return None
        if mn == 'neg': setr(dst, -val(src)); return None
        if mn == 'not': setr(dst, ~val(src)); return None
        if mn == 'tst':
            a = int(src[1:], 0) if src.startswith('#') else val(src)
            self.T = 1 if (a & val(dst)) == 0 else 0; return None
        if mn.startswith('cmp/'):
            op = mn[4:]
            if op in ('pz', 'pl'):
                v = s32(val(src)); self.T = 1 if (v >= 0 if op == 'pz' else v > 0) else 0; return None
            a = int(src[1:], 0) if src.startswith('#') else val(src)
            b = val(dst)
            if op == 'eq': self.T = 1 if (a & M32) == b else 0
            elif op == 'gt': self.T = 1 if s32(b) > s32(a) else 0
            elif op == 'ge': self.T = 1 if s32(b) >= s32(a) else 0
            elif op == 'hi': self.T = 1 if b > (a & M32) else 0
            elif op == 'hs': self.T = 1 if b >= (a & M32) else 0
            else: raise SystemExit('cmp ' + op)
            return None
        if mn == 'clrt': self.T = 0; return None
        if mn == 'sett': self.T = 1; return None
        if mn == 'movt': setr(ops, self.T); return None
        if mn in ('shll', 'shal'): v = val(ops); self.T = v >> 31; setr(ops, v << 1); return None
        if mn == 'shlr': v = val(ops); self.T = v & 1; setr(ops, v >> 1); return None
        if mn == 'shar': v = val(ops); self.T = v & 1; setr(ops, s32(v) >> 1); return None
        m = re.match(r'^sh(l|r)l?(\d+)$', mn) or re.match(r'^sh(ll|lr)(\d+)$', mn)
        if mn in ('shll2', 'shll8', 'shll16'): setr(ops, val(ops) << int(mn[4:])); return None
        if mn in ('shlr2', 'shlr8', 'shlr16'): setr(ops, val(ops) >> int(mn[4:])); return None
        if mn in ('shad', 'shld'):
            n = s32(val(src)); v = val(dst)
            if n >= 0: setr(dst, v << (n & 31))
            elif mn == 'shad': setr(dst, s32(v) >> ((-n) & 31) if (n & 31) else (-1 if s32(v) < 0 else 0))
            else: setr(dst, v >> ((-n) & 31) if (n & 31) else 0)
            return None
        if mn == 'exts.w': v = val(src) & 0xFFFF; setr(dst, v - 0x10000 if v & 0x8000 else v); return None
        if mn == 'exts.b': v = val(src) & 0xFF; setr(dst, v - 0x100 if v & 0x80 else v); return None
        if mn == 'extu.w': setr(dst, val(src) & 0xFFFF); return None
        if mn == 'extu.b': setr(dst, val(src) & 0xFF); return None
        if mn == 'swap.w': v = val(src); setr(dst, ((v >> 16) | (v << 16))); return None
        if mn == 'xtrct': setr(dst, (val(src) << 16) | (val(dst) >> 16)); return None
        if mn == 'mul.l': self.MACL = (val(src) * val(dst)) & M32; return None
        if mn == 'muls.w':
            a = val(src) & 0xFFFF; b = val(dst) & 0xFFFF
            a = a - 0x10000 if a & 0x8000 else a; b = b - 0x10000 if b & 0x8000 else b
            self.MACL = (a * b) & M32; return None
        if mn in ('dmuls.l', 'dmulu.l'):
            a, b = val(src), val(dst)
            if mn == 'dmuls.l': a, b = s32(a), s32(b)
            p = (a * b) & 0xFFFFFFFFFFFFFFFF
            self.MACH, self.MACL = p >> 32, p & M32; return None
        if mn == 'clrmac': self.MACH = self.MACL = 0; return None
        if mn == 'mac.w':
            a = addr(src, 2, False); b = addr(dst, 2, False)
            x = self.rd(a, 2); y = self.rd(b, 2)
            x = x - 0x10000 if x & 0x8000 else x; y = y - 0x10000 if y & 0x8000 else y
            acc = ((self.MACH << 32) | self.MACL)
            acc = acc - (1 << 64) if acc >> 63 else acc
            acc = (acc + x * y) & 0xFFFFFFFFFFFFFFFF
            self.MACH, self.MACL = acc >> 32, acc & M32; return None
        if mn == 'sts':
            setr(dst, self.MACL if src == 'macl' else self.MACH); return None
        if mn == 'sts.l':
            a = addr(dst, 4, True); self.wr(a, 4, self.PR); return None
        if mn == 'lds.l':
            a = addr(src, 4, False); self.PR = self.rd(a, 4); return None
        if mn == 'nop': return None
        if mn in ('bt', 'bf', 'bt.s', 'bf.s'):
            tgt = int(ops.split()[0], 16)
            take = (self.T == 1) == (mn[1] == 't')
            if not take: return None
            return ('delayed', tgt) if mn.endswith('.s') else ('now', tgt)
        if mn == 'bra': return ('delayed', int(ops.split()[0], 16))
        if mn == 'rts': return ('delayed', self.PR)
        raise SystemExit('shrun: unknown %s %s' % (mn, ops))

def timing(path):
    ready, now, last = {}, 0, 'CO'
    for pc, mn, ops in path:
        unit, issue, lat, rd, wr, base = sim.info(mn, ops)
        if last == 'CO' or unit == 'CO' or (last == unit and last != 'MT'):
            last, cyc = unit, issue
        else:
            last, cyc = 'CO', 0
        at = now
        for x in rd: at = max(at, ready.get(x, 0))
        for x in wr: ready[x] = at + lat
        for b in (base if isinstance(base, list) else ([base] if base else [])): ready[b] = at + 1
        now += cyc + (at - now)
    return now

def tables():
    unr = []
    for i in range(257):
        v = ((0x40000 // (i + 0x100)) + 1) // 2 - 0x101
        unr.append(v if v > 0 else 0)
    clz = []
    for i in range(256):
        n, v = 8, i
        while v: n -= 1; v >>= 1
        clz.append(n)
    return unr, clz

def main():
    args = sys.argv[1:]
    obj, sym = args[0], args[1]
    skip = set()
    for flag in ('--max', '--last'):
        if flag in args: skip.add(args.index(flag) + 1)
    files = [a for k, a in enumerate(args) if k >= 2 and not a.startswith('--') and k not in skip]
    limit = int(args[args.index('--max') + 1]) if '--max' in args else 10**9
    only_last = int(args[args.index('--last') + 1]) if '--last' in args else None
    code, entry, cdata = load_object(obj, sym)
    unr, clz = tables()
    G = 0x10000000
    stats = collections.Counter(); cycles = collections.Counter(); bad = 0; shown = 0
    for f in files:
        for n, line in enumerate(open(f)):
            if n >= limit: break
            v = [int(x) for x in line.split()]
            sf, lm, vh, last = v[0], v[1], v[2], v[3]
            before, rtp, after = v[4:85], v[85:90], v[90:171]
            if sf == 0: stats['sf0 (not the core\'s)'] += 1; continue
            if only_last is not None and last != only_last: continue
            m = Machine(code, cdata)
            for i, w in enumerate(before): m.wr(G + 4 * i, 4, w)
            for i, w in enumerate(rtp): m.wr(G + 4 * (648 + i), 4, w)
            for i, w in enumerate(unr): m.wr(G + 4 * (128 + i), 4, w)
            for i, w in enumerate(clz): m.wr(G + 4 * (392 + i), 4, w)
            m.r[15] = 0x20001000
            m.r[4], m.r[5], m.r[6] = G + 4 * (vh >> 1), 1 if lm else 0, G
            path = m.run(entry)
            rc = m.r[0]
            got = [s32(m.rd(G + 4 * i, 4)) for i in range(81)]
            want = [s32(x) for x in (after if rc == 0 else before)]
            if rc != 0:
                # MAC1-3 and IR1-3 are outputs only: a core may write them before it declines,
                # and the C path then writes them again
                for i in range(17, 23): got[i] = want[i]
            if got != want or m.r[15] != 0x20001000:
                bad += 1
                if shown < 5:
                    shown += 1
                    diff = [(i, got[i], want[i]) for i in range(81) if got[i] != want[i]]
                    print('MISMATCH rc=%d sample %s:%d lm=%d vh=%d last=%d words %s' % (rc, f, n, lm, vh, last, diff[:8]))
            key = 'done' if rc == 0 else 'declined'
            stats[key] += 1
            cycles[key] += timing(path)
    print(stats, 'mismatches', bad)
    for k in ('done', 'declined'):
        if stats[k]: print('%s: %.1f cycles on average' % (k, cycles[k] / stats[k]))

if __name__ == '__main__':
    main()
