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

	/** `j` to an address outside this function: a tail call. */
	public final tailCalls:Array<CallSite> = [];

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
		if (unresolvedJumps.length > 0) {
			final at = unresolvedJumps.map(a -> Vaddr.hex(a)).join(", ");
			lines.push('  unresolved jr at: $at');
		}
		for (w in warnings) lines.push('  warning: $w');
		return lines.join("\n");
	}
}
