package gpu;

import cxx.CArray;
import cxx.num.UInt8;
import shim.IntMath;
import shim.RawMem;

/**
	The PS1 framebuffer: 1024 x 512 halfwords, one megabyte, and every pixel format the GPU
	produces is a view onto it. Colours are BGR555 with bit 15 doubling as the mask bit.

	Only the storage and the coordinate arithmetic live here. Rasterisation belongs in
	`gpu.Raster` (M4) and display timing in `gpu.Scanout`; keeping the buffer separate means the
	determinism hash and, later, save states have exactly one place to read from.
**/
class Vram {
	public static inline var WIDTH  = 1024;
	public static inline var HEIGHT = 512;
	public static inline var BYTES  = WIDTH * HEIGHT * 2;

	public static var data:CArray<UInt8>;

	public static function init():Void {
		data = RawMem.alloc(BYTES);
	}

	public static inline function get(x:Int, y:Int):Int
		return RawMem.get16(data, ((y & (HEIGHT - 1)) * WIDTH + (x & (WIDTH - 1))) * 2);

	public static inline function set(x:Int, y:Int, v:Int):Void
		RawMem.set16(data, ((y & (HEIGHT - 1)) * WIDTH + (x & (WIDTH - 1))) * 2, v);

	/** Packs 5-bit components into BGR555. */
	public static inline function rgb(r:Int, g:Int, b:Int):Int
		return (r & 0x1F) | ((g & 0x1F) << 5) | ((b & 0x1F) << 10);

	/**
		A deterministic test pattern, used before any real rasteriser exists to prove the whole
		chain — Haxe, generated C++, the shim, the C backend, the window — carries pixels end to
		end. `phase` shifts it so consecutive frames differ, which is what makes a per-frame hash
		worth comparing.
	**/
	public static function testPattern(w:Int, h:Int, phase:Int):Void {
		var y = 0;
		while (y < h) {
			final g = IntMath.div(y * 31, h - 1);
			var x = 0;
			while (x < w) {
				final r = IntMath.div(x * 31, w - 1);
				// A slow diagonal wash, integer-only so the pattern is identical on every target.
				final b = ((x + y + phase) >> 3) & 0x1F;
				set(x, y, rgb(r, g, b));
				x++;
			}
			y++;
		}

		// A moving marker: an obvious visual cue that frames are actually advancing.
		final mx = IntMath.mod(phase, w - 16);
		var by = 8;
		while (by < 24) {
			var bx = 0;
			while (bx < 16) { set(mx + bx, by, rgb(31, 31, 31)); bx++; }
			by++;
		}
	}
}
