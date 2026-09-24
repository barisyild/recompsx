package recomp.codegen;

import recomp.ir.Effect;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	Conservative forwarding for ordinary stack slots inside one basic block.

	The machine still owns memory at all observable boundaries. This pass only uses a previous
	word store when the same `$sp`/`$fp` plus immediate address is reached again before another
	memory operation, and only removes a previous word store when a later store to the exact same
	address supersedes it. Register versions protect the forwarded value when the source register
	was changed in between. Any other memory operation, stack-pointer change, trap or unknown
	effect clears the facts.

	It intentionally does not infer RAM from an arbitrary pointer. `$sp` and `$fp` are the only
	addresses that are safe to treat as stack slots without a game-specific memory map, and the
	pass stays within one original basic block so no call, branch or scheduler boundary is crossed.
**/
enum StackMemoryDecision {
	ForwardLoad(source:Int);
	DropStore;
}

typedef StackStoreFact = {
	index:Int,
	baseVersion:Int,
	source:Int,
	sourceVersion:Int
};

typedef StackAddress = {key:String, base:Int};

class StackMemoryForwarding {

	/** One nullable decision per body instruction; null means emit the original instruction. */
	public static function plan(body:Array<InstructionIR>):Array<Null<StackMemoryDecision>> {
		final decisions:Array<Null<StackMemoryDecision>> = [for (_ in body) null];
		final versions:Array<Int> = [for (_ in 0...32) 0];
		final stores:Map<String, StackStoreFact> = [];

		for (index in 0...body.length) {
			final instruction = body[index];
			final op = instruction.decoded.op;
			final wordAddress = stackAddress(instruction.decoded);

			switch (op) {
				case SW if (wordAddress != null):
					final key = wordAddress.key;
					final previous = stores.get(key);
					if (previous != null && previous.baseVersion == versions[wordAddress.base])
						decisions[previous.index] = DropStore;
					// A different stack store could alias through an unknown relationship between
					// `$sp` and `$fp`, so keep only the exact current fact.
					stores.clear();
					stores.set(key, {
						index: index,
						baseVersion: versions[wordAddress.base],
						source: instruction.decoded.rt,
						sourceVersion: versions[instruction.decoded.rt]
					});

				case LW if (wordAddress != null && instruction.decoded.rt != 0):
					final key = wordAddress.key;
					final previous = stores.get(key);
					if (previous != null
						&& previous.baseVersion == versions[wordAddress.base]
						&& previous.sourceVersion == versions[previous.source])
						decisions[index] = ForwardLoad(previous.source);
					stores.clear();

				case _ if (instruction.effects.has(Effect.READ_MEMORY)
					|| instruction.effects.has(Effect.WRITE_MEMORY)
					|| instruction.effects.has(Effect.TRAP)
					|| instruction.effects.has(Effect.UNKNOWN)
					|| instruction.effects.has(Effect.CONTROL)):
					stores.clear();

				case _:
			}

			// A new stack/frame pointer value invalidates every address fact. Other register
			// writes only affect a store's source-version check above.
			if (instruction.writes.has(29) || instruction.writes.has(30)) stores.clear();
			for (register in 1...32) if (instruction.writes.has(register)) versions[register]++;
		}
		return decisions;
	}

	static function stackAddress(instruction:Instr):Null<StackAddress> {
		if (instruction.op != Op.SW && instruction.op != Op.LW) return null;
		if (instruction.rs != 29 && instruction.rs != 30) return null;
		return {key: '${instruction.rs}:${instruction.immS}', base: instruction.rs};
	}
}
