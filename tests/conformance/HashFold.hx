import core.Hash;
import shim.RawMem;

/**
	`core.Hash` — the instrument every other digest is measured with.

	Nothing else in this suite means anything if this disagrees between targets. A conformance
	digest is FNV-1a over emulated state, and the frame digests that decide whether a *game* runs
	identically on JavaScript and reflaxe.CPP are folded with these four functions. If `word`
	returned something different on one target, every comparison built on it would be a
	tautology — two runs agreeing about the same wrong arithmetic — and the failure would surface
	as a mismatch somewhere in a 963-function program rather than here, in ten lines.

	`Hash.word` in particular is the shape this project has been bitten by twice: a multi-statement
	`inline` function whose parameter is used four times, which is exactly what upstream defect 1
	(PROGRESS.md) mishandles. It went untested from the day it was written until the day the game
	digest needed it, which is the argument for this file existing.

	Named `HashFold` rather than `Hash`: a root-package test compiles to a bare `HashFold.h`, and
	`Hash.h` would both shadow the runtime's `core_Hash.h` in intent and read as the class it is
	testing (see `VideoTime.hx` for the same reasoning about libc's `time.h`).
**/
class HashFold {
	public static function main():Void {
		Conf.feedName("HashFold");

		// ---- byte: the primitive the other three are made of ------------------------------------
		//
		// Every input that could reveal a sign or masking error: the high bit set, values past a
		// byte that must be masked down to one, and the offset basis unchanged.
		Conf.expect("the empty hash is the offset basis", Hash.FNV_OFFSET, 0x811C9DC5);
		Conf.feed(Hash.byte(Hash.FNV_OFFSET, 0));
		Conf.feed(Hash.byte(Hash.FNV_OFFSET, 0xFF));
		Conf.feed(Hash.byte(Hash.FNV_OFFSET, 0x80));
		// Masking: only the low eight bits may reach the hash, so these three must agree.
		final wide = Hash.byte(Hash.FNV_OFFSET, 0x1234);
		Conf.expect("bytes past the low eight are masked off", wide, Hash.byte(Hash.FNV_OFFSET, 0x34));
		Conf.expect("and a negative input is masked the same way", Hash.byte(Hash.FNV_OFFSET, -204),
			Hash.byte(Hash.FNV_OFFSET, 0x34));
		// Order matters — a hash that commuted would not distinguish two different streams.
		Conf.expect("folding is not commutative",
			Hash.byte(Hash.byte(Hash.FNV_OFFSET, 1), 2) == Hash.byte(Hash.byte(Hash.FNV_OFFSET, 2), 1)
				? 1 : 0, 0);

		// ---- word: four bytes, least significant first ------------------------------------------
		//
		// The one with the inlining hazard. Each case is also asserted against the same value
		// folded by hand through `byte`, so a target that inlines it wrongly fails here with the
		// arithmetic named rather than producing a digest nobody can attribute.
		wordCase(0);
		wordCase(1);
		wordCase(-1);
		wordCase(0x12345678);
		wordCase(0x80000000);
		wordCase(0x7FFFFFFF);
		wordCase(0x000000FF);
		wordCase(0xFF000000);

		// Chained, because that is how a real digest is built: each value folds into the last.
		var chain = Hash.FNV_OFFSET;
		var i = 0;
		while (i < 64) {
			chain = Hash.word(chain, i * 0x01010101);
			i++;
		}
		Conf.feed(chain);

		// ---- region: bytes out of a buffer -------------------------------------------------------
		final buf = RawMem.alloc(256);
		var b = 0;
		while (b < 256) {
			RawMem.set8(buf, b, (b * 7) & 0xFF);
			b++;
		}
		Conf.feed(Hash.region(Hash.FNV_OFFSET, buf, 0, 256));
		Conf.feed(Hash.region(Hash.FNV_OFFSET, buf, 0, 0));       // empty is the basis, untouched
		Conf.expect("an empty region changes nothing",
			Hash.region(Hash.FNV_OFFSET, buf, 17, 0), Hash.FNV_OFFSET);
		Conf.feed(Hash.region(Hash.FNV_OFFSET, buf, 128, 128));   // an offset run
		Conf.feed(Hash.region(Hash.FNV_OFFSET, buf, 1, 3));       // unaligned, short
		// A region equals the same bytes fed one at a time.
		var byHand = Hash.FNV_OFFSET;
		var k = 0;
		while (k < 16) {
			byHand = Hash.byte(byHand, RawMem.get8(buf, 32 + k));
			k++;
		}
		Conf.expect("a region is its bytes in order",
			Hash.region(Hash.FNV_OFFSET, buf, 32, 16), byHand);

		// ---- rect: a framebuffer's shape ---------------------------------------------------------
		//
		// Halfwords with a row pitch, which is how VRAM is hashed. The cases that matter are the
		// ones where pitch and width differ: a rect that ignored the pitch would read a straight
		// run and agree with itself forever while describing the wrong picture.
		final pitch = 16;
		final vram = RawMem.alloc(pitch * 8 * 2);
		var p = 0;
		while (p < pitch * 8) {
			RawMem.set8(vram, p * 2, p & 0xFF);
			RawMem.set8(vram, p * 2 + 1, (p >>> 8) & 0xFF);
			p++;
		}
		Conf.feed(Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, pitch, 8));   // the whole buffer
		Conf.feed(Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, 4, 4));       // a corner
		Conf.feed(Hash.rect(Hash.FNV_OFFSET, vram, pitch, 4, 2, 4, 4));       // an offset window
		Conf.feed(Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, pitch, 1));   // one row
		Conf.feed(Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, 0, 8));       // no columns
		// A full-pitch rect of one row is exactly that row as a region — the pitch cannot matter
		// when the width fills it.
		Conf.expect("a full-width row is a contiguous region",
			Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 3, pitch, 1),
			Hash.region(Hash.FNV_OFFSET, vram, 3 * pitch * 2, pitch * 2));
		// Two rects reading the same bytes through different geometry must differ, because the
		// picture they describe differs.
		Conf.expect("geometry is part of what is hashed",
			Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, 8, 2)
				== Hash.rect(Hash.FNV_OFFSET, vram, pitch, 0, 0, 2, 8) ? 1 : 0, 0);

		// ---- hex: how a digest reaches a person --------------------------------------------------
		//
		// Fed as characters: the printed form is what lands in PROGRESS.md and what scripts grep,
		// so a target that formatted differently would break the comparison without breaking the
		// arithmetic.
		Conf.feedName(Hash.hex(0));
		Conf.feedName(Hash.hex(-1));
		Conf.feedName(Hash.hex(0x0BADF00D));
		Conf.feedName(Hash.hex(Hash.FNV_OFFSET));

		Conf.report("HashFold");
	}

	/** One `word`, checked against the same four bytes folded by hand. */
	static function wordCase(v:Int):Void {
		var byHand = Hash.byte(Hash.FNV_OFFSET, v);
		byHand = Hash.byte(byHand, v >>> 8);
		byHand = Hash.byte(byHand, v >>> 16);
		byHand = Hash.byte(byHand, v >>> 24);
		Conf.expect("word " + Hash.hex(v) + " is its four bytes",
			Hash.word(Hash.FNV_OFFSET, v), byHand);
	}
}
