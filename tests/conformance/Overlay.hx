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
	// A large region, and a small one loaded inside it. That nesting is the shape overlays
	// actually have — a game loads a level's worth of code once and then swaps a piece of it —
	// and it is the case that decides which of two resident overlays answers for an address.
	static inline var WIN_A = 0x80100000;
	static inline var WIN_A_END = 0x80100800;
	static inline var WIN_B = 0x80100200;
	static inline var WIN_B_END = 0x80100400;

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
		// Window A holds A's bytes and window B holds B's, so both are found. They overlap, and
		// both stay resident: overlays nest. A game loads a large region and then swaps a smaller
		// piece of it, and the large one is still there everywhere the small one is not.
		final found = OverlayMgr.rescan();
		Conf.feed(found);
		Conf.feed(OverlayMgr.activations);
		Conf.expect("both are resident at once", OverlayMgr.isResident(0) ? 1 : 0, 1);
		Conf.expect("nesting is not exclusion", OverlayMgr.isResident(1) ? 1 : 0, 1);

		// Where they overlap, the smaller window answers: it is the more recent truth about those
		// addresses. Where only the larger one reaches, it still does.
		Conf.expect("the smaller window owns the overlap", OverlayMgr.residentAt(WIN_B), 1);
		Conf.expect("the larger one keeps the rest", OverlayMgr.residentAt(WIN_A), 0);

		// ---- a load takes one away ------------------------------------------------------------
		//
		// Only a write over the bytes an overlay is *recognised by* unseats it. That is the half a
		// fingerprint cannot see — a window filled with artwork matches nothing and must still
		// stop answering — and it is deliberately narrow, because a write elsewhere in a window is
		// how nesting happens in the first place.
		OverlayMgr.noteLoad(WIN_B, 64);
		Conf.expect("a load over what identifies it evicts it", OverlayMgr.isResident(1) ? 1 : 0, 0);
		Conf.expect("and the window beneath answers again", OverlayMgr.residentAt(WIN_B), 0);
		Conf.feed(OverlayMgr.evictions);

		// A load elsewhere in a resident window does not unseat it — this is the nesting case.
		OverlayMgr.noteLoad(WIN_A_END - 16, 16);
		Conf.expect("a load past what identifies it does not", OverlayMgr.isResident(0) ? 1 : 0, 1);

		// A load that misses every window changes nothing at all.
		OverlayMgr.noteLoad(0x80200000, 4096);
		Conf.expect("a load elsewhere entirely changes nothing",
			OverlayMgr.isResident(0) ? 1 : 0, 1);

		// ---- looking again ---------------------------------------------------------------------
		//
		// B's identifying bytes now hold something nothing was compiled for, so looking finds
		// nothing and says so rather than guessing.
		fill(WIN_B, HASH_WORDS * 4, 0x33);
		Conf.feed(OverlayMgr.rescan());
		Conf.expect("bytes nothing was compiled for do not become an overlay",
			OverlayMgr.isResident(1) ? 1 : 0, 0);
		Conf.feed(OverlayMgr.fruitlessRescans);

		// Put B's bytes back and it is recognised again, and takes the shared addresses back with
		// it. A game reloading an overlay it had before is the ordinary case, not a special one.
		fill(WIN_B, HASH_WORDS * 4, 0x22);
		Conf.feed(OverlayMgr.rescan());
		Conf.expect("the same overlay is recognised again", OverlayMgr.residentAt(WIN_B), 1);
		Conf.expect("without disturbing the one it sits inside",
			OverlayMgr.isResident(0) ? 1 : 0, 1);

		// ---- one byte, four names --------------------------------------------------------------
		//
		// The same RAM byte is reachable as KUSEG, KSEG0 or KSEG1, and callers use whichever
		// their code held: the DMA engine reconstructs one form, the kernel's file API passes
		// through the game's own. Residency must not depend on the spelling.
		Conf.expect("KSEG1 names the same window", OverlayMgr.residentAt(0xA0100200), 1);
		Conf.expect("so does KUSEG", OverlayMgr.residentAt(0x00100200), 1);
		OverlayMgr.noteLoad(0xA0100200, 64);
		Conf.expect("a KSEG1 load evicts all the same", OverlayMgr.isResident(1) ? 1 : 0, 0);
		fill(WIN_B, HASH_WORDS * 4, 0x22);
		Conf.feed(OverlayMgr.rescan());
		Conf.expect("and the window recovers as before", OverlayMgr.residentAt(WIN_B), 1);

		// ---- the boundaries --------------------------------------------------------------------
		//
		// Off-by-one at a window's edge would dispatch one instruction of a function to the wrong
		// program, which is a failure with no symptom where the mistake is.
		Conf.expect("the first address is inside", OverlayMgr.windowOf(WIN_A), 0);
		Conf.expect("one before it is not", OverlayMgr.windowOf(WIN_A - 1), -1);
		Conf.expect("the last address is inside", OverlayMgr.windowOf(WIN_A_END - 1), 0);
		Conf.expect("one past the end is not", OverlayMgr.windowOf(WIN_A_END), -1);
		// The nested window's own edges, where an off-by-one would send one instruction of a
		// function to the program it replaced.
		Conf.expect("the inner window starts where it says", OverlayMgr.residentAt(WIN_B), 1);
		Conf.expect("one before it belongs to the outer one",
			OverlayMgr.residentAt(WIN_B - 1), 0);
		Conf.expect("its last address is still its own",
			OverlayMgr.residentAt(WIN_B_END - 1), 1);
		Conf.expect("one past its end is the outer one again",
			OverlayMgr.residentAt(WIN_B_END), 0);

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
