package kernel;

import core.Runtime;
import mem.Memory;

/**
	Which code is sitting in a window right now.

	A PlayStation game bigger than two megabytes keeps most of itself on the disc and loads pieces
	into a fixed window of RAM as it needs them. Those pieces are linked at their final address —
	nothing relocates them — so an overlay is exactly a pair: some bytes, and the window they go
	in. The recompiler compiles each one against the memory it will see and emits a table of
	addresses for it. This decides which of those tables is the live one.

	**The runtime installs nothing.** The game loads its own overlays, through hardware that is
	already emulated: a CD read, a DMA transfer, a kernel file read. By the time anything here
	runs, emulated RAM already holds the right bytes. The only thing that has to follow is the
	mapping from address to code, and that is all this does.

	Three signals, in order of how much they know:

	1. **A load happened.** Whatever a game writes into a window, the code that used to be there
	   is gone — even if what replaced it is artwork. So a load that overlaps a window *evicts*
	   whatever was resident. This is not an optimisation; it is the half of the problem that
	   fingerprints cannot see, because a window full of texture data matches nothing and must
	   still stop answering as the overlay it used to hold.

	2. **`FlushCache`.** Code written to RAM is invisible to a real machine's instruction cache
	   until the kernel is told to drop it, so every game that loads code calls this — whatever its
	   loader did, and however it did it. That makes it the one place where checking "what is
	   actually in each window" is *complete*: it catches a decompressor writing through the CPU,
	   which no amount of watching DMA ever would.

	3. **A dispatch missed.** If code asks for an address inside a window and nothing answers,
	   look once more before reporting it. A game whose loader we do not recognise still ends up
	   with the right bytes in the right place, and one rescan turns that into a working program
	   instead of a diagnostic.

	Recognition is a fingerprint: FNV-1a over the first words of the window, compared against the
	value the tool computed from the overlay's bytes at build time. The tool refuses to build a
	program whose overlays share one, so a match is an identification rather than a guess.
**/
class OverlayMgr {
	/** Enough for any PlayStation game; more would mean a design nobody has met. */
	static inline var MAX = 64;

	static var count = 0;
	static var lo:Array<Int>;
	static var hi:Array<Int>;
	static var fingerprint:Array<Int>;
	static var hashBytes:Array<Int>;
	static var resident:Array<Bool>;

	/** How many times an overlay has become, and stopped being, the answer for its window. */
	public static var activations(default, null) = 0;
	public static var evictions(default, null) = 0;

	/** Rescans that found nothing — the shape of a loader we do not understand. */
	public static var fruitlessRescans(default, null) = 0;

	public static function init():Void {
		lo = [for (_ in 0...MAX) 0];
		hi = [for (_ in 0...MAX) 0];
		fingerprint = [for (_ in 0...MAX) 0];
		hashBytes = [for (_ in 0...MAX) 0];
		resident = [for (_ in 0...MAX) false];
		loadFrom = [for (_ in 0...TRACKED) 0];
		loadTo = [for (_ in 0...TRACKED) 0];
		loadCount = 0;
		loadNext = 0;
		count = 0;
		activations = 0;
		evictions = 0;
		fruitlessRescans = 0;
	}

	/**
		Declares an overlay. Called once per overlay at boot, by the generated program.

		The runtime does not read the generated tables and the generated code does not implement
		any policy: it hands over four numbers, and asks `residentAt` which of its tables to use.
		That keeps this file compilable — and testable — with no generated code present at all,
		which is what lets a conformance test drive it.
	**/
	public static function define(index:Int, windowLo:Int, windowHi:Int, print:Int,
			hashWords:Int):Void {
		if (index < 0 || index >= MAX) return tooMany(index);
		else {}
		lo[index] = windowLo;
		hi[index] = windowHi;
		fingerprint[index] = print;
		hashBytes[index] = hashWords * 4;
		resident[index] = false;
		if (index >= count) count = index + 1;
		else {}
	}

	static function tooMany(index:Int):Void {
		Runtime.reportOnce(0x6E000000, "a program declared overlay " + index + ", past the "
			+ MAX + " this runtime holds");
	}

	// ---- asking ---------------------------------------------------------------------------------

	/**
		The overlay currently answering for an address, or -1.

		Linear over the declared overlays, which is a handful and mostly not resident. A game with
		many overlays still has few *windows*, and this is only reached on a dispatch the compiler
		could not resolve — never on a direct call.
	**/
	public static function residentAt(addr:Int):Int {
		for (i in 0...count) {
			if (resident[i] && addr >= lo[i] && addr < hi[i]) return i;
			else {}
		}
		return -1;
	}

	/** Any window containing an address, resident or not — for deciding whether to look again. */
	public static function windowOf(addr:Int):Int {
		for (i in 0...count) {
			if (addr >= lo[i] && addr < hi[i]) return i;
			else {}
		}
		return -1;
	}

	public static inline function isResident(index:Int):Bool {
		return index >= 0 && index < count && resident[index];
	}

	// ---- being told things ----------------------------------------------------------------------

	/**
		The game wrote something into RAM.

		Only eviction happens here, deliberately. What was written might be an overlay, or the
		artwork that came with it, or a save block — and the difference is decided by looking at
		the bytes, which is what `rescan` does at a moment when the bytes are all there. A load is
		often several transfers, so identifying after the first one would identify half an overlay.

		What is certain immediately is the negative: the code that used to be at those addresses is
		not there any more.
	**/
	public static function noteLoad(dest:Int, length:Int):Void {
		if (length <= 0) return;
		else {}
		final from = dest;
		final to = dest + length;
		for (i in 0...count) {
			if (!resident[i]) continue;
			else {}
			if (to <= lo[i] || from >= hi[i]) continue;
			else {}
			evict(i);
		}
		remember(from, to);
	}

	// ---- remembering where the disc landed ---------------------------------------------------
	//
	// This is how a game that has no config yet gets one. A dispatch that misses tells you an
	// address; what you need in order to write an overlay stanza is the *window*, and the only
	// thing that knows it is whatever wrote there. So the ranges the disc has been read into are
	// kept, coalesced, and quoted back when a miss lands in one.
	//
	// A handful of ranges, not a log. A game streams audio and artwork through the same channels
	// as its code, so an unbounded record would be mostly noise and would allocate forever; what
	// makes a range interesting is a miss inside it, and by then the coalesced span is the answer.

	static inline var TRACKED = 8;
	static var loadFrom:Array<Int>;
	static var loadTo:Array<Int>;
	static var loadCount = 0;
	static var loadNext = 0;

	static function remember(from:Int, to:Int):Void {
		for (i in 0...loadCount) {
			// Adjacent or overlapping runs are one load: a game reads an overlay a few sectors at
			// a time, and eight separate ranges would describe none of it.
			if (from > loadTo[i] || to < loadFrom[i]) continue;
			else {}
			if (from < loadFrom[i]) loadFrom[i] = from;
			else {}
			if (to > loadTo[i]) loadTo[i] = to;
			else {}
			return;
		}
		loadFrom[loadNext] = from;
		loadTo[loadNext] = to;
		loadNext = (loadNext + 1) % TRACKED;
		if (loadCount < TRACKED) loadCount++;
		else {}
	}

	/** The span the disc was read into that covers this address, or -1. */
	static function loadCovering(addr:Int):Int {
		for (i in 0...loadCount) {
			if (addr >= loadFrom[i] && addr < loadTo[i]) return i;
			else {}
		}
		return -1;
	}

	static function evict(i:Int):Void {
		resident[i] = false;
		evictions++;
		Runtime.noteOnce(0x6E100000 | i, "overlay " + i + " was overwritten and no longer "
			+ "answers for its window");
	}

	/** The other way an overlay stops answering: something it shares memory with arrived. */
	static function displace(i:Int, by:Int):Void {
		resident[i] = false;
		evictions++;
		Runtime.noteOnce(0x6E300000 | i, "overlay " + i + " gave up its window to overlay " + by
			+ ", which overlaps it");
	}

	/**
		Looks at every window and says what is in it.

		Called where a game has finished loading — `FlushCache` — and once more if a dispatch
		misses inside a window. Returns how many overlays became resident, so a caller can tell
		"looked and found something" from "looked and did not".

		An overlay already resident is left alone rather than re-checked: its window's bytes cannot
		have changed without a load, and a load evicts.
	**/
	public static function rescan():Int {
		var found = 0;
		for (i in 0...count) {
			if (resident[i]) continue;
			else {}
			if (hashOf(lo[i], hashBytes[i]) != fingerprint[i]) continue;
			else {}
			// Two overlays cannot share a fingerprint — the tool refuses to emit that — but two
			// *windows* may overlap, and only one thing can be at an address.
			evictOverlapping(i);
			resident[i] = true;
			activations++;
			found++;
			Runtime.noteOnce(0x6E200000 | i, "overlay " + i + " is resident: its window holds the "
				+ "bytes the tool compiled");
		}
		if (found == 0) fruitlessRescans++;
		else {}
		return found;
	}

	static function evictOverlapping(index:Int):Void {
		for (j in 0...count) {
			if (j == index || !resident[j]) continue;
			else {}
			if (hi[index] <= lo[j] || lo[index] >= hi[j]) continue;
			else {}
			displace(j, index);
		}
	}

	/**
		FNV-1a over emulated RAM, byte for byte identical to what the tool computed.

		The two implementations are deliberately the same seven lines — see
		`recomp.codegen.Universe.fingerprint`. The prime is written as the shifts it is made of
		because a 32-bit multiply loses its low bits wherever `Int` is a double, and a fingerprint
		that differs between JavaScript and C++ would activate an overlay on one target and not the
		other, which is the one class of bug this project's whole test strategy exists to catch.
	**/
	static function hashOf(addr:Int, length:Int):Int {
		var h = 0x811C9DC5;
		for (i in 0...length) {
			h = (h ^ Memory.read8u((addr + i) | 0)) | 0;
			h = (h + ((h << 1) | 0) + ((h << 4) | 0) + ((h << 7) | 0) + ((h << 8) | 0)
				+ ((h << 24) | 0)) | 0;
		}
		return h;
	}

	// ---- what to say when nothing answers ---------------------------------------------------------

	/**
		A dispatch landed in a window and found nothing, even after looking again.

		Worth telling apart from an ordinary miss, because the cause is different in kind. A missed
		function in the executable is a defect in the analysis; this is either an overlay the config
		does not describe yet, or one whose window holds something the tool never compiled. The
		window and the address are what a person needs to write the stanza, so they are what this
		says.
	**/
	public static function reportMiss(addr:Int, ra:Int):Bool {
		final w = windowOf(addr);
		if (w >= 0) {
			Runtime.reportOnce(addr, "no code resident at " + hex(addr) + " (ra=" + hex(ra) + "), "
				+ "which is inside overlay " + w + "'s window " + hex(lo[w]) + ".." + hex(hi[w])
				+ ". Either the game loaded something this build does not describe, or that window "
				+ "currently holds an overlay the config does not list.");
			return true;
		} else {}

		// No window covers it — but if the disc was read into this address, that is an overlay
		// nobody has described yet, and the span that was read is the window to describe. This is
		// the whole of how a new game's config gets written: run it, and the misses say where to
		// look.
		final l = loadCovering(addr);
		if (l < 0) return false;
		else {}
		Runtime.reportOnce(addr, "no function at " + hex(addr) + " (ra=" + hex(ra) + ") — but the "
			+ "disc was read into " + hex(loadFrom[l]) + ".." + hex(loadTo[l]) + ", which covers "
			+ "it. That is an overlay: code the executable never held, so the tool never saw it. "
			+ "Add it to games/<id>/game.json with loadAddr " + (loadFrom[l] >>> 0)
			+ " length " + (loadTo[l] - loadFrom[l]) + " and entryHint " + (addr >>> 0) + ".");
		return true;
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
