package recomp.analysis;

import recomp.Vaddr;

/** One basic block: a straight run of instructions ending in a control transfer. */
class Block {
	public final addr:Int;
	/** Instruction count, including the delay slot of a terminating branch. */
	public var length:Int = 0;
	/** Addresses control can reach from here, inside this function. */
	public final successors:Array<Int> = [];
	/** True when the block ends by leaving the function (return or tail call). */
	public var exits:Bool = false;

	public function new(addr:Int) this.addr = addr;

	public inline function endAddr():Int return addr + length * 4;
}

/** A call site, kept with its address so the coverage report can point at it. */
class CallSite {
	public final from:Int;
	public final target:Int;   // 0 when the target is computed
	public final indirect:Bool;
	public function new(from:Int, target:Int, indirect:Bool) {
		this.from = from;
		this.target = target;
		this.indirect = indirect;
	}
}

/**
	A discovered function: where it starts, the blocks it is made of, and what it reaches.

	`extent` is the span of addresses its blocks cover. It is not necessarily contiguous in
	principle — a compiler may place a cold path elsewhere — but on the PlayStation it always is
	in practice, and a function whose blocks are not contiguous is worth reporting rather than
	quietly accepting.
**/
class Func {
	public final entry:Int;
	public var name:String;
	public final confidence:Confidence;

	public final blocks:Map<Int, Block> = [];
	public final calls:Array<CallSite> = [];

	/** `jr` through a register other than ra, whose targets analysis could not recover. Each one
	    is a switch or a computed call that will fall back to runtime dispatch. */
	public final unresolvedJumps:Array<Int> = [];
	/**
		`jr`s that return through a copy of `$ra`, keyed by address. Hand-written code that makes
		a call of its own keeps its return address in a scratch register first (`move $at, $ra`)
		and leaves with `jr $at`; that is a return, and emitted as one.
	**/
	public final registerReturns:Map<Int, Bool> = [];
	/**
		`jr $ra` returns where `$ra` may hold an address the function was not called with — a
		load from somewhere other than its own stack slot reached them — keyed by address. The
		emitter compares `$ra` with the entry value there, and a mismatch returns to whichever
		caller continues at that address (ADR-0027, `Discovery.markCheckedReturns`).
	**/
	public final checkedReturns:Map<Int, Bool> = [];

	/** `j` to an address outside this function: a tail call. */
	public final tailCalls:Array<CallSite> = [];

	/**
		Other functions' entries this one reaches by a branch, by running into them or as a call's
		continuation, and hands over to there instead of carrying their code: a tail call in the
		emitted code, which skips the entry's pump and checkpoint as the code would have done
		inline (`Discovery.cutAtEntries`). Keyed by the entry.
	**/
	public final hops:Map<Int, Bool> = [];
	/**
		Hand-overs after which `$ra` may hold something other than this function's entry value:
		the callee's return goes where `$ra` points, as a return of this function's own would
		(`Discovery.markCheckedReturns`). Keyed by the block that hands over.
	**/
	public final checkedHops:Map<Int, Bool> = [];
	/**
		Hand-overs that enter with the pump and checkpoint: the code they replace pumped at that
		entry's block, which an edge back to it made a pump point (FunctionIR). Keyed by the entry.
	**/
	public final pumpedHops:Map<Int, Bool> = [];

	/**
		BIOS calls, as `{from, vector, fnNumber}`.

		Psy-Q reaches the kernel by loading a vector into $t2 and jumping through it, with the
		function number in $t1 — so these arrive here as computed jumps and are only recognisable
		after constant propagation. They are calls, not jumps: the emitter routes them to the
		kernel HLE, and the coverage report should not count them as unresolved dispatch.
	**/
	public final kernelCalls:Array<{from:Int, vector:Int, fnNumber:Int}> = [];

	public var endAddr:Int = 0;
	public final warnings:Array<String> = [];

	/**
		Set when the tracer decided this is not a function after all.

		Only reachable in a lenient pass — an overlay window, where the tool is reading code and
		artwork side by side and was never told where one ends. In the executable the same
		discovery is still a hard error, because there it means the analysis is wrong.
	**/
	public var abandoned:Bool = false;

	public function new(entry:Int, name:String, confidence:Confidence) {
		this.entry = entry;
		this.name = name;
		this.confidence = confidence;
	}

	public inline function sizeBytes():Int return endAddr - entry;
	public function instructionCount():Int {
		var n = 0;
		for (b in blocks) n += b.length;
		return n;
	}

	public function describe():String {
		final lines = ['${Vaddr.hex(entry)}  $name'];
		lines.push('  ${Lambda.count(blocks)} blocks, ${instructionCount()} instructions, '
			+ '${sizeBytes()} bytes, discovered by ${confidence}');
		if (calls.length > 0) {
			final direct = calls.filter(c -> !c.indirect).length;
			lines.push('  calls: $direct direct, ${calls.length - direct} indirect');
		}
		if (tailCalls.length > 0) lines.push('  tail calls: ${tailCalls.length}');
		if (kernelCalls.length > 0) lines.push('  kernel calls: ${kernelCalls.length}');
		if (registerReturns.keys().hasNext()) {
			final at = [for (a in registerReturns.keys()) Vaddr.hex(a)].join(", ");
			lines.push('  returns through a copy of ra at: $at');
		}
		if (checkedReturns.keys().hasNext()) {
			final at = [for (a in checkedReturns.keys()) a];
			at.sort((x, y) -> x - y);
			lines.push('  returns checked against the entry ra at: ${at.map(a -> Vaddr.hex(a)).join(", ")}');
		}
		if (unresolvedJumps.length > 0) {
			final at = unresolvedJumps.map(a -> Vaddr.hex(a)).join(", ");
			lines.push('  unresolved jr at: $at');
		}
		for (w in warnings) lines.push('  warning: $w');
		return lines.join("\n");
	}
}
