import kernel.OverlayMgr;
import mem.Memory;

/**
	Cross-target conformance for deciding which code is in a window.

	Overlay activation is a fingerprint compared against a number the tool computed at build time,
	and a fingerprint is exactly the kind of arithmetic that goes wrong differently on different
	targets: a 32-bit multiply whose low bits are lost wherever `Int` is a double, an exclusive-or
	that must wrap, a shift that must not become an arithmetic one. If the two targets disagree by
	a single bit, one of them activates an overlay and the other does not — and the failure appears
	as a game that works in the browser and hangs on a console, which is the worst shape a bug can
	have here.

	So this drives the whole state machine by hand — declare, load, look, evict, miss, look again —
	and feeds every answer into the digest. The tool's half of the same arithmetic is checked
	separately by the synthetic overlay tests under `tools/recomp/test`.
**/
class Overlay {
	// Two windows: one on its own, and one overlapping it, so eviction has something to do.
	static inline var WIN_A = 0x80100000;
	static inline var WIN_A_END = 0x80100400;
	static inline var WIN_B = 0x80100200;
	static inline var WIN_B_END = 0x80100600;

	static inline var HASH_WORDS = 16;

	public static function main():Void {
		Conf.feedName("overlay");
		Memory.init();
		OverlayMgr.init();

		// Nothing declared: every address is somebody else's problem.
		Conf.expect("no overlays means no windows", OverlayMgr.windowOf(WIN_A), -1);
		Conf.expect("and nothing resident", OverlayMgr.residentAt(WIN_A), -1);

		// ---- two overlays, recognised by what is in their windows ----------------------------
		//
		// The fingerprints are computed here from the same bytes that get written, which is what
		// the tool does from an overlay's file. Feeding them into the digest is the point: two
		// targets that hash differently disagree here, before anything else can hide it.
		final printA = fill(WIN_A, HASH_WORDS * 4, 0x11);
		final printB = fill(WIN_B, HASH_WORDS * 4, 0x22);
		Conf.feed(printA);
		Conf.feed(printB);
		Conf.expect("different bytes hash differently", printA != printB ? 1 : 0, 1);

		OverlayMgr.define(0, WIN_A, WIN_A_END, printA, HASH_WORDS);
		OverlayMgr.define(1, WIN_B, WIN_B_END, printB, HASH_WORDS);

		Conf.expect("an address in a window is known", OverlayMgr.windowOf(WIN_A), 0);
		Conf.expect("even before anything is resident", OverlayMgr.residentAt(WIN_A), -1);

		// ---- recognising ------------------------------------------------------------------------
		//
		// Window A holds A's bytes; window B holds B's. Both should be found, and they overlap, so
		// finding the second must displace the first.
		final found = OverlayMgr.rescan();
		Conf.feed(found);
		Conf.feed(OverlayMgr.activations);
		Conf.feed(OverlayMgr.evictions);
		// Only one of two overlapping windows can be the answer for the addresses they share.
		Conf.expect("the later one owns the overlap", OverlayMgr.residentAt(WIN_B), 1);

		// ---- a load takes it away -----------------------------------------------------------------
		//
		// Whatever the game wrote there, the code that was compiled for those addresses is gone.
		// This is the half a fingerprint cannot see: a window full of artwork matches nothing and
		// must still stop answering.
		final residentBefore = OverlayMgr.residentAt(WIN_B);
		OverlayMgr.noteLoad(WIN_B, 64);
		Conf.feed(residentBefore);
		Conf.expect("a load evicts what it overwrote", OverlayMgr.residentAt(WIN_B), -1);
		Conf.feed(OverlayMgr.evictions);

		// A load that misses a window leaves it alone.
		final untouched = OverlayMgr.residentAt(WIN_A);
		OverlayMgr.noteLoad(0x80200000, 4096);
		Conf.expect("a load elsewhere changes nothing", OverlayMgr.residentAt(WIN_A), untouched);

		// ---- looking again ---------------------------------------------------------------------
		//
		// B's identifying bytes are overwritten with something nothing was compiled for, so B is
		// not found. A's are untouched — the write landed past where A is recognised from — so A
		// is, and since the windows overlap, A now answers for the addresses they share.
		//
		// That is not a quirk to work around. Two overlays overlapping means the game reuses the
		// memory, and at any moment exactly one thing is in it; "whichever one's bytes are
		// actually there" is the only answer that can be right.
		fill(WIN_B, HASH_WORDS * 4, 0x33);
		Conf.feed(OverlayMgr.rescan());
		Conf.expect("bytes nothing was compiled for do not become an overlay",
			OverlayMgr.isResident(1) ? 1 : 0, 0);
		Conf.expect("the overlay whose bytes are still there owns the overlap",
			OverlayMgr.residentAt(WIN_B), 0);
		Conf.feed(OverlayMgr.fruitlessRescans);

		// Put B's bytes back and it is recognised again, displacing A from the shared addresses.
		// A game reloading an overlay it had before is the ordinary case, not a special one.
		fill(WIN_B, HASH_WORDS * 4, 0x22);
		Conf.feed(OverlayMgr.rescan());
		Conf.expect("the same overlay is recognised again", OverlayMgr.residentAt(WIN_B), 1);
		Conf.expect("and displaces the one it overlaps", OverlayMgr.isResident(0) ? 1 : 0, 0);

		// ---- the boundaries --------------------------------------------------------------------
		//
		// Off-by-one at a window's edge would dispatch one instruction of a function to the wrong
		// program, which is a failure with no symptom where the mistake is.
		Conf.expect("the first address is inside", OverlayMgr.windowOf(WIN_A) >= 0 ? 1 : 0, 1);
		Conf.expect("one before it is not", OverlayMgr.windowOf(WIN_A - 1), -1);
		Conf.expect("the last address is inside", OverlayMgr.windowOf(WIN_B_END - 1), 1);
		Conf.expect("one past the end is not", OverlayMgr.windowOf(WIN_B_END), -1);

		// ---- the hash itself ---------------------------------------------------------------------
		//
		// Fed at several lengths and byte patterns, because the parts that break per target are
		// the wrap and the low bits, and those show up as a function of how many rounds ran.
		for (n in 0...8) {
			Conf.feed(fill(WIN_A, n * 7 + 1, 0x80 + n * 13));
		}
		// A byte with the high bit set, which is where a sign-extending shift would show.
		Conf.feed(fill(WIN_A, 32, 0xFF));
		Conf.feed(fill(WIN_A, 32, 0x00));

		Conf.report("overlay");
	}

	/**
		Writes a recognisable pattern into emulated RAM and returns its fingerprint.

		The pattern is deliberately not constant: a hash fed only equal bytes cannot tell a working
		implementation from one that ignores position.
	**/
	static function fill(addr:Int, length:Int, seed:Int):Int {
		var v = seed & 0xFF;
		for (i in 0...length) {
			Memory.write8(addr + i, v);
			v = ((v * 31) + 17) & 0xFF;
		}
		return hashOf(addr, length);
	}

	/** The same seven lines as `kernel.OverlayMgr` and `recomp.codegen.Universe`. */
	static function hashOf(addr:Int, length:Int):Int {
		var h = 0x811C9DC5;
		for (i in 0...length) {
			h = (h ^ Memory.read8u((addr + i) | 0)) | 0;
			h = (h + ((h << 1) | 0) + ((h << 4) | 0) + ((h << 7) | 0) + ((h << 8) | 0)
				+ ((h << 24) | 0)) | 0;
		}
		return h;
	}
}
