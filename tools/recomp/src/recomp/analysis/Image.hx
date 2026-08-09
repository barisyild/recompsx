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

	/**
		Where guessing at function boundaries stops making sense.

		The prologue sweep is a heuristic, and heuristics need a prior. Inside an executable it is a
		good one: the layout is text and then data, both written by a compiler, and a frame setup
		after a return really is a function nine times out of ten. A RAM capture appended above the
		executable is not that — it is mostly the game's assets, and sweeping it finds "functions"
		in texture data, whose first branch lands in a number.

		So the sweep stops here, and code above it is reached the honest way: from a seed, or from
		a call by something already known. Defaults to the whole image, which is what a plain
		executable wants.
	**/
	public var sweepEnd(default, null):Int;

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
		this.sweepEnd = this.baseAddr + size;
		kinds = [for (_ in 0...words) Kind.Unknown];
		owner = [for (_ in 0...words) 0];
	}

	function limitSweepTo(addr:Int):Image {
		sweepEnd = Vaddr.canonRam(addr);
		return this;
	}

	public static function ofExe(name:String, exe:PsxExe):Image {
		return new Image(name, exe.loadAddr, exe.payload);
	}

	/**
		The executable with a slice of a captured RAM image laid in above it.

		This is how overlays are analysed. A game that loads code from its disc runs machine code
		the executable never contained, so no amount of sweeping the executable will find it — the
		bytes have to be supplied. The runtime writes them out the first time a call lands in
		something it read from the disc, and this is where they come back in.

		The slice starts at the executable's end, never inside it. The captured RAM also holds the
		executable's own text, and it would be *almost* the same — but only almost, and letting a
		capture rewrite the code being analysed would make the tool's output depend on the state of
		a running game. Above the executable there was nothing to disagree with.
	**/
	public static function ofExeAndRam(name:String, exe:PsxExe, ram:Bytes, from:Int, to:Int):Image {
		final base = Vaddr.canonRam(exe.loadAddr);
		final exeEnd = base + exe.payload.length;
		final lo = Vaddr.canonRam(from) < exeEnd ? exeEnd : Vaddr.canonRam(from);
		final hi = Vaddr.canonRam(to);
		if (hi <= lo) return ofExe(name, exe);

		final combined = Bytes.alloc(hi - base);
		combined.blit(0, exe.payload, 0, exe.payload.length);
		// The capture is indexed by physical address: RAM is 2 MB and mirrors every 2 MB.
		final at = lo & 0x1FFFFF;
		final len = hi - lo;
		if (at + len > ram.length) {
			throw new LoaderError('the RAM capture is ${ram.length} bytes, too small to hold '
				+ '${Vaddr.hex(from)}..${Vaddr.hex(to)}');
		}
		combined.blit(lo - base, ram, at, len);
		return new Image(name, exe.loadAddr, combined).limitSweepTo(exeEnd);
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
