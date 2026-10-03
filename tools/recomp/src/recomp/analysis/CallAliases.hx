package recomp.analysis;

import recomp.ir.Effect;
import recomp.ir.FunctionIR.BlockIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Op;

/** Exact wrapped affine relations between CURRENT GPR values at one call. Facts start
    fresh at every public block entry, and observations discard them. A copy retains its
    immutable value version even when the original register is overwritten afterwards.
    Build-time only: no runtime alias table or calling-convention assumption. */
class CallAliases {
	final values:Array<AliasValue> = [];
	var nextRoot = 0;
	public function new() reset();
	function reset():Void {
		values.resize(0); values.push({root:0, offset:0});
		for (_ in 1...32) values.push(fresh());
	}
	function fresh():AliasValue return {root:++nextRoot, offset:0};
	static function plus(value:AliasValue, offset:Int):AliasValue return {root:value.root, offset:(value.offset + offset) | 0};
	static function constant(value:Int):AliasValue return {root:0, offset:value};
	public function invalidate(mask:Int):Void {
		for (r in 1...32) if ((mask & (1 << r)) != 0) values[r] = fresh();
	}
	/** reg == donor + result modulo 2^32. Absence is unknown, never a disequality. */
	public function difference(reg:Int, donor:Int):Null<Int> {
		return values[reg].root == values[donor].root ? (values[reg].offset - values[donor].offset) | 0 : null;
	}
	public function visit(x:InstructionIR):Void {
		if (((x.effects : Int) & ~(Effect.CONTROL : Int)) != 0) { reset(); return; }
		final d = x.decoded; final a = values[d.rs]; final b = values[d.rt];
		var value:Null<AliasValue> = null; var dest = d.rd;
		switch (d.op) {
			case ADD | ADDU:
				if (b.root == 0) value = plus(a, b.offset);
				else if (a.root == 0) value = plus(b, a.offset);
			case SUB | SUBU:
				if (b.root == 0) value = plus(a, (-b.offset) | 0);
				else if (a.root == b.root) value = constant((a.offset - b.offset) | 0);
			case ADDI | ADDIU: dest = d.rt; value = plus(a, d.immS);
			case LUI: dest = d.rt; value = constant(d.immU << 16);
			case OR | XOR | AND:
				if (a.root == 0 && b.root == 0) value = constant(switch (d.op) {
					case OR: a.offset | b.offset; case XOR: a.offset ^ b.offset; case _: a.offset & b.offset;
				});
				else if (a.root == b.root && a.offset == b.offset) value = d.op == Op.XOR ? constant(0) : a;
				else if (d.op != Op.AND) {
					if (a.root == 0 && a.offset == 0) value = b;
					else if (b.root == 0 && b.offset == 0) value = a;
				}
			case ORI | XORI | ANDI:
				dest = d.rt;
				if (a.root == 0) value = constant(switch (d.op) {
					case ORI: a.offset | d.immU; case XORI: a.offset ^ d.immU; case _: a.offset & d.immU;
				});
				else if (d.immU == 0 && d.op != Op.ANDI) value = a;
			case SLL | SRL | SRA:
				if (d.shamt == 0) value = b;
				else if (b.root == 0) value = constant(switch (d.op) {
					case SLL: b.offset << d.shamt; case SRL: (b.offset >>> d.shamt) | 0; case _: b.offset >> d.shamt;
				});
			case _:
		}
		invalidate(x.writes);
		if (dest != 0 && value != null) values[dest] = value;
	}
	public static function beforeCall(block:BlockIR):CallAliases {
		final facts = new CallAliases();
		for (x in block.body) facts.visit(x);
		// A link is written BEFORE the delay slot. The call itself has not happened yet.
		if (block.transfer != null) facts.invalidate(block.transfer.writes);
		if (block.delaySlot != null) facts.visit(block.delaySlot);
		return facts;
	}
}

private typedef AliasValue = {root:Int, offset:Int};
