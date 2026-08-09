package cd;

import core.Runtime;
import shim.Backend;
import shim.IntMath;
import shim.RawBuf;
import shim.RawMem;

/**
	Finding files in a disc image.

	Enough ISO9660 to answer the one question a PlayStation game asks: given `\\DIR\\NAME.EXT;1`,
	where does it start and how long is it. Directories are walked from the root each time rather
	than cached, because a game opens a handful of files per level and the walk is a few sector
	reads — a cache here would cost more in code than it saves in time.

	**Two sector layouts, detected rather than configured.** A `.iso` holds 2048-byte sectors of
	user data. A `.bin` holds the raw 2352-byte sectors a CD really carries, with the user data at
	an offset that depends on the mode: 16 bytes into a Mode 1 sector, 24 into Mode 2 Form 1. The
	giveaway is the volume descriptor's `CD001` signature at LBA 16, which is looked for at each
	candidate offset — the disc identifies its own format, which is better than trusting a filename.

	No Joliet, no path table, no multi-session. PlayStation discs are plain, and every extra format
	is a way to be wrong about a disc nobody will hand us.
**/
class Iso9660 {
	/** Where the primary volume descriptor lives, on every ISO9660 disc ever made. */
	static inline var PVD_LBA = 16;

	/** User bytes in a sector, whatever the image wraps them in. Public because tracking a load
	    back to the disc is arithmetic in these units (`kernel.OverlayMgr`). */
	public static inline var USER_BYTES = 2048;

	/** Candidate (sector size, offset of user data) pairs, most common first. */
	static inline var RAW_SIZE = 2352;

	static var slot = -1;
	static var sectorSize = 0;
	static var userOffset = 0;
	static var rootLba = 0;
	static var rootSize = 0;

	static var sector:RawBuf;

	public static var mounted(default, null) = false;

	/**
		Opens an image and works out its shape.

		Returns false rather than reporting a hard failure: a caller may reasonably try an image
		path, find it is not one, and fall back to a directory.
	**/
	/**
		Allocates the scratch sector, once, at boot.

		Not lazily on first use: `RawBuf` is a value type on the C++ side, so it can never be null
		and `if (buf == null)` does not compile there at all. Which is the rule this runtime already
		has — nothing allocates after boot — arriving from a second direction.
	**/
	public static function init():Void {
		sector = RawMem.alloc(RAW_SIZE);
		mounted = false;
	}

	public static function mount(backendSlot:Int):Bool {
		slot = backendSlot;
		mounted = false;
		if (!detectLayout()) return false;
		else {}
		if (!readPvd()) return false;
		else {}
		mounted = true;
		Runtime.noteOnce(0x63000000, "mounted a disc image: " + sectorSize + "-byte sectors, "
			+ "user data at +" + userOffset + ", root directory at LBA " + rootLba);
		return true;
	}

	/**
		Finds the sector layout by looking for the volume descriptor where each layout would put it.

		`CD001` at offset 1 of the descriptor is the whole test. Trying 2048 first means a plain
		ISO costs one read; a raw image costs two more.
	**/
	static function detectLayout():Bool {
		if (signatureAt(USER_BYTES, 0)) return adopt(USER_BYTES, 0);
		else if (signatureAt(RAW_SIZE, 16)) return adopt(RAW_SIZE, 16);   // Mode 1
		else if (signatureAt(RAW_SIZE, 24)) return adopt(RAW_SIZE, 24);   // Mode 2 Form 1
		else return notAnImage();
	}

	static function adopt(size:Int, offset:Int):Bool {
		sectorSize = size;
		userOffset = offset;
		return true;
	}

	static function notAnImage():Bool {
		Runtime.reportOnce(0x63000001, "no ISO9660 volume descriptor — not a disc image we know");
		return false;
	}

	static function signatureAt(size:Int, offset:Int):Bool {
		final at = size * PVD_LBA + offset;
		if (Backend.fileRead(slot, at, sector, 8) < 8) return false;
		else {}
		// Byte 0 is the descriptor type; bytes 1..5 are "CD001".
		return RawMem.get8(sector, 1) == 0x43 && RawMem.get8(sector, 2) == 0x44
			&& RawMem.get8(sector, 3) == 0x30 && RawMem.get8(sector, 4) == 0x30
			&& RawMem.get8(sector, 5) == 0x31;
	}

	/** The root directory's extent lives in the PVD's own directory record, at offset 156. */
	static function readPvd():Bool {
		if (!readSector(PVD_LBA)) return false;
		else {}
		rootLba = le32(156 + 2);
		rootSize = le32(156 + 10);
		return rootLba > 0;
	}

	// ---- lookup ------------------------------------------------------------------------------

	/** Where the last successful `find` put its answer. */
	public static var foundLba(default, null) = 0;
	public static var foundSize(default, null) = 0;

	/**
		Resolves a path like `\\CRASHBSH\\LEVEL.BIN;1`, one component at a time.

		The version suffix and the case are both ignored on comparison. ISO9660 stores names
		upper-cased with `;1` appended and games write them the same way, but not always the same
		way as each other — matching loosely costs nothing and avoids a class of failure that looks
		like a missing file.
	**/
	public static function find(path:String):Bool {
		if (!mounted) return false;
		else {}
		var lba = rootLba;
		var size = rootSize;
		var start = 0;
		while (start < path.length) {
			var end = start;
			while (end < path.length && path.charAt(end) != "\\" && path.charAt(end) != "/") end++;
			final part = path.substring(start, end);
			if (part.length > 0 && !step(part, lba, size)) return false;
			else {}
			if (part.length > 0) { lba = foundLba; size = foundSize; }
			else {}
			start = end + 1;
		}
		return true;
	}

	/** Scans one directory extent for a name, leaving its extent in `foundLba`/`foundSize`. */
	static function step(name:String, dirLba:Int, dirSize:Int):Bool {
		final sectors = IntMath.div(dirSize + USER_BYTES - 1, USER_BYTES);
		for (s in 0...sectors) {
			if (!readSector(dirLba + s)) return false;
			else {}
			if (scanSector(name)) return true;
			else {}
		}
		return false;
	}

	static function scanSector(name:String):Bool {
		var off = 0;
		while (off < USER_BYTES) {
			final len = RawMem.get8(sector, off);
			// A zero length means the rest of the sector is padding: records never span sectors.
			if (len == 0) return false;
			else {}
			if (matches(off, name)) return recordFound(off);
			else {}
			off += len;
		}
		return false;
	}

	static function recordFound(off:Int):Bool {
		foundLba = le32(off + 2);
		foundSize = le32(off + 10);
		return true;
	}

	/** Compares the record's name to ours, ignoring case and the `;1` on either side. */
	static function matches(off:Int, name:String):Bool {
		final nameLen = RawMem.get8(sector, off + 32);
		var recEnd = nameLen;
		for (i in 0...nameLen) {
			if (RawMem.get8(sector, off + 33 + i) == 0x3B) { recEnd = i; break; }
			else {}
		}
		var wantEnd = name.length;
		for (i in 0...name.length) {
			if (name.charAt(i) == ";") { wantEnd = i; break; }
			else {}
		}
		if (recEnd != wantEnd) return false;
		else {}
		for (i in 0...recEnd) {
			// Compared as one-character strings rather than codes. `String.charCodeAt` on a String
			// *parameter* does not survive reflaxe.CPP — it indexes to a `char` and then calls a
			// method on it — though it compiles elsewhere, which is why this is a note here and not
			// a blanket rule. Cold path anyway: a few name lookups per level.
			if (upperChar(String.fromCharCode(RawMem.get8(sector, off + 33 + i)))
					!= upperChar(name.charAt(i))) return false;
			else {}
		}
		return true;
	}

	static inline function upperChar(c:String):String {
		return c.toUpperCase();
	}

	// ---- reading -----------------------------------------------------------------------------

	/**
		One sector's user data, for the CD-ROM controller.

		The controller reads by absolute sector, not by file — libcd seeks to an LBA it worked out
		itself and streams from there, so it needs the disc as a flat array of sectors rather than
		as a filesystem. Same layout arithmetic, different caller.
	**/
	public static function rawSector(lba:Int, dst:RawBuf):Bool {
		if (!mounted) return false;
		else {}
		return Backend.fileRead(slot, lba * sectorSize + userOffset, dst, USER_BYTES) == USER_BYTES;
	}

	/** Where a raw sector's own 4-byte address header sits, after the 12 sync bytes. */
	static inline var HEADER_AT = 12;

	/** Everything from the header to the end of the sector — Setmode bit 5's unit. */
	public static inline var WHOLE_BYTES = 0x924;

	/**
		A sector as the drive presents it with `Setmode` bit 5 set: header first, then the data.

		Not a fussy option. libcd reads whole sectors precisely so it can look at the four header
		bytes — minute, second, frame, mode — and check that the sector it was handed is the one it
		asked for. Serving it 2048 bytes of user data instead puts file contents where the address
		belongs, so every sector reads as the wrong sector and a perfectly good read reports a
		sector error.

		On a 2352-byte image the bytes are simply there. On a cooked 2048-byte one they are not, and
		they have to be built: the header is a function of the LBA, and a disc that has thrown away
		its addresses has thrown away nothing that cannot be recomputed. The EDC/ECC tail is left
		zero — it is not checked by anything on this side of a real drive.
	**/
	public static function wholeSector(lba:Int, dst:RawBuf):Bool {
		if (!mounted) return false;
		else if (sectorSize == RAW_SIZE) {
			return Backend.fileRead(slot, lba * RAW_SIZE + HEADER_AT, dst, WHOLE_BYTES)
				== WHOLE_BYTES;
		} else return synthesizeWhole(lba, dst);
	}

	static function synthesizeWhole(lba:Int, dst:RawBuf):Bool {
		writeHeader(lba, dst);
		// Subheader, twice as the format requires: file 0, channel 0, submode "data", coding 0.
		for (i in 0...2) {
			RawMem.set8(dst, 4 + i * 4, 0);
			RawMem.set8(dst, 5 + i * 4, 0);
			RawMem.set8(dst, 6 + i * 4, 0x08);
			RawMem.set8(dst, 7 + i * 4, 0);
		}
		for (i in 0...WHOLE_BYTES - 12 - USER_BYTES) RawMem.set8(dst, 12 + USER_BYTES + i, 0);
		// Staged through the scratch sector because the backend always fills a buffer from its
		// start — `bp_file_read` has no destination offset, deliberately, since every extra
		// parameter in that header is one more thing each console port has to get right.
		if (!readSector(lba)) return false;
		else {}
		for (i in 0...USER_BYTES) RawMem.set8(dst, 12 + i, RawMem.get8(sector, i));
		return true;
	}

	/** The sector's address, in the minutes/seconds/frames the drive counts in. */
	static function writeHeader(lba:Int, dst:RawBuf):Void {
		// LBA 0 is 00:02:00 on the disc: the first 150 frames are the lead-in.
		final total = lba + 150;
		RawMem.set8(dst, 0, toBcd(IntMath.div(total, 60 * 75)));
		RawMem.set8(dst, 1, toBcd(IntMath.mod(IntMath.div(total, 75), 60)));
		RawMem.set8(dst, 2, toBcd(IntMath.mod(total, 75)));
		RawMem.set8(dst, 3, 2);   // Mode 2, which is what a PlayStation disc carries
	}

	static inline function toBcd(v:Int):Int {
		return (IntMath.mod(IntMath.div(v, 10), 10) << 4) | IntMath.mod(v, 10);
	}

	/** How many sectors the image holds — the disc's length, for `GetTD`. */
	public static function totalSectors():Int {
		if (!mounted) return 0;
		else {}
		return IntMath.div(Backend.fileSize(slot), sectorSize);
	}

	/** Reads one sector's user data into the scratch buffer. */
	static function readSector(lba:Int):Bool {
		return Backend.fileRead(slot, lba * sectorSize + userOffset, sector, USER_BYTES)
			== USER_BYTES;
	}

	/**
		Reads user bytes out of a file's extent, skipping whatever the sector layout wraps them in.

		This is why the raw layouts need handling at all: on a 2352-byte image the bytes a game
		asked for are not contiguous in the file, so a read has to be cut at sector boundaries and
		reassembled.
	**/
	public static function readAt(fileLba:Int, offset:Int, dst:RawBuf, dstOff:Int, len:Int):Int {
		var done = 0;
		while (done < len) {
			final abs = offset + done;
			final lba = fileLba + IntMath.div(abs, USER_BYTES);
			final within = abs % USER_BYTES;
			var chunk = USER_BYTES - within;
			if (chunk > len - done) chunk = len - done;
			else {}
			final at = lba * sectorSize + userOffset + within;
			if (Backend.fileRead(slot, at, dst, chunk + dstOff) < 0) return done;
			else {}
			// The backend writes from the start of the buffer, so a chunk at a time it is.
			done += chunk;
			if (chunk == 0) break;
			else {}
		}
		return done;
	}

	static function le32(off:Int):Int {
		return RawMem.get8(sector, off)
			| (RawMem.get8(sector, off + 1) << 8)
			| (RawMem.get8(sector, off + 2) << 16)
			| (RawMem.get8(sector, off + 3) << 24);
	}
}
