#!/usr/bin/env python3
"""scripts/dc-trisrun.py — the scene build's run of textured triangles in assembly (dc_tris_uv) against
run_tris, offline.

    scripts/dc-trisrun.py <object> [--n N] [--seed S]

Runs the routine (scripts/sh4/tris.blk, assembled: `scripts/dc-sched.py scripts/sh4/tris.blk tris.s &&
sh-elf-as -little -isa=sh4 tris.s -o tris.o`) in scripts/dc-shrun.py's SH-4 interpreter, given the
single-precision instructions it uses, over N generated runs — records under the run's tag and
others, rows inside the cut and past it, colours that brighten and not, the run's header owed or
not, raw textures, the brightening header ready or not — and compares what it writes where the
store queue would be (its 32-byte blocks in order), the record it stops at, and the run's
`restate` and `half`, with a transcription of run_tris's textured branch for the common binding
(dc_scene.c: bgr_parts, tri_inside, put_tri_uv256_at, sq_header). Each run is timed with the cache
model's issue rules, as a cycles-per-triangle figure.
"""
import importlib.util, os, random, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('shrun', os.path.join(HERE, 'dc-shrun.py'))
sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)
M32 = 0xFFFFFFFF
REC, K, Q, UV, HDR, OVER, STACK = 0x10000000, 0x20000000, 0x30000000, 0x40000000, 0x50000000, 0x50000020, 0x60001000

def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def bits(x): return struct.unpack('<I', struct.pack('<f', x))[0]
def flt(b): return struct.unpack('<f', struct.pack('<I', b & M32))[0]

class FMachine(sr.Machine):
    """The interpreter with single precision: the FR registers hold their bits."""
    def step(self, pc, mn, ops):
        r = self.r
        if mn == 'pref': return None
        if mn == 'fldi1':
            self.FR[int(ops[2:])] = bits(1.0); return None
        if mn in ('fmul', 'fsub', 'fadd'):
            a, b = [x.strip() for x in ops.split(',')]
            m, n = int(a[2:]), int(b[2:])
            x, y = flt(self.FR[n]), flt(self.FR[m])
            self.FR[n] = bits(f32(x * y if mn == 'fmul' else (x - y if mn == 'fsub' else x + y))); return None
        if mn == 'fcmp/gt':
            a, b = [x.strip() for x in ops.split(',')]
            self.T = 1 if flt(self.FR[int(b[2:])]) > flt(self.FR[int(a[2:])]) else 0; return None
        if mn in ('fmov.s', 'fmov'):
            src, dst = [x.strip() for x in sr.sim.split_ops(ops)]
            def ea(s, write):
                if s.startswith('@('):
                    a_, b_ = [x.strip() for x in s[2:-1].split(',')]
                    return (r[0] + r[int(b_[1:])]) & M32
                if s.startswith('@-'):
                    n = int(s[3:]); r[n] = (r[n] - 4) & M32; return r[n]
                if s.endswith('+'):
                    n = int(s[2:-1]); a = r[n]; r[n] = (r[n] + 4) & M32; return a
                return r[int(s[2:])]
            if src.startswith('@'):
                self.FR[int(dst[2:])] = self.rd(ea(src, False), 4); return None
            if dst.startswith('@'):
                self.wr(ea(dst, True), 4, self.FR[int(src[2:])]); return None
            self.FR[int(dst[2:])] = self.FR[int(src[2:])]; return None
        return super().step(pc, mn, ops)

def parts(c):
    t = c & 0x808080; l = c ^ t; u = t - ((t + t) >> 8)
    return t, l, u

def swap_rb(c):
    x = c & 0x00FF00FF
    return ((x << 16 | x >> 16) & M32) | (c & 0xFF00)

def bgr_mod(c): return swap_rb(((c << 1) & 0x00FEFEFE) | (((c & 0x808080) << 1) - ((c & 0x808080) >> 7)))
def bgr_over(c):
    v = ((c & 0x007F7F7F) << 1) | 0x00010101
    return swap_rb(v & (((c & 0x808080) << 1) - ((c & 0x808080) >> 7)))
def brightens(c): return (c & ((c & 0x007F7F7F) + 0x007F7F7F) & 0x00808080) != 0

def reference(recs, end, k):
    """run_tris's textured branch at uv256, the C form: what it sends and where it stops."""
    out, c, restate = [], 0, k['restate']
    uv = [bits(f32((2 * i + 1) / 512.0)) for i in range(256)]
    while True:
        if c >= end: return c, out, restate, 0
        x, y, col, u, v, tag = recs[c]
        if tag != k['tag']: return c, out, restate, 0
        if any(yy < k['ylo_i'] or yy > k['yhi_i'] for yy in y): return c, out, restate, 0
        cols = [bgr_mod(cc) | k['a'] for cc in col]
        bright = any(brightens(cc) for cc in col)
        def tri(cs):
            for j in range(3):
                fx = f32(f32(float(x[j] - k['ox'])) * f32(k['sx']))
                fy = f32(f32(float(y[j] - k['oy'])) * f32(k['sy']))
                out.append([0xF0000000 if j == 2 else 0xE0000000, bits(fx), bits(fy), bits(1.0),
                            uv[u[j]], uv[v[j]], cs[j], 0])
        if restate:
            out.append(list(k['hdr'])); restate = 0
        tri(cols)
        if bright and not k['raw']:
            if not k['over_ready']: return c, out, restate, 1
            out.append(list(k['over'])); tri([bgr_over(cc) | k['a'] for cc in col]); restate = 1
        c += 1

def main():
    args = sys.argv[1:]
    obj = args[0]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 2000
    rnd = random.Random(int(args[args.index('--seed') + 1]) if '--seed' in args else 1)
    code, entry, cdata = sr.load_object(obj, '_dc_tris_uv')
    bad, shown, tris, cycles = 0, 0, 0, 0
    for it in range(n):
        tag = rnd.choice([3, 3, 3, 7, 100, 0x3FFF, 5])
        cnt = rnd.randrange(1, 9)
        ylo, yhi = (rnd.randrange(-40, 60), rnd.randrange(150, 260)) if rnd.random() < 0.7 else (-32768, 32767)
        if rnd.random() < 0.03: ylo, yhi = 32767, 32767
        recs = []
        for _ in range(cnt):
            def coord(lo, hi): return rnd.randrange(lo, hi)
            lo, hi = max(ylo, -2048), min(yhi, 2046)
            if lo > hi: lo, hi = -2048, 2046      # bounds no record can meet: every row outside
            yv = [coord(lo - 5, hi + 6) if rnd.random() < 0.08 else coord(lo, hi + 1) for _ in range(3)]
            xv = [coord(-1024, 1023) for _ in range(3)]
            def colour():
                ch = lambda: rnd.choice([0, 0x10, 0x7F, 0x80, 0x81, 0xC0, 0xFF, rnd.randrange(256)])
                return ch() | ch() << 8 | ch() << 16
            c0 = colour()
            col = [c0, c0, c0] if rnd.random() < 0.2 else [colour(), colour(), colour()]
            recs.append((xv, yv, col, [rnd.randrange(256) for _ in range(3)], [rnd.randrange(256) for _ in range(3)],
                         tag if rnd.random() < 0.9 else rnd.choice([1, 2, tag + 1, 0x4003, 0x8000 | tag])))
        k = dict(tag=tag, restate=rnd.choice([0, 0, 1]), raw=rnd.random() < 0.1, over_ready=rnd.random() < 0.7,
                 a=rnd.choice([0xFF000000, 0x80000000, 0]), ox=rnd.randrange(0, 700), oy=rnd.randrange(0, 300),
                 sx=rnd.choice([1.25, 1.0, 0.625, 1.5]), sy=rnd.choice([2.0, 1.0, 1.875]),
                 ylo_i=ylo, yhi_i=yhi, hdr=[rnd.randrange(1 << 32) for _ in range(8)],
                 over=[rnd.randrange(1 << 32) for _ in range(8)])
        end = cnt if rnd.random() < 0.8 else rnd.randrange(0, cnt + 1)
        want = reference(recs, end, k)
        m = FMachine(code, cdata)
        for i, (xv, yv, col, u, v, tg) in enumerate(recs):
            a = REC + 32 * i
            for j in range(3):
                m.wr(a + 2 * j, 2, xv[j] & 0xFFFF); m.wr(a + 6 + 2 * j, 2, yv[j] & 0xFFFF)
                m.wr(a + 12 + 4 * j, 4, col[j]); m.wr(a + 24 + j, 1, u[j]); m.wr(a + 27 + j, 1, v[j])
            m.wr(a + 30, 2, tg)
        for i in range(256): m.wr(UV + 4 * i, 4, bits(f32((2 * i + 1) / 512.0)))
        for i in range(8): m.wr(HDR + 4 * i, 4, k['hdr'][i]); m.wr(OVER + 4 * i, 4, k['over'][i])
        stag = tag - 0x10000 if tag & 0x8000 else tag
        words = [Q, stag & M32, k['restate'], (2 if k['raw'] else 0) | (4 if k['over_ready'] else 0), HDR, OVER,
                 0xE0000000, 0xF0000000, 0, k['a'], UV, 0x808080, 0x00FF00FF,
                 bits(float(k['ox'])), bits(float(k['oy'])), bits(f32(k['sx'])), bits(f32(k['sy'])),
                 bits(float(ylo)), bits(float(yhi))]
        for i, w in enumerate(words): m.wr(K + 4 * i, 4, w)
        m.r[15] = STACK
        m.r[4], m.r[5], m.r[6] = REC, REC + 32 * end, K
        path = m.run(entry, limit=200000)
        stop = (m.r[0] - REC) // 32
        q = m.rd(K, 4)
        blocks = [[m.rd(Q + 32 * (b + 1) + 4 * w, 4) for w in range(8)] for b in range((q - Q) // 32)]
        got = (stop, blocks, m.rd(K + 8, 4), m.rd(K + 32, 4))
        sregs = [m.r[i] for i in range(8, 15)]
        if got != want or m.r[15] != STACK:
            bad += 1
            if shown < 5:
                shown += 1
                print('MISMATCH run %d: stop %d/%d blocks %d/%d restate %d/%d half %d/%d' % (
                    it, got[0], want[0], len(got[1]), len(want[1]), got[2], want[2], got[3], want[3]))
                for b in range(min(len(got[1]), len(want[1]))):
                    if got[1][b] != want[1][b]:
                        print('  block %d: %s / %s' % (b, ' '.join('%08x' % w for w in got[1][b]), ' '.join('%08x' % w for w in want[1][b])))
                        break
        tris += max(1, want[0]); cycles += sr.timing(path)
    print('runs %d, mismatches %d; %.1f cycles a record taken' % (n, bad, cycles / tris))
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
