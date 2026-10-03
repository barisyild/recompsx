package gte;

import shim.IntMath;
import shim.MemA;

/**
	The GTE commands run where generated code issues them: NCLIP, AVSZ3, AVSZ4, RTPS, and DPCS and
	DPCT at sf = 1.

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

	DPCS, DPCT and INTPL pull a colour towards the far colour by IR0. As calls each paid the general form's
	prologue (seven registers saved) and its range tests for a few multiplies: Crash Bash depth-cues
	~580 colours a present with DPCS, Crash Bandicoot: Warped's gameplay ~360 with DPCT. Here the
	32-bit form only, at sf = 1, whenever the far colour allows it (`Gte.FC_WIDE`, kept by setCtrl).

	What they leave out is the profiler's GTE bracket (`Gte.enter`/`leave`), which nothing emulated
	reads (the Dreamcast no longer brackets GTE commands at all).
**/
@:headerOnly
@:headerCode("#include \"recompsx_arena.h\"")
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
		// As Gte.nclip: two 32-bit products while every coordinate is within +-2^14 (Gte.SXY_WIDE).
		if (MemA.likely(shim.GteFile.get(Gte.SXY_WIDE) == 0)) {
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

	/** Gte.cmdDpcs: FLAG cleared, RGBC's colour depth-cued (Gte.dpcs). */
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function dpcs(sf:Int, lm:Bool):Void {
		if (sf != 0 && MemA.likely(shim.GteFile.get(Gte.FC_WIDE) == 0)) {
			Gte.flag = 0;
			depthCue(Gte.rgbc, lm);
		} else Gte.cmdDpcs(sf, lm);
	}

	/** Gte.cmdDpct: FLAG cleared, the colour FIFO's bottom entry depth-cued three times, each push
		moving the next one down (Gte.dpct). */
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function dpct(sf:Int, lm:Bool):Void {
		if (sf != 0 && MemA.likely(shim.GteFile.get(Gte.FC_WIDE) == 0)) {
			Gte.flag = 0;
			depthCue(Gte.rgb0, lm);
			depthCue(Gte.rgb0, lm);
			depthCue(Gte.rgb0, lm);
		} else Gte.cmdDpct(sf, lm);
	}

	/**
		Gte.cmdIntpl: FLAG cleared, IR pulled towards the far colour by IR0 and pushed (Gte.intpl).
		The general form starts MAC at IR * 1000h, so at sf = 1 (FC * 1000h - MAC) SAR 12 is FC - IR
		exactly; with the far colour within +-2^18 (`Gte.FC_WIDE` clear) and IR and IR0 sixteen-bit,
		every sum is within 2^31 and no 44-bit flag can arise — farColorInterpolate's 32-bit form,
		which it takes for these inputs (and for a component at -2^18, which it sends the wide way,
		the same values). Crash Bash interpolates ~300 colours a frame this way.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function intpl(sf:Int, lm:Bool):Void {
		if (sf != 0 && MemA.likely(shim.GteFile.get(Gte.FC_WIDE) == 0)) {
			Gte.flag = 0;
			final ir0 = Gte.ir0;
			final a1 = Gte.ir1, a2 = Gte.ir2, a3 = Gte.ir3;
			final i1 = Gte.saturateIr(Gte.rfc - a1, false, Gte.F_IR1);
			final i2 = Gte.saturateIr(Gte.gfc - a2, false, Gte.F_IR2);
			final i3 = Gte.saturateIr(Gte.bfc - a3, false, Gte.F_IR3);
			final m1 = ((a1 << 12) + IntMath.mul(i1, ir0)) >> 12;
			final m2 = ((a2 << 12) + IntMath.mul(i2, ir0)) >> 12;
			final m3 = ((a3 << 12) + IntMath.mul(i3, ir0)) >> 12;
			Gte.mac1 = m1;
			Gte.mac2 = m2;
			Gte.mac3 = m3;
			Gte.pushColor(Gte.saturateColor(m1 >> 4, Gte.F_COLOR_R), Gte.saturateColor(m2 >> 4, Gte.F_COLOR_G),
				Gte.saturateColor(m3 >> 4, Gte.F_COLOR_B));
			Gte.ir1 = Gte.saturateIr(m1, lm, Gte.F_IR1);
			Gte.ir2 = Gte.saturateIr(m2, lm, Gte.F_IR2);
			Gte.ir3 = Gte.saturateIr(m3, lm, Gte.F_IR3);
		} else Gte.cmdIntpl(sf, lm);
	}

	/**
		One colour, the low three bytes of `c`, pulled towards the far colour by IR0 at sf = 1 and
		pushed: Gte.farColorInterpolate's 32-bit form from `startFromColor`, then finishColor. The
		start is the colour shifted 16, so (FC * 1000h - start) SAR 12 is FC - colour * 10h exactly,
		and with FC within +-2^18 and IR and IR0 sixteen-bit every sum is within 2^31. The first IR
		saturation ignores lm as the hardware's does (farColorInterpolate); the last obeys it.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function depthCue(c:Int, lm:Bool):Void {
		final r = c & 0xFF, g = (c >> 8) & 0xFF, b = (c >> 16) & 0xFF;
		final ir0 = Gte.ir0;
		final i1 = Gte.saturateIr(Gte.rfc - (r << 4), false, Gte.F_IR1);
		final i2 = Gte.saturateIr(Gte.gfc - (g << 4), false, Gte.F_IR2);
		final i3 = Gte.saturateIr(Gte.bfc - (b << 4), false, Gte.F_IR3);
		final m1 = ((r << 16) + IntMath.mul(i1, ir0)) >> 12;
		final m2 = ((g << 16) + IntMath.mul(i2, ir0)) >> 12;
		final m3 = ((b << 16) + IntMath.mul(i3, ir0)) >> 12;
		Gte.mac1 = m1;
		Gte.mac2 = m2;
		Gte.mac3 = m3;
		Gte.pushColor(Gte.saturateColor(m1 >> 4, Gte.F_COLOR_R), Gte.saturateColor(m2 >> 4, Gte.F_COLOR_G),
			Gte.saturateColor(m3 >> 4, Gte.F_COLOR_B));
		Gte.ir1 = Gte.saturateIr(m1, lm, Gte.F_IR1);
		Gte.ir2 = Gte.saturateIr(m2, lm, Gte.F_IR2);
		Gte.ir3 = Gte.saturateIr(m3, lm, Gte.F_IR3);
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
