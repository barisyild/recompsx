package recomp.analysis;

import recomp.Vaddr;
import recomp.analysis.TableConfidence;

/**
	A recovered switch: the `jr` that dispatches, the table it reads, and where it can go.

	Recovering these is the single largest lever on coverage. A switch statement compiles to a
	computed jump, and every arm of it is code the call closure cannot see — so an unrecovered
	table is not one missing edge but a whole subtree of the program. It is also the difference
	between a `switch` in the generated code and a runtime address lookup, which matters for
	speed but matters more for knowing the program is fully translated.
**/
class JumpTable {
	/** Address of the `jr` that reads this table. */
	public final jrAddr:Int;
	/** Where the table lives. */
	public final base:Int;
	/** Register holding the index, for diagnostics. */
	public final indexReg:Int;
	public final confidence:TableConfidence;
	public final targets:Array<Int>;

	public function new(jrAddr:Int, base:Int, indexReg:Int, confidence:TableConfidence,
			targets:Array<Int>) {
		this.jrAddr = jrAddr;
		this.base = base;
		this.indexReg = indexReg;
		this.confidence = confidence;
		this.targets = targets;
	}

	public inline function count():Int return targets.length;
	public inline function sizeBytes():Int return targets.length * 4;

	public function describe():String {
		return '${Vaddr.hex(jrAddr)}: switch on $' + recomp.mips.Instr.regName(indexReg)
			+ ', ${targets.length} arms at ${Vaddr.hex(base)} ($confidence)';
	}
}
