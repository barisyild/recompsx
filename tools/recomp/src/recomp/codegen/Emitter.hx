package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	Turns analysed MIPS into Haxe.

	The shape of the output is set by two facts about the target language. Haxe has no `goto`, so
	a function's control flow becomes a state machine — `while (true) switch (bb)` with each basic
	block a case that assigns the next block and continues. And Haxe's `Int` does not wrap on
	overflow everywhere (JavaScript's does not), so every arithmetic result that can overflow is
	written `| 0`, which JS needs and C++ folds away (ADR-0004).

	The subtle part is the delay slot. On MIPS the instruction after a branch executes *before*
	the branch takes effect, so it cannot simply be emitted in program order. The rule here is to
	evaluate the branch condition into a temporary first, then emit the slot instruction, then
	transfer — which preserves the semantics even when the slot writes a register the condition
	read. For a `jal` the same ordering applies to the link register.

	Functions with a single straight-line block skip the state machine and emit a flat body. Most
	leaf functions are that shape, and it costs nothing to read better.
**/
class Emitter {
	final image:Image;
	final discovery:Discovery;

	/** Names for shards, so a call can be written as `Fns_03_80012340.f_80012340(ctx)`. */
	public var shardOf:Int -> String = _ -> "Fns";

	public function new(image:Image, discovery:Discovery) {
		this.image = image;
		this.discovery = discovery;
	}

	public function emitFunction(fn:Func):String {
		final buf = new StringBuf();
		final blockAddrs = [for (k in fn.blocks.keys()) k];
		blockAddrs.sort((a, b) -> a - b);

		// Dense indices in address order: stable across regenerations, and the case labels read
		// in the same order as the original listing.
		final indexOf:Map<Int, Int> = [];
		for (i in 0...blockAddrs.length) indexOf.set(blockAddrs[i], i);

		final pumpAt = loopHeaders(fn, blockAddrs);

		buf.add('\t/**\n');
		buf.add('\t\t${fn.name} — ${Vaddr.hex(fn.entry)}..${Vaddr.hex(fn.endAddr - 1)}, '
			+ '${blockAddrs.length} block${blockAddrs.length == 1 ? "" : "s"}, '
			+ '${fn.instructionCount()} instructions.\n');
		if (fn.confidence == recomp.analysis.Confidence.Swept) {
			buf.add('\t\tFound by the prologue sweep rather than by a call, so nothing in the\n');
			buf.add('\t\tprogram is known to reach it statically.\n');
		}
		buf.add('\t**/\n');
		buf.add('\tpublic static function ${fn.name}(ctx:CpuState, entry:Int = 0):Void {\n');
		buf.add(PUMP_ENTRY);

		final flat = blockAddrs.length == 1;
		if (!flat) {
			buf.add('\t\tvar bb = entry;\n');
			buf.add('\t\twhile (true) switch (bb) {\n');
		}

		for (i in 0...blockAddrs.length) {
			final addr = blockAddrs[i];
			final indent = flat ? "\t\t" : "\t\t\t\t";
			if (!flat) buf.add('\t\t\tcase $i: // ${Vaddr.hex(addr)}\n');
			if (pumpAt.exists(addr)) buf.add(indent + PUMP_LINE + "\n");
			emitBlock(buf, fn, addr, indexOf, indent);
		}

		if (!flat) {
			buf.add('\t\t\tdefault: return;   // unreachable; keeps the switch total\n');
			buf.add('\t\t}\n');
		}
		buf.add('\t}\n');
		return buf.toString();
	}

	/**
		The pump check, as it appears in generated code.

		`| 0` is not decoration. The comparison is a subtraction so that it stays correct when the
		cycle counter passes 2^31, and that only works if the subtraction wraps — which C++ does
		and JavaScript does not (ADR-0004). Without it a deadline just past the wrap reads as long
		overdue on one target and correctly future on the other, and the two builds diverge.

		Deliberately one statement in the `if` body and no `else`: an `if` with a multi-statement
		body and no `else` was silently deleted by reflaxe.CPP (upstream defect 8, fixed in our
		fork), and generated code should not depend on that fix being present.
	**/
	// The cycleHint store is not decoration: memory-mapped registers whose value derives from
	// the clock — the root counters above all — read it, and a poll loop that only updated it
	// inside pump() would watch a frozen timer for a whole scheduler interval between deadlines.
	static inline final PUMP_LINE =
		"Memory.cycleHint = ctx.cycles; Memory.raHint = ctx.ra; if (((ctx.cycles - ctx.nextEvent) | 0) >= 0) Runtime.pump(ctx);";

	static inline final PUMP_ENTRY = "\t\t" + PUMP_LINE + "\n";

	/**
		What makes `longjmp` able to leave.

		A non-local jump has to abandon every frame between where it was called and where it
		lands, and in a recompiled program those are host stack frames that only return normally.
		So `longjmp` restores the emulated registers, sets the token, and this line — after every
		call — carries the return all the way out. The top of the runtime then dispatches afresh
		to the saved address, with `sp` and `ra` already correct.

		One statement and no `else`, for the same reason the pump check is.
	**/
	static inline final UNWIND_LINE = "if (ctx.unwindToken != 0) return;";

	/**
		Blocks that a back-edge returns to — the loop headers.

		The pump goes here rather than at each back-edge *source*, which is the same guarantee for
		less code: every path that re-enters a loop passes through its header, including the ones
		that are easy to miss when writing them out one at a time (a recovered switch table's
		edges, a conditional whose two arms are emitted as a ternary). One check per loop instead
		of one per branch, and no way to leave a path uncovered.

		Forward progress follows: any loop in the original program has a back-edge, so any loop in
		the generated program pumps, and an idle `b .` spin still lets time advance.
	**/
	function loopHeaders(fn:Func, blockAddrs:Array<Int>):Map<Int, Bool> {
		final headers:Map<Int, Bool> = [];
		for (from in blockAddrs) {
			final block = fn.blocks.get(from);
			for (to in block.successors) {
				// Backwards or to itself: the definition of a back-edge in an address-ordered CFG.
				if (to <= from) headers.set(to, true);
			}
		}
		return headers;
	}

	// ---- one block ------------------------------------------------------------------------------

	function emitBlock(buf:StringBuf, fn:Func, blockAddr:Int, indexOf:Map<Int, Int>,
			ind:String):Void {
		final block = fn.blocks.get(blockAddr);
		var addr = blockAddr;
		var remaining = block.length;
		var cycles = 0;
		var tempCounter = 0;

		while (remaining > 0) {
			final instr = Decoder.decode(addr, image.readWord(addr));

			if (!instr.op.hasDelaySlot) {
				final line = simple(instr);
				if (line != "") buf.add('$ind$line\n');
				cycles++;
				addr += 4;
				remaining--;
				continue;
			}

			// A control transfer. Its delay slot is the next instruction and runs first.
			final slotAddr = addr + 4;
			final hasSlot = remaining > 1;
			final slot = hasSlot ? Decoder.decode(slotAddr, image.readWord(slotAddr)) : null;
			cycles += hasSlot ? 2 : 1;

			emitTransfer(buf, fn, instr, slot, blockAddr, indexOf, ind, cycles, tempCounter);
			return;   // a block ends at its transfer
		}

		// The block ran out without a transfer: it falls through to the next one.
		if (cycles > 0) buf.add('${ind}ctx.cycles += $cycles;\n');
		if (block.successors.length == 1) {
			emitGoto(buf, ind, block.successors[0], indexOf, addr);
		} else {
			buf.add('${ind}return;   // no successor: analysis stopped here\n');
		}
	}

	function emitTransfer(buf:StringBuf, fn:Func, instr:Instr, slot:Null<Instr>, blockAddr:Int,
			indexOf:Map<Int, Int>, ind:String, cycles:Int, tempCounter:Int):Void {
		final retAddr = instr.addr + 8;
		final slotLine = slot == null ? "" : simple(slot);

		inline function emitSlot():Void {
			if (slot == null) return;
			if (slotLine == "") buf.add('$ind// delay slot: nop\n');
			else buf.add('$ind$slotLine   // delay slot\n');
		}

		inline function bump():Void {
			if (cycles > 0) buf.add('${ind}ctx.cycles += $cycles;\n');
		}

		switch (instr.op) {
			case JR if (instr.rs == 31):
				emitSlot();
				bump();
				buf.add('${ind}return;\n');

			case JR:
				final table = discovery.tables.get(instr.addr);
				final constant = discovery.constantJumps.get(instr.addr);
				if (table != null) {
					final t = 't${tempCounter}';
					buf.add('${ind}final $t = ${reg(instr.rs)};\n');
					emitSlot();
					bump();
					buf.add('${ind}switch ($t) {\n');
					// A switch may send several indices to the same arm, which shows up here as a
					// repeated case label. Emit each target once.
					final emitted:Map<Int, Bool> = [];
					for (target in table.targets) {
						if (indexOf.exists(target) && !emitted.exists(target)) {
							emitted.set(target, true);
							buf.add('$ind\tcase ${hex(target)}: bb = ${indexOf.get(target)}; continue;\n');
						}
					}
					buf.add('$ind\tdefault: ctx.pc = $t; Runtime.call(ctx, $t); return;\n');
					buf.add('$ind}\n');
				} else if (constant != null && isKernelVector(constant.target)) {
					emitSlot();
					bump();
					buf.add('${ind}ctx.pc = ${hex(instr.addr)};\n');
					buf.add('${ind}Kernel.call(ctx, ${hex(constant.target)}, ctx.t1);'
						+ '   // BIOS ${vectorName(constant.target)}('
						+ (constant.fnNumber >= 0 ? hex16(constant.fnNumber) : "?") + ')\n');
					buf.add('${ind}return;\n');
				} else {
					final t = 't${tempCounter}';
					buf.add('${ind}final $t = ${reg(instr.rs)};\n');
					emitSlot();
					bump();
					buf.add('${ind}ctx.pc = $t;\n');
					buf.add('${ind}Runtime.call(ctx, $t);   // computed jump, dispatched by address\n');
					buf.add('${ind}return;\n');
				}

			case JAL:
				// The link is written before the slot runs, which matters when the slot reads $ra.
				buf.add('${ind}ctx.ra = ${hex(retAddr)};\n');
				emitSlot();
				bump();
				emitCall(buf, ind, instr.target);
				emitFallThrough(buf, fn, ind, indexOf, retAddr);

			case JALR:
				final t = 't${tempCounter}';
				// The target is latched before the link is written, so `jalr $ra, $ra` works.
				buf.add('${ind}final $t = ${reg(instr.rs)};\n');
				buf.add('${ind}${reg(instr.rd)} = ${hex(retAddr)};\n');
				emitSlot();
				bump();
				buf.add('${ind}ctx.pc = $t;\n');
				buf.add('${ind}Runtime.call(ctx, $t);\n');
				buf.add(ind + UNWIND_LINE + "\n");
				emitFallThrough(buf, fn, ind, indexOf, retAddr);

			case J:
				final target = instr.target;
				emitSlot();
				bump();
				if (indexOf.exists(target)) {
					buf.add('${ind}bb = ${indexOf.get(target)}; continue;\n');
				} else {
					emitCall(buf, ind, target);        // a tail call
					buf.add('${ind}return;\n');
				}

			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ | BLTZAL | BGEZAL:
				final cond = 'c${tempCounter}';
				// The condition is evaluated before the slot, because the slot may overwrite one
				// of the registers it reads. This is the single most common way to get delay
				// slots wrong.
				buf.add('${ind}final $cond = ${condition(instr)};\n');
				if (instr.op == Op.BLTZAL || instr.op == Op.BGEZAL) {
					// The link happens whether or not the branch is taken.
					buf.add('${ind}ctx.ra = ${hex(retAddr)};   // linked even when not taken\n');
				}
				emitSlot();
				bump();

				final taken = instr.target;
				final notTaken = instr.addr + 8;
				final takenIdx = indexOf.exists(taken) ? indexOf.get(taken) : -1;
				final notTakenIdx = indexOf.exists(notTaken) ? indexOf.get(notTaken) : -1;

				if (takenIdx >= 0 && notTakenIdx >= 0) {
					buf.add('${ind}bb = $cond ? $takenIdx : $notTakenIdx; continue;\n');
				} else if (takenIdx >= 0) {
					buf.add('${ind}if ($cond) { bb = $takenIdx; continue; } else { return; }\n');
				} else if (notTakenIdx >= 0) {
					buf.add('${ind}if ($cond) { return; } else { bb = $notTakenIdx; continue; }\n');
				} else {
					buf.add('${ind}return;\n');
				}

			case _:
				buf.add('$ind// unhandled transfer: ${Disasm.text(instr)}\n');
				buf.add('${ind}return;\n');
		}
	}

	function emitCall(buf:StringBuf, ind:String, target:Int):Void {
		final t = Vaddr.canonRam(target);
		if (discovery.functions.exists(t)) {
			buf.add('$ind${shardOf(t)}.${Discovery.defaultName(t)}(ctx);\n');
			buf.add(ind + UNWIND_LINE + "\n");
		} else {
			// Outside this image — another overlay, or the kernel.
			buf.add('${ind}ctx.pc = ${hex(t)};\n');
			buf.add('${ind}Runtime.call(ctx, ${hex(t)});\n');
			buf.add(ind + UNWIND_LINE + "\n");
		}
	}

	function emitFallThrough(buf:StringBuf, fn:Func, ind:String, indexOf:Map<Int, Int>,
			addr:Int):Void {
		if (indexOf.exists(addr)) buf.add('${ind}bb = ${indexOf.get(addr)}; continue;\n');
		else buf.add('${ind}return;\n');
	}

	function emitGoto(buf:StringBuf, ind:String, target:Int, indexOf:Map<Int, Int>,
			fallback:Int):Void {
		if (indexOf.exists(target)) buf.add('${ind}bb = ${indexOf.get(target)}; continue;\n');
		else buf.add('${ind}return;\n');
	}

	// ---- instructions without a delay slot -------------------------------------------------------

	/** The Haxe statement for one non-branching instruction, or "" for a nop. */
	function simple(i:Instr):String {
		if (i.isNop) return "";

		final rd = i.rd, rt = i.rt, rs = i.rs;
		return switch (i.op) {
			// Arithmetic wraps. `| 0` is what makes JavaScript agree with the hardware; C++
			// folds it away. See ADR-0004.
			// Folded where a source is $zero or the immediate is 0. These are not micro-
			// optimisations — the compiler would fold them anyway — but the generated code is
			// read by people during bring-up, and `ctx.v0 = 4` says what `(0 + 4) | 0` hides.
			case ADDI | ADDIU:
				if (rs == 0) assign(rt, Std.string(i.immS), false)
				else if (i.immS == 0) assign(rt, reg(rs), false)
				else assign(rt, '${reg(rs)} + ${i.immS}', true);
			case ADD | ADDU:
				if (rs == 0) assign(rd, reg(rt), false)
				else if (rt == 0) assign(rd, reg(rs), false)
				else assign(rd, '${reg(rs)} + ${reg(rt)}', true);
			case SUB | SUBU:
				if (rt == 0) assign(rd, reg(rs), false)
				else assign(rd, '${reg(rs)} - ${reg(rt)}', true);

			case AND:  assign(rd, '${reg(rs)} & ${reg(rt)}', false);
			case OR:
				// `or rd, rs, $zero` is the canonical register move.
				if (rt == 0) assign(rd, reg(rs), false)
				else if (rs == 0) assign(rd, reg(rt), false)
				else assign(rd, '${reg(rs)} | ${reg(rt)}', false);
			case XOR:  assign(rd, '${reg(rs)} ^ ${reg(rt)}', false);
			case NOR:  assign(rd, '~(${reg(rs)} | ${reg(rt)})', false);

			case ANDI: assign(rt, '${reg(rs)} & ${hex16(i.immU)}', false);
			case ORI:  assign(rt, '${reg(rs)} | ${hex16(i.immU)}', false);
			case XORI: assign(rt, '${reg(rs)} ^ ${hex16(i.immU)}', false);
			case LUI:  assign(rt, hex(i.immU << 16), false);

			case SLT:   assign(rd, '${reg(rs)} < ${reg(rt)} ? 1 : 0', false);
			case SLTI:  assign(rt, '${reg(rs)} < ${i.immS} ? 1 : 0', false);
			// Unsigned comparison on a signed type: flip both sign bits and compare.
			case SLTU:  assign(rd, '(${reg(rs)} ^ 0x80000000) < (${reg(rt)} ^ 0x80000000) ? 1 : 0', false);
			case SLTIU: assign(rt, '(${reg(rs)} ^ 0x80000000) < ${hex(i.immS ^ 0x80000000)} ? 1 : 0', false);

			case SLL:  assign(rd, '${reg(rt)} << ${i.shamt}', false);
			case SRL:  assign(rd, '${reg(rt)} >>> ${i.shamt}', false);
			case SRA:  assign(rd, '${reg(rt)} >> ${i.shamt}', false);
			case SLLV: assign(rd, '${reg(rt)} << (${reg(rs)} & 31)', false);
			case SRLV: assign(rd, '${reg(rt)} >>> (${reg(rs)} & 31)', false);
			case SRAV: assign(rd, '${reg(rt)} >> (${reg(rs)} & 31)', false);

			case MULT:  'Ops.mult(ctx, ${reg(rs)}, ${reg(rt)});';
			case MULTU: 'Ops.multu(ctx, ${reg(rs)}, ${reg(rt)});';
			case DIV:   'Ops.div(ctx, ${reg(rs)}, ${reg(rt)});';
			case DIVU:  'Ops.divu(ctx, ${reg(rs)}, ${reg(rt)});';
			case MFHI:  assign(rd, 'ctx.hi', false);
			case MFLO:  assign(rd, 'ctx.lo', false);
			case MTHI:  'ctx.hi = ${reg(rs)};';
			case MTLO:  'ctx.lo = ${reg(rs)};';

			// A load into $zero still performs the read: half the address space is hardware.
			case LB:  load(rt, 'Memory.read8s(${addrExpr(i)})');
			case LBU: load(rt, 'Memory.read8u(${addrExpr(i)})');
			case LH:  load(rt, 'Memory.read16s(${addrExpr(i)})');
			case LHU: load(rt, 'Memory.read16u(${addrExpr(i)})');
			case LW:  load(rt, 'Memory.read32(${addrExpr(i)})');
			case LWL: load(rt, 'Memory.lwl(${addrExpr(i)}, ${reg(rt)})');
			case LWR: load(rt, 'Memory.lwr(${addrExpr(i)}, ${reg(rt)})');

			case SB: 'Memory.write8(${addrExpr(i)}, ${reg(rt)});';
			case SH: 'Memory.write16(${addrExpr(i)}, ${reg(rt)});';
			case SW: 'Memory.write32(${addrExpr(i)}, ${reg(rt)});';
			case SWL: 'Memory.swl(${addrExpr(i)}, ${reg(rt)});';
			case SWR: 'Memory.swr(${addrExpr(i)}, ${reg(rt)});';

			case SYSCALL: 'ctx.pc = ${hex(i.addr)}; Kernel.syscall(ctx, ${i.code});';
			case BREAK:   'ctx.pc = ${hex(i.addr)}; Kernel.brk(ctx, ${i.code});';

			case MFC0: assign(rt, 'Runtime.mfc0(ctx, ${i.rd})', false);
			case MTC0: 'Runtime.mtc0(ctx, ${i.rd}, ${reg(rt)});';
			case RFE:  'Runtime.rfe(ctx);';

			case MFC2: assign(rt, 'Gte.getData(ctx, ${i.rd})', false);
			case MTC2: 'Gte.setData(ctx, ${i.rd}, ${reg(rt)});';
			case CFC2: assign(rt, 'Gte.getCtrl(ctx, ${i.rd})', false);
			case CTC2: 'Gte.setCtrl(ctx, ${i.rd}, ${reg(rt)});';
			case LWC2: 'Gte.setData(ctx, ${i.rt}, Memory.read32(${addrExpr(i)}));';
			case SWC2: 'Memory.write32(${addrExpr(i)}, Gte.getData(ctx, ${i.rt}));';
			case COP2CMD: 'Gte.execute(ctx, ${hex(i.code)});';

			case _: '// unhandled: ${Disasm.text(i)}';
		}
	}

	/** `rs + offset`, with the offset folded away when it is zero. */
	function addrExpr(i:Instr):String {
		if (i.rs == 0) return hex(i.immS);
		if (i.immS == 0) return reg(i.rs);
		return '(${reg(i.rs)} + ${i.immS}) | 0';
	}

	/** An assignment, dropped entirely when the destination is $zero. */
	function assign(dest:Int, expr:String, wraps:Bool):String {
		if (dest == 0) return "";
		return '${reg(dest)} = ' + (wraps ? '($expr) | 0;' : '$expr;');
	}

	/** A load whose result is discarded still has to happen: the address may be a register. */
	function load(dest:Int, expr:String):String {
		return dest == 0 ? '$expr;   // result discarded; the read may have side effects'
			: '${reg(dest)} = $expr;';
	}

	function condition(i:Instr):String {
		return switch (i.op) {
			case BEQ:  '${reg(i.rs)} == ${reg(i.rt)}';
			case BNE:  '${reg(i.rs)} != ${reg(i.rt)}';
			case BLEZ: '${reg(i.rs)} <= 0';
			case BGTZ: '${reg(i.rs)} > 0';
			case BLTZ | BLTZAL: '${reg(i.rs)} < 0';
			case BGEZ | BGEZAL: '${reg(i.rs)} >= 0';
			case _: 'false';
		}
	}

	// ---- naming -----------------------------------------------------------------------------------

	/** `$zero` is a literal, not a field: it is the most-read register and costs nothing. */
	inline function reg(n:Int):String
		return n == 0 ? "0" : "ctx." + Instr.regName(n);

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}

	static function hex16(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 12;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}

	static inline function isKernelVector(a:Int):Bool
		return a == 0xA0 || a == 0xB0 || a == 0xC0;

	static function vectorName(a:Int):String
		return a == 0xA0 ? "A0" : (a == 0xB0 ? "B0" : "C0");
}
