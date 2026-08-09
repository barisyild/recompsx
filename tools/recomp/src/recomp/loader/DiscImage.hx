package recomp.loader;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileSeek;

/**
	A disc image, as a flat array of 2048-byte sectors.

	The tool needs exactly one thing from a disc: the bytes of a file the game will load. That is
	a filesystem walk over sectors, and this is the sector half of it.

	**Three layouts, detected rather than configured.** A `.iso` holds 2048-byte sectors of user
	data and nothing else. A `.bin` holds the raw 2352-byte sectors a CD really carries, with the
	user data 16 bytes in on a Mode 1 disc and 24 on Mode 2 Form 1. Which one is in front of us is
	answered by the disc itself: the volume descriptor at LBA 16 begins with `CD001`, so looking
	for it at each candidate offset identifies the layout in at most three reads. Trusting a file
	extension instead would be one more thing that can be wrong about a dump.

	This deliberately duplicates the same detection in `src/runtime/cd/Iso9660.hx` rather than
	sharing it. The runtime's version reads through the backend ABI into a `RawBuf` and obeys the
	portable subset; this one reads through `sys.io` into `haxe.io.Bytes` and does not. Unifying
	them means inventing the byte-buffer abstraction `shared/psxdisc` was meant to be, which is
	worth doing — as its own change, not in the middle of this one. Two readers of a hundred lines
	each beat one abstraction introduced under pressure.
**/
class DiscImage {
	public static inline var USER_BYTES = 2048;

	static inline var PVD_LBA = 16;
	static inline var RAW_SIZE = 2352;

	public final path:String;

	/** Bytes per sector on disc: 2048 for a cooked image, 2352 for a raw one. */
	public final sectorSize:Int;

	/** Where the user data starts within a sector: 0, 16 (Mode 1) or 24 (Mode 2 Form 1). */
	public final userOffset:Int;

	final input:FileInput;
	final size:Int;

	function new(path:String, input:FileInput, size:Int, sectorSize:Int, userOffset:Int) {
		this.path = path;
		this.input = input;
		this.size = size;
		this.sectorSize = sectorSize;
		this.userOffset = userOffset;
	}

	/**
		Opens an image, or the image a CUE sheet points at.

		A CUE is followed rather than parsed: the tool wants the data track, which on every
		PlayStation disc is the first `FILE`, and the track list matters only to a CD-ROM
		controller emulating seeks. Anything more would be a second implementation of the runtime's
		disc model with no second caller.
	**/
	public static function open(path:String):DiscImage {
		final imagePath = StringTools.endsWith(path.toLowerCase(), ".cue")
			? firstFileOfCue(path) : path;
		if (!FileSystem.exists(imagePath)) {
			throw new LoaderError('no such disc image: $imagePath');
		}
		final input = File.read(imagePath, true);
		final size = FileSystem.stat(imagePath).size;

		final layouts = [
			{sector: USER_BYTES, offset: 0},
			{sector: RAW_SIZE, offset: 16},   // Mode 1
			{sector: RAW_SIZE, offset: 24},   // Mode 2 Form 1
		];
		for (l in layouts) {
			if (hasVolumeDescriptor(input, size, l.sector, l.offset)) {
				return new DiscImage(imagePath, input, size, l.sector, l.offset);
			}
		}
		input.close();
		throw new LoaderError('$imagePath has no ISO9660 volume descriptor at LBA 16 — it is '
			+ 'not a disc image this tool recognises');
	}

	static function hasVolumeDescriptor(input:FileInput, size:Int, sector:Int, offset:Int):Bool {
		final at = sector * PVD_LBA + offset;
		if (at + 6 > size) return false;
		input.seek(at, FileSeek.SeekBegin);
		final head = input.read(6);
		// Byte 0 is the descriptor type; bytes 1..5 spell the standard's name.
		return head.getString(1, 5) == "CD001";
	}

	/** The first data file a CUE names, resolved next to the sheet. */
	static function firstFileOfCue(cuePath:String):String {
		final dir = cuePath.lastIndexOf("/") >= 0
			? cuePath.substr(0, cuePath.lastIndexOf("/")) : ".";
		for (line in File.getContent(cuePath).split("\n")) {
			final trimmed = StringTools.trim(line);
			if (!StringTools.startsWith(trimmed.toUpperCase(), "FILE ")) continue;
			final open = trimmed.indexOf("\"");
			final close = trimmed.lastIndexOf("\"");
			if (open < 0 || close <= open) continue;
			final name = trimmed.substring(open + 1, close);
			// A sheet may name an absolute path, though almost none do.
            return StringTools.startsWith(name, "/") ? name : '$dir/$name';
		}
		throw new LoaderError('$cuePath names no FILE');
	}

	public function close():Void {
		input.close();
	}

	/** How many whole sectors the image holds. */
	public inline function totalSectors():Int {
		return Std.int(size / sectorSize);
	}

	/** One sector's user data. */
	public function readSector(lba:Int):Bytes {
		return readRaw(lba * sectorSize + userOffset, USER_BYTES);
	}

	/**
		Bytes out of a file's extent, cut at sector boundaries and reassembled.

		This is the reason the raw layouts need handling at all: on a 2352-byte image the bytes a
		file contains are not contiguous on disc, because every 2048 of them are wrapped in a
		header and an error-correction tail.
	**/
	public function readExtent(fileLba:Int, offset:Int, length:Int):Bytes {
		final out = Bytes.alloc(length);
		var done = 0;
		while (done < length) {
			final abs = offset + done;
			final lba = fileLba + Std.int(abs / USER_BYTES);
			final within = abs % USER_BYTES;
			var chunk = USER_BYTES - within;
			if (chunk > length - done) chunk = length - done;
			final at = lba * sectorSize + userOffset + within;
			out.blit(done, readRaw(at, chunk), 0, chunk);
			done += chunk;
		}
		return out;
	}

	function readRaw(at:Int, length:Int):Bytes {
		if (at + length > size) {
			throw new LoaderError('$path ends before offset ${at + length}; the dump is short');
		}
		input.seek(at, FileSeek.SeekBegin);
		return input.read(length);
	}
}
