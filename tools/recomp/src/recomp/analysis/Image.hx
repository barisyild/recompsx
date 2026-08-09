package recomp.analysis;

import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.loader.LoaderError;
import recomp.loader.PsxExe;
import recomp.analysis.Kind;

/**
	A loaded program as analysis sees it: a flat, address-indexed image plus a running record of
	what each word turned out to be.

	This is the "universe" the specs refer to. The base executable is one; each overlay is
	another, being the base with that overlay's bytes patched over it — because an overlay's code
	must be analysed against the memory *it* will see, not against whatever happened to be
	resident when the base was analysed.

	Keeping classification here rather than inside the discovery pass means the coverage report
	is a straight read of this structure, and that a word claimed twice — by a function and by a
	jump table, say — is caught rather than silently resolved.
**/
class Image {
	public final name:String;
	public final baseAddr:Int;
	public final size:Int;
	public final bytes:Bytes;

	/** One entry per word. Indexed by `(addr - baseAddr) >> 2`. */
	final kinds:Array<Kind>;

	/** Which function claimed each word, for reporting overlaps. */
	final owner:Array<Int>;

	public function new(name:String, baseAddr:Int, bytes:Bytes) {
		this.name = name;
		this.baseAddr = Vaddr.canonRam(baseAddr);
		this.bytes = bytes;
		this.size = bytes.length;
		final words = size >> 2;
		kinds = [for (_ in 0...words) Kind.Unknown];
		owner = [for (_ in 0...words) 0];
	}

	public static function ofExe(name:String, exe:PsxExe):Image {
		return new Image(name, exe.loadAddr, exe.payload);
	}

	/**
		The executable with an overlay's bytes laid over it — one *universe*.

		An overlay is code the game loads from its disc into a fixed window of RAM, and while it is
		resident that window holds its bytes and not the executable's. Analysis has to see the same
		thing: a jump table inside the overlay indexes the overlay's data, and a function there
		reads the overlay's constants. Analysing overlay code against the executable's bytes would
		be reading one program through another's memory.

		So each overlay gets its own image, and the base gets its own, and they are analysed
		separately. The window may extend past the executable's end — usually does, since that is
		where a game has room — so the image grows to hold it.
	**/
	public static function ofExeWithOverlay(name:String, exe:PsxExe, overlay:Bytes,
			loadAddr:Int):Image {
		final base = Vaddr.canonRam(exe.loadAddr);
		final at = Vaddr.canonRam(loadAddr);
		if (at < base) {
			throw new LoaderError('an overlay at ${Vaddr.hex(at)} starts below the executable '
				+ '(${Vaddr.hex(base)}); windows below the load address are not supported');
		}
		final end = at + overlay.length;
		final exeEnd = base + exe.payload.length;
		final size = end > exeEnd ? end - base : exeEnd - base;

		final combined = Bytes.alloc(size);
		combined.blit(0, exe.payload, 0, exe.payload.length);
		combined.blit(at - base, overlay, 0, overlay.length);
		return new Image(name, exe.loadAddr, combined);
	}

	public inline function endAddr():Int return baseAddr + size;

	public inline function contains(addr:Int):Bool {
		final a = Vaddr.canonRam(addr);
		return a >= baseAddr && a < baseAddr + size;
	}

	/** True if a whole instruction fits at this address. */
	public inline function containsWord(addr:Int):Bool {
		final a = Vaddr.canonRam(addr);
		return a >= baseAddr && a + 4 <= baseAddr + size && (a & 3) == 0;
	}

	public function readWord(addr:Int):Int {
		if (!containsWord(addr)) {
			throw new LoaderError('${Vaddr.hex(addr)} is outside ${name} '
				+ '(${Vaddr.hex(baseAddr)}..${Vaddr.hex(endAddr() - 1)})');
		}
		return bytes.getInt32(Vaddr.canonRam(addr) - baseAddr);
	}

	inline function index(addr:Int):Int return (Vaddr.canonRam(addr) - baseAddr) >> 2;

	public function kindAt(addr:Int):Kind
		return containsWord(addr) ? kinds[index(addr)] : Kind.Unknown;

	public function ownerAt(addr:Int):Int
		return containsWord(addr) ? owner[index(addr)] : 0;

	/** Records a classification. Returns the previous owner if this word was already claimed by a
	    different function, so the caller can report the overlap rather than lose it. */
	public function claim(addr:Int, kind:Kind, byFunction:Int):Int {
		if (!containsWord(addr)) return 0;
		final i = index(addr);
		final previous = kinds[i] == Kind.Code && owner[i] != byFunction ? owner[i] : 0;
		kinds[i] = kind;
		owner[i] = byFunction;
		return previous;
	}

	public function claimRange(from:Int, toExclusive:Int, kind:Kind, byFunction:Int):Void {
		var a = Vaddr.canonRam(from);
		final end = Vaddr.canonRam(toExclusive);
		while (a < end) {
			claim(a, kind, byFunction);
			a += 4;
		}
	}

	/** Forgets every classification, keeping the bytes. Discovery runs a second pass once jump
	    tables are known, and starting from a clean slate is simpler — and more obviously correct
	    — than trying to unpick what the first pass concluded. */
	public function resetClassification():Void {
		for (i in 0...kinds.length) {
			kinds[i] = Kind.Unknown;
			owner[i] = 0;
		}
	}

	/** Word counts by kind, for the coverage report. */
	public function tally():Map<Kind, Int> {
		final out = [Kind.Unknown => 0, Kind.Code => 0, Kind.DataInText => 0, Kind.Padding => 0];
		for (k in kinds) out[k] = out[k] + 1;
		return out;
	}

	/**
		Runs of consecutive unclassified words, largest first.

		This is the working list for reverse engineering: every gap is either data the analyzer
		correctly left alone, or code it failed to reach. Sorting by size puts the ones worth
		looking at first, since a 40 KB hole is a missed subsystem and a 16-byte one is a table.
	**/
	public function unknownRuns(minWords:Int = 1):Array<{addr:Int, words:Int}> {
		final runs = [];
		var i = 0;
		while (i < kinds.length) {
			if (kinds[i] != Kind.Unknown) {
				i++;
				continue;
			}
			final start = i;
			while (i < kinds.length && kinds[i] == Kind.Unknown) i++;
			final len = i - start;
			if (len >= minWords) runs.push({addr: baseAddr + (start << 2), words: len});
		}
		runs.sort((a, b) -> b.words - a.words);
		return runs;
	}
}
