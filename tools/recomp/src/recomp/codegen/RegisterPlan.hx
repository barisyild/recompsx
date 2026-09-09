package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.RegisterMask;
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
