#!/usr/bin/env python3
"""scripts/dc-polyrun.py — the GPU's SH-4 polygon core (ADR-0047) against Gpu.polygonHw, offline.

    scripts/dc-polyrun.py <object> [--n N] [--seed S]

Runs the core (scripts/sh4/poly.blk, assembled: `scripts/dc-sched.py scripts/sh4/poly.blk poly.s &&
sh-elf-as -little -isa=sh4 poly.s -o poly.o`) in scripts/dc-shrun.py's SH-4 interpreter over N
generated packets and GPU states, with what the C++ around it does — the state the core leaves when it
answers 2 (bp_gpu_state_w), the record from the twelve words it leaves (bp_gpu_tri_w),
the second triangle of a quad through _recompsx_gpu_poly2 —
and compares the whole outcome with a transcription of the C form (polygonHw, triPacket,
triangleWork, pixelWork, triState, sendState, setClut, setTexPage): GPU words 0-35 and the
backend's calls (gpuState, gpuTri), in order. The packets mix the cases: every command 20h-3Fh,
positions on and off the drawing area, too wide and too tall, lines, coordinates with stray high
bits, palettes and pages new and kept, states sent and not, packets that could wrap at the end of
RAM (which the core declines). Each path is timed with the cache model's issue rules.
"""
import importlib.util, os, random, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('shrun', os.path.join(HERE, 'dc-shrun.py'))
sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)
M32 = 0xFFFFFFFF
RAM_HOST, G_HOST, STACK = 0x20000000, 0x10000000, 0x30001000

def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v

def sext11(v):
    v &= 0x7FF
    return v - 0x800 if v & 0x400 else v

class Ref:
    """The C form, from src/runtime/gpu/Gpu.hx (the hardware path: hw, not offscreen)."""
    def __init__(self, G, ram):
        self.G, self.ram, self.calls = list(G), ram, []
    def rd(self, off): return self.ram.get(off & 0x1FFFFC, 0)
    def set_clut(self, a):
        G = self.G; G[26] = (a & 0x3F) << 4; G[27] = (a >> 6) & 0x1FF; G[1] = a & 0x7FFF
    def set_tex_page(self, a):
        G = self.G
        G[23] = (a & 0x0F) << 6; G[24] = ((a >> 4) & 1) << 8; G[28] = (a >> 5) & 3
        G[25] = (a >> 7) & 3; G[0] = a & 0x1FF
    def poly(self, at, op):
        G = self.G
        at0 = at & 0x1FFFFC
        textured = (op & 4) != 0
        step = (1 + (1 if textured else 0) + (1 if op & 0x10 else 0)) << 2
        first = at0 + 4
        if textured:
            ca = (self.rd(first + 4) >> 16) & 0xFFFF
            if (ca & 0x7FFF) != G[1]: self.set_clut(ca)
            tp = (self.rd(first + step + 4) >> 16) & 0xFFFF
            if (tp & 0x1FF) != G[0]: self.set_tex_page(tp)
        G[16] = 1 if textured else 0; G[17] = op & 1; G[18] = 1 if op & 2 else 0
        self.tri(at0, first, first + step, first + 2 * step, op)
        if op & 8: self.tri(at0, first + step, first + 2 * step, first + 3 * step, op)
    def tri(self, at0, a, b, c, op):
        G = self.G
        pa, pb, pc = self.rd(a), self.rd(b), self.rd(c)
        x0, y0 = s32(sext11(pa) + G[8]), s32(sext11(pa >> 16) + G[9])
        x1, y1 = s32(sext11(pb) + G[8]), s32(sext11(pb >> 16) + G[9])
        x2, y2 = s32(sext11(pc) + G[8]), s32(sext11(pc >> 16) + G[9])
        loX, hiX, loY, hiY = min(x0, x1, x2), max(x0, x1, x2), min(y0, y1, y2), max(y0, y1, y2)
        e = s32((x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0))
        if hiX - loX <= 1023 and hiY - loY <= 511 and e != 0:
            G[15] = s32(G[15] + 1)
            self.triangle_work(e, loX, hiX, loY, hiY)
            self.tri_state()
            gouraud = (op & 0x10) != 0
            tm = 0xFFFF if op & 4 else 0
            t = [self.rd(v + 4) & tm for v in (a, b, c)]
            col = [self.rd(v - 4 if gouraud else at0) & 0xFFFFFF for v in (a, b, c)]
            self.calls.append(('tri', x0, y0, col[0], t[0] & 0xFF, t[0] >> 8, x1, y1, col[1], t[1] & 0xFF,
                               t[1] >> 8, x2, y2, col[2], t[2] & 0xFF, t[2] >> 8))
    def triangle_work(self, twice, loX, hiX, loY, hiY):
        G = self.G
        l, t, r, b = G[10], G[11], G[12], G[13]
        w = (hiX if hiX < r else r) - (loX if loX > l else l) + 1
        h = (hiY if hiY < b else b) - (loY if loY > t else t) + 1
        box = s32(w * h) if w > 0 and h > 0 else 0
        area = (-twice if twice < 0 else twice) >> 1
        px = area if area < box else box
        c = (px >> 1) + (px >> 3) if G[16] else (px >> 2) + (px >> 4)
        G[14] = s32(G[14] + c + ((c >> 1) if G[18] else 0) + 16)
    def tri_state(self):
        G = self.G
        flags = (1 if G[16] else 0) | (2 if G[18] else 0) | (4 if G[17] else 0)
        if G[0] != G[2] or G[1] != G[3] or flags != G[4] or G[6] != G[19] or G[7] != G[5]:
            G[2] = G[0]; G[3] = G[1]; G[4] = flags; G[5] = G[7]
            self.send_state(flags)
    def send_state(self, flags):
        G = self.G
        a = s32(G[23] | (G[24] << 10) | (G[25] << 20) | (G[28] << 22) | (flags << 24))
        b = s32(G[26] | (G[27] << 10))
        area = s32(G[10] | (G[11] << 10))
        if a != G[20] or b != G[21] or G[6] != G[19] or area != G[22]:
            G[20] = a; G[21] = b; G[19] = G[6]; G[22] = area
            self.calls.append(('state', G[23], G[24], G[25], G[26], G[27], G[28], flags, G[6], G[10], G[11]))

class Core:
    def __init__(self, obj):
        self.code, self.poly, self.cdata = sr.load_object(obj, '_recompsx_gpu_poly')
        _, self.poly2, _ = sr.load_object(obj, '_recompsx_gpu_poly2')
    def run(self, entry, m):
        m.r[15] = STACK
        path = m.run(entry, limit=20000)
        if m.r[15] != STACK: raise SystemExit('stack moved')
        return m.r[0], path

def machine(core, ram, G):
    m = sr.Machine(core.code, core.cdata)
    m.mem.update(core.cdata)             # the section's data (the command table) where its code reads it
    for off, w in ram.items(): m.wr(RAM_HOST + off, 4, w)
    for i, w in enumerate(G): m.wr(G_HOST + 4 * i, 4, w)
    return m

def gen(rnd):
    """A packet and a GPU state: (ram {offset: word}, at, op, G[64])."""
    op = rnd.randrange(0x20, 0x40)
    if rnd.random() < 0.03: at = 0x1FFFFC - rnd.randrange(0, 60)       # near the end of RAM
    else: at = rnd.randrange(0, 0x1FFF00) & ~3
    at |= rnd.choice((0, 0x80000000, 0xA0000000, 0x00600000))           # segments and mirrors
    G = [0] * 64
    G[8], G[9] = rnd.choice((0, rnd.randrange(-1024, 1024))), rnd.choice((0, rnd.randrange(-1024, 1024)))
    L, T = rnd.choice((0, rnd.randrange(0, 600))), rnd.choice((0, rnd.randrange(0, 500)))
    R, B = L + rnd.choice((319, 511, 639, rnd.randrange(-50, 1024))), T + rnd.choice((239, 479, rnd.randrange(-50, 512)))
    G[10], G[11], G[12], G[13] = L, T, R, B
    G[14], G[15] = rnd.randrange(-2**31, 2**31), rnd.randrange(-2**31, 2**31)
    G[6], G[7] = rnd.choice((0, 0x1234)), rnd.choice((0, 0x40000))
    for i in (23, 24, 25, 26, 27, 28): G[i] = rnd.randrange(0, 1024)
    G[20], G[21], G[22] = rnd.randrange(0, 2**30), rnd.randrange(0, 2**20), rnd.randrange(0, 2**20)
    # vertices: near the screen mostly, sometimes wide, a line now and then, stray high bits
    def coord(lo, hi, wide):
        v = rnd.randrange(lo, hi) if not wide else rnd.randrange(-1024, 1024)
        v &= 0x7FF
        if rnd.random() < 0.1: v |= rnd.randrange(0, 32) << 11                 # bits 11-15 not a sign
        elif v & 0x400: v |= 0xF800
        return v
    wide = rnd.random() < 0.15
    cx, cy = rnd.randrange(-200, 900), rnd.randrange(-200, 700)
    spread = rnd.choice((8, 40, 200, 600, 1100))
    verts = []
    for k in range(4):
        x = coord(cx - G[8] - spread, cx - G[8] + spread, wide)
        y = coord(cy - G[9] - spread // 2, cy - G[9] + spread // 2, wide)
        verts.append(x | (y << 16))
    if rnd.random() < 0.05: verts[2] = verts[1]                            # a line
    at0 = at & 0x1FFFFC
    textured, gouraud = (op & 4) != 0, (op & 0x10) != 0
    words = [rnd.randrange(0, 2**32) & 0xFFFFFF | (op << 24)]
    clut, page = rnd.randrange(0, 0x10000), rnd.randrange(0, 0x10000)
    for k in range(4):
        if gouraud and k > 0: words.append(rnd.randrange(0, 2**24))
        words.append(verts[k])
        if textured:
            hi = clut if k == 0 else (page if k == 1 else rnd.randrange(0, 0x10000))
            words.append((hi << 16) | rnd.randrange(0, 0x10000))
    words += [rnd.randrange(0, 2**32) for _ in range(4)]
    ram = {}
    for k, w in enumerate(words): ram[(at0 + 4 * k) & 0x1FFFFC] = w
    # keys and sent state: the packet's own or not
    if textured and rnd.random() < 0.7: G[1] = clut & 0x7FFF
    else: G[1] = rnd.randrange(0, 0x8000)
    if textured and rnd.random() < 0.7: G[0] = page & 0x1FF
    else: G[0] = rnd.randrange(0, 0x200)
    flags = (1 if textured else 0) | (2 if op & 2 else 0) | (4 if op & 1 else 0)
    same = rnd.random() < 0.6
    G[2] = G[0] if same or rnd.random() < 0.5 else rnd.randrange(0, 0x200)
    G[3] = G[1] if same or rnd.random() < 0.5 else rnd.randrange(0, 0x8000)
    G[4] = flags if same or rnd.random() < 0.5 else rnd.randrange(0, 8)
    G[19] = G[6] if same or rnd.random() < 0.5 else 7
    G[5] = G[7] if same or rnd.random() < 0.5 else 9
    for i in (16, 17, 18): G[i] = rnd.randrange(0, 2)
    for i in range(29, 36): G[i] = rnd.randrange(0, 100)
    return ram, at, op, [s32(v) for v in G]

def main():
    args = sys.argv[1:]
    obj = args[0]
    n = int(args[args.index('--n') + 1]) if '--n' in args else 20000
    rnd = random.Random(int(args[args.index('--seed') + 1]) if '--seed' in args else 1)
    core = Core(obj)
    stats, cyc, bad = collections.Counter(), collections.Counter(), 0
    for i in range(n):
        ram, at, op, G = gen(rnd)
        ref = Ref(G, ram); ref.poly(at, op)
        m = machine(core, ram, G)
        m.r[4], m.r[5], m.r[6], m.r[7] = RAM_HOST, at & M32, op, G_HOST
        rc, path = core.run(core.poly, m)
        if rc == 1:
            stats['declined'] += 1
            same = all(s32(m.rd(G_HOST + 4 * k, 4)) == G[k] for k in range(64))
            if (at & 0x1FFFFC) <= 0x1FFFFC - 44 or not same:
                bad += 1; print('bad decline', i, hex(at), hex(op))
            continue
        # the C++ around the core: triState when it answers 2, the record from words 36-47
        flow = Ref([s32(m.rd(G_HOST + 4 * k, 4)) for k in range(64)], ram)
        at0 = at & 0x1FFFFC
        step = (1 + (1 if op & 4 else 0) + (1 if op & 0x10 else 0)) << 2
        def record(rc, first):
            # Gpu.triRecord: the state the core left in words 52-61 when it answers 2 (it did triState
            # and sendState itself: bp_gpu_state_w), then the backend's triangle from the twelve words
            # 36-47 (bp_gpu_tri_w)
            if rc == 3: return
            if rc == 2:
                flow.calls.append(('state',) + tuple(s32(m.rd(G_HOST + 4 * k, 4)) for k in range(52, 62)))
            elif rc != 0: raise SystemExit('rc %d' % rc)
            w = [s32(m.rd(G_HOST + 4 * k, 4)) for k in range(36, 48)]
            args = []
            for v in range(3):
                x, y, c, t = w[4 * v:4 * v + 4]
                args += [x, y, c & 0xFFFFFF, t & 0xFF, (t & M32) >> 8]
            flow.calls.append(('tri',) + tuple(args))
        record(rc, at0 + 4)
        kind = ('quad ' if op & 8 else '') + {0: 'drawn', 2: 'drawn, state', 3: 'rejected'}[rc]
        total = sr.timing(path)
        if op & 8:
            m.r[4], m.r[5], m.r[6], m.r[7] = RAM_HOST, at & M32, op, G_HOST
            rc2, path2 = core.run(core.poly2, m)
            flow.G = [s32(m.rd(G_HOST + 4 * k, 4)) for k in range(64)]
            record(rc2, at0 + 4 + step)
            total += sr.timing(path2)
        got = [s32(m.rd(G_HOST + 4 * k, 4)) for k in range(36)]
        for k in (2, 3, 4, 5, 19, 20, 21, 22): got[k] = flow.G[k]
        if got != ref.G[:36] or flow.calls != ref.calls:
            bad += 1
            if bad <= 5:
                diff = [(k, got[k], ref.G[k]) for k in range(36) if got[k] != ref.G[k]]
                print('MISMATCH %d at %x op %x rc %d words %s' % (i, at, op, rc, diff[:8]))
                print('  core ', flow.calls)
                print('  C    ', ref.calls)
        stats[kind] += 1; cyc[kind] += total
    print(stats, 'mismatches', bad)
    for k in sorted(stats):
        if k in cyc: print('%-20s %6.1f cycles on average' % (k, cyc[k] / stats[k]))

if __name__ == '__main__':
    main()
