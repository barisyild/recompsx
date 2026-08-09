package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.loader.PsxExe;
import recomp.codegen.Shards;
import recomp.codegen.Shards.Shard;
import sys.FileSystem;
import sys.io.File;

/**
	Writes a whole recompiled program: one file per shard, plus the dispatch table and the
	program's own facts.

	Everything emitted here is machine-written and is never edited by hand — a defect in the
	output is a defect in this tool, and the fix is to regenerate. The output is also
	deterministic: the same executable and the same tool version produce byte-identical files, so
	`git diff` on generated code shows what actually changed rather than what happened to move.
**/
class Program {
	final image:Image;
	final discovery:Discovery;
	final exe:PsxExe;
	final shards:Shards;
	final emitter:Emitter;

	public var filesWritten(default, null) = 0;
	public var linesWritten(default, null) = 0;

	public function new(image:Image, discovery:Discovery, exe:PsxExe, limit:Int = 0) {
		this.image = image;
		this.discovery = discovery;
		this.exe = exe;
		this.shards = new Shards(discovery, limit);
		this.emitter = new Emitter(image, discovery);
		emitter.shardOf = a -> shards.classOf(a);
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
		for (s in shards.shards) write('$dir/${s.className}.hx', shardSource(s));
		write('$dir/FnTable.hx', fnTableSource());
		write('$dir/GameInfo.hx', gameInfoSource());
	}

	// ---- one shard --------------------------------------------------------------------------

	function shardSource(shard:Shard):String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tFunctions ${Vaddr.hex(shard.functions[0].entry)}'
			+ '..${Vaddr.hex(shard.functions[shard.functions.length - 1].endAddr - 1)}'
			+ ' — ${shard.functions.length} of them.\n');
		buf.add('**/\n');
		buf.add('class ${shard.className} {\n');

		for (fn in shard.functions) {
			buf.add(emitter.emitFunction(fn));
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

	// ---- the dispatch table -------------------------------------------------------------------

	function fnTableSource():String {
		// Every basic-block leader, not just every function entry. Only the functions that were
		// actually emitted: under --limit the rest do not exist.
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
		buf.add('\tconsole with 32 MB of RAM and costs about ${bits(addrs.length)} comparisons here.\n');
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
		for (s in shards.shards) {
			buf.add('\t\t\tcase ${s.index}: ${s.className}.dispatch(slot, entry, ctx);\n');
		}
		buf.add("			default: Runtime.badHandle(ctx, \"table\", handle >>> 20, slot);
		}
	}

	/** Runs the code at an address. Used for everything the analysis left dynamic. */
	public static function call(addr:Int, ctx:CpuState):Bool {
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
		buf.add('\tpublic static inline var FUNCTIONS   = ${shards.totalFunctions()};\n');
		buf.add('\tpublic static inline var SHARDS      = ${shards.shards.length};\n');
		buf.add('}\n');
		return buf.toString();
	}

	// ---- plumbing -------------------------------------------------------------------------------

	function header():String {
		return "// Generated by recompsx from " + image.name + ". Do not edit.\n"
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
