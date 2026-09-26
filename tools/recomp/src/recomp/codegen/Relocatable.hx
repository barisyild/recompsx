package recomp.codegen;

import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.analysis.AnalysisError;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.config.GameConfig.RelocConfig;
import recomp.mips.Decoder;
import recomp.mips.Op;

/** One compiled relocatable function: its code, where it was traced, and its identity. */
class RelocFunc {
	public final func:Func;
	public final unit:RelocUnit;
	/** SHA-1 over (offset from the entry, word) for every instruction it covers. */
	public final signature:String;
	public var handle:Int = -1;

	public function new(func:Func, unit:RelocUnit, signature:String) {
		this.func = func;
		this.unit = unit;
		this.signature = signature;
	}
}

/** One aligned unit of a source file, mapped at the nominal base, with its own analysis. */
class RelocUnit {
	public final image:Image;
	public final discovery:Discovery;
	public var emitter:Emitter;

	public function new(image:Image, discovery:Discovery) {
		this.image = image;
		this.discovery = discovery;
	}
}

/** A key whose occurrences do not all name one function, and how the runtime tells them apart. */
class RelocGroup {
	/** Word offsets from the entry the runtime reads. */
	public final positions:Array<Int> = [];
	/** One row per distinct reading: the words at `positions`, then which function. */
	public final rowWords:Array<Array<Int>> = [];
	public final rowFuncs:Array<Int> = [];

	public function new() {}
}

/**
	Everything the program needs about one `relocatable` stanza (ADR-0025).

	Built from the disc alone: every file the stanza names is read, every aligned occurrence of
	the entry marker becomes an entry at the word after it, and each entry is traced as a function
	in the unit it sits in, mapped at a nominal base no real code occupies. Whatever the trace
	rejects is data that happened to contain the marker. What survives is deduplicated by content —
	the same object's code is on the disc once per level that uses it — and keyed by the words at
	its entry, which is all the runtime can see when the game jumps there.
**/
class RelocSet {
	public final config:RelocConfig;
	public final nominalBase:Int;
	public final functions:Array<RelocFunc> = [];
	public final units:Array<RelocUnit> = [];
	/** Runtime keys, ascending, and what each resolves to: a function index, or -1 - group. */
	public final keys:Array<Int> = [];
	public final keyValues:Array<Int> = [];
	public final groups:Array<RelocGroup> = [];

	public var files(default, null) = 0;
	public var entries(default, null) = 0;
	public var rejected(default, null) = 0;
	public var notPositionIndependent(default, null) = 0;
	public var tooShortForKey(default, null) = 0;

	public var shards:Array<Shards.Shard> = [];

	final bySignature:Map<String, Int> = [];

	public function new(config:RelocConfig, nominalBase:Int) {
		this.config = config;
		this.nominalBase = nominalBase;
	}

	/**
		A base for the units that nothing real lives at: near the top of RAM, rounded down to the
		unit. The caller checks it against the executable and every overlay window, because a
		unit that overlapped them would make a call into real code look like a call into itself.
	**/
	public static function chooseBase(unit:Int):Int {
		// Two units down, not one: the window's end must stay inside RAM too, and 0x80200000
		// itself folds back to 0x80000000 as a RAM address.
		return (0x80200000 - 2 * unit) & ~(unit - 1);
	}

	/** Adds one source file. Occurrence bookkeeping is kept here; functions accumulate. */
	public function addFile(path:String, bytes:Bytes, occurrences:Array<Occurrence>):Void {
		files++;
		final unitSize = config.unit;
		final words = bytes.length >> 2;
		final entriesByUnit:Map<Int, Array<Int>> = [];
		final unitOrder:Array<Int> = [];
		for (i in 0...words) {
			if (bytes.getInt32(i << 2) != config.marker) continue;
			final entryOff = (i + 1) << 2;
			if (entryOff >= bytes.length) continue;
			final u = Std.int(entryOff / unitSize);
			if (!entriesByUnit.exists(u)) { entriesByUnit.set(u, []); unitOrder.push(u); }
			else {}
			entriesByUnit.get(u).push(entryOff - u * unitSize);
		}
		for (u in unitOrder) {
			final start = u * unitSize;
			final len = (start + unitSize > bytes.length ? bytes.length - start : unitSize) & ~3;
			final unitBytes = bytes.sub(start, len);
			final image = new Image('$path@${StringTools.hex(start)}', nominalBase, unitBytes);
			final d = new Discovery(image, nominalBase, nominalBase + len, true);
			final offsets = entriesByUnit.get(u);
			for (off in offsets) {
				entries++;
				final at = nominalBase + off;
				if (d.plausibleEntry(at)) d.addSeed(at, Discovery.defaultName(at), Confidence.Entry);
				else {}
			}
			// No sweep: a data file is mostly not code, and the entries are all known. No table
			// recovery either: position-independent code cannot hold absolute jump tables.
			d.run(false, false);
			final unit = new RelocUnit(image, d);
			var used = false;
			for (off in offsets) {
				final at = nominalBase + off;
				final fn = d.functions.get(Vaddr.canonRam(at));
				if (fn == null) { rejected++; continue; }
				else {}
				if (!positionIndependent(fn, nominalBase, nominalBase + len)) {
					notPositionIndependent++;
					continue;
				} else {}
				final sig = signatureOf(fn, image);
				var index = bySignature.get(sig);
				if (index == null) {
					index = functions.length;
					bySignature.set(sig, index);
					fn.name = "r_" + sig.substr(0, 12);
					functions.push(new RelocFunc(fn, unit, sig));
					used = true;
				} else {}
				if (off + config.hashWords * 4 > len) { tooShortForKey++; continue; }
				else {}
				occurrences.push(new Occurrence(unitBytes, off, index,
					keyOf(unitBytes, off, config.hashWords)));
			}
			if (used) units.push(unit);
			else {}
		}
	}

	/**
		No call or jump may land inside the unit by absolute address: such code only works where it
		was linked, and the game puts it somewhere else. (Branches are relative and fine.)
	**/
	static function positionIndependent(fn:Func, lo:Int, hi:Int):Bool {
		for (c in fn.calls) if (!c.indirect && c.target >= lo && c.target < hi) return false;
		for (c in fn.tailCalls) if (c.target >= lo && c.target < hi) return false;
		return true;
	}

	static function signatureOf(fn:Func, image:Image):String {
		final addrs = [for (a in fn.blocks.keys()) a];
		addrs.sort((a, b) -> a - b);
		final buf = new haxe.io.BytesBuffer();
		for (a in addrs) {
			final b = fn.blocks.get(a);
			for (i in 0...b.length) {
				final at = a + i * 4;
				buf.addInt32((at - fn.entry) | 0);
				buf.addInt32(image.readWord(at));
			}
		}
		return haxe.crypto.Sha1.make(buf.getBytes()).toHex();
	}

	/**
		FNV-1a over `n` words from `off`, byte by byte in memory order. The runtime computes the
		same function over emulated RAM (`RelocTable.keyAt`); the two are the same lines, and the
		prime is written as its shifts so that no wide multiply can lose bits on either side.
	**/
	public static function keyOf(bytes:Bytes, off:Int, n:Int):Int {
		var h = 0x811C9DC5;
		for (i in 0...n * 4) {
			h = (h ^ bytes.get(off + i)) | 0;
			h = (h + ((h << 1) | 0) + ((h << 4) | 0) + ((h << 7) | 0) + ((h << 8) | 0)
				+ ((h << 24) | 0)) | 0;
		}
		return h;
	}

	/**
		Turns occurrences into the runtime's table: one key per distinct entry reading, and for a
		key several different functions share, the fewest word positions that tell them apart.

		Positions are chosen greedily among the offsets the candidates cover, pair by pair, until no
		two occurrences of different functions read the same. Two occurrences of the same function
		may read differently there (the words around code are bytecode); each distinct reading is a
		row, so every occurrence on the disc is recognised.
	**/
	public function finish(occurrences:Array<Occurrence>):Void {
		final byKey:Map<Int, Array<Occurrence>> = [];
		final keyOrder:Array<Int> = [];
		for (o in occurrences) {
			if (!byKey.exists(o.key)) { byKey.set(o.key, []); keyOrder.push(o.key); }
			else {}
			byKey.get(o.key).push(o);
		}
		keyOrder.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		for (k in keyOrder) {
			final list = byKey.get(k);
			var single = true;
			for (o in list) if (o.func != list[0].func) single = false;
			keys.push(k);
			if (single) { keyValues.push(list[0].func); continue; }
			else {}
			final g = separate(list);
			keyValues.push(-1 - groups.length);
			groups.push(g);
		}
	}

	function separate(list:Array<Occurrence>):RelocGroup {
		final g = new RelocGroup();
		// Candidate offsets: every word any candidate function covers, relative to its entry.
		final covered:Map<Int, Bool> = [];
		for (o in list) {
			final fn = functions[o.func].func;
			for (a in fn.blocks.keys()) {
				final b = fn.blocks.get(a);
				for (i in 0...b.length) covered.set(((a - fn.entry) >> 2) + i, true);
			}
		}
		final candidates = [for (c in covered.keys()) c];
		candidates.sort((a, b) -> a - b);
		var guard = 0;
		while (true) {
			if (++guard > 64) throw new AnalysisError('relocatable "${config.id}": could not separate '
				+ 'functions sharing a key in 64 positions');
			else {}
			var a:Occurrence = null;
			var b:Occurrence = null;
			for (i in 0...list.length) {
				for (j in 0...i) {
					if (list[i].func != list[j].func && sameReading(list[i], list[j], g.positions)) {
						a = list[i];
						b = list[j];
						break;
					} else {}
				}
				if (a != null) break;
				else {}
			}
			if (a == null) break;
			else {}
			var picked = false;
			for (c in candidates) {
				if (g.positions.indexOf(c) >= 0) continue;
				final wa = a.wordAt(c);
				final wb = b.wordAt(c);
				if (wa != null && wb != null && wa != wb) { g.positions.push(c); picked = true; break; }
				else {}
			}
			if (!picked) throw new AnalysisError('relocatable "${config.id}": two different functions '
				+ 'read identically at every word either covers');
			else {}
		}
		for (o in list) {
			final reading = [for (p in g.positions) { final w = o.wordAt(p); w == null ? 0 : w; }];
			var known = false;
			for (r in 0...g.rowWords.length) {
				if (sameWords(g.rowWords[r], reading)) { known = true; break; }
				else {}
			}
			if (!known) { g.rowWords.push(reading); g.rowFuncs.push(o.func); }
			else {}
		}
		return g;
	}

	static function sameReading(a:Occurrence, b:Occurrence, positions:Array<Int>):Bool {
		for (p in positions) {
			final wa = a.wordAt(p);
			final wb = b.wordAt(p);
			if (wa == null || wb == null || wa != wb) return false;
			else {}
		}
		return true;
	}

	static function sameWords(a:Array<Int>, b:Array<Int>):Bool {
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	public function describe():String {
		return 'relocatable "${config.id}": $files files, $entries entries, '
			+ '${functions.length} distinct functions, $rejected rejected as data'
			+ (notPositionIndependent > 0 ? ', $notPositionIndependent not position independent' : '')
			+ (tooShortForKey > 0 ? ', $tooShortForKey too close to a unit end to key' : '')
			+ '; ${keys.length} keys, ${groups.length} shared';
	}
}

/** One place an entry appears on the disc: its bytes, which function it is, its key. */
class Occurrence {
	public final unitBytes:Bytes;
	public final off:Int;
	public final func:Int;
	public final key:Int;

	public function new(unitBytes:Bytes, off:Int, func:Int, key:Int) {
		this.unitBytes = unitBytes;
		this.off = off;
		this.func = func;
		this.key = key;
	}

	/** The word `p` words from the entry, or null outside the unit. */
	public function wordAt(p:Int):Null<Int> {
		final at = off + p * 4;
		if (at < 0 || at + 4 > unitBytes.length) return null;
		return unitBytes.getInt32(at);
	}
}
