package recomp.codegen;

import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Op;

/**
	Small, semantics-preserving instruction fusions selected before Haxe emission.

	The matcher deliberately sees only adjacent instructions in a basic-block body. That keeps
	delay slots, control transfers, traps and scheduler boundaries out of the first fusion pass.
	The original instructions remain in FunctionIR, so their register masks and cycle charges are
	still authoritative; a fusion only changes the host expression used to implement them.
**/
enum FusedKind {
	ConstantOr;
	ConstantAdd;
	MultLo;
	MultHi;
	MultuLo;
	MultuHi;
	DivLo;
	DivHi;
	DivuLo;
	DivuHi;
}

class FusedPattern {
	public final kind:FusedKind;
	public final length:Int;

	public function new(kind:FusedKind, length:Int = 2) {
		this.kind = kind;
		this.length = length;
	}
}

class PatternMatcher {
	/** Return a fusion beginning at `index`, or null when the pair is not exact. */
	public static function match(body:Array<InstructionIR>, index:Int):Null<FusedPattern> {
		if (index + 1 >= body.length) return null;
		final a = body[index].decoded;
		final b = body[index + 1].decoded;

		// A constant is formed entirely in a register. The destination must be reused by the
		// second instruction; otherwise the first LUI remains architecturally observable.
		if (a.op == Op.LUI && b.rt == a.rt && b.rs == a.rt) {
			return switch (b.op) {
				case ORI: new FusedPattern(ConstantOr);
				case ADDIU: new FusedPattern(ConstantAdd);
				case _: null;
			};
		}

		// MULT/DIV update both HI and LO. The helper preserves that architectural side effect and
		// returns the immediately consumed half, removing a state read from the generated code.
		return switch (a.op) {
			case MULT: resultPair(b, MultLo, MultHi);
			case MULTU: resultPair(b, MultuLo, MultuHi);
			case DIV: resultPair(b, DivLo, DivHi);
			case DIVU: resultPair(b, DivuLo, DivuHi);
			case _: null;
		};
	}

	static function resultPair(i:recomp.mips.Instr, lo:FusedKind, hi:FusedKind):Null<FusedPattern> {
		return if (i.op == Op.MFLO) new FusedPattern(lo)
		else if (i.op == Op.MFHI) new FusedPattern(hi)
		else null;
	}
}
