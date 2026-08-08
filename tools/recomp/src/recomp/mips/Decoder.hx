package recomp.mips;

/**
	Turns a 32-bit word into an `Instr`.

	The R3000A encoding is regular enough that this is mostly three lookup tables — the primary
	opcode, the SPECIAL function field, and the REGIMM branch selector — plus the two coprocessor
	spaces the PlayStation actually populates. What takes care is the negative space: which
	encodings must be rejected.

	Rejecting aggressively is the point. The disassembler's hardest job is not decoding
	instructions, it is noticing that it has walked off the end of a function into a jump table or
	a string. A word that decodes to a plausible-looking instruction when it is really data leads
	to a function that "exists" and quietly emits nonsense. So anything the PlayStation cannot
	execute — the FPU, COP3, TLB management, coprocessor condition branches — decodes to
	`INVALID`, and analysis treats a run of those as evidence it is reading data.
**/
class Decoder {
	// Primary opcode field, bits 31..26.
	static inline var OP_SPECIAL = 0x00;
	static inline var OP_REGIMM  = 0x01;
	static inline var OP_COP0    = 0x10;
	static inline var OP_COP2    = 0x12;

	public static function decode(addr:Int, raw:Int):Instr {
		final primary = (raw >>> 26) & 0x3F;
		final rs = (raw >>> 21) & 0x1F;
		final rt = (raw >>> 16) & 0x1F;
		final rd = (raw >>> 11) & 0x1F;
		final shamt = (raw >>> 6) & 0x1F;
		final funct = raw & 0x3F;
		final imm = raw & 0xFFFF;
		final immS = (imm << 16) >> 16;   // sign-extended
		final immU = imm;

		var op = Op.INVALID;
		var target = 0;
		var code = 0;

		switch (primary) {
			case OP_SPECIAL:
				op = decodeSpecial(funct);
				if (op == Op.SYSCALL || op == Op.BREAK) code = (raw >>> 6) & 0xFFFFF;

			case OP_REGIMM:
				// Only four of the 32 rt values are canonical. The hardware decodes others as
				// aliases, but no compiler emits them, so treating them as data is the useful
				// reading.
				op = switch (rt) {
					case 0x00: Op.BLTZ;
					case 0x01: Op.BGEZ;
					case 0x10: Op.BLTZAL;
					case 0x11: Op.BGEZAL;
					case _: Op.INVALID;
				}
				if (op != Op.INVALID) target = branchTarget(addr, immS);

			case 0x02: op = Op.J;   target = jumpTarget(addr, raw);
			case 0x03: op = Op.JAL; target = jumpTarget(addr, raw);

			case 0x04: op = Op.BEQ;  target = branchTarget(addr, immS);
			case 0x05: op = Op.BNE;  target = branchTarget(addr, immS);
			case 0x06: op = Op.BLEZ; target = branchTarget(addr, immS);
			case 0x07: op = Op.BGTZ; target = branchTarget(addr, immS);

			case 0x08: op = Op.ADDI;
			case 0x09: op = Op.ADDIU;
			case 0x0A: op = Op.SLTI;
			case 0x0B: op = Op.SLTIU;
			case 0x0C: op = Op.ANDI;
			case 0x0D: op = Op.ORI;
			case 0x0E: op = Op.XORI;
			case 0x0F: op = Op.LUI;

			case OP_COP0: op = decodeCop0(rs, funct);
			case OP_COP2: {
				// Bit 25 distinguishes a GTE command from a register transfer.
				if ((raw & 0x02000000) != 0) {
					op = Op.COP2CMD;
					code = raw & 0x01FFFFFF;
				} else {
					op = switch (rs) {
						case 0x00: Op.MFC2;
						case 0x02: Op.CFC2;
						case 0x04: Op.MTC2;
						case 0x06: Op.CTC2;
						case _: Op.INVALID;   // includes BC2F/BC2T: the condition line is unwired
					}
				}
			}

			case 0x20: op = Op.LB;
			case 0x21: op = Op.LH;
			case 0x22: op = Op.LWL;
			case 0x23: op = Op.LW;
			case 0x24: op = Op.LBU;
			case 0x25: op = Op.LHU;
			case 0x26: op = Op.LWR;

			case 0x28: op = Op.SB;
			case 0x29: op = Op.SH;
			case 0x2A: op = Op.SWL;
			case 0x2B: op = Op.SW;
			case 0x2E: op = Op.SWR;

			case 0x32: op = Op.LWC2;
			case 0x3A: op = Op.SWC2;

			// Everything else — COP1 (no FPU), COP3, the other coprocessor loads and stores,
			// and the unassigned slots — is not something this machine can run.
			case _: op = Op.INVALID;
		}

		return new Instr(addr, raw, op, rs, rt, rd, shamt, immS, immU, target, code);
	}

	static function decodeSpecial(funct:Int):Op {
		return switch (funct) {
			case 0x00: Op.SLL;
			case 0x02: Op.SRL;
			case 0x03: Op.SRA;
			case 0x04: Op.SLLV;
			case 0x06: Op.SRLV;
			case 0x07: Op.SRAV;
			case 0x08: Op.JR;
			case 0x09: Op.JALR;
			case 0x0C: Op.SYSCALL;
			case 0x0D: Op.BREAK;
			case 0x10: Op.MFHI;
			case 0x11: Op.MTHI;
			case 0x12: Op.MFLO;
			case 0x13: Op.MTLO;
			case 0x18: Op.MULT;
			case 0x19: Op.MULTU;
			case 0x1A: Op.DIV;
			case 0x1B: Op.DIVU;
			case 0x20: Op.ADD;
			case 0x21: Op.ADDU;
			case 0x22: Op.SUB;
			case 0x23: Op.SUBU;
			case 0x24: Op.AND;
			case 0x25: Op.OR;
			case 0x26: Op.XOR;
			case 0x27: Op.NOR;
			case 0x2A: Op.SLT;
			case 0x2B: Op.SLTU;
			case _: Op.INVALID;
		}
	}

	static function decodeCop0(rs:Int, funct:Int):Op {
		// rs bit 4 set marks the "CO" forms, of which the PlayStation implements only rfe.
		if ((rs & 0x10) != 0) return funct == 0x10 ? Op.RFE : Op.INVALID;
		return switch (rs) {
			case 0x00: Op.MFC0;
			case 0x04: Op.MTC0;
			// 0x02/0x06 (cfc0/ctc0) read as zero on this CPU and no game uses them; 0x08 is
			// BC0F/BC0T, whose condition line does not exist here.
			case _: Op.INVALID;
		}
	}

	/** j/jal keep the top four bits of the delay slot's address, not of the branch itself. */
	static inline function jumpTarget(addr:Int, raw:Int):Int
		return ((addr + 4) & 0xF0000000) | ((raw & 0x03FFFFFF) << 2);

	/** Branches are relative to the delay slot. */
	static inline function branchTarget(addr:Int, immS:Int):Int
		return addr + 4 + (immS << 2);

	/** Decodes a run of words. Convenience for tests and for `recompsx dis`. */
	public static function decodeRange(baseAddr:Int, words:Array<Int>):Array<Instr> {
		final out = [];
		for (i in 0...words.length) out.push(decode(baseAddr + i * 4, words[i]));
		return out;
	}
}
