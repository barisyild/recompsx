package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;

/** One output file: a class holding a contiguous run of functions by address. */
class Shard {
	public final index:Int;
	public final className:String;
	public final functions:Array<Func> = [];

	public function new(index:Int, firstAddr:Int) {
		this.index = index;
		this.className = "Fns_" + pad2(index) + "_" + hex(firstAddr);
	}

	public inline function startAddr():Int return functions[0].entry;

	static function pad2(n:Int):String return n < 10 ? "0" + n : Std.string(n);

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return out;
	}
}

/**
	Splits a program's functions across output files.

	A PS1 game is tens of thousands of instructions, and putting them in one Haxe class produces a
	file no compiler is happy with and no person can navigate. Splitting is therefore mandatory,
	and the interesting question is only where the cuts go.

	Two rules: address order, and a cap on both function count and estimated size. Address order
	matters more than it sounds — it keeps a shard's contents contiguous in the original program,
	so a function and the ones it sits between stay together, and it makes the split *stable*.
	Regenerating after a change that adds one function must not renumber everything, or every
	diff of generated output becomes unreadable and incremental compilation rebuilds the world.
**/
class Shards {
	/** Enough functions to keep the file count sane, few enough to keep each file compilable. */
	static inline var MAX_FUNCTIONS = 120;

	/** A rough instruction budget per shard; large functions get their own. */
	static inline var MAX_INSTRUCTIONS = 6000;

	public final shards:Array<Shard> = [];
	final shardOfAddr:Map<Int, Shard> = [];

	public function new(discovery:Discovery) {
		final entries = [for (k in discovery.functions.keys()) k];
		entries.sort((a, b) -> a - b);

		var current:Shard = null;
		var instructions = 0;

		for (addr in entries) {
			final fn = discovery.functions.get(addr);
			final size = fn.instructionCount();

			final tooMany = current != null && current.functions.length >= MAX_FUNCTIONS;
			final tooBig = current != null && instructions + size > MAX_INSTRUCTIONS
				&& current.functions.length > 0;

			if (current == null || tooMany || tooBig) {
				current = new Shard(shards.length, addr);
				shards.push(current);
				instructions = 0;
			}

			current.functions.push(fn);
			instructions += size;
			shardOfAddr.set(addr, current);
		}
	}

	/** The class a function lives in, for emitting a call. */
	public function classOf(addr:Int):String {
		final s = shardOfAddr.get(Vaddr.canonRam(addr));
		return s == null ? "FnTable" : s.className;
	}

	/**
		The handle for a function: which shard, and which slot within it.

		Handles rather than function references, per ADR-0002 — reflaxe.CPP lowers a function
		value to a heap-allocated `std::function`, and an array of them does not compile at all.
		A packed integer costs nothing, survives being stored in emulated memory, and dispatches
		through a generated switch that the C++ compiler turns into a jump table.
	**/
	public function handleOf(addr:Int):Int {
		final a = Vaddr.canonRam(addr);
		final s = shardOfAddr.get(a);
		if (s == null) return -1;
		for (i in 0...s.functions.length) {
			if (s.functions[i].entry == a) return (s.index << 20) | i;
		}
		return -1;
	}

	public function totalFunctions():Int {
		var n = 0;
		for (s in shards) n += s.functions.length;
		return n;
	}
}
