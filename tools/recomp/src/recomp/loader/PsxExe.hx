package recomp.loader;

import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.loader.LoaderError;

/**
	A PS-EXE: the executable format the BIOS loads from disc.

	The header is 2048 bytes — one sector — of which only about fifty are used. The rest is
	padding and, in retail games, a region string the BIOS checks. Layout follows psx-spx,
	"CDROM File Formats".

	Two things here are load-bearing and easy to get wrong. `fileSize` counts the payload only,
	excluding this header, so a truncated dump shows up as `fileSize` exceeding what is actually
	present — worth a hard error rather than a mysterious disassembly failure five steps later.
	And `spBase`/`spOffset` are only a default: when the disc's SYSTEM.CNF carries a `STACK`
	entry, the BIOS uses that instead, which is why the loader surfaces both and lets the caller
	decide (see docs/specs/runtime.md §1).
**/
class PsxExe {
	public static inline var HEADER_SIZE = 0x800;
	static inline var MAGIC = "PS-X EXE";

	public final initialPc:Int;
	public final initialGp:Int;
	public final loadAddr:Int;
	public final fileSize:Int;
	public final dataAddr:Int;
	public final dataSize:Int;
	public final memfillAddr:Int;
	public final memfillSize:Int;
	public final spBase:Int;
	public final spOffset:Int;
	public final regionMarker:String;

	/** Exactly `fileSize` bytes: the image to place at `loadAddr`. */
	public final payload:Bytes;

	/** Notes that do not prevent loading but that a person should see. */
	public final warnings:Array<String>;

	function new(initialPc, initialGp, loadAddr, fileSize, dataAddr, dataSize, memfillAddr,
			memfillSize, spBase, spOffset, regionMarker, payload, warnings) {
		this.initialPc = initialPc;
		this.initialGp = initialGp;
		this.loadAddr = loadAddr;
		this.fileSize = fileSize;
		this.dataAddr = dataAddr;
		this.dataSize = dataSize;
		this.memfillAddr = memfillAddr;
		this.memfillSize = memfillSize;
		this.spBase = spBase;
		this.spOffset = spOffset;
		this.regionMarker = regionMarker;
		this.payload = payload;
		this.warnings = warnings;
	}

	/** The initial stack pointer the BIOS would use, absent a SYSTEM.CNF override.
	    `spBase == 0` means "leave the caller's stack alone", which homebrew loaders rely on. */
	public function initialSp():Int return spBase == 0 ? 0 : spBase + spOffset;

	/** Last address covered by the loaded image, inclusive. */
	public function loadEnd():Int return loadAddr + fileSize - 1;

	public function containsAddr(a:Int):Bool {
		final p = Vaddr.phys(a);
		final base = Vaddr.phys(loadAddr);
		return p >= base && p < base + fileSize;
	}

	/** Reads the word at a virtual address inside the loaded image. */
	public function readWord(addr:Int):Int {
		final off = Vaddr.phys(addr) - Vaddr.phys(loadAddr);
		if (off < 0 || off + 4 > payload.length) {
			throw new LoaderError('address ${Vaddr.hex(addr)} is outside the loaded image '
				+ '(${Vaddr.hex(loadAddr)}..${Vaddr.hex(loadEnd())})');
		}
		return payload.getInt32(off);
	}

	public static function parse(b:Bytes):PsxExe {
		if (b.length < HEADER_SIZE) {
			throw new LoaderError('file is ${b.length} bytes, too short to be a PS-EXE '
				+ '(the header alone is $HEADER_SIZE)');
		}
		if (b.getString(0, MAGIC.length) != MAGIC) {
			throw new LoaderError('not a PS-EXE: expected "$MAGIC" at offset 0, found '
				+ '"${printable(b, 0, 8)}"');
		}

		final initialPc   = b.getInt32(0x10);
		final initialGp   = b.getInt32(0x14);
		final loadAddr    = b.getInt32(0x18);
		final fileSize    = b.getInt32(0x1C);
		final dataAddr    = b.getInt32(0x20);
		final dataSize    = b.getInt32(0x24);
		final memfillAddr = b.getInt32(0x28);
		final memfillSize = b.getInt32(0x2C);
		final spBase      = b.getInt32(0x30);
		final spOffset    = b.getInt32(0x34);

		final warnings = [];
		final available = b.length - HEADER_SIZE;

		if (fileSize < 0 || fileSize > available) {
			throw new LoaderError('header claims a ${fileSize} byte payload but only ${available} '
				+ 'bytes follow the header — the dump is truncated');
		}
		if (fileSize == 0) throw new LoaderError("header claims an empty payload");
		if ((fileSize & 0x7FF) != 0) {
			// Retail images are always sector-aligned; homebrew linkers often are not.
			warnings.push('payload size ${Vaddr.hex(fileSize)} is not a multiple of 0x800 '
				+ '(normal for homebrew, unusual for a retail image)');
		}
		if ((loadAddr & 3) != 0) {
			throw new LoaderError('load address ${Vaddr.hex(loadAddr)} is not word-aligned');
		}
		if ((initialPc & 3) != 0) {
			throw new LoaderError('entry point ${Vaddr.hex(initialPc)} is not word-aligned');
		}
		if (!Vaddr.isRam(loadAddr)) {
			warnings.push('load address ${Vaddr.hex(loadAddr)} is outside main RAM');
		}
		if (available > fileSize) {
			warnings.push('${available - fileSize} bytes follow the payload and were ignored');
		}

		final exe = new PsxExe(initialPc, initialGp, loadAddr, fileSize, dataAddr, dataSize,
			memfillAddr, memfillSize, spBase, spOffset, readRegion(b),
			b.sub(HEADER_SIZE, fileSize), warnings);

		// Checked after construction so the message can use the accessors.
		if (!exe.containsAddr(initialPc)) {
			warnings.push('entry point ${Vaddr.hex(initialPc)} is outside the loaded image '
				+ '(${Vaddr.hex(loadAddr)}..${Vaddr.hex(exe.loadEnd())})');
		}
		return exe;
	}

	/** The region string retail discs carry at 0x4C. Zero-filled on most homebrew. */
	static function readRegion(b:Bytes):String {
		var out = new StringBuf();
		var i = 0x4C;
		while (i < HEADER_SIZE) {
			final c = b.get(i);
			if (c == 0) break;
			if (c < 0x20 || c > 0x7E) break;
			out.addChar(c);
			i++;
		}
		return out.toString();
	}

	static function printable(b:Bytes, pos:Int, len:Int):String {
		var out = new StringBuf();
		for (i in 0...len) {
			final c = b.get(pos + i);
			out.addChar(c >= 0x20 && c <= 0x7E ? c : ".".code);
		}
		return out.toString();
	}

	/** Human-readable summary — what `recompsx info` prints and what tests compare against. */
	public function describe():String {
		final lines = [
			'entry point   ${Vaddr.hex(initialPc)}',
			'initial gp    ${Vaddr.hex(initialGp)}',
			'load address  ${Vaddr.hex(loadAddr)}',
			'payload size  ${Vaddr.hex(fileSize)} (${fileSize} bytes)',
			'loaded range  ${Vaddr.hex(loadAddr)}..${Vaddr.hex(loadEnd())}',
			'bss fill      ' + (memfillSize == 0 ? "none"
				: '${Vaddr.hex(memfillAddr)} for ${Vaddr.hex(memfillSize)} bytes'),
			'initial sp    ' + (spBase == 0 ? "caller's (header requests no change)"
				: '${Vaddr.hex(initialSp())} (base ${Vaddr.hex(spBase)} + ${Vaddr.hex(spOffset)})'),
			'region        ' + (regionMarker == "" ? "(none)" : regionMarker)
		];
		for (w in warnings) lines.push('warning: $w');
		return lines.join("\n");
	}
}
