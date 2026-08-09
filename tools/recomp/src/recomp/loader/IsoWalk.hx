package recomp.loader;

import haxe.io.Bytes;

/** Where a file lives on the disc: a starting sector and a length in bytes. */
typedef Extent = {lba:Int, length:Int};

/**
	Enough ISO9660 to answer one question: given `\DIR\NAME.EXT;1`, where does it start.

	Directories are walked from the root every time rather than cached. A build reads two or three
	files from a disc, the walk costs a handful of sector reads, and a cache here would be more
	code than it could ever save.

	No Joliet, no path table, no multi-session. PlayStation discs are plain ones, and every extra
	format supported is another way to be confidently wrong about a disc nobody will hand us.
	Layout from ECMA-119, which is what psx-spx points at for the filesystem.
**/
class IsoWalk {
	static inline var PVD_LBA = 16;

	/** Offset of the root directory record inside the primary volume descriptor. */
	static inline var ROOT_RECORD = 156;

	// Field offsets within a directory record.
	static inline var REC_LENGTH = 0;
	static inline var REC_EXTENT = 2;
	static inline var REC_SIZE = 10;
	static inline var REC_NAME_LEN = 32;
	static inline var REC_NAME = 33;

	final disc:DiscImage;
	final root:Extent;

	public function new(disc:DiscImage) {
		this.disc = disc;
		final pvd = disc.readSector(PVD_LBA);
		root = {
			lba: le32(pvd, ROOT_RECORD + REC_EXTENT),
			length: le32(pvd, ROOT_RECORD + REC_SIZE),
		};
	}

	/**
		Resolves a path, or returns null if the disc has no such file.

		Separators may be either slash, and empty components are skipped, so `\CRASHBSH\FILE.BIN;1`
		and `/CRASHBSH/FILE.BIN;1` name the same thing. A game writes them the way its own library
		does and there is no reason for the config to have to match.
	**/
	public function find(path:String):Extent {
		var at = root;
		for (part in split(path)) {
			at = step(part, at);
			if (at == null) return null;
		}
		return at;
	}

	static function split(path:String):Array<String> {
		final out = [];
		for (part in StringTools.replace(path, "\\", "/").split("/")) {
			if (part.length > 0) out.push(part);
		}
		return out;
	}

	/** Scans one directory's extent for a name. */
	function step(name:String, dir:Extent):Extent {
		final sectors = Math.ceil(dir.length / DiscImage.USER_BYTES);
		for (s in 0...sectors) {
			final found = scan(disc.readSector(dir.lba + s), name);
			if (found != null) return found;
		}
		return null;
	}

	static function scan(sector:Bytes, name:String):Extent {
		var off = 0;
		while (off < DiscImage.USER_BYTES) {
			final len = sector.get(off + REC_LENGTH);
			// A zero length means the rest of the sector is padding: records never span sectors.
			if (len == 0) return null;
			if (matches(sector, off, name)) {
				return {lba: le32(sector, off + REC_EXTENT), length: le32(sector, off + REC_SIZE)};
			}
			off += len;
		}
		return null;
	}

	/**
		Compares a record's name to ours, ignoring case and the version suffix on either side.

		ISO9660 stores names upper-cased with `;1` appended, and games mostly write them that way
		too — but not always the same way as each other. Matching loosely costs nothing and avoids
		a class of failure that presents as a missing file on a disc that plainly has it.
	**/
	static function matches(sector:Bytes, off:Int, name:String):Bool {
		final nameLen = sector.get(off + REC_NAME_LEN);
		var recorded = "";
		for (i in 0...nameLen) recorded += String.fromCharCode(sector.get(off + REC_NAME + i));
		return stripVersion(recorded) == stripVersion(name);
	}

	static function stripVersion(s:String):String {
		final semi = s.indexOf(";");
		return (semi >= 0 ? s.substr(0, semi) : s).toUpperCase();
	}

	static function le32(b:Bytes, off:Int):Int {
		return b.get(off) | (b.get(off + 1) << 8) | (b.get(off + 2) << 16) | (b.get(off + 3) << 24);
	}
}
