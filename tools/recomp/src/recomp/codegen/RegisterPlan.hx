package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.RegisterMask;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	Scalar replacement of the guest register file. Only registers actually mentioned by the
	function get locals; only registers it writes need publishing back to CpuState. All locals
	are initialised even on a mid-function entry. Calls and scheduler safe points publish before
	entering guest/kernel code; the backwards liveness pass reloads only values needed by the
	continuation, while function exits keep every written architectural register observable.
	This makes no guest ABI or callback-preservation assumption.

	HI/LO and coprocessor state remain in CpuState: Ops and Gte already operate on that state,
	and none of their helpers observes or changes a general-purpose register.
**/
class RegisterPlan {
	public final used:Array<Int> = [];
	public final written:Array<Int> = [];
	final writtenMask:RegisterMask;
	/** Registers whose incoming value is needed before a block's first local definition. */
	final liveIn:Map<Int, RegisterMask> = [];
	/** Registers whose value is needed by a successor after this block completes. */
	final liveOut:Map<Int, RegisterMask> = [];
	/** Value needed after each original instruction, in emitter order. */
	final after:Map<Int, Array<RegisterMask>> = [];
	/** Blocks where a local write can be observed by a pump/call/return publication. */
	final protectedBlocks:Map<Int, Bool> = [];

	public function new(ir:FunctionIR) {
		var reads:RegisterMask = 0;
		var writes:RegisterMask = 0;
		for (block in ir.blocks) for (instruction in block.instructions) {
			reads |= instruction.reads;
			writes |= instruction.writes;
		}
		for (r in 1...32) {
			if (reads.has(r) || writes.has(r)) used.push(r);
			if (writes.has(r)) written.push(r);
		}
		writtenMask = writes;
		for (block in ir.blocks) {
			if (block.pump || hasExternalBoundary(block)) protectedBlocks.set(block.addr, true);
		}
		// A call/pump publishes the locals it receives. Any predecessor path can carry a
		// value into that boundary even when the boundary block itself never reads the GPR.
		// Protect the whole reverse reachability slice; dead writes remain available in isolated
		// leaf/internal regions where there is no external observation boundary ahead.
		var expanded = true;
		while (expanded) {
			expanded = false;
			for (block in ir.blocks) if (!protectedBlocks.exists(block.addr)) {
				for (successor in block.successors) {
					if (protectedBlocks.exists(successor)) {
						protectedBlocks.set(block.addr, true);
						expanded = true;
						break;
					}
				}
			}
		}

		computeLiveness(ir);
	}

	public function declare(buf:StringBuf, ind:String):Void {
		for (r in used) buf.add('${ind}var ${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
	}

	public function publish(buf:StringBuf, ind:String):Void {
		for (r in written) buf.add('${ind}ctx.${Instr.regName(r)} = ${Instr.regName(r)};\n');
	}

	public function reload(buf:StringBuf, ind:String):Void {
		reloadMask(buf, ind, usedMask());
	}

	/** Reload only values needed on entry to a block after an external mutation. */
	public function reloadBlock(buf:StringBuf, ind:String, block:Int):Void {
		reloadMask(buf, ind, liveIn.get(block));
	}

	/** Reload only values needed after one instruction has crossed a runtime barrier. */
	public function reloadAfter(buf:StringBuf, ind:String, block:Int, instruction:Int):Void {
		final values = after.get(block);
		if (values == null || instruction < 0 || instruction >= values.length) reload(buf, ind);
		else reloadMask(buf, ind, values[instruction]);
	}

	/** Reload values needed when a call returns into a known block address. */
	public function reloadContinuation(buf:StringBuf, ind:String, block:Int):Void {
		reloadMask(buf, ind, liveIn.get(block));
	}

	/** Whether a GPR's value is needed after this original instruction. */
	public function liveAfter(block:Int, instruction:Int, register:Int):Bool {
		final values = after.get(block);
		return values == null || instruction < 0 || instruction >= values.length
			? true : values[instruction].has(register);
	}

	/** Pure write elimination is disabled where publication can observe the local. */
	public function canDropPureWrite(block:Int):Bool return !protectedBlocks.exists(block);

	function reloadMask(buf:StringBuf, ind:String, mask:RegisterMask):Void {
		for (r in used) if (mask.has(r))
			buf.add('${ind}${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
	}

	function usedMask():RegisterMask {
		var mask:RegisterMask = 0;
		for (r in used) mask = mask.withRegister(r);
		return mask;
	}

	/**
		Classic backwards liveness over the machine CFG. Calls remain full barriers in the
		emitter: this pass only decides which locals must be restored after the barrier. It
		therefore cannot make an ABI or callback assumption, and interior block entries remain
		valid because every block has its own live-in set.
	**/
	function computeLiveness(ir:FunctionIR):Void {
		final use:Map<Int, RegisterMask> = [];
		final defs:Map<Int, RegisterMask> = [];
		for (block in ir.blocks) {
			var blockUse:RegisterMask = 0;
			var blockDefs:RegisterMask = 0;
			for (instruction in block.instructions) {
				blockUse |= instruction.reads & ~blockDefs;
				blockDefs |= instruction.writes;
			}
			use.set(block.addr, blockUse);
			defs.set(block.addr, blockDefs);
			liveIn.set(block.addr, 0);
			liveOut.set(block.addr, 0);
		}

		var changed = true;
		while (changed) {
			changed = false;
			var index = ir.blocks.length - 1;
			while (index >= 0) {
				final block = ir.blocks[index];
				// A function return publishes every register this function may write, even if
				// the final block does not read it. Keeping that architectural state live is
				// required when a callback/pump changed it while the local was suspended.
				var out:RegisterMask = mayReturn(ir, block) ? writtenMask : 0;
				for (successor in block.successors) out |= liveIn.get(successor);
				final incoming = use.get(block.addr) | (out & ~defs.get(block.addr));
				if ((out:Int) != (liveOut.get(block.addr):Int)
					|| (incoming:Int) != (liveIn.get(block.addr):Int)) changed = true;
				liveOut.set(block.addr, out);
				liveIn.set(block.addr, incoming);
				index--;
			}
		}

		for (block in ir.blocks) {
			final values = [for (_ in block.instructions) 0];
			var needed = liveOut.get(block.addr);
			var index = block.instructions.length - 1;
			while (index >= 0) {
				values[index] = needed;
				final instruction = block.instructions[index];
				needed = instruction.reads | (needed & ~instruction.writes);
				index--;
			}
			after.set(block.addr, values);
		}
	}

	/** A control block can have a dynamically dispatched or tail path that publishes locals. */
	function hasExternalBoundary(block:recomp.ir.FunctionIR.BlockIR):Bool {
		for (instruction in block.instructions)
			if (instruction.effects.has(recomp.ir.Effect.TRAP)
				|| instruction.effects.has(recomp.ir.Effect.CALL)) return true;
		if (block.transfer == null) return false;
		return switch (block.transfer.decoded.op) {
			case JR: true;
			case J: block.successors.length == 0;
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ: block.successors.length < 2;
			case _: false;
		};
	}

	/** Match every emitter path that can return without entering a discovered successor. */
	function mayReturn(ir:FunctionIR, block:recomp.ir.FunctionIR.BlockIR):Bool {
		if (block.successors.length == 0 || block.transfer == null) return block.successors.length == 0;
		final transfer = block.transfer.decoded;
		return switch (transfer.op) {
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ | BLTZAL | BGEZAL:
				// A discovered internal arm may coexist with an external arm. The emitter
				// publishes and returns on that external path.
				block.successors.length < 2;
			case J: !ir.byAddress.exists(transfer.target);
			case JR: true;
			case JAL: !ir.byAddress.exists(transfer.addr + 8);
			case JALR:
				transfer.rs == 31 || !ir.byAddress.exists(transfer.addr + 8);
			case _: true;
		};
	}
}
