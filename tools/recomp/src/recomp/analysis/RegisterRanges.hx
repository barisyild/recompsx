package recomp.analysis;

import recomp.ir.Effect;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Op;

/** Signed word intervals within ONE basic block. Every addressable block can be entered by
	dispatch/resumption with arbitrary registers, so predecessor facts are never assumed.
	No host floating point or wider integer arithmetic is used, even for overflow proofs.
**/
class RegisterRanges {
	final regs:Array<WordRange> = [];
	public function new() { clear(); }
	function clear():Void {
		for (r in 0...32) regs[r] = r == 0 ? WordRange.ZERO : WordRange.ANY;
	}
	public function get(r:Int):WordRange return regs[r];

	public function visit(x:InstructionIR):Void {
		final i = x.decoded;
		final a = regs[i.rs]; final b = regs[i.rt];
		var result = WordRange.ANY;
		var rd = i.rd;
		switch (i.op) {
			case ADD | ADDU:
				if (i.op == Op.ADD && a.canAdd(b)) x.proveNoOverflow();
				result = a.add(b);
			case SUB | SUBU:
				if (i.op == Op.SUB && (i.rs == i.rt || a.canSub(b))) x.proveNoOverflow();
				result = i.rs == i.rt ? WordRange.ZERO : a.sub(b);
			case ADDI | ADDIU:
				rd = i.rt;
				final immediate = WordRange.constant(i.immS);
				if (i.op == Op.ADDI && a.canAdd(immediate)) x.proveNoOverflow();
				result = a.add(immediate);
			case AND: result = i.rs == i.rt ? a : a.and(b);
			case OR: result = i.rs == i.rt ? a : a.or(b);
			case XOR: result = i.rs == i.rt ? WordRange.ZERO : a.xor(b);
			case NOR: result = (i.rs == i.rt ? a : a.or(b)).not();
			case ANDI: rd = i.rt; result = a.and(WordRange.constant(i.immU));
			case ORI: rd = i.rt; result = a.or(WordRange.constant(i.immU));
			case XORI: rd = i.rt; result = a.xor(WordRange.constant(i.immU));
			case LUI: rd = i.rt; result = WordRange.constant(i.immU << 16);
			case SLL: result = b.shl(i.shamt);
			case SRL: result = b.shr(i.shamt);
			case SRA: result = b.sar(i.shamt);
			case SLLV: result = a.singleton() ? b.shl(a.lo & 31) : WordRange.ANY;
			case SRLV: result = a.singleton() ? b.shr(a.lo & 31) : (b.lo >= 0 ? new WordRange(0, b.hi) : WordRange.ANY);
			case SRAV: result = a.singleton() ? b.sar(a.lo & 31) : new WordRange(b.lo < 0 ? b.lo : 0, b.hi < 0 ? -1 : b.hi);
			case SLT | SLTU: result = WordRange.BOOL;
			case SLTI | SLTIU: rd = i.rt; result = WordRange.BOOL;
			case JAL | JALR | BLTZAL | BGEZAL:
				// The callee executes AFTER the slot. Preserve pre-call facts for that slot,
				// but not the link's address: relocatable code has no fixed guest PC here.
				for (r in 1...32) if (x.writes.has(r)) regs[r] = WordRange.ANY;
				return;
			case J | JR | BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ: return;
			case _:
				// Loads and runtime helpers are barriers too: neither successful aligned RAM
				// access nor a completed R3000A load delay is proved by an opcode's width.
				clear(); return;
		}
		if (x.effects.has(Effect.TRAP)) {
			// An unproved arithmetic trap may enter a handler before execution continues.
			clear(); return;
		}
		if (rd != 0) regs[rd] = result;
	}
}

/** Immutable signed bounds; wrapped results widen to ANY unless both operands are constants. */
class WordRange {
	public static inline final MIN = 0x80000000;
	public static inline final MAX = 0x7fffffff;
	public static final ANY = new WordRange(MIN, MAX);
	public static final ZERO = new WordRange(0, 0);
	public static final BOOL = new WordRange(0, 1);
	public final lo:Int;
	public final hi:Int;
	public function new(lo:Int, hi:Int) { this.lo = lo; this.hi = hi; }
	public static function constant(n:Int):WordRange return n == 0 ? ZERO : new WordRange(n, n);
	public function singleton():Bool return lo == hi;
	public function contains(n:Int):Bool return n >= lo && n <= hi;
	public function canAdd(b:WordRange):Bool {
		return (b.lo >= 0 || lo >= MIN - b.lo) && (b.hi <= 0 || hi <= MAX - b.hi);
	}
	public function canSub(b:WordRange):Bool {
		return (b.hi <= 0 || lo >= MIN + b.hi) && (b.lo >= 0 || hi <= MAX + b.lo);
	}
	public function add(b:WordRange):WordRange {
		if (singleton() && b.singleton()) return constant((lo + b.lo) | 0);
		return canAdd(b) ? new WordRange((lo + b.lo) | 0, (hi + b.hi) | 0) : ANY;
	}
	public function sub(b:WordRange):WordRange {
		if (singleton() && b.singleton()) return constant((lo - b.lo) | 0);
		return canSub(b) ? new WordRange((lo - b.hi) | 0, (hi - b.lo) | 0) : ANY;
	}
	public function and(b:WordRange):WordRange {
		if (singleton() && b.singleton()) return constant(lo & b.lo);
		if (lo >= 0 && b.lo >= 0) return new WordRange(0, hi < b.hi ? hi : b.hi);
		if (lo >= 0) return new WordRange(0, hi);
		if (b.lo >= 0) return new WordRange(0, b.hi);
		return hi < 0 && b.hi < 0 ? new WordRange(MIN, hi < b.hi ? hi : b.hi) : ANY;
	}
	static function cover(n:Int):Int {
		n |= n >>> 1; n |= n >>> 2; n |= n >>> 4; n |= n >>> 8; n |= n >>> 16;
		return n;
	}
	public function or(b:WordRange):WordRange {
		if (b.singleton() && b.lo == 0) return this;
		if (singleton() && lo == 0) return b;
		if (singleton() && b.singleton()) return constant(lo | b.lo);
		if (lo >= 0 && b.lo >= 0) return new WordRange(0, cover(hi | b.hi));
		if (hi < 0 && b.hi < 0) return new WordRange(lo > b.lo ? lo : b.lo, -1);
		if (hi < 0) return new WordRange(lo, -1);
		return b.hi < 0 ? new WordRange(b.lo, -1) : ANY;
	}
	public function xor(b:WordRange):WordRange {
		if (b.singleton() && b.lo == 0) return this;
		if (singleton() && lo == 0) return b;
		if (singleton() && b.singleton()) return constant(lo ^ b.lo);
		if (lo >= 0 && b.lo >= 0) return new WordRange(0, cover(hi | b.hi));
		if (hi < 0 && b.hi < 0) return new WordRange(0, MAX);
		return (hi < 0 && b.lo >= 0) || (lo >= 0 && b.hi < 0) ? new WordRange(MIN, -1) : ANY;
	}
	public function not():WordRange return new WordRange(~hi, ~lo);
	public function shl(n:Int):WordRange {
		if (singleton()) return constant(lo << n);
		return lo >= (MIN >> n) && hi <= (MAX >> n) ? new WordRange(lo << n, hi << n) : ANY;
	}
	public function shr(n:Int):WordRange {
		if (n == 0) return this;
		return lo >= 0 || hi < 0 ? new WordRange(lo >>> n, hi >>> n) : new WordRange(0, -1 >>> n);
	}
	public function sar(n:Int):WordRange return new WordRange(lo >> n, hi >> n);
}
