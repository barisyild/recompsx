package recomp.mips;

import recomp.Vaddr;

/** Resolves an address to a name, if one is known. Symbols come from `syms.txt` and from
    discovery; the disassembler works fine without any. */
typedef SymLookup = Int -> Null<String>;

/**
	Formats decoded instructions the way a person reads them.

	Every diagnostic this tool produces quotes disassembly — an unknown instruction, a branch into
	nowhere, a jump table that failed to resolve. The listing is therefore not a debugging
	convenience, it is the primary interface for the reverse-engineering work the project needs a
	human to do, and it is worth making readable: ABI register names rather than numbers, symbols
	substituted for addresses where known, and `nop` printed as `nop`.
**/
class Disasm {
	/** GTE command names, indexed by the low six bits of a COP2 command word. Only the real
	    operations are named; anything else prints numerically and should be treated as suspect. */
	static final GTE_OPS = [
		0x01 => "RTPS",  0x06 => "NCLIP", 0x0C => "OP",    0x10 => "DPCS",
		0x11 => "INTPL", 0x12 => "MVMVA", 0x13 => "NCDS",  0x14 => "CDP",
		0x16 => "NCDT",  0x1B => "NCCS",  0x1C => "CC",    0x1E => "NCS",
		0x20 => "NCT",   0x28 => "SQR",   0x29 => "DCPL",  0x2A => "DPCT",
		0x2D => "AVSZ3", 0x2E => "AVSZ4", 0x30 => "RTPT",  0x3D => "GPF",
		0x3E => "GPL",   0x3F => "NCCT"
	];

	/** COP0 register names. Only the ones the PlayStation implements are worth naming. */
	static final COP0_NAMES = [
		3 => "BPC", 5 => "BDA", 6 => "JUMPDEST", 7 => "DCIC", 8 => "BadVaddr",
		9 => "BDAM", 11 => "BPCM", 12 => "SR", 13 => "Cause", 14 => "EPC", 15 => "PRID"
	];

	/** One instruction, without the address prefix. */
	public static function text(i:Instr, ?syms:SymLookup):String {
		if (i.isNop) return "nop";

		final m = i.op.mnemonic;
		return switch (i.op) {
			// rd, rt, shamt
			case SLL | SRL | SRA:
				'$m ${r(i.rd)}, ${r(i.rt)}, ${i.shamt}';
			// rd, rt, rs  (note the operand order: the shift amount comes from rs)
			case SLLV | SRLV | SRAV:
				'$m ${r(i.rd)}, ${r(i.rt)}, ${r(i.rs)}';
			// rd, rs, rt
			case ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU:
				'$m ${r(i.rd)}, ${r(i.rs)}, ${r(i.rt)}';
			// rs, rt
			case MULT | MULTU | DIV | DIVU:
				'$m ${r(i.rs)}, ${r(i.rt)}';
			case MFHI | MFLO:
				'$m ${r(i.rd)}';
			case MTHI | MTLO:
				'$m ${r(i.rs)}';
			// rt, rs, immediate
			case ADDI | ADDIU | SLTI | SLTIU:
				'$m ${r(i.rt)}, ${r(i.rs)}, ${signed(i.immS)}';
			case ANDI | ORI | XORI:
				'$m ${r(i.rt)}, ${r(i.rs)}, ${Vaddr.hex16(i.immU)}';
			case LUI:
				'$m ${r(i.rt)}, ${Vaddr.hex16(i.immU)}';
			// loads and stores
			case LB | LH | LWL | LW | LBU | LHU | LWR | SB | SH | SWL | SW | SWR:
				'$m ${r(i.rt)}, ${signed(i.immS)}(${r(i.rs)})';
			case LWC2 | SWC2:
				'$m ${gteData(i.rt)}, ${signed(i.immS)}(${r(i.rs)})';
			// branches
			case BEQ | BNE:
				'$m ${r(i.rs)}, ${r(i.rt)}, ${addr(i.target, syms)}';
			case BLEZ | BGTZ | BLTZ | BGEZ | BLTZAL | BGEZAL:
				'$m ${r(i.rs)}, ${addr(i.target, syms)}';
			// jumps
			case J | JAL:
				'$m ${addr(i.target, syms)}';
			case JR:
				'$m ${r(i.rs)}';
			case JALR:
				// `jalr rs` is the common form; the explicit destination only prints when it is
				// something other than ra, because that is the case worth noticing.
				i.rd == 31 ? '$m ${r(i.rs)}' : '$m ${r(i.rd)}, ${r(i.rs)}';
			// system
			case SYSCALL | BREAK:
				i.code == 0 ? m : '$m ${Vaddr.hex(i.code)}';
			case RFE:
				m;
			// coprocessor transfers
			case MFC0 | MTC0:
				'$m ${r(i.rt)}, ${cop0(i.rd)}';
			case MFC2 | MTC2:
				'$m ${r(i.rt)}, ${gteData(i.rd)}';
			case CFC2 | CTC2:
				'$m ${r(i.rt)}, ${gteCtrl(i.rd)}';
			case COP2CMD:
				gteCommand(i.code);
			case INVALID:
				'<invalid ${Vaddr.hex(i.raw)}>';
			case _:
				m;
		}
	}

	/** A full listing line: address, raw word, and the instruction. */
	public static function line(i:Instr, ?syms:SymLookup):String {
		final label = syms == null ? null : syms(i.addr);
		final prefix = '${hex8(i.addr)}: ${hex8(i.raw)}  ';
		final body = text(i, syms);
		return label == null ? prefix + body : '$prefix$body' + "   ; <" + label + ">";
	}

	/** Several instructions, one per line. */
	public static function lines(instrs:Array<Instr>, ?syms:SymLookup):String {
		final out = [];
		for (i in instrs) out.push(line(i, syms));
		return out.join("\n");
	}

	/**
		The ±n instructions around an address, marking the one in question.

		Every hard error in the analyzer prints one of these. Being told "invalid instruction at
		0x8003f2a4" is nearly useless; being shown that it sits immediately after a `jr ra` and
		looks like four ASCII characters answers the question on the spot.
	**/
	public static function context(instrs:Array<Instr>, index:Int, radius:Int = 8,
			?syms:SymLookup):String {
		final out = [];
		var i = index - radius;
		if (i < 0) i = 0;
		final end = index + radius + 1 < instrs.length ? index + radius + 1 : instrs.length;
		while (i < end) {
			final marker = i == index ? " >> " : "    ";
			out.push(marker + line(instrs[i], syms));
			i++;
		}
		return out.join("\n");
	}

	// ---- operand formatting ----------------------------------------------------------------

	static inline function r(n:Int):String return "$" + Instr.regName(n);

	static function signed(v:Int):String {
		// Offsets read better as decimal when small and hex when they are clearly addresses.
		if (v > -1024 && v < 1024) return Std.string(v);
		return v < 0 ? "-" + Vaddr.hex16(-v & 0xFFFF) : Vaddr.hex16(v & 0xFFFF);
	}

	static function addr(a:Int, syms:Null<SymLookup>):String {
		if (syms != null) {
			final name = syms(a);
			if (name != null) return '$name /* ${hex8(a)} */';
		}
		return hex8(a);
	}

	static function cop0(n:Int):String {
		final name = COP0_NAMES[n];
		return name != null ? "$" + name : "$cop0_" + n;
	}

	static inline function gteData(n:Int):String return '$$$n';
	static inline function gteCtrl(n:Int):String return '$$${n + 32}';

	static function gteCommand(imm25:Int):String {
		final opcode = imm25 & 0x3F;
		final name = GTE_OPS[opcode];
		if (name == null) return 'cop2 ${Vaddr.hex(imm25)}';

		// The fields games actually vary: the fractional shift, the saturation flag, and for
		// MVMVA the three operand selectors. Printing them saves constant manual bit-picking.
		final parts = [name];
		final sf = (imm25 >>> 19) & 1;
		final lm = (imm25 >>> 10) & 1;
		if (sf != 0) parts.push("sf=1");
		if (lm != 0) parts.push("lm=1");
		if (opcode == 0x12) {
			final mx = (imm25 >>> 17) & 3;
			final v = (imm25 >>> 15) & 3;
			final cv = (imm25 >>> 13) & 3;
			parts.push('mx=$mx');
			parts.push('v=$v');
			parts.push('cv=$cv');
		}
		return parts.join(" ");
	}

	static function hex8(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}
}
