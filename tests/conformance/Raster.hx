/**
	Cross-target conformance for the triangle rasteriser.

	Coverage is decided by three integer edge functions and a sign test, and every part of that is
	a place the two targets can disagree without either looking wrong on its own: an intermediate
	that overflows wraps on C++ and grows into a double on JavaScript, a shift of a negative number
	is only arithmetic if it is written to be, and the tie-break on a shared edge decides whether a
	pixel belongs to one triangle, both, or neither. None of it shows up as a crash. It shows up as
	a game whose pixel count differs between targets by a few percent, which is exactly how this
	test came to exist.

	Driven through `writeGp0` with real packets rather than by calling the rasteriser, because the
	packet decode — vertex stride, gouraud colour words, the drawing offset — is part of what
	decides where a triangle lands, and a test that skipped it would pin half the answer.

	The digest covers the framebuffer itself, not just the counters: two rasterisers can write the
	same number of pixels in different places.
**/
class Raster {
	static inline var W = 1024;
	static inline var H = 512;

	/** A deterministic source of test geometry. Integer LCG — no host randomness anywhere. */
	static var seed = 0x13579BDF;

	static function next(bound:Int):Int {
		// Numerical Recipes' constants, wrapped exactly as ADR-0004 requires.
		seed = (shim.IntMath.mul(seed, 1664525) + 1013904223) | 0;
		return shim.IntMath.mod(seed >>> 8, bound);
	}

	public static function main():Void {
		Conf.feedName("Raster");
		mem.Memory.init();
		gpu.Gpu.init();

		// A drawing area that is not the whole of VRAM, so clipping is exercised, and an offset
		// that is not zero, so the signed-11 decode is too.
		gp0(0xE3000000 | (16 | (8 << 10)));          // draw area top-left
		gp0(0xE4000000 | (600 | (400 << 10)));       // draw area bottom-right
		gp0(0xE5000000 | (24 | (12 << 11)));         // draw offset

		exactTiling();
		flatTriangles();
		gouraudTriangles();
		sharedEdges();
		extremeCoordinates();
		quads();

		Conf.expect("something was drawn", gpu.Gpu.primitives > 0 ? 1 : 0, 1);
		Conf.feed(gpu.Gpu.primitives);
		Conf.feed(gpu.Gpu.pixels);
		feedVram();

		Conf.report("Raster");
	}

	/** Ordinary opaque triangles across the drawing area, including some that fall outside it. */
	static function flatTriangles():Void {
		for (i in 0...120) {
			gp0(0x20000000 | rgb());
			vertex(next(700) - 40, next(500) - 40);
			vertex(next(700) - 40, next(500) - 40);
			vertex(next(700) - 40, next(500) - 40);
		}
	}

	/**
		Gouraud triangles, whose three colour words are the interpolation this rasteriser will grow.

		Pinned now, while every vertex of a triangle still paints the same colour, so that the day
		interpolation lands the digest moves once, deliberately, and not again.
	**/
	static function gouraudTriangles():Void {
		for (i in 0...120) {
			gp0(0x30000000 | rgb());
			vertex(next(700) - 40, next(500) - 40);
			gp0(rgb());
			vertex(next(700) - 40, next(500) - 40);
			gp0(rgb());
			vertex(next(700) - 40, next(500) - 40);
		}
	}

	/**
		Two triangles forming a rectangle must cover it exactly once.

		The sharpest statement of a fill rule there is: `w*h` pixels, not one more and not one
		fewer. Every pixel along the shared diagonal is claimed by exactly one of the two, so the
		count is the area — overdraw shows as a surplus, a gap as a shortfall, and both are
		invisible on an opaque surface while being a bright or dark line on a blended one.
	**/
	static function exactTiling():Void {
		final before = gpu.Gpu.pixels;
		gp0(0x20FFFFFF);
		vertex(100, 100); vertex(200, 100); vertex(100, 180);
		gp0(0x20FFFFFF);
		vertex(200, 100); vertex(200, 180); vertex(100, 180);
		Conf.expect("two triangles tile their rectangle exactly once",
			gpu.Gpu.pixels - before, 100 * 80);

		// And again with both wound the other way, which must not change the answer.
		final before2 = gpu.Gpu.pixels;
		gp0(0x20FFFFFF);
		vertex(300, 100); vertex(300, 180); vertex(400, 100);
		gp0(0x20FFFFFF);
		vertex(400, 100); vertex(300, 180); vertex(400, 180);
		Conf.expect("and the same with the opposite winding",
			gpu.Gpu.pixels - before2, 100 * 80);

		// Four rectangles meeting at a point: no pixel drawn twice, none missed.
		final before3 = gpu.Gpu.pixels;
		for (q in 0...4) {
			final ox = 100 + (q % 2) * 40, oy = 300 + shim.IntMath.div(q, 2) * 40;
			gp0(0x20FFFFFF);
			vertex(ox, oy); vertex(ox + 40, oy); vertex(ox, oy + 40);
			gp0(0x20FFFFFF);
			vertex(ox + 40, oy); vertex(ox + 40, oy + 40); vertex(ox, oy + 40);
		}
		Conf.expect("four rectangles meeting at a corner tile exactly",
			gpu.Gpu.pixels - before3, 4 * 40 * 40);
	}

	/**
		Two triangles meeting along an exact shared edge, which is where a fill rule is decided.

		Drawn both ways round, so a rule that depends on winding shows up. Pixels on the seam belong
		to one of them, both, or neither; whichever this rasteriser chooses, both targets must
		choose the same, and overdraw on the seam is visible in `pixels` even when the framebuffer
		looks identical.
	**/
	static function sharedEdges():Void {
		for (i in 0...40) {
			final x = next(500), y = next(300);
			final w = 8 + next(120), h = 8 + next(90);
			gp0(0x20000000 | rgb());
			vertex(x, y); vertex(x + w, y); vertex(x, y + h);
			gp0(0x20000000 | rgb());
			vertex(x + w, y); vertex(x + w, y + h); vertex(x, y + h);
			// The same pair with the opposite winding.
			gp0(0x20000000 | rgb());
			vertex(x, y + h); vertex(x + w, y); vertex(x, y);
		}
	}

	/**
		Coordinates at the edges of what the packet can express, where an overflow would live.

		The signed-11 field spans -1024..1023 and the drawing offset adds as much again, so an edge
		function multiplies differences of up to about four thousand. That product is nowhere near
		the 32-bit ceiling — but "nowhere near" is a claim, and this is what checks it rather than
		asserting it, including the degenerate cases (zero area, a single point, a line) that make a
		rasteriser divide by zero or run a loop backwards.
	**/
	static function extremeCoordinates():Void {
		final ext = [-1024, -1023, -512, -1, 0, 1, 511, 1022, 1023];
		for (a in 0...ext.length) {
			for (b in 0...ext.length) {
				gp0(0x20000000 | rgb());
				vertex(ext[a], ext[b]);
				vertex(ext[b], ext[a]);
				vertex(ext[(a + 3) % ext.length], ext[(b + 5) % ext.length]);
			}
		}
		// Degenerate: no area at all, then two points, then a horizontal sliver.
		gp0(0x20FF00FF); vertex(100, 100); vertex(100, 100); vertex(100, 100);
		gp0(0x2000FF00); vertex(200, 150); vertex(300, 150); vertex(250, 150);
		gp0(0x200000FF); vertex(50, 60); vertex(400, 61); vertex(400, 60);
	}

	/** Quads, which are two triangles sharing the middle edge — the seam case again, by another route. */
	static function quads():Void {
		for (i in 0...60) {
			final x = next(500), y = next(300);
			gp0(0x28000000 | rgb());
			vertex(x, y);
			vertex(x + 10 + next(100), y);
			vertex(x, y + 10 + next(80));
			vertex(x + 10 + next(100), y + 10 + next(80));
		}
	}

	// ---- helpers -----------------------------------------------------------------------------------

	static inline function gp0(word:Int):Void {
		gpu.Gpu.writeGp0(word);
	}

	static inline function vertex(x:Int, y:Int):Void {
		gpu.Gpu.writeGp0((x & 0x7FF) | ((y & 0x7FF) << 16));
	}

	static function rgb():Int {
		return next(256) | (next(256) << 8) | (next(256) << 16);
	}

	/**
		The framebuffer, folded a row at a time.

		Every pixel, not a sample: a rasteriser that is wrong in one corner is wrong, and a sample
		grid is exactly the kind of test that passes while the bug ships.
	**/
	static function feedVram():Void {
		for (y in 0...H) {
			var rowHash = 0;
			for (x in 0...W) rowHash = (shim.IntMath.mul(rowHash, 31) + gpu.Vram.get(x, y)) | 0;
			Conf.feed(rowHash);
		}
	}
}
