/**
	Cross-target conformance for the video time base.

	Named `VideoTime`, not `Time`, and that is not taste. A root-package Haxe class compiles to a
	bare header — `Time.h` — and the generated include directory is on the compiler's `-I` path,
	so on a case-insensitive filesystem libc++'s `#include <time.h>` resolves to *this file*
	instead of the C library's. `time_t` then goes unresolved and `timespec` is an incomplete
	type, in translation units that never mentioned time at all. `scripts/check.sh` guards the
	whole class of collision.

	`TimeBase` answers where the beam is from nothing but the cycle count, so it is pure integer
	arithmetic and exactly the kind of thing that has to agree on both targets before anything
	leans on it (ADR-0005 §6). Every divergence this project has found so far came from a layer
	verified on one target and assumed on the other.

	What is probed: the derived constants, the beam position across a whole frame and past the
	wrap point, and the vblank edges — including the case that matters most, asking for the next
	vblank from *inside* one, where the answer has to be the following frame's.
**/
class VideoTime {
	public static function main():Void {
		for (region in 0...2) {
			core.TimeBase.setRegion(region == 1);
			Conf.feedName(region == 1 ? "pal" : "ntsc");

			// The derived constants. If these move, everything timed by them moved too.
			Conf.feed(core.TimeBase.cyclesPerLine());
			Conf.feed(core.TimeBase.cyclesPerFrame());

			probeFrame();
			probeEdges();
			probeWrap();
		}
		Conf.report("VideoTime");
	}

	/** Walk a frame at a fine step and record the beam position and blanking state. */
	static function probeFrame():Void {
		final frame = core.TimeBase.cyclesPerFrame();
		final step = shim.IntMath.div(frame, 64);
		var c = 0;
		while (c < frame) {
			Conf.feed(core.TimeBase.line(c));
			Conf.feed(core.TimeBase.intoFrame(c));
			Conf.feed(core.TimeBase.inVblank(c) ? 1 : 0);
			Conf.feed(core.TimeBase.evenOddBit(c));
			c += step;
		}
	}

	/**
		The vblank edges, asked from several points including from inside blanking.

		Asking for the next vblank while already in one is the case a naive implementation gets
		wrong — it must answer the *following* frame's, not the current cycle.
	**/
	static function probeEdges():Void {
		final frame = core.TimeBase.cyclesPerFrame();
		final line = core.TimeBase.cyclesPerLine();
		final probes = [
			0,
			line,
			shim.IntMath.mul(line, 100),
			shim.IntMath.mul(line, 255),          // last active line
			shim.IntMath.mul(line, 256),          // first blanking line
			shim.IntMath.mul(line, 260),          // well inside blanking
			frame - 1,
			frame,
			frame + 1
		];
		for (p in probes) {
			final start = core.TimeBase.nextVblankStart(p);
			final end = core.TimeBase.nextVblankEnd(p);
			Conf.feed(start);
			Conf.feed(end);
			// A deadline must be strictly ahead, or the scheduler would spin on it forever.
			Conf.feed(start - p > 0 ? 1 : 0);
			Conf.feed(end - p > 0 ? 1 : 0);
			// And the vblank that a start lands on must actually be one.
			Conf.feed(core.TimeBase.inVblank(start) ? 1 : 0);
		}
	}

	/**
		Past the wrap point.

		`cycles` is a plain Int and goes negative after about a minute of emulated time (ADR-0004),
		so the beam position has to stay in range there too — a negative remainder would put it on
		a line that does not exist.
	**/
	static function probeWrap():Void {
		final probes = [
			0x7FFFFF00, 0x7FFFFFFF, -0x80000000, -0x7FFFFFFF, -1000000, -1, 1
		];
		for (p in probes) {
			final l = core.TimeBase.line(p);
			Conf.feed(l);
			Conf.feed(core.TimeBase.intoFrame(p));
			// The invariant that matters: always a real line, whatever the sign of the input.
			Conf.feed(l >= 0 ? 1 : 0);
		}
	}
}
