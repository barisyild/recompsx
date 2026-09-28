package sio;

import core.Hash;
import core.Runtime;
import shim.Backend;
import shim.Bulk;
import shim.IntMath;
import shim.RawBuf;
import shim.RawMem;

/**
	The memory card in slot 1: 128 KB of flash, 1024 frames of 128 bytes, and the FLAG byte it
	answers every command with (psx-spx "Memory Card Read/Write Commands" and "Memory Card Data
	Format"; docs/specs/runtime.md §7.11). The kernel's card functions (`kernel.KCard`) and a game
	that talks to SIO0 itself (`sio.Sio0`) reach the same card, so it looks the same from both:
	the same frames, the same "new card" latch.

	The game sees a whole card with fifteen blocks, as on a PlayStation. What is kept between runs
	is what the game put on it and nothing else (ADR-0037): every game has a card of its own, kept
	under its product code in recompsx's card format — a header, then each block the game's saves
	occupy with its directory frame. A one-block save is 8336 bytes, not 128 KB; the card grows as
	the game saves more and shrinks as it deletes, and with nothing on it nothing is kept. The
	rest of a card is what a freshly formatted one holds, and is rebuilt that way when it goes in.
	A deleted file is not kept: its blocks come back free, as the next save would treat them.

	The card goes back to the backend once the game has stopped writing for a while, and at exit.
	One equal to what the backend already has is not written again: the BIOS writes a frame every
	time it opens a card, and flash — a VMU's included — wears.

	Slot 2 is empty, as on most consoles, so the card costs one image of memory, not two.

	**A headless run** gets a freshly formatted card and never reads or writes the host's: a digest
	is a function of the disc and the frame count, as with `Pads` and `kernel.KSettings`.
**/
class MemoryCard {
	public static inline var FRAME = 0x80;
	public static inline var BYTES = 0x20000;
	public static inline var BLOCK = 0x2000;
	/** Blocks 1..15 hold files; block 0 is the directory. */
	public static inline var FILE_BLOCKS = 15;
	/** The last valid sector: 1024 frames. */
	public static inline var LAST_SECTOR = 0x3FF;

	/** FLAG.3: the directory has not been read since the card went in. Only a write clears it. */
	public static inline var FLAG_NEW = 0x08;

	// Directory entry states, the low byte of an entry's first word.
	public static inline var FREE = 0xA0;
	public static inline var FIRST = 0x51;
	public static inline var MIDDLE = 0x52;
	public static inline var LAST = 0x53;
	public static inline var NO_NEXT = 0xFFFF;

	// The card format (ADR-0037).
	public static inline var HEADER = 16;
	public static inline var RECORD = FRAME + BLOCK;
	public static inline var MAX = HEADER + FILE_BLOCKS * RECORD;
	static inline var VERSION = 1;
	static inline var MAGIC = 0x434D5852;   // "RXMC", little-endian

	/** Vblanks without a write before the card goes back to the backend: a save moves a sector
	    every second vblank, so half a second of quiet is well after the game's last. */
	static inline var SETTLE = 30;

	static var card:RawBuf;
	/** The card format, built for the backend and read from it. */
	static var kept:RawBuf;
	static var present = false;
	static var flag = 0;
	static var dirty = false;
	static var quiet = 0;

	static var game = "";
	static var title = "";
	/** Whether the card comes from and goes back to the backend: not in a headless run or a test. */
	static var persistent = false;
	/** The length and checksum of the card the backend has, so an unchanged one is not rewritten. */
	static var keptLength = -1;
	static var keptSum = 0;

	/** Saves the backend took, for a test or a log to watch. */
	public static var saves(default, null) = 0;

	public static function init():Void {
		card = RawMem.alloc(BYTES);
		kept = RawMem.alloc(MAX);
		present = false;
		flag = 0;
		dirty = false;
		quiet = 0;
		game = "";
		title = "";
		persistent = false;
		keptLength = -1;
		keptSum = 0;
		saves = 0;
	}

	/**
		The game's card into slot 1: the one the backend kept for `productCode` when `keep` is set,
		else — or when there is none, or it does not read back — a freshly formatted one. Its FLAG
		says "new card", as a card just plugged in does.
	**/
	public static function insert(productCode:String, gameTitle:String, keep:Bool):Void {
		game = productCode;
		title = gameTitle;
		persistent = keep && productCode != "";
		keptLength = -1;
		keptSum = 0;
		format(card);
		if (persistent) load();
		else {}
		present = true;
		flag = FLAG_NEW;
		dirty = false;
		quiet = 0;
	}

	static function load():Void {
		final n = Backend.cardLoad(game, kept, MAX);
		if (n >= 0 && fromFormat(card, kept, n)) {
			keptLength = n;
			keptSum = RawMem.get32(kept, 8);
			Runtime.note("memory card: " + game + "'s card is in slot 1, " + IntMath.div(n - HEADER, RECORD)
				+ " block(s) in use");
		} else if (n >= 0) {
			Runtime.note("memory card: the card kept for " + game + " does not read back; the game gets a blank one");
		} else {}
	}

	/** Slot 1 left empty: the port answers nothing at 81h, as a real empty slot does. */
	public static function eject():Void {
		flush();
		present = false;
	}

	public static inline function isPresent(port:Int):Bool return port == 0 && present;

	/** The FLAG byte the card answers a command with. */
	public static inline function flagByte():Int return flag;

	/** One byte of the card: frame `sector`, byte `i`. */
	public static inline function read8(sector:Int, i:Int):Int return RawMem.get8(card, (sector << 7) + i);

	/** One frame of the card into `buf` at `off`. */
	public static function readFrame(sector:Int, buf:RawBuf, off:Int):Void {
		Bulk.copy(buf, off, card, sector << 7, FRAME);
	}

	/**
		One frame written from `buf` at `off`. FLAG.3 falls, as the first write after insertion
		clears it on a real card, and the card is due back to the backend once the game has been
		quiet for a while.
	**/
	public static function writeFrame(sector:Int, buf:RawBuf, off:Int):Void {
		Bulk.copy(card, sector << 7, buf, off, FRAME);
		flag = flag & ~FLAG_NEW;
		dirty = true;
		quiet = 0;
	}

	/** Once per vblank: a card the game has stopped writing goes back to the backend. */
	public static function tick():Void {
		if (dirty) {
			quiet++;
			if (quiet >= SETTLE) save();
			else {}
		} else {}
	}

	/** A card with unsaved frames goes back to the backend now: at exit. */
	public static function flush():Void {
		if (dirty) save();
		else {}
	}

	static function save():Void {
		dirty = false;
		quiet = 0;
		if (persistent) keep();
		else {}
	}

	static function keep():Void {
		final n = toFormat(card, kept);
		final sum = RawMem.get32(kept, 8);
		if (n == keptLength && sum == keptSum) return;
		else {}
		if (Backend.cardSave(game, title, kept, n) == 0) {
			keptLength = n;
			keptSum = sum;
			saves++;
		} else {
			Runtime.reportOnce(0x6D000001, "the backend could not keep the memory card; "
				+ "this session's saves are lost at exit");
		}
	}

	// ---- the card as a PlayStation formats it ---------------------------------------------------

	/**
		A blank card as the BIOS formats one: "MC" in frame 0, fifteen free directory entries, an
		empty broken-sector list, FFh in the frames nothing uses and frame 0's copy in the write-test
		frame 63 (psx-spx; OpenBIOS `buFormat`). Every directory frame carries its checksum. The
		broken-sector frames have FFFFh at 08h as well as their FFFFFFFFh: the BIOS writes them from
		the buffer its last free entry went through, whose next-block field that is (`KCard.format`),
		and psx-spx has seen it on cards. The file blocks are zero.
	**/
	public static function format(c:RawBuf):Void {
		Bulk.fill16(c, 0, BYTES >> 1, 0);
		RawMem.set8(c, 0, 0x4D);
		RawMem.set8(c, 1, 0x43);
		seal(c, 0);
		for (b in 1...FILE_BLOCKS + 1) {
			final f = b << 7;
			RawMem.set8(c, f, FREE);
			RawMem.set16(c, f + 8, NO_NEXT);
			seal(c, b);
		}
		for (i in 16...36) {
			RawMem.set32(c, i << 7, -1);
			RawMem.set16(c, (i << 7) + 8, NO_NEXT);
			seal(c, i);
		}
		Bulk.fill16(c, 36 << 7, (63 - 36) << 6, 0xFFFF);
		Bulk.copy(c, 63 << 7, c, 0, FRAME);
	}

	/** Byte 7Fh of a directory-block frame: the XOR of the 127 before it. */
	public static function seal(c:RawBuf, frame:Int):Void {
		final f = frame << 7;
		var x = 0;
		for (k in 0...0x7F) x ^= RawMem.get8(c, f + k);
		RawMem.set8(c, f + 0x7F, x);
	}

	public static inline function stateOf(c:RawBuf, block:Int):Int return RawMem.get8(c, block << 7);

	static inline function inUse(state:Int):Bool return state == FIRST || state == MIDDLE || state == LAST;

	/** The card in slot 1, for a test or a tool. */
	public static inline function image():RawBuf return card;

	// ---- the card format (ADR-0037) ----------------------------------------------------------------
	//
	//   00h  "RXMC"
	//   04h  version, 1
	//   05h  N, the blocks kept
	//   06h  a mask with bit b set for each block b kept (1..15), little-endian
	//   08h  FNV-1a (core.Hash) of bytes 04h..07h and then of every byte after the header
	//   0Ch  zero
	//   10h  N records in block order: the block's directory frame (frame b of block 0, its
	//        checksum included), then the block's 8 KB
	//
	// A block is kept while its directory entry says it is in use (51h, 52h, 53h). Everything
	// else on a card — frame 0, the free and deleted entries, the broken-sector list, the unused
	// frames, frame 63 — is what `format` writes, and is written again when the card goes in.

	/** The card `c` in the card format, into `out`; its length. */
	public static function toFormat(c:RawBuf, out:RawBuf):Int {
		var n = 0;
		var mask = 0;
		var at = HEADER;
		for (b in 1...FILE_BLOCKS + 1) {
			if (inUse(stateOf(c, b))) {
				Bulk.copy(out, at, c, b << 7, FRAME);
				Bulk.copy(out, at + FRAME, c, b * BLOCK, BLOCK);
				at += RECORD;
				n++;
				mask |= 1 << b;
			} else {}
		}
		RawMem.set32(out, 0, MAGIC);
		RawMem.set8(out, 4, VERSION);
		RawMem.set8(out, 5, n);
		RawMem.set16(out, 6, mask);
		RawMem.set32(out, 12, 0);
		RawMem.set32(out, 8, checksum(out, at));
		return at;
	}

	/**
		A card in the card format, `len` bytes of `src`, onto a freshly formatted `c`. False, and `c`
		left as it was, for anything that is not one: another version, a length that does not match
		its header, or a checksum that does not match its bytes.
	**/
	public static function fromFormat(c:RawBuf, src:RawBuf, len:Int):Bool {
		if (len < HEADER || RawMem.get32(src, 0) != MAGIC || RawMem.get8(src, 4) != VERSION) return false;
		else {}
		final n = RawMem.get8(src, 5);
		final mask = RawMem.get16(src, 6);
		if (n > FILE_BLOCKS || (mask & 1) != 0 || bits(mask) != n || len != HEADER + n * RECORD) return false;
		else {}
		if (checksum(src, len) != RawMem.get32(src, 8)) return false;
		else {}
		format(c);
		var at = HEADER;
		for (b in 1...FILE_BLOCKS + 1) {
			if (((mask >> b) & 1) != 0) {
				Bulk.copy(c, b << 7, src, at, FRAME);
				Bulk.copy(c, b * BLOCK, src, at + FRAME, BLOCK);
				at += RECORD;
			} else {}
		}
		return true;
	}

	static function checksum(buf:RawBuf, len:Int):Int {
		final h = Hash.region(Hash.FNV_OFFSET, buf, 4, 4);
		return Hash.region(h, buf, HEADER, len - HEADER);
	}

	static function bits(mask:Int):Int {
		var n = 0;
		for (b in 0...16) n += (mask >> b) & 1;
		return n;
	}
}
