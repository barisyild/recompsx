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
		buf.add('\tpublic static function dispatch(slot:Int, ctx:CpuState):Void {\n');
		buf.add('\t\tswitch (slot) {\n');
		for (i in 0...shard.functions.length) {
			buf.add('\t\t\tcase $i: ${shard.functions[i].name}(ctx);\n');
		}
		buf.add('\t\t\tdefault: Runtime.badHandle(ctx, "${shard.className}", ${shard.index}, slot);\n');
		buf.add('\t\t}\n');
		buf.add('\t}\n');
		buf.add('}\n');
		return buf.toString();
	}

	// ---- the dispatch table -------------------------------------------------------------------

	function fnTableSource():String {
		// Only the functions that were actually emitted: under --limit the rest do not exist.
		final entries = [];
		for (s in shards.shards) for (fn in s.functions) entries.push(fn.entry);
		entries.sort((a, b) -> a - b);

		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tAddress to function, for calls this tool could not resolve statically.\n\n');
		buf.add('\tThe table holds packed integer handles, not function references: reflaxe.CPP\n');
		buf.add('\tlowers a function value to a heap-allocated std::function and an array of them\n');
		buf.add('\tdoes not compile at all (ADR-0002). A handle is `(shard << 20) | slot`, costs\n');
		buf.add('\tone integer, and dispatches through generated switches the C++ compiler turns\n');
		buf.add('\tinto jump tables.\n\n');
		buf.add('\tLookup is a binary search over a sorted address array rather than a flat table\n');
		buf.add('\tindexed by address: ${entries.length} entries against 512K slots, which matters\n');
		buf.add('\ton a console with 32 MB of RAM and costs about nine comparisons here.\n');
		buf.add('**/\n');
		buf.add('class FnTable {\n');

		buf.add('\t/** Entry addresses, ascending. */\n');
		buf.add('\tstatic final ADDRS:Array<Int> = [\n');
		emitIntArray(buf, entries, a -> hex(a));
		buf.add('\t];\n\n');

		buf.add('\t/** Handles, in the same order. */\n');
		buf.add('\tstatic final HANDLES:Array<Int> = [\n');
		emitIntArray(buf, entries, a -> Std.string(shards.handleOf(a)));
		buf.add('\t];\n\n');

		buf.add("	/** The handle for an address, or -1 if this program has no function there. */
	public static function lookup(addr:Int):Int {
		var lo = 0;
		var hi = ADDRS.length - 1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = ADDRS[mid];
			if (at == addr) return HANDLES[mid];
			if (at < addr) lo = mid + 1;
			else hi = mid - 1;
		}
		return -1;
	}

	/** Routes a handle to the shard that owns it. */
	public static function dispatch(handle:Int, ctx:CpuState):Void {
		final slot = handle & 0xFFFFF;
		switch (handle >>> 20) {
");
		for (s in shards.shards) {
			buf.add('\t\t\tcase ${s.index}: ${s.className}.dispatch(slot, ctx);\n');
		}
		buf.add("			default: Runtime.badHandle(ctx, \"table\", handle >>> 20, slot);
		}
	}

	/** Calls the function at an address. Used for everything the analysis left dynamic. */
	public static function call(addr:Int, ctx:CpuState):Bool {
		final handle = lookup(addr);
		if (handle < 0) return false;
		dispatch(handle, ctx);
		return true;
	}
}
");
		return buf.toString();
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
