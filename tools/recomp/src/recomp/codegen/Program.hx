package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.loader.PsxExe;
import recomp.codegen.Shards;
import recomp.codegen.Shards.Shard;
import recomp.codegen.Universe;
import sys.FileSystem;
import sys.io.File;

/** One universe's dispatch rows: sorted addresses, and what each resolves to. */
typedef Rows = {addrs:Array<Int>, handle:Map<Int, Int>, block:Map<Int, Int>};

/**
	Writes a whole recompiled program: one file per shard, plus the dispatch table and the
	program's own facts.

	Everything emitted here is machine-written and is never edited by hand — a defect in the
	output is a defect in this tool, and the fix is to regenerate. The output is also
	deterministic: the same executable and the same tool version produce byte-identical files, so
	`git diff` on generated code shows what actually changed rather than what happened to move.
**/
class Program {
	final exe:PsxExe;

	/** Universe 0 is the executable; the rest are overlays, in config order. */
	final universes:Array<Universe>;

	/** Function bodies already emitted, keyed by their text, mapped to the class holding them. */
	final emitted:Map<String, String> = [];

	public var filesWritten(default, null) = 0;
	public var linesWritten(default, null) = 0;

	/** Function bodies a second universe did not need to emit because the first had them. */
	public var deduplicated(default, null) = 0;

	public function new(universes:Array<Universe>, exe:PsxExe, limit:Int = 0) {
		this.universes = universes;
		this.exe = exe;

		// Shard indices are program-wide: the base takes the first block and each overlay
		// continues from where the last stopped, so a handle names one shard in the whole program.
		var nextIndex = 0;
		for (u in universes) {
			u.shards = new Shards(u.discovery, limit, nextIndex, u.classPrefix());
			nextIndex += u.shards.shards.length;
		}
		if (nextIndex > MAX_SHARDS) {
			throw new recomp.analysis.AnalysisError('this program needs $nextIndex shards; a '
				+ 'handle has room for $MAX_SHARDS (ADR-0002: the top eleven bits of an Int)');
		}

		for (u in universes) {
			u.emitter = new Emitter(u.image, u.discovery);
			u.emitter.staticTargetOf = a -> staticTargetFor(u, a);
		}
		checkFingerprintsDistinct();
	}

	/** A handle packs the shard index into the bits above the slot; this is what fits. */
	static inline var MAX_SHARDS = 2047;

	/**
		Where a call from `from` to `addr` should go, or null to dispatch it by address.

		Three answers, and the middle one is the whole overlay design:

		- Inside the calling universe's own scope, if it found a function there: a direct call.
		  An overlay calling into itself is safe because the caller running proves the callee is
		  resident — they arrived on the disc together.
		- Inside *some other* universe's window: by address. From the executable, nothing knows
		  which overlay is loaded; from one overlay into another's window, the same. That is not a
		  limitation to work around, it is what the hardware does, and the runtime's table is where
		  the answer lives.
		- In the executable, outside every window: a direct call. The base is always resident.
	**/
	function staticTargetFor(from:Universe, addr:Int):String {
		final a = Vaddr.canonRam(addr);
		// An overlay's own functions first: the caller running proves they are resident. This
		// must not apply to the executable — the executable can have functions *inside* a window
		// (windows overlap its tail), and those are exactly the ones whose bytes may be gone.
		if (!from.isBase() && from.shards.has(a)) return from.shards.classOf(a);
		if (inSomeWindow(a)) return null;
		final base = universes[0];
		return base.shards.has(a) ? base.shards.classOf(a) : null;
	}

	function inSomeWindow(addr:Int):Bool {
		for (u in universes) if (u.contains(addr)) return true;
		return false;
	}

	public function writeTo(dir:String):Void {
		ensureDir(dir);
		// Remove every previously generated file first. Shard names carry their split point, so
		// when a discovery change moves a split, the old file's name no longer matches anything —
		// and a directory that accumulates every layout it has ever had is a haunted one: twenty
		// files where eleven belong, and any tooling that globs `Fns_*.hx` reads functions from
		// builds that no longer exist. Generated output is machine-owned; nothing hand-edited
		// lives here to protect (golden rule 5).
		for (name in FileSystem.readDirectory(dir)) {
			if (StringTools.endsWith(name, ".hx")) FileSystem.deleteFile('$dir/$name');
		}
		for (u in universes) {
			for (s in u.shards.shards) write('$dir/${s.className}.hx', shardSource(u, s));
		}
		write('$dir/FnTable.hx', fnTableSource());
		write('$dir/Overlays.hx', overlaysSource());
		write('$dir/GameInfo.hx', gameInfoSource());
	}

	// ---- one shard --------------------------------------------------------------------------

	function shardSource(u:Universe, shard:Shard):String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tFunctions ${Vaddr.hex(shard.functions[0].entry)}'
			+ '..${Vaddr.hex(shard.functions[shard.functions.length - 1].endAddr - 1)}'
			+ ' — ${shard.functions.length} of them');
		if (!u.isBase()) buf.add(', from overlay "${u.overlay.id}"');
		buf.add('.\n');
		buf.add('**/\n');
		buf.add('class ${shard.className} {\n');

		for (fn in shard.functions) {
			buf.add(bodyOf(u, shard, fn));
			buf.add("\n");
		}

		// The shard's own dispatcher. Every function is reachable from here, which is also what
		// keeps them alive through `-dce full` — `@:keep` is not honoured upstream.
		buf.add('\t/**\n');
		buf.add('\t\tCalls one of this shard\'s functions by slot.\n\n');
		buf.add('\t\tThis switch is the only reference to most of them, which is deliberate: it is\n');
		buf.add('\t\twhat makes them survive dead-code elimination, and it is how an address in\n');
		buf.add('\t\temulated memory turns into a call without any function value existing.\n');
		buf.add('\t**/\n');
		buf.add('\tpublic static function dispatch(slot:Int, entry:Int, ctx:CpuState):Void {\n');
		buf.add('\t\tRuntime.lastSlot = slot;\n');
		buf.add('\t\tswitch (slot) {\n');
		for (i in 0...shard.functions.length) {
			buf.add('\t\t\tcase $i: ${shard.functions[i].name}(ctx, entry);\n');
		}
		buf.add('\t\t\tdefault: Runtime.badHandle(ctx, "${shard.className}", ${shard.index}, slot);\n');
		buf.add('\t\t}\n');
		buf.add('\t}\n');
		buf.add('}\n');
		return buf.toString();
	}

	/**
		A function's body, or a note saying where the identical one already is.

		Overlays are linked from the same libraries as each other and as the executable, so the
		same routine appears at the same address in several universes, byte for byte. Emitting it
		once matters most where it costs most — a console links every overlay into one binary — and
		it is free to detect: the emitted *text* is compared, not the bytes.

		Text rather than bytes because two identical byte sequences do not always compile to the
		same thing here. A call inside a window resolves to the calling universe's own class, so
		the same instructions in two overlays can name two different callees. Comparing what was
		actually written cannot get that wrong, and the cases it does merge are exactly the ones
		that are genuinely the same code — usually library routines that only call into the base.
	**/
	function bodyOf(u:Universe, shard:Shard, fn:Func):String {
		final text = u.emitter.emitFunction(fn);
		final owner = emitted.get(text);
		if (owner != null) {
			deduplicated++;
			return '\t/** Identical to `${owner}.${fn.name}`; one body serves both. */\n'
				+ '\tpublic static function ${fn.name}(ctx:CpuState, entry:Int = 0):Void {\n'
				+ '\t\t${owner}.${fn.name}(ctx, entry);\n'
				+ '\t}\n';
		}
		emitted.set(text, shard.className);
		return text;
	}

	// ---- the dispatch table -------------------------------------------------------------------

	/**
		Every addressable block in one universe, as three parallel columns.

		The rows are what dispatch searches: an address, the handle of the function that owns it,
		and which of that function's blocks it is. Built the same way for the executable and for
		every overlay, because they answer the same question about different memory.
	**/
	function rowsOf(shards:Shards):Rows {
		final addrs = [];
		final handle:Map<Int, Int> = [];
		final block:Map<Int, Int> = [];
		for (s in shards.shards) {
			for (slot in 0...s.functions.length) {
				final fn = s.functions[slot];
				final h = (s.index << 20) | slot;
				final order = Emitter.blockOrder(fn);
				for (i in 0...order.length) {
					final a = order[i];
					// A block duplicated into two functions belongs to the one that starts at it if
					// either does; otherwise first-come, which is address order and so is stable.
					if (handle.exists(a) && a != fn.entry) continue;
					else {}
					if (!handle.exists(a)) addrs.push(a);
					else {}
					handle.set(a, h);
					block.set(a, i);
				}
			}
		}
		addrs.sort((a, b) -> a - b);
		return {addrs: addrs, handle: handle, block: block};
	}

	function fnTableSource():String {
		// Only the executable's own code. An overlay's blocks live in `Overlays`, because at any
		// moment at most one overlay answers for a window and a single flat table cannot say which.
		final rows = rowsOf(universes[0].shards);
		final addrs = rows.addrs;
		final handle = rows.handle;
		final block = rows.block;

		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tAddress to code, for every jump this tool could not resolve statically.\n\n');
		buf.add('\tThe table holds packed integer handles, not function references: reflaxe.CPP\n');
		buf.add('\tlowers a function value to a heap-allocated std::function and an array of them\n');
		buf.add('\tdoes not compile at all (ADR-0002). A handle is `(shard << 20) | slot`, costs\n');
		buf.add('\tone integer, and dispatches through generated switches the C++ compiler turns\n');
		buf.add('\tinto jump tables.\n\n');
		buf.add('\t**Every basic block is addressable, not only every function entry.** A recompiled\n');
		buf.add('\tprogram has to be able to resume in the middle of a function, because that is\n');
		buf.add('\twhere `longjmp` lands: `setjmp` saves the return address of its own call, so the\n');
		buf.add('\tjump target is by construction an instruction after a `jal`, never a prologue. The\n');
		buf.add('\tsame is true of a thread switch and of an exception hook returning. An entries-only\n');
		buf.add('\ttable answers "no function there" to all of them, and the jump silently does\n');
		buf.add('\tnothing — which is how a game gets stuck with no error at all.\n\n');
		buf.add('\tSo each row carries the block index as well, and the shard switch passes it as the\n');
		buf.add('\tfunction\'s `entry` argument. Entering at block 0 is an ordinary call; entering\n');
		buf.add('\tanywhere else is a resume, and the emitted state machine needs nothing extra to\n');
		buf.add('\tsupport it because every block already assigns its own locals.\n\n');
		buf.add('\tLookup is a binary search over a sorted address array rather than a flat table\n');
		buf.add('\tindexed by address: ${addrs.length} entries against 512K slots, which matters on a\n');
		buf.add('\tconsole with 32 MB of RAM and costs about ${bits(addrs.length)} comparisons here.\n\n');
		buf.add('\tThese rows are the executable\'s. Code the game loads from its disc lives in\n');
		buf.add('\t`Overlays`, whose windows shadow these addresses while they are resident.\n');
		buf.add('**/\n');
		buf.add('class FnTable {\n');

		buf.add('\t/** Block addresses, ascending. */\n');
		buf.add('\tstatic final ADDRS:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> hex(a));
		buf.add('\t];\n\n');

		buf.add('\t/** Handles, in the same order. */\n');
		buf.add('\tstatic final HANDLES:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> Std.string(handle.get(a)));
		buf.add('\t];\n\n');

		buf.add('\t/** Which block of that function each address is — the `entry` argument. */\n');
		buf.add('\tstatic final BLOCKS:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> Std.string(block.get(a)));
		buf.add('\t];\n\n');

		buf.add("	/** The row for an address, or -1 if this program has no code there. */
	public static function lookup(addr:Int):Int {
		var lo = 0;
		var hi = ADDRS.length - 1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = ADDRS[mid];
			if (at == addr) return mid;
			if (at < addr) lo = mid + 1;
			else hi = mid - 1;
		}
		return -1;
	}

	/** Routes a handle to the shard that owns it, entering at block `entry`. */
	public static function dispatch(handle:Int, entry:Int, ctx:CpuState):Void {
		Runtime.dispatches++;
		final slot = handle & 0xFFFFF;
		switch (handle >>> 20) {
");
		// Every shard in the program, overlays included: a handle is program-wide, and an overlay's
		// table hands its handles to this same switch.
		for (u in universes) {
			for (s in u.shards.shards) {
				buf.add('\t\t\tcase ${s.index}: ${s.className}.dispatch(slot, entry, ctx);\n');
			}
		}
		buf.add("			default: Runtime.badHandle(ctx, \"table\", handle >>> 20, slot);
		}
	}

	/**
		Runs the code at an address. Used for everything the analysis left dynamic.

		A resident overlay is asked first, and wins — including when it has nothing there. Its
		window shadows these addresses for as long as the game has it loaded, which is what the
		memory itself does: the executable's bytes at a shadowed address are *gone*, so falling
		back to the executable's table would run code whose bytes the game overwrote. An address
		the resident overlay has no row for is data, or an entry the analysis has not been given
		yet, and either way the honest answer is a miss that names it.
	**/
	public static function call(addr:Int, ctx:CpuState):Bool {
		final ovl = kernel.OverlayMgr.residentAt(addr);
		if (ovl >= 0) {
			// The resident overlay shadows the executable here: no fallthrough.
			final row = Overlays.lookup(ovl, addr);
			if (row < 0) return false;
			dispatch(Overlays.handleAt(row), Overlays.blockAt(row), ctx);
			return true;
		}
		final row = lookup(addr);
		if (row < 0) return false;
		dispatch(HANDLES[row], BLOCKS[row], ctx);
		return true;
	}

	/** Whether an address is a function entry rather than a block inside one. Diagnostics only. */
	public static function isEntry(addr:Int):Bool {
		final row = lookup(addr);
		return row >= 0 && BLOCKS[row] == 0;
	}
}
");
		return buf.toString();
	}

	// ---- the overlays --------------------------------------------------------------------------

	/**
		What the runtime needs to know about code the game loads from its disc.

		Two halves. The **descriptors** say which overlays exist, where each one goes and how to
		recognise it: a window, and a fingerprint over the first words of its bytes. The **rows**
		are the same address/handle/block columns `FnTable` has, one set per overlay, concatenated
		into single arrays with a start and end index per overlay.

		Concatenated rather than nested because `Array<Array<Int>>` is a shape nothing in this
		project has put through reflaxe.CPP, and a flat array of integers is the shape everything
		else already uses. A slice is two more integers and no new risk.

		This file knows nothing about *when* an overlay is resident — that is `OverlayMgr`'s, and
		it asks these questions. Emitted even when a game has no overlays, so that the runtime can
		be written once against a table that is sometimes empty.
	**/
	function overlaysSource():String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tCode this game loads from its disc: where it goes, how to recognise it, and\n');
		buf.add('\twhich function answers for each address while it is there.\n\n');
		buf.add('\tAn overlay is bytes from the disc placed at a fixed address. PlayStation overlays\n');
		buf.add('\tare linked at their final address — nothing relocates them at load time — so an\n');
		buf.add('\toverlay is identified by exactly two things, its window and its contents, and both\n');
		buf.add('\tare here. The fingerprint is FNV-1a over the first words of the overlay, which is\n');
		buf.add('\tits own code and so differs between overlays built from the same libraries; the\n');
		buf.add('\ttool checks at generation time that no two collide.\n');
		buf.add('**/\n');
		buf.add('class Overlays {\n');

		final overlays = universes.slice(1);
		buf.add('\tpublic static inline var COUNT = ${overlays.length};\n\n');

		final allAddrs = [];
		final allHandles = [];
		final allBlocks = [];
		final starts = [];
		final ends = [];
		for (u in overlays) {
			final rows = rowsOf(u.shards);
			starts.push(allAddrs.length);
			for (a in rows.addrs) {
				allAddrs.push(a);
				allHandles.push(rows.handle.get(a));
				allBlocks.push(rows.block.get(a));
			}
			ends.push(allAddrs.length);
		}

		emitTable(buf, "LO", "Where each overlay's window begins.",
			[for (u in overlays) u.overlay.loadAddr], a -> hex(a));
		emitTable(buf, "HI", "One past where it ends.",
			[for (u in overlays) u.overlay.endAddr()], a -> hex(a));
		emitTable(buf, "FINGERPRINT", "FNV-1a over the overlay's first words.",
			[for (u in overlays) u.fingerprint()], a -> hex(a));
		emitTable(buf, "HASH_WORDS", "How many words that fingerprint covers.",
			[for (u in overlays) u.overlay.hashWords], a -> Std.string(a));
		emitTable(buf, "ROW_START", "First row of this overlay's slice of the columns below.",
			starts, a -> Std.string(a));
		emitTable(buf, "ROW_END", "One past its last row.", ends, a -> Std.string(a));
		emitTable(buf, "ADDRS", "Every addressable block, ascending within each overlay.",
			allAddrs, a -> hex(a));
		emitTable(buf, "HANDLES", "The function that owns each, program-wide.", allHandles,
			a -> Std.string(a));
		emitTable(buf, "BLOCKS", "Which block of that function it is.", allBlocks,
			a -> Std.string(a));

		buf.add("	/**
		The row for an address within one overlay, or -1 if that overlay has no code there.

		A binary search over that overlay's slice. An address inside a window is not necessarily
		code: a window holds whatever the game loaded into it, and the parts that are artwork have
		no rows.
	**/
	public static function lookup(overlay:Int, addr:Int):Int {
		if (overlay < 0 || overlay >= COUNT) return -1;
		var lo = ROW_START[overlay];
		var hi = ROW_END[overlay] - 1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = ADDRS[mid];
			if (at == addr) return mid;
			if (at < addr) lo = mid + 1;
			else hi = mid - 1;
		}
		return -1;
	}

	/** Whether an address falls inside an overlay's window, resident or not. */
	public static function inWindow(overlay:Int, addr:Int):Bool {
		return overlay >= 0 && overlay < COUNT && addr >= LO[overlay] && addr < HI[overlay];
	}

	public static function handleAt(row:Int):Int return HANDLES[row];
	public static function blockAt(row:Int):Int return BLOCKS[row];

	/**
		Tells the runtime which overlays exist. Called once, at boot, after `Runtime.boot`.

		Four numbers each, and no tables: the runtime decides *whether* an overlay is resident and
		this class knows *what is in it*, which is what keeps `kernel.OverlayMgr` compilable with
		no generated code present at all.
	**/
	public static function register():Void {
		for (i in 0...COUNT) {
			kernel.OverlayMgr.define(i, LO[i], HI[i], FINGERPRINT[i], HASH_WORDS[i]);
		}
	}

	/** The overlay's name, for diagnostics. A switch rather than a table of strings: this is a
	    cold path, and it keeps the generated tables to plain integers. */
	public static function name(overlay:Int):String {
		switch (overlay) {
");
		for (i in 0...overlays.length) {
			buf.add('\t\t\tcase $i: return "${overlays[i].overlay.id}";\n');
		}
		buf.add("			default: return \"?\";
		}
	}
}
");
		return buf.toString();
	}

	/** One named table, with its comment. Empty arrays still emit, so the runtime compiles. */
	function emitTable(buf:StringBuf, name:String, doc:String, values:Array<Int>,
			render:Int -> String):Void {
		buf.add('\t/** $doc */\n');
		buf.add('\tstatic final $name:Array<Int> = [\n');
		emitIntArray(buf, values, render);
		buf.add('\t];\n\n');
	}

	/**
		No two overlays may look alike where the runtime looks.

		Recognition is a fingerprint over the first words of an overlay's bytes, so two overlays
		that begin with the same prologue would be indistinguishable — and the runtime would
		activate whichever it checked first, dispatching an address to the wrong code. That is a
		failure with no symptom at the point of the mistake, so it is caught here instead, where
		the fix is one number in a config.
	**/
	function checkFingerprintsDistinct():Void {
		final overlays = universes.slice(1);
		for (u in overlays) {
			// The tool clamps its hash to the bytes it has; the runtime hashes the full
			// `hashWords`. An overlay shorter than its own fingerprint would therefore hash
			// differently in the two places and never be recognised — silently. Refusing here
			// turns a game that mysteriously never activates into one number in a config.
			if (u.overlay.length < u.overlay.hashWords * 4) {
				throw new recomp.analysis.AnalysisError('overlay "${u.overlay.id}" is '
					+ '${u.overlay.length} bytes but its fingerprint covers '
					+ '${u.overlay.hashWords * 4}. Lower hashWords to at most '
					+ '${Std.int(u.overlay.length / 4)}.');
			}
		}
		for (i in 0...overlays.length) {
			for (j in 0...i) {
				if (overlays[i].fingerprint() != overlays[j].fingerprint()) continue;
				throw new recomp.analysis.AnalysisError(
					'overlays "${overlays[i].overlay.id}" and "${overlays[j].overlay.id}" have the '
					+ 'same fingerprint over their first ${overlays[i].overlay.hashWords} words, so '
					+ 'the runtime could not tell them apart. Raise hashWords on one of them.');
			}
		}
	}

	/** Comparisons a binary search over `n` rows costs, for the doc comment. */
	static function bits(n:Int):Int {
		var b = 0;
		var v = 1;
		while (v < n) { v <<= 1; b++; }
		return b;
	}

	/** Ten per line: readable in a diff, and not so long that an editor struggles. */
	function emitIntArray(buf:StringBuf, values:Array<Int>, render:Int -> String):Void {
		var i = 0;
		while (i < values.length) {
			buf.add("\t\t");
			var n = 0;
			while (n < 10 && i < values.length) {
				buf.add(render(values[i]));
				if (i < values.length - 1) buf.add(", ");
				i++;
				n++;
			}
			buf.add("\n");
		}
	}

	// ---- what the loader needs -----------------------------------------------------------------

	function gameInfoSource():String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/** What the executable declares about itself, so the runtime can start it. */\n');
		buf.add('class GameInfo {\n');
		buf.add('\tpublic static inline var ENTRY_POINT = ${hex(exe.initialPc)};\n');
		buf.add('\tpublic static inline var INITIAL_GP  = ${hex(exe.initialGp)};\n');
		buf.add('\tpublic static inline var LOAD_ADDR   = ${hex(exe.loadAddr)};\n');
		buf.add('\tpublic static inline var LOAD_SIZE   = ${hex(exe.fileSize)};\n');
		buf.add('\tpublic static inline var INITIAL_SP  = ${hex(exe.initialSp())};\n');
		// The executable's own, not the whole program's: this is what the loader places in RAM,
		// and an overlay is not there until the game fetches it.
		buf.add('\tpublic static inline var FUNCTIONS   = ${universes[0].shards.totalFunctions()};\n');
		buf.add('\tpublic static inline var SHARDS      = ${universes[0].shards.shards.length};\n');
		buf.add('}\n');
		return buf.toString();
	}

	// ---- plumbing -------------------------------------------------------------------------------

	function header():String {
		// The executable's name, on every file. An overlay's shards say which overlay they came
		// from in their own class comment; the program as a whole came from one game.
		return "// Generated by recompsx from " + universes[0].image.name + ". Do not edit.\n"
			+ "//\n"
			+ "// A defect here is a defect in tools/recomp; fix the generator and regenerate.\n"
			+ "// Generation is deterministic: the same input and tool version give the same bytes.\n\n"
			+ "import core.CpuState;\n"
			+ "import core.Ops;\n"
			+ "import core.Runtime;\n"
			+ "import mem.Memory;\n"
			+ "import kernel.Kernel;\n"
			+ "import gte.Gte;\n\n";
	}

	function write(path:String, source:String):Void {
		File.saveContent(path, source);
		filesWritten++;
		var lines = 1;
		for (i in 0...source.length) if (source.charCodeAt(i) == 10) lines++;
		linesWritten += lines;
	}

	static function ensureDir(dir:String):Void {
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}
}
