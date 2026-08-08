package kernel;

import core.Runtime;
import mem.Memory;
import shim.Backend;
import shim.RawBuf;
import shim.RawMem;

/**
	Puts the game's own bytes into emulated RAM.

	Recompilation translates the *code*, but a PS-EXE is code and data in one image, and the data
	half still has to be there: jump tables, string literals, structure templates, the lot. Until
	it is, every load returns zero and the game runs on a memory full of nothing — which looks
	like a hundred unrelated bugs rather than one missing step.

	The payload lives at offset 0x800 in the file and belongs at the load address the header
	declares, both of which the recompiler already recorded in `GameInfo`. So this does not parse
	the header again: the tool read it at build time, and re-deriving facts at runtime is how the
	two drift apart.
**/
class ExeLoader {
	/** Loaded once, at init, so nothing allocates later. */
	public static function load(path:String, loadAddr:Int, size:Int):Bool {
		if (Backend.fileOpen(SLOT, path) != 0) return fail("cannot open " + path);
		else {}

		final available = Backend.fileSize(SLOT) - PAYLOAD_OFFSET;
		if (available < size) return fail("image is short: " + available + " bytes after the "
			+ "header, header declares " + size);
		else {}

		final staging = RawMem.alloc(size);
		final got = Backend.fileRead(SLOT, PAYLOAD_OFFSET, staging, size);
		Backend.fileClose(SLOT);
		if (got != size) return fail("short read: " + got + " of " + size);
		else {}

		copyIntoRam(staging, loadAddr, size);
		Runtime.noteOnce(0x10ADED, "loaded " + size + " bytes at " + hex(loadAddr));
		return true;
	}

	// Byte at a time through the memory map rather than into `Memory.ram` directly: the load
	// address is a virtual one, and letting the map fold it is what keeps this correct if a game
	// ever loads somewhere other than the obvious RAM window.
	static function copyIntoRam(src:RawBuf, addr:Int, size:Int):Void {
		var i = 0;
		while (i < size) {
			Memory.write8(addr + i, RawMem.get8(src, i));
			i++;
		}
	}

	static function fail(why:String):Bool {
		Backend.log(Backend.LOG_ERROR, "image not loaded: " + why);
		return false;
	}

	static inline var SLOT = 0;

	/** A PS-EXE header is 0x800 bytes; the payload follows it. */
	static inline var PAYLOAD_OFFSET = 0x800;

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
