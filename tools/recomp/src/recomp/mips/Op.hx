package recomp.mips;

/**
	Every operation the R3000A can perform that a PlayStation game can contain.

	An `enum abstract Op(Int)` rather than a real enum: it costs exactly an integer at run time
	and switches compile to jump tables, but the compiler still checks that a switch over `Op`
	handles what it claims to. That matters more here than anywhere else in the project — when a
	case is added, every consumer that must learn about it fails to compile instead of silently
	falling through to a default and emitting nothing.

	Deliberately absent: FPU (COP1) and COP3, which the PlayStation does not have; TLB
	instructions, which its cut-down COP0 does not implement; and the branch-on-coprocessor-
	condition forms, whose condition lines are not wired. Encountering any of them means the
	disassembler is reading data as code, which is exactly the signal `INVALID` exists to give.
**/
enum abstract Op(Int) to Int {
	// Shifts
	var SLL; var SRL; var SRA; var SLLV; var SRLV; var SRAV;
	// Jumps and traps within SPECIAL
	var JR; var JALR; var SYSCALL; var BREAK;
	// hi/lo
	var MFHI; var MTHI; var MFLO; var MTLO; var MULT; var MULTU; var DIV; var DIVU;
	// ALU, register form
	var ADD; var ADDU; var SUB; var SUBU; var AND; var OR; var XOR; var NOR; var SLT; var SLTU;
	// Branches
	var BLTZ; var BGEZ; var BLTZAL; var BGEZAL;
	var J; var JAL; var BEQ; var BNE; var BLEZ; var BGTZ;
	// ALU, immediate form
	var ADDI; var ADDIU; var SLTI; var SLTIU; var ANDI; var ORI; var XORI; var LUI;
	// Loads and stores
	var LB; var LH; var LWL; var LW; var LBU; var LHU; var LWR;
	var SB; var SH; var SWL; var SW; var SWR;
	// COP0 — only the parts a PlayStation has
	var MFC0; var MTC0; var RFE;
	// COP2 — the GTE
	var MFC2; var CFC2; var MTC2; var CTC2; var LWC2; var SWC2; var COP2CMD;
	// Not an instruction: a word that decodes to nothing this machine can execute.
	var INVALID;

	/** The mnemonic, as a disassembly listing would show it. */
	public var mnemonic(get, never):String;

	function get_mnemonic():String {
		return switch (cast this : Op) {
			case SLL: "sll"; case SRL: "srl"; case SRA: "sra";
			case SLLV: "sllv"; case SRLV: "srlv"; case SRAV: "srav";
			case JR: "jr"; case JALR: "jalr"; case SYSCALL: "syscall"; case BREAK: "break";
			case MFHI: "mfhi"; case MTHI: "mthi"; case MFLO: "mflo"; case MTLO: "mtlo";
			case MULT: "mult"; case MULTU: "multu"; case DIV: "div"; case DIVU: "divu";
			case ADD: "add"; case ADDU: "addu"; case SUB: "sub"; case SUBU: "subu";
			case AND: "and"; case OR: "or"; case XOR: "xor"; case NOR: "nor";
			case SLT: "slt"; case SLTU: "sltu";
			case BLTZ: "bltz"; case BGEZ: "bgez"; case BLTZAL: "bltzal"; case BGEZAL: "bgezal";
			case J: "j"; case JAL: "jal"; case BEQ: "beq"; case BNE: "bne";
			case BLEZ: "blez"; case BGTZ: "bgtz";
			case ADDI: "addi"; case ADDIU: "addiu"; case SLTI: "slti"; case SLTIU: "sltiu";
			case ANDI: "andi"; case ORI: "ori"; case XORI: "xori"; case LUI: "lui";
			case LB: "lb"; case LH: "lh"; case LWL: "lwl"; case LW: "lw";
			case LBU: "lbu"; case LHU: "lhu"; case LWR: "lwr";
			case SB: "sb"; case SH: "sh"; case SWL: "swl"; case SW: "sw"; case SWR: "swr";
			case MFC0: "mfc0"; case MTC0: "mtc0"; case RFE: "rfe";
			case MFC2: "mfc2"; case CFC2: "cfc2"; case MTC2: "mtc2"; case CTC2: "ctc2";
			case LWC2: "lwc2"; case SWC2: "swc2"; case COP2CMD: "cop2";
			case INVALID: "<invalid>";
		}
	}

	/** True for instructions followed by a delay slot: the next instruction executes before the
	    transfer takes effect. Every one of these needs the slot duplicated into its paths at
	    codegen time (docs/specs/tool.md Appendix A). `syscall` and `break` are NOT in this set —
	    exceptions are immediate. */
	public var hasDelaySlot(get, never):Bool;

	function get_hasDelaySlot():Bool {
		return switch (cast this : Op) {
			case J | JAL | JR | JALR: true;
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ | BLTZAL | BGEZAL: true;
			case _: false;
		}
	}

	/** True if control may continue at the following instruction. False for the unconditional
	    transfers, which is how a basic block learns it has no fall-through successor. */
	public var fallsThrough(get, never):Bool;

	function get_fallsThrough():Bool {
		return switch (cast this : Op) {
			case J | JR: false;
			case _: true;
		}
	}
}
