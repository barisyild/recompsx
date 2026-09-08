package recomp.analysis;

import recomp.Vaddr;
import recomp.mips.Decoder;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.analysis.JumpTable;
import recomp.analysis.TableConfidence;
import recomp.analysis.JumpKind;

/**
	What a register is known to hold, as far as this analysis cares.

	Deliberately tiny. The goal is not to understand the program, it is to recognise one compiler
	idiom — index, scale, add to a table base, load, jump — and everything outside that pattern
	can safely collapse to `Unknown`, because the recovered table is validated afterwards. A
	wrong guess is rejected by the validator; a missing guess costs one runtime dispatch.
**/
enum Val {
	Unknown;
	/** A known constant, usually half-built by `lui` and completed by `addiu` or `ori`. */
	Const(v:Int);
	/** `srcReg << shift` — the scaled index. */
	Scaled(srcReg:Int, shift:Int);
	/** `base + (idxReg << shift)` — a table base plus a scaled index. */
	Based(base:Int, idxReg:Int, shift:Int);
	/** The value loaded from `mem[tableBase + (idxReg << shift)]` — a table entry. */
	Loaded(tableBase:Int, idxReg:Int, shift:Int);
}

/**
	Recovers switch tables from computed jumps.

	Psy-Q and GCC both compile a dense `switch` to the same shape:

	```
	sltiu $v0, $idx, N        ; bound check against the arm count
	beqz  $v0, default
	 sll  $v0, $idx, 2        ; scale the index to a word offset
	lui   $at, hi(table)
	addu  $at, $at, $v0
	lw    $v0, lo(table)($at) ; fetch the arm's address
	nop
	jr    $v0
	```

	so the recovery is a small forward constant-propagation over the instructions leading up to
	the `jr`, looking for a value that came from a load at a constant base plus a scaled index.
	The bound check gives the entry count directly; when it is missing — the compiler can prove
	the index in range, or it sits in a block this window does not cover — entries are read until
	one stops looking like a jump target.

	Everything recovered is validated before it is believed: every entry must be word-aligned and
	inside the image, and the whole table must not overlap code already claimed by a function.
	That validation is what makes the guessing safe. The cost of guessing wrong and being caught
	is nothing; the cost of not guessing is one runtime dispatch, which is also correct, just
	slower and less legible.
**/
class TableFinder {
	/** How far back to look for the pattern. The idiom is compact; a wider window mostly finds
	    coincidences. */
	static inline var WINDOW = 24;

	/** No switch has this many arms; a "table" this long is data being misread. */
	static inline var MAX_ENTRIES = 512;

	final image:Image;

	public function new(image:Image) {
		this.image = image;
	}

	/**
		Attempts to recover the table behind one `jr`.

		`codeStart`/`codeEnd` bound where a jump target may plausibly point — the code region, not
		the whole image — because an entry pointing into the data segment is the clearest sign
		that this was never a table.
	**/
	public function analyze(jrAddr:Int, codeStart:Int, codeEnd:Int):JumpKind {
		final jr = Decoder.decode(jrAddr, image.readWord(jrAddr));
		if (!jr.isRegisterJump || jr.rs == 31) return JumpKind.Unresolved;

		final regs = propagate(jrAddr);

		switch (regs[jr.rs]) {
			case Loaded(tableBase, idxReg, shift):
				// A word table: anything else is not a switch on a word-indexed array.
				if (shift != 2) return JumpKind.Unresolved;
				final bound = findBound(jrAddr, idxReg);
				final t = build(jrAddr, tableBase, idxReg, bound, codeStart, codeEnd);
				return t == null ? JumpKind.Unresolved : JumpKind.Table(t);

			case Const(target):
				// The delay slot runs before the jump, so it carries the function number for a
				// BIOS call. Propagating one more instruction is what makes that visible.
				final slotAddr = jrAddr + 4;
				var fnNumber = -1;
				if (image.containsWord(slotAddr)) {
					step(regs, Decoder.decode(slotAddr, image.readWord(slotAddr)));
					switch (regs[9]) {          // $t1 by the Psy-Q kernel-call convention
						case Const(n): fnNumber = n;
						case _:
					}
				}
				return JumpKind.Constant(target, fnNumber);

			case _:
				return JumpKind.Unresolved;
		}
	}

	// ---- the small abstract interpreter -------------------------------------------------------

	/**
		Propagates values forward over the instructions preceding `jrAddr`.

		The window is taken in address order rather than by walking the control-flow graph. That
		is an approximation — the instructions before a `jr` in memory are not guaranteed to be
		the ones that executed — but the idiom being matched is emitted as one straight run, and
		the validator catches any table the approximation invents.
	**/
	function propagate(jrAddr:Int):Array<Val> {
		final regs = [for (_ in 0...32) Val.Unknown];
		var addr = jrAddr - WINDOW * 4;
		if (addr < image.baseAddr) addr = image.baseAddr;

		while (addr < jrAddr) {
			if (!image.containsWord(addr)) break;
			final i = Decoder.decode(addr, image.readWord(addr));
			step(regs, i);
			addr += 4;
		}
		return regs;
	}

	function step(regs:Array<Val>, i:Instr):Void {
		inline function set(r:Int, v:Val):Void {
			if (r != 0) regs[r] = v;   // $zero never changes
		}

		switch (i.op) {
			case LUI:
				set(i.rt, Const(i.immU << 16));

			case ADDIU | ADDI:
				set(i.rt, switch (regs[i.rs]) {
					case Const(c): Const(c + i.immS);
					case _ if (i.rs == 0): Const(i.immS);
					case _: Unknown;
				});

			case ORI:
				set(i.rt, switch (regs[i.rs]) {
					case Const(c): Const(c | i.immU);
					case _ if (i.rs == 0): Const(i.immU);
					case _: Unknown;
				});

			case SLL:
				// `sll rd, rt, sa` scales an index. sa == 0 is a move, which is also worth
				// tracking so a copied index still resolves.
				set(i.rd, i.shamt == 0 ? regs[i.rt] : Scaled(i.rt, i.shamt));

			case ADDU | ADD:
				set(i.rd, combine(regs[i.rs], regs[i.rt], i.rs, i.rt));

			case LW:
				set(i.rt, switch (regs[i.rs]) {
					case Based(base, idx, shift): Loaded(base + i.immS, idx, shift);
					case _: Unknown;
				});

			// Anything else that writes a register makes it unknown. Being conservative here
			// costs a recovery at worst; being optimistic would cost correctness.
			case SRL | SRA | SLLV | SRLV | SRAV | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU
				| ANDI | SLTI | SLTIU | XORI | MFHI | MFLO:
				set(i.rd == 0 ? i.rt : i.rd, Unknown);
			case LB | LBU | LH | LHU | LWL | LWR | MFC0 | MFC2 | CFC2:
				set(i.rt, Unknown);
			case JAL | JALR:
				// A call clobbers the caller-saved registers, which is exactly the set an index
				// would live in. Anything surviving a call is not part of this idiom.
				for (r in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25, 31]) {
					regs[r] = Unknown;
				}
			case _:
		}
	}

	/** `addu` of a constant and a scaled index is the table-address computation. */
	function combine(a:Val, b:Val, aReg:Int, bReg:Int):Val {
		// $zero contributes nothing, so `addu rd, rs, $zero` is a move.
		if (aReg == 0) return b;
		if (bReg == 0) return a;

		return switch [a, b] {
			case [Const(c1), Const(c2)]: Const(c1 + c2);
			case [Const(c), Scaled(idx, s)] | [Scaled(idx, s), Const(c)]: Based(c, idx, s);
			case [Const(c), Based(base, idx, s)] | [Based(base, idx, s), Const(c)]:
				Based(base + c, idx, s);
			case _: Unknown;
		}
	}

	/**
		Looks backwards for the compiler's own bound check on the index.

		`sltiu rC, idx, N` sets rC when the index is below N, and the branch that follows sends
		everything else to the default arm — so N is the arm count, stated by the compiler rather
		than inferred by us. This is the difference between a table we know the size of and one we
		had to guess at.
	**/
	function findBound(jrAddr:Int, idxReg:Int):Int {
		var addr = jrAddr - 4;
		final limit = jrAddr - WINDOW * 4;
		while (addr >= limit && addr >= image.baseAddr) {
			if (!image.containsWord(addr)) break;
			final i = Decoder.decode(addr, image.readWord(addr));
			if ((i.op == Op.SLTIU || i.op == Op.SLTI) && i.rs == idxReg && i.immU > 0) {
				return i.immU;
			}
			// The index being redefined ends the search: anything earlier bounds a different value.
			if (writes(i, idxReg)) break;
			addr -= 4;
		}
		return 0;
	}

	function writes(i:Instr, reg:Int):Bool {
		return switch (i.op) {
			case SLL | SRL | SRA | SLLV | SRLV | SRAV | ADD | ADDU | SUB | SUBU | AND | OR
				| XOR | NOR | SLT | SLTU | MFHI | MFLO: i.rd == reg;
			case ADDI | ADDIU | SLTI | SLTIU | ANDI | ORI | XORI | LUI | LB | LBU | LH | LHU
				| LW | LWL | LWR | MFC0 | MFC2 | CFC2: i.rt == reg;
			case _: false;
		}
	}

	// ---- validation ---------------------------------------------------------------------------

	function build(jrAddr:Int, base:Int, idxReg:Int, bound:Int, codeStart:Int,
			codeEnd:Int):Null<JumpTable> {
		if (!image.containsWord(base)) return null;

		final targets = [];
		final limit = bound > 0 ? (bound < MAX_ENTRIES ? bound : MAX_ENTRIES) : MAX_ENTRIES;
		var i = 0;
		while (i < limit) {
			final at = base + i * 4;
			if (!image.containsWord(at)) break;
			final entry = image.readWord(at);
			if (!plausibleTarget(entry, codeStart, codeEnd)) break;
			targets.push(Vaddr.canonRam(entry));
			i++;
		}

		if (bound > 0) {
			// The compiler told us the count; if the table does not hold that many plausible
			// entries, the pattern matched something that is not a table.
			if (targets.length < bound) return null;
			return new JumpTable(jrAddr, base, idxReg, TableConfidence.Bounded, targets);
		}

		// Without a bound, insist on enough entries that coincidence is unlikely.
		if (targets.length < 3) return null;
		return new JumpTable(jrAddr, base, idxReg, TableConfidence.Scanned, targets);
	}

	/** Could this word be the address of a switch arm? */
	function plausibleTarget(v:Int, codeStart:Int, codeEnd:Int):Bool {
		if ((v & 3) != 0) return false;
		final a = Vaddr.canonRam(v);
		if (a < codeStart || a >= codeEnd) return false;
		if (!image.containsWord(a)) return false;
		// An arm starts with a real instruction. This rejects tables of data pointers, which are
		// otherwise indistinguishable from tables of code pointers.
		return Decoder.decode(a, image.readWord(a)).op != Op.INVALID;
	}
}
