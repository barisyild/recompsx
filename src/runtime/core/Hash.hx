package core;

import shim.IntMath;
import shim.RawBuf;
import shim.RawMem;

/**
	FNV-1a, 32-bit. This is the determinism instrument: hashing the scanout and the audio stream
	each frame turns "does it still behave identically" into a single comparable number, across
	runs, across machines and eventually across compile targets.

	It is not a security hash and does not need to be. What it needs to be is *exactly* the same
	arithmetic everywhere, which is why it is plain 32-bit integer work with no host dependencies.
**/
class Hash {
	public static inline var FNV_OFFSET = 0x811C9DC5;
	static inline var FNV_PRIME = 16777619;

	// IntMath.mul, not `*`. FNV-1a is defined on a 32-bit wrapping multiply; plain `*` wraps
	// correctly in C++ under -fwrapv but silently loses low bits in JavaScript once the exact
	// product passes 2^53, so the two targets computed different digests for identical input.
	// Caught by comparing them — which is the whole reason for keeping both.
	public static inline function byte(h:Int, b:Int):Int
		return IntMath.mul(h ^ (b & 0xFF), FNV_PRIME);

	public static inline function word(h:Int, w:Int):Int {
		var acc = byte(h, w);
		acc = byte(acc, w >>> 8);
		acc = byte(acc, w >>> 16);
		return byte(acc, w >>> 24);
	}

	/** Hashes `len` bytes starting at `offset`. */
	public static function region(h:Int, m:RawBuf, offset:Int, len:Int):Int {
		var acc = h;
		var i = 0;
		while (i < len) {
			acc = byte(acc, RawMem.get8(m, offset + i));
			i++;
		}
		return acc;
	}

	/** Hashes a rectangle of a halfword buffer with a row pitch — the shape a framebuffer has.
	    Hashing only the visible rectangle, rather than all of VRAM, keeps the digest meaningful:
	    it changes when the picture changes, not when scratch areas do. */
	public static function rect(h:Int, m:RawBuf, pitchHalfwords:Int, x:Int, y:Int, w:Int, hgt:Int):Int {
		var acc = h;
		var row = 0;
		while (row < hgt) {
			final base = ((y + row) * pitchHalfwords + x) * 2;
			var col = 0;
			while (col < w) {
				acc = byte(acc, RawMem.get8(m, base + col * 2));
				acc = byte(acc, RawMem.get8(m, base + col * 2 + 1));
				col++;
			}
			row++;
		}
		return acc;
	}

	/** Lowercase 8-digit hex, for logs and for pasting into PROGRESS.md. */
	public static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return out;
	}
}
