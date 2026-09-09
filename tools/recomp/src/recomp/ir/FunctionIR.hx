package recomp.ir;

import recomp.analysis.AnalysisError;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.mips.Decoder;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	Decoded machine IR shared by code-generation passes. This is build-time data, never guest
	state. It deliberately keeps machine registers, observable effects and original block IDs:
	neither a calling convention nor immutable RAM may be inferred from an instruction's shape.
**/
class FunctionIR {
	public final blocks:Array<BlockIR> = [];
	public final byAddress:Map<Int, BlockIR> = [];

	public function new(fn:Func, image:Image) {
		final order = blockOrder(fn);
		for (id in 0...order.length) {
			final source = fn.blocks.get(order[id]);
			final block = new BlockIR(id, source.addr);
			for (n in 0...source.length) {
				final addr = source.addr + n * 4;
				final instruction = new InstructionIR(Decoder.decode(addr, image.readWord(addr)));
				block.instructions.push(instruction);
				block.cycles += instruction.cycles;
				if (block.transfer == null) {
					if (instruction.decoded.op.hasDelaySlot) block.transfer = instruction;
					else block.body.push(instruction);
				} else if (block.delaySlot == null) block.delaySlot = instruction;
				else throw new AnalysisError('instructions after a block terminator at $addr');
			}
			for (to in source.successors) {
				if (block.successors.indexOf(to) < 0) block.successors.push(to);
			}
			blocks.push(block);
			byAddress.set(block.addr, block);
		}
		for (block in blocks) for (to in block.successors) {
			final target = byAddress.get(to);
			if (target == null) throw new AnalysisError('missing block successor at $to');
			target.predecessors.push(block.addr);
			// Preserve the existing safe points even if structuring hides a backward edge.
			if (to <= block.addr) target.pump = true;
		}
	}

	/** Shared with function/overlay dispatch tables. Structuring never renumbers an entry. */
	public static function blockOrder(fn:Func):Array<Int> {
		final order = [for (addr in fn.blocks.keys()) addr];
		order.sort((a, b) -> a - b);
		return order;
	}
}

class BlockIR {
	public final resumeId:Int;
	public final addr:Int;
	public final instructions:Array<InstructionIR> = [];
	public final body:Array<InstructionIR> = [];
	public var transfer:Null<InstructionIR> = null;
	public var delaySlot:Null<InstructionIR> = null;
	public final successors:Array<Int> = [];
	public final predecessors:Array<Int> = [];
	public var cycles:Int = 0;
	public var pump:Bool = false;

	public function new(resumeId:Int, addr:Int) {
		this.resumeId = resumeId;
		this.addr = addr;
	}

	/** Ordinary two-way branches only; linked branches are calls, not region selectors. */
	public function conditional():Bool {
		return transfer != null && switch (transfer.decoded.op) {
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ: true;
			case _: false;
		};
	}

	public function selfLoopExit():Null<Int> {
		if (!conditional() || delaySlot == null) return null;
		final branch = transfer.decoded;
		final after = branch.addr + 8;
		return branch.target == addr && successors.indexOf(addr) >= 0
			&& successors.indexOf(after) >= 0 ? after : null;
	}
}

/**
	Explicit instruction effects. Register masks describe the instruction itself; calls/traps
	have unknown transitive effects, including callbacks. CONTROL also covers possible tail
	transfers; its lack of a CALL flag is not evidence that a transfer preserves registers.
	Memory reads remain effects even when their destination is $zero: an address may name MMIO.
**/
class InstructionIR {
	public final decoded:Instr;
	public final cycles:Int;
	public var reads(default, null):RegisterMask = 0;
	public var writes(default, null):RegisterMask = 0;
	public var effects(default, null):Effect = Effect.NONE;

	public function new(i:Instr) {
		decoded = i;
		cycles = i.op.cost;
		switch (i.op) {
			case ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU:
				read(i.rs); read(i.rt); write(i.rd);
			case SLL | SRL | SRA: read(i.rt); write(i.rd);
			case SLLV | SRLV | SRAV: read(i.rs); read(i.rt); write(i.rd);
			case ADDI | ADDIU | ANDI | ORI | XORI | SLTI | SLTIU:
				read(i.rs); write(i.rt);
			case LUI: write(i.rt);
			case LB | LBU | LH | LHU | LW:
				read(i.rs); write(i.rt); effects = Effect.READ_MEMORY;
			case LWL | LWR:
				read(i.rs); read(i.rt); write(i.rt); effects = Effect.READ_MEMORY;
			case SB | SH | SW:
				read(i.rs); read(i.rt); effects = Effect.WRITE_MEMORY;
			case SWL | SWR:
				read(i.rs); read(i.rt); effects = Effect.READ_MEMORY | Effect.WRITE_MEMORY;
			case MULT | MULTU | DIV | DIVU:
				read(i.rs); read(i.rt); effects = Effect.WRITE_HILO;
			case MFHI | MFLO: write(i.rd); effects = Effect.READ_HILO;
			case MTHI | MTLO: read(i.rs); effects = Effect.WRITE_HILO;
			case BEQ | BNE: read(i.rs); read(i.rt); effects = Effect.CONTROL;
			case BLEZ | BGTZ | BLTZ | BGEZ: read(i.rs); effects = Effect.CONTROL;
			case BLTZAL | BGEZAL: read(i.rs); write(31); effects = Effect.CONTROL | Effect.CALL;
			case JAL: write(31); effects = Effect.CONTROL | Effect.CALL;
			case JALR: read(i.rs); write(i.rd); effects = Effect.CONTROL | Effect.CALL;
			case JR: read(i.rs); effects = Effect.CONTROL;
			case J: effects = Effect.CONTROL;
			case MFC0 | MFC2 | CFC2: write(i.rt); effects = Effect.READ_COP;
			case MTC0 | MTC2 | CTC2: read(i.rt); effects = Effect.WRITE_COP;
			case LWC2: read(i.rs); effects = Effect.READ_MEMORY | Effect.WRITE_COP;
			case SWC2: read(i.rs); effects = Effect.READ_COP | Effect.WRITE_MEMORY;
			case COP2CMD | RFE: effects = Effect.READ_COP | Effect.WRITE_COP;
			case SYSCALL | BREAK: effects = Effect.TRAP;
			case INVALID: effects = Effect.UNKNOWN;
		}
	}

	inline function read(r:Int):Void { reads = reads.withRegister(r); }
	inline function write(r:Int):Void { writes = writes.withRegister(r); }
}
