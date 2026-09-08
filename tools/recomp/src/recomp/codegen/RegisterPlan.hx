package recomp.codegen;

import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.mips.Decoder;
import recomp.mips.Instr;

/**
	Scalar replacement of the guest register file. Only registers actually mentioned by the
	function get locals; only registers it writes need publishing back to CpuState. All locals
	are initialised even on a mid-function entry. Calls and scheduler safe points publish before
	entering guest/kernel code and reload afterwards, so this makes no guest ABI assumptions.

	HI/LO and coprocessor state remain in CpuState: Ops and Gte already operate on that state,
	and none of their helpers observes or changes a general-purpose register.
**/
class RegisterPlan {
	public final used:Array<Int> = [];
	public final written:Array<Int> = [];

	public function new(fn:Func, image:Image) {
		final reads:Map<Int, Bool> = [];
		final writes:Map<Int, Bool> = [];
		function read(r:Int):Void { if (r != 0) reads.set(r, true); }
		function write(r:Int):Void { if (r != 0) writes.set(r, true); }
		for (block in fn.blocks) {
			for (n in 0...block.length) {
				final addr = block.addr + n * 4;
				final i = Decoder.decode(addr, image.readWord(addr));
				switch (i.op) {
					case ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU:
						read(i.rs); read(i.rt); write(i.rd);
					case SLL | SRL | SRA: read(i.rt); write(i.rd);
					case SLLV | SRLV | SRAV: read(i.rs); read(i.rt); write(i.rd);
					case ADDI | ADDIU | ANDI | ORI | XORI | SLTI | SLTIU:
						read(i.rs); write(i.rt);
					case LUI: write(i.rt);
					case LB | LBU | LH | LHU | LW: read(i.rs); write(i.rt);
					case LWL | LWR: read(i.rs); read(i.rt); write(i.rt);
					case SB | SH | SW | SWL | SWR: read(i.rs); read(i.rt);
					case MULT | MULTU | DIV | DIVU: read(i.rs); read(i.rt);
					case MFHI | MFLO: write(i.rd);
					case MTHI | MTLO: read(i.rs);
					case BEQ | BNE: read(i.rs); read(i.rt);
					case BLEZ | BGTZ | BLTZ | BGEZ: read(i.rs);
					case BLTZAL | BGEZAL: read(i.rs); write(31);
					case JAL: write(31);
					case JALR: read(i.rs); write(i.rd);
					case JR: read(i.rs);
					case MFC0 | MFC2 | CFC2: write(i.rt);
					case MTC0 | MTC2 | CTC2: read(i.rt);
					case LWC2 | SWC2: read(i.rs);
					case _:
				}
			}
		}
		for (r in 1...32) {
			if (reads.exists(r) || writes.exists(r)) used.push(r);
			if (writes.exists(r)) written.push(r);
		}
	}

	public function declare(buf:StringBuf, ind:String):Void {
		for (r in used) buf.add('${ind}var ${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
	}

	public function publish(buf:StringBuf, ind:String):Void {
		for (r in written) buf.add('${ind}ctx.${Instr.regName(r)} = ${Instr.regName(r)};\n');
	}

	public function reload(buf:StringBuf, ind:String):Void {
		for (r in used) buf.add('${ind}${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
	}
}
