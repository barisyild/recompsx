package recomp.mips;

/**
	One decoded instruction. A flat record rather than a sum type: every consumer — the CFG
	builder, the jump-table matcher, the emitter, the formatter — wants a different subset of
	fields, and a variant per shape would force each of them through the same pattern match.
	Fields an operation does not use are zero.
**/
class Instr {
	/** Virtual address this instruction was fetched from (canonical KSEG0 form). */
	public final addr:Int;
	/** The raw 32-bit word, for diagnostics and golden tests. */
	public final raw:Int;
	public final op:Op;

	/** Register numbers, 0..31. Meaning depends on the operation; see the MIPS field layout. */
	public final rs:Int;
	public final rt:Int;
	public final rd:Int;
	public final shamt:Int;

	/** The 16-bit immediate, sign-extended — loads, stores, ALU-immediate, branch offsets. */
	public final immS:Int;
	/** The same bits zero-extended — andi/ori/xori/lui take them unsigned. */
	public final immU:Int;

	/** Absolute target VA for j/jal and for taken branches; 0 otherwise. */
	public final target:Int;

	/** The 20-bit code field of syscall/break, or the full 25-bit COP2 command word. */
	public final code:Int;

	public function new(addr:Int, raw:Int, op:Op, rs:Int, rt:Int, rd:Int, shamt:Int,
			immS:Int, immU:Int, target:Int, code:Int) {
		this.addr = addr;
		this.raw = raw;
		this.op = op;
		this.rs = rs;
		this.rt = rt;
		this.rd = rd;
		this.shamt = shamt;
		this.immS = immS;
		this.immU = immU;
		this.target = target;
		this.code = code;
	}

	/** `sll $zero, $zero, 0` — the canonical nop, and what padding looks like. */
	public var isNop(get, never):Bool;
	function get_isNop():Bool return raw == 0;

	/** JALR with rd=$zero discards the link and transfers exactly like JR. */
	public var isRegisterJump(get, never):Bool;
	function get_isRegisterJump():Bool return op == Op.JR || (op == Op.JALR && rd == 0);

	/** The MIPS ABI names, indexed by register number. These appear in every listing and every
	    diagnostic; the numeric form appears nowhere a person is expected to read. */
	public static final REG_NAMES = [
		"zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
		"t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
		"s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
		"t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra"
	];

	public static inline function regName(r:Int):String return REG_NAMES[r & 31];
}
