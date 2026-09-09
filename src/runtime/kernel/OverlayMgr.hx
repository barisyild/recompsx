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

	**Residency is attested by the fingerprint region only.** "Resident" means the first
	`hashWords` words of the window hold the overlay's bytes — nothing has checked the rest, and
	eviction watches only that region, because overlays nest: a game loads a small piece into the
	middle of a large one, and the large one must keep answering everywhere else. The cost of that
	choice is deliberate and known: a load into the *tail* of a resident window leaves the overlay
	resident, and its rows there would dispatch code whose bytes are gone. In practice the piece a
	game swaps is itself an overlay with its own stanza — the nested window then answers, and the
	stale rows are shadowed. A game that streams artwork over the tail of live code with no
	corresponding stanza would be mis-dispatched; none has been met, and the miss diagnostics
	would name the window if one ever is.
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
		loadLba = [for (_ in 0...TRACKED) -1];
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
	/**
		One address form everywhere inside this class.

		The same RAM byte has four names on this machine — KUSEG, KSEG0, KSEG1, and the mirrors —
		and the callers of this class use whichever their code happened to hold: the DMA engine
		reconstructs a KSEG0 address, the kernel's file API passes through whatever the game gave
		it. Comparing windows in mixed forms would make residency depend on which segment a game
		likes, so everything is folded to KSEG0 on the way in.
	**/
	static inline function canon(a:Int):Int {
		return 0x80000000 | (a & 0x1FFFFF);
	}

	public static function define(index:Int, windowLo:Int, windowHi:Int, print:Int,
			hashWords:Int):Void {
		if (index < 0 || index >= MAX) return tooMany(index);
		else {}
		// The end is kept as start plus length rather than canonicalised itself: a window ending
		// exactly at the top of RAM would fold to the bottom.
		lo[index] = canon(windowLo);
		hi[index] = lo[index] + ((windowHi - windowLo) | 0);
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
		// The most specific one wins. Overlays nest: a game loads a large region once and then
		// swaps a smaller piece of it in and out, so several resident windows can cover the same
		// address and the smallest is the one that was most recently made true of it. Anything
		// else would answer with the code the small overlay replaced.
		final a = canon(addr);
		var best = -1;
		var bestSize = 0;
		for (i in 0...count) {
			if (!resident[i] || a < lo[i] || a >= hi[i]) continue;
			else {}
			final size = hi[i] - lo[i];
			if (best >= 0 && size >= bestSize) continue;
			else {}
			best = i;
			bestSize = size;
		}
		return best;
	}

	/** Any window containing an address, resident or not — for deciding whether to look again. */
	public static function windowOf(addr:Int):Int {
		final a = canon(addr);
		for (i in 0...count) {
			if (a >= lo[i] && a < hi[i]) return i;
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
	public static function noteLoad(dest:Int, length:Int, lba:Int = -1):Void {
		if (length <= 0) return;
		else {}
		final from = canon(dest);
		final to = from + length;
		for (i in 0...count) {
			if (!resident[i]) continue;
			else {}
			// Only a write over the bytes an overlay is *recognised by* unseats it. A write
			// elsewhere in its window does not: overlays nest, and a game swapping a small piece
			// into a large resident region is the ordinary case — the large one is still there,
			// still identifiable, and still the right answer everywhere the small one is not.
			if (to <= lo[i] || from >= lo[i] + hashBytes[i]) continue;
			else {}
			evict(i);
		}
		remember(from, to, lba);
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
	/** The disc sector the lowest address of this span came from, or -1 if nothing said. */
	static var loadLba:Array<Int>;
	static var loadCount = 0;
	static var loadNext = 0;

	static function remember(from:Int, to:Int, lba:Int):Void {
		for (i in 0...loadCount) {
			// Adjacent or overlapping runs are one load: a game reads an overlay a few sectors at
			// a time, and eight separate ranges would describe none of it.
			if (from > loadTo[i] || to < loadFrom[i]) continue;
			else {}
			if (!continues(i, from, lba)) {
				// Same memory, different part of the disc — so this is the *next* overlay, not
				// more of the last one. Merging them would report the first overlay's sector for
				// the second's addresses, which is precisely the number a person would then use
				// to read the wrong bytes.
				loadFrom[i] = from;
				loadTo[i] = to;
				loadLba[i] = lba;
				return;
			} else {}
			// The sector belonging to the span's *lowest* address, since that is the one an
			// overlay stanza's offset is measured from.
			if (from < loadFrom[i]) { loadFrom[i] = from; loadLba[i] = lba; }
			else {}
			if (to > loadTo[i]) loadTo[i] = to;
			else {}
			return;
		}
		loadFrom[loadNext] = from;
		loadTo[loadNext] = to;
		loadLba[loadNext] = lba;
		loadNext = (loadNext + 1) % TRACKED;
		if (loadCount < TRACKED) loadCount++;
		else {}
	}

	/**
		Whether a load is more of the span it overlaps, or the start of a different one.

		A game reads an overlay as a run of sectors into a run of addresses, so within one load the
		two advance together: an address this far into the span came from a sector that far past
		its first. When they disagree, the same memory is being filled from somewhere else on the
		disc — a different overlay — and it deserves its own record.

		A load whose sector nobody knows (the kernel's file API, which reports no LBA) is taken as
		continuing, because guessing otherwise would split one load into eight.
	**/
	static function continues(i:Int, from:Int, lba:Int):Bool {
		if (lba < 0 || loadLba[i] < 0) return true;
		else {}
		final ahead = (from - loadFrom[i]) | 0;
		if (ahead < 0) return true;
		return loadLba[i] + shim.IntMath.div(ahead, cd.Iso9660.USER_BYTES) == lba;
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
			// Nothing is displaced. Two overlays whose windows overlap can both be genuinely
			// present — a small one loaded inside a large one's region — and `residentAt` settles
			// which answers for a shared address by taking the smaller window.
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
		// The two window cases point at different fixes, and conflating them sends a person
		// hunting for a second overlay when the first one is sitting right there.
		final r = residentAt(addr);
		if (r >= 0) {
			// Resident, but has the disc been read over *this* part of its window since? Overlays
			// nest, and only a write across the fingerprint unseats one — so an overlay can be
			// correctly resident while the address in question belongs to something loaded on top
			// of it later. The two cases want opposite fixes, and saying "add an entryHint" for
			// the second sends a person to add a hint the tool will refuse, because the bytes the
			// *executable* holds there are data. Crash Bash does exactly this: a block lands over
			// the stage overlay and past its end, and the call goes into the part past the end.
			// ...by a load that is not this overlay's *own*. An overlay arrives by being read from
			// the disc, so a covering load whose span is exactly this window is how it got here,
			// and says nothing about anything else being on top. Only a foreign span does.
			final l = loadCovering(addr);
			if (l >= 0 && !(loadFrom[l] == lo[r] && loadTo[l] == hi[r] + 1)) {
				Runtime.reportOnce(addr, "no code at " + hex(addr) + " (ra=" + hex(ra) + "): "
					+ "overlay " + r + " is resident, but the disc has since been read over this "
					+ "part of its window, so what is there belongs to something else."
					+ provenance(addr));
				return true;
			} else {}
			// The overlay is present and identified; it just has no code at this address. That is
			// an entry the analysis was never given — overlays are all reached through pointers,
			// so the sweep misses some — and the fix is a hint on *this* overlay.
			Runtime.reportOnce(addr, "overlay " + r + " is resident but has no code at "
				+ hex(addr) + " (ra=" + hex(ra) + "). Add " + udec(addr)
				+ " to its entryHints.");
			return true;
		} else {}
		final w = windowOf(addr);
		if (w >= 0) {
			// A window with nothing resident is the ordinary way a *second* overlay announces
			// itself: the game reused the memory, and what is there now was never described. The
			// span and sector of the load that covers it are what the new stanza is made of, so
			// they are said here too rather than only when no window matches.
			Runtime.reportOnce(addr, "no code resident at " + hex(addr) + " (ra=" + hex(ra) + "), "
				+ "which is inside overlay " + w + "'s window " + hex(lo[w]) + ".." + hex(hi[w])
				+ ". The window holds something this build does not describe — most likely another "
				+ "overlay that shares it." + provenance(addr));
			return true;
		} else {}

		// No window covers it — but if the disc was read into this address, that is an overlay
		// nobody has described yet, and the span that was read is the window to describe. This is
		// the whole of how a new game's config gets written: run it, and the misses say where to
		// look.
		if (loadCovering(addr) < 0) return false;
		else {}
		Runtime.reportOnce(addr, "no function at " + hex(addr) + " (ra=" + hex(ra) + ") — but the "
			+ "disc was read here. That is an overlay: code the executable never held, so the tool "
			+ "never saw it." + provenance(addr));
		return true;
	}

	/**
		The numbers a person needs to write the stanza, appended to whichever diagnostic ran.

		Not a separate recording mode, because the moment you want them is the moment something
		missed — and a message you are already reading beats a file you have to remember to open.
		The sector is what turns a window into a place on the disc: a file's own starting sector
		subtracted from this one, times 2048, is the offset to read from.
	**/
	static function provenance(addr:Int):String {
		final l = loadCovering(addr);
		if (l < 0) return "";
		else {}
		return " Add it to games/<id>/game.json with loadAddr " + udec(loadFrom[l])
			+ " length " + (loadTo[l] - loadFrom[l]) + " and entryHint " + udec(canon(addr))
			+ (loadLba[l] >= 0 ? ", from disc sector " + loadLba[l] : "") + ".";
	}

	/**
		An address as the unsigned decimal the config wants.

		`Std.string` on a KSEG0 address prints a minus sign, and `value >>> 0` only helps on
		JavaScript — on C++ a zero-bit shift is the same signed integer, so the number a person was
		told to paste would be negative on exactly one target. Division by ten is done as a
		halved-then-fifth, which is exact for every unsigned 32-bit value and never needs a type
		wider than Int.
	**/
	static function udec(v:Int):String {
		if (v >= 0) return Std.string(v);
		else {}
		// floor(u / 10) where u is v reinterpreted as unsigned: shift out one bit first so the
		// intermediate stays positive, then divide by five.
		final q = shim.IntMath.div(v >>> 1, 5);
		final r = (v - ((q * 10) | 0)) | 0;
		return Std.string(q) + Std.string(r);
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
