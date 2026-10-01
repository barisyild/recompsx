package gte;

import shim.IntMath;
import shim.MemA;

/**
	The GTE commands run where generated code issues them: NCLIP, AVSZ3, AVSZ4 and RTPS.

	Each is a handful of loads, one or two multiplies and a store, and as a call it paid the call
	— the return address saved, the caller's registers given up, the command's own prologue — for
	work shorter than that. Crash Bandicoot: Warped issues ~1,350 NCLIP and ~1,100 AVSZ3 a frame,
	Crash Bash ~1,150 and ~1,200. Header-only and forced inline (as `mem.Access` is), so every
	generated shard has the bodies; only the common case is here, the 64-bit forms stay `Gte`'s,
	out of line. The emitter calls these in optimized builds; `Gte.execute` and the reference build
	keep the `Gte.cmd*` entries, which do the same thing.

	RTPS is not small, but it is one vertex, and it was a call on every one: Crash Bandicoot:
	Warped's title screen transforms ~2,000 vertices a frame through it, and the call cost its
	prologue and epilogue (seven registers saved and restored), and the caller every CpuState field
	and span it held, which a call may have changed. Inlined, the sf and lm of the instruction are
	constants at each site, and the wide forms (rowsWide, screenWide, depthCueWide) stay out of line.
	RTPT, three vertices in one, stays `Gte.cmdRtpt`: at every one of its sites it would be three
	copies of the transform.

	What they leave out is the profiler's GTE bracket (`Gte.enter`/`leave`), which nothing emulated
	reads (the Dreamcast no longer brackets GTE commands at all).
**/
@:headerOnly
@:headerCode("#include \"recompsx_gte.h\"")
@:access(gte.Gte)
class GteQuick {
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function nclip():Void {
		Gte.flag = 0;
		final s0 = Gte.sxy0, s1 = Gte.sxy1, s2 = Gte.sxy2;
		final x0 = (s0 << 16) >> 16, y0 = s0 >> 16;
		final x1 = (s1 << 16) >> 16, y1 = s1 >> 16;
		final x2 = (s2 << 16) >> 16, y2 = s2 >> 16;
		// As Gte.nclip: two 32-bit products while every coordinate is within +-2^14.
		if (MemA.likely((((x0 + 0x4000) | (y0 + 0x4000) | (x1 + 0x4000) | (y1 + 0x4000) | (x2 + 0x4000)
				| (y2 + 0x4000)) & -0x8000) == 0)) {
			Gte.mac0 = IntMath.mul(x1 - x0, y2 - y0) - IntMath.mul(x2 - x0, y1 - y0);
		} else {
			Gte.nclipWide(x0, y0, x1, y1, x2, y2);
		}
	}

	/** Gte.cmdRtps: FLAG cleared, vertex 0 projected with the depth cue (Gte.rtps). */
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function rtps(sf:Int, lm:Bool):Void {
		Gte.flag = 0;
		final v = Gte.vxy0;
		Gte.project(sf, lm, (v << 16) >> 16, v >> 16, Gte.vz0, Gte.V0H, true);
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function avsz3():Void {
		Gte.flag = 0;
		final z = Gte.zsf3;
		if (MemA.likely(z >= -10922 && z <= 10922)) {
			final m = IntMath.mul(z, (Gte.sz1 & 0xFFFF) + (Gte.sz2 & 0xFFFF) + (Gte.sz3 & 0xFFFF));
			Gte.mac0 = m;
			Gte.otz = Gte.saturateSz3(m >> 12);
		} else {
			Gte.avsz3Wide();
		}
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function avsz4():Void {
		Gte.flag = 0;
		final z = Gte.zsf4;
		if (MemA.likely(z >= -8192 && z <= 8192)) {
			final m = IntMath.mul(z, (Gte.sz0 & 0xFFFF) + (Gte.sz1 & 0xFFFF) + (Gte.sz2 & 0xFFFF) + (Gte.sz3 & 0xFFFF));
			Gte.mac0 = m;
			Gte.otz = Gte.saturateSz3(m >> 12);
		} else {
			Gte.avsz4Wide();
		}
	}
}
