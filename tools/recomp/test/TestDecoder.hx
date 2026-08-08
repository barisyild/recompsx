import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.mips.Op;

/**
	Golden decoding tests.

	Each case is a real instruction word and the listing line it must produce. The words are
	written as hex rather than built by an encoder on purpose: an encoder would share whatever
	misunderstanding the decoder has, and agreeing with itself proves nothing. These come from the
	published encoding, and several are lifted from actual Psy-Q prologues and epilogues, which is
	where the operand-order mistakes live.
**/
class TestDecoder {
	static inline var BASE = 0x80010000;

	/** word, expected text */
	static final CASES:Array<{w:Int, t:String}> = [
		// The shapes every compiled function begins and ends with
		{w: 0x27BDFFE8, t: "addiu $sp, $sp, -24"},
		{w: 0xAFBF0014, t: "sw $ra, 20($sp)"},
		{w: 0x8FBF0014, t: "lw $ra, 20($sp)"},
		{w: 0x03E00008, t: "jr $ra"},
		{w: 0x27BD0018, t: "addiu $sp, $sp, 24"},
		{w: 0x00000000, t: "nop"},

		// ALU, register form. `slt` in particular has a operand order worth pinning down.
		{w: 0x00001021, t: "addu $v0, $zero, $zero"},
		{w: 0x0104082A, t: "slt $at, $t0, $a0"},
		{w: 0x00481021, t: "addu $v0, $v0, $t0"},
		{w: 0x00851023, t: "subu $v0, $a0, $a1"},
		{w: 0x00851024, t: "and $v0, $a0, $a1"},
		{w: 0x00851025, t: "or $v0, $a0, $a1"},
		{w: 0x00851027, t: "nor $v0, $a0, $a1"},
		{w: 0x0085102B, t: "sltu $v0, $a0, $a1"},

		// Shifts. `sllv` takes its amount from rs, which reads out of order.
		{w: 0x00042080, t: "sll $a0, $a0, 2"},
		{w: 0x00042082, t: "srl $a0, $a0, 2"},
		{w: 0x00042083, t: "sra $a0, $a0, 2"},
		{w: 0x00A42004, t: "sllv $a0, $a0, $a1"},
		{w: 0x00A42006, t: "srlv $a0, $a0, $a1"},
		{w: 0x00A42007, t: "srav $a0, $a0, $a1"},

		// ALU, immediate form. Signed operands print signed, logical ones print hex.
		{w: 0x24420001, t: "addiu $v0, $v0, 1"},
		{w: 0x2442FFFF, t: "addiu $v0, $v0, -1"},
		{w: 0x28820010, t: "slti $v0, $a0, 16"},
		{w: 0x2C820010, t: "sltiu $v0, $a0, 16"},
		{w: 0x308200FF, t: "andi $v0, $a0, 0x00ff"},
		{w: 0x34820100, t: "ori $v0, $a0, 0x0100"},
		{w: 0x3C018001, t: "lui $at, 0x8001"},

		// hi/lo
		{w: 0x00850018, t: "mult $a0, $a1"},
		{w: 0x0085001B, t: "divu $a0, $a1"},
		{w: 0x00001012, t: "mflo $v0"},
		{w: 0x00001010, t: "mfhi $v0"},

		// Loads and stores, including the unaligned pair
		{w: 0x80820000, t: "lb $v0, 0($a0)"},
		{w: 0x90820000, t: "lbu $v0, 0($a0)"},
		{w: 0x84820000, t: "lh $v0, 0($a0)"},
		{w: 0x94820000, t: "lhu $v0, 0($a0)"},
		{w: 0x88820000, t: "lwl $v0, 0($a0)"},
		{w: 0x98820003, t: "lwr $v0, 3($a0)"},
		{w: 0xA8820000, t: "swl $v0, 0($a0)"},
		{w: 0xB8820003, t: "swr $v0, 3($a0)"},

		// System
		{w: 0x0000000C, t: "syscall"},
		{w: 0x0000000D, t: "break"},
		{w: 0x42000010, t: "rfe"},
		{w: 0x40086000, t: "mfc0 $t0, $SR"},
		{w: 0x40886000, t: "mtc0 $t0, $SR"},

		// GTE: register transfers and two commands, with their flag fields decoded
		{w: 0x48880000, t: "mtc2 $t0, $0"},
		{w: 0x48080000, t: "mfc2 $t0, $0"},
		{w: 0xC88C0000, t: "lwc2 $12, 0($a0)"},
		{w: 0x4A180001, t: "RTPS sf=1"},
		{w: 0x4A280030, t: "RTPT sf=1"},

		// Words this machine cannot execute. Being strict here is what stops the analyzer from
		// walking into a jump table and inventing functions out of pointer values.
		{w: 0x44000000, t: "<invalid 0x44000000>"},   // COP1 — there is no FPU
		{w: 0x582D5350, t: "<invalid 0x582d5350>"}    // the ASCII "PS-X", read as an instruction
	];

	public static function run():Void {
		Assert.group("decoder: golden instruction listings");
		for (c in CASES) {
			final i = Decoder.decode(BASE, c.w);
			Assert.equals(Disasm.text(i), c.t, "word " + StringTools.hex(c.w, 8));
		}

		Assert.group("decoder: branch and jump targets");
		// A branch's offset counts from the delay slot, not from the branch.
		final bne = Decoder.decode(BASE, 0x14200007);
		Assert.equals(bne.op, Op.BNE, "bne decodes");
		Assert.equals(bne.target, BASE + 4 + 7 * 4, "branch target is relative to the delay slot");

		// A negative offset, which is what every loop uses.
		final back = Decoder.decode(BASE + 0x38, 0x1000FFF5);
		Assert.equals(back.target, BASE + 0x38 + 4 + (-11 * 4), "backward branch");

		// j/jal keep the top four bits of the *delay slot's* address.
		final jal = Decoder.decode(BASE + 0x20, 0x0C004010);
		Assert.equals(jal.op, Op.JAL, "jal decodes");
		Assert.equals(jal.target, 0x80010040, "jal target");

		// The boundary case: a jump in the last slot of a 256 MB region takes the *next*
		// region's top bits, because the calculation uses pc+4.
		final edge = Decoder.decode(0x8FFFFFFC, 0x08000000);
		Assert.equals(edge.target, 0x90000000, "jump at a region boundary uses pc+4");

		Assert.group("decoder: instruction properties");
		Assert.isTrue(Decoder.decode(BASE, 0x0C004010).op.hasDelaySlot, "jal has a delay slot");
		Assert.isTrue(Decoder.decode(BASE, 0x14200007).op.hasDelaySlot, "bne has a delay slot");
		Assert.isTrue(!Decoder.decode(BASE, 0x0000000C).op.hasDelaySlot, "syscall has none");
		Assert.isTrue(!Decoder.decode(BASE, 0x03E00008).op.fallsThrough, "jr does not fall through");
		Assert.isTrue(!Decoder.decode(BASE, 0x08000000).op.fallsThrough, "j does not fall through");
		Assert.isTrue(Decoder.decode(BASE, 0x0C004010).op.fallsThrough, "jal does fall through");
		Assert.isTrue(Decoder.decode(BASE, 0x14200007).op.fallsThrough, "a branch falls through");

		Assert.group("decoder: rejects what the PlayStation cannot run");
		// Non-canonical REGIMM selectors, coprocessor condition branches, COP1 and COP3.
		Assert.equals(Decoder.decode(BASE, 0x04080000).op, Op.INVALID, "REGIMM rt=8 is not canonical");
		Assert.equals(Decoder.decode(BASE, 0x41000000).op, Op.INVALID, "BC0F has no condition line");
		Assert.equals(Decoder.decode(BASE, 0x49000000).op, Op.INVALID, "BC2F has no condition line");
		Assert.equals(Decoder.decode(BASE, 0x4C000000).op, Op.INVALID, "COP3 does not exist");
		Assert.equals(Decoder.decode(BASE, 0x42000001).op, Op.INVALID, "TLB ops do not exist");
		Assert.equals(Decoder.decode(BASE, 0x00000001).op, Op.INVALID, "unassigned SPECIAL funct");

		Assert.group("decoder: syscall and break carry their code field");
		final sys = Decoder.decode(BASE, 0x0000004C);   // code 1
		Assert.equals(sys.op, Op.SYSCALL, "syscall with a code still decodes");
		Assert.equals(sys.code, 1, "syscall code field");
		Assert.equals(Disasm.text(sys), "syscall 0x00000001", "syscall prints its code");
	}
}
