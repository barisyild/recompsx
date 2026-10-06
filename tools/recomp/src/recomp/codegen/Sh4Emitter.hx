package recomp.codegen;

import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.ir.FunctionIR;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	ADR-0048: a guest function as SH-4 assembly, which a Dreamcast build (`-D recompsx_sh4`) links in
	place of the function's C++ form for its ordinary entry. The C++ form stays the definition: every
	other target compiles it, and on the Dreamcast it still serves every entry but 0 and a call that
	finds a pump due (Program writes the wrapper that chooses).

	The assembly does what the C++ form does — the same loads and stores in the same order, the same
	cycle charges at the same places, the same registers written, the same pumps at the same loop
	headers — and it is held to that by the game digests on the Dreamcast (`scripts/dc-digest.sh`).
	What differs is where values live, which is the whole point (docs/perf/dreamcast-ledger.md
	E-131, E-136: a straight translation was a sixth slower than GCC's code, its guest registers
	past the sixth going through CpuState at every use):

	- **Homes.** The guest registers worth it — counted by their uses, a block inside a loop
	  counting eight times per level, against what holding one costs: its load at the entry when
	  its value there is needed, its store at the ways out when the function writes it, and the
	  save and restore of an SH-4 register the C ABI wants kept — live in SH-4 registers for the
	  whole function. The rest go through CpuState, a temporary remembering what it last held.
	- **Fastmem only** (ADR-0049): an access is its bus address's mask and one `mov.{b,w,l}`; an
	  offset that is not negative goes from the base's bus address, kept in r2 while the base is
	  unchanged — the C++ form's `recompsx_p0_ld32b`, whose displacement forms the trap decodes.
	  lwl and lwr read their aligned word through P0 too: what traps is emulated as a word read,
	  which is what `Memory.lwl`/`lwr` do.
	- **Loops** pump at their headers as the C++ form does (`Emitter.emitPump`): the clock
	  against the deadline, and when it is due, out of line, every home the function writes
	  stored, the pump, the unwind test and every home loaded again. A loop the C++ form counts
	  idle turns of (IdleLoopPlan) is declined, as is anything that calls, traps or touches a
	  coprocessor: those keep their C++ form everywhere.

	SH-4 registers: r0-r3 temporaries (r2 the base's bus address, or a branch's condition across its
	delay slot), r4 the CpuState, r5 the clock, r6 0x1FFFFFFF when the function reaches memory, the
	homes in r7 (free in a leaf) and r8-r14 (saved and restored), r15 the stack.
**/
class Sh4Emitter {
	final image:Image;
	final discovery:Discovery;

	/** Why functions were declined, by reason: the generator reports it. */
	public final declined:Map<String, Int> = [];

	/** Set by Program before `emit`: whether the function's C++ form skips the idle turns of one of
	    its loops (IdleLoopPlan), which the assembly does not do. */
	public var idleLoops = false;

	public function new(image:Image, discovery:Discovery) {
		this.image = image;
		this.discovery = discovery;
	}

	/** CpuState's layout as reflaxe.CPP lays it out (core_CpuState.h); checked at compile time by
	    the static_asserts Program writes beside the assembly. */
	public static final FIELD_OFFSET:Map<String, Int> = [
		"v0" => 0, "v1" => 4, "cycles" => 8, "a0" => 12, "sp" => 16, "t8" => 20, "a1" => 24,
		"t9" => 28, "s0" => 32, "ra" => 36, "unwindToken" => 40, "a2" => 44, "s1" => 48,
		"a3" => 52, "s2" => 56, "at" => 60, "nextEvent" => 64, "t0" => 68, "s7" => 72,
		"s3" => 76, "s4" => 80, "t2" => 84, "s5" => 88, "t1" => 92, "s6" => 96, "t5" => 100,
		"t3" => 104, "gp" => 108, "t6" => 112, "t4" => 116, "t7" => 120, "pc" => 124,
		"fp" => 128, "lo" => 132, "tailTarget" => 136, "returnTarget" => 140, "hi" => 144,
		"k0" => 148, "k1" => 152,
	];

	static inline function offsetOf(name:String):Int return FIELD_OFFSET.get(name);

	static inline function gregOffset(r:Int):Int return FIELD_OFFSET.get(Instr.regName(r));

	/** The accesses as fastmem's (ADR-0049): a Dreamcast build with `RECOMPSX_FASTMEM` links them.
	    Set by the generator (`RECOMPSX_SH4_FASTMEM`); without it nothing is taken. */
	public static var FASTMEM = Sys.getEnv("RECOMPSX_SH4_FASTMEM") != null;

	/** For bisecting: `RECOMPSX_SH4_ONLY` names the only functions taken (comma-separated), and
	    `RECOMPSX_SH4_SKIP` functions never taken. */
	static final ONLY:Null<Map<String, Bool>> = listEnv("RECOMPSX_SH4_ONLY");
	static final SKIP:Null<Map<String, Bool>> = listEnv("RECOMPSX_SH4_SKIP");
	/** `RECOMPSX_SH4_DUMP=<dir>`: each function's assembly written there too, as `<symbol>.s`. */
	static final DUMP:Null<String> = Sys.getEnv("RECOMPSX_SH4_DUMP");

	static function listEnv(name:String):Null<Map<String, Bool>> {
		final v = Sys.getEnv(name);
		if (v == null || v == "") return null;
		return [for (s in v.split(",")) StringTools.trim(s) => true];
	}

	static final CTX = "r4";
	static final CYC = "r5";
	static final MASK = "r6";
	/** The registers homes go to, in the order they are given: r7 costs nothing in a function that
	    calls nothing, r8-r14 a save and a restore at each call of the function. */
	static final HOMES = ["r7", "r8", "r9", "r10", "r11", "r12", "r13", "r14"];

	// ---- the function --------------------------------------------------------------------------

	var asm:Sh4Asm;
	var ir:FunctionIR;
	var fn:Func;
	var symbol:String;
	var index:Map<Int, Int>;
	/** The function's webs and their SH-4 registers. */
	var webs:Sh4Webs;
	/** The sites (Sh4Webs) whose uses and definitions the instruction being written reads and writes:
	    one instruction's both, or for a fused pair the first's uses and the second's definitions. */
	var useSite = 0;
	var defSite = 0;
	/** Guest registers (bit per register) written somewhere in the function. */
	var written:Int;
	/** The accesses PortBases expects at a port, by address. */
	var ports:Map<Int, Bool>;
	var usesMemory:Bool;
	/** Callee-saved registers this function uses, in push order. */
	var saved:Array<String>;
	/** Whether the function has a checked return (ADR-0027): `$ra` at the entry kept on the stack. */
	var checksRa:Bool;
	/** Whether the clock register has been written to CpuState since it last changed: an access
	    that traps reads it there. */
	var clockStored:Bool;
	var labelCount:Int;
	var stubs:Array<Void->Void>;
	/** What a temporary holds, in straight-line code: a guest register's value (its number), or a
	    base's bus address (`BUS + number`). Every write of a temporary drops what it held
	    (Sh4Asm.onWrite); a label others jump to, all of it. */
	var holds:Map<String, Int> = [];
	/** Guest registers known to hold a constant, in straight-line code (a label forgets them). */
	var consts:Map<Int, Int> = [];

	static inline var BUS = 64;
	/** Whether r2 holds a branch's condition across its delay slot: no base's bus address there. */
	var r2Locked = false;

	public function emit(fn:Func, symbol:String):Null<String> {
		final reason = eligibility(fn);
		if (reason != null) {
			declined.set(reason, (declined.exists(reason) ? declined.get(reason) : 0) + 1);
			if (Sys.getEnv("RECOMPSX_SH4_WHY") != null) Sys.println('sh4: ${fn.name} declined: $reason (all: ${allReasons(fn).join(", ")})');
			else {}
			return null;
		} else {}
		this.fn = fn;
		this.symbol = symbol;
		ir = new FunctionIR(fn, image);
		analyze();
		// Every conditional branch long the first time, then short wherever the last pass put the
		// target within reach — until a pass whose short branches all still reach (an island can
		// move between passes, so this is checked rather than assumed).
		var shortOk:Map<Int, Bool> = [];
		generate(shortOk);
		shortOk = asm.reachable();
		var settled = false;
		for (_ in 0...6) {
			generate(shortOk);
			if (asm.shortsReach()) {
				settled = true;
				break;
			} else {}
			final now = asm.reachable();
			shortOk = [for (k in shortOk.keys()) if (now.exists(k)) k => true];
		}
		final text = settled ? asm.finish(symbol) : null;
		if (text == null) {
			declined.set("pool out of reach", (declined.exists("pool out of reach") ? declined.get("pool out of reach") : 0) + 1);
			if (Sys.getEnv("RECOMPSX_SH4_WHY") != null) Sys.println('sh4: ${fn.name} declined: pool out of reach (${asm.bytes()} bytes)');
			else {}
			return null;
		} else {}
		if (DUMP != null) sys.io.File.saveContent('$DUMP/$symbol.s', '! ${fn.name}: ${webs.webCount} webs, saved ${saved.join(" ")}\n' + text);
		else {}
		return text;
	}

	/** Null when this step can emit `fn`, else why not. */
	function eligibility(fn:Func):Null<String> {
		if (!FASTMEM) return "not fastmem";
		if (ONLY != null && !ONLY.exists(fn.name)) return "not listed";
		if (SKIP != null && SKIP.exists(fn.name)) return "skipped";
		if (idleLoops) return "idle loop";
		if (fn.hops.keys().hasNext()) return "hands over";
		if (fn.registerReturns.keys().hasNext()) return "returns through a copy of ra";
		final ir = new FunctionIR(fn, image);
		for (block in ir.blocks) {
			for (x in block.body) {
				final r = instrReason(x.decoded);
				if (r != null) return r;
			}
			if (block.delaySlot != null) {
				final r = instrReason(block.delaySlot.decoded);
				if (r != null) return r;
			} else {}
			if (block.transfer != null) {
				final t = block.transfer.decoded;
				switch (t.op) {
					case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
						if (!ir.byAddress.exists(t.target) || !ir.byAddress.exists(t.addr + 8)) return "branch out";
					case J:
						if (!ir.byAddress.exists(t.target)) return "tail call";
					case JR:
						if (t.rs != 31 && discovery.tables.get(t.addr) == null) return "computed jump";
						if (t.rs == 31 && discovery.raJumpOf(fn.entry, t.addr) != null) return "ra jump";
					case _:
						return "calls";
				}
			} else {
				// A block that runs on: into a block of its own, never into another function.
				final next = block.addr + block.instructions.length * 4;
				if (block.successors.length != 1 || block.successors[0] != next || !ir.byAddress.exists(next)) return "runs on";
			}
		}
		return null;
	}

	/** Every reason, with counts, for the generator's diagnostics (RECOMPSX_SH4_WHY). */
	function allReasons(fn:Func):Array<String> {
		final counts:Map<String, Int> = [];
		function add(r:String) counts.set(r, (counts.exists(r) ? counts.get(r) : 0) + 1);
		if (idleLoops) add("idle loop");
		if (fn.hops.keys().hasNext()) add("hands over");
		if (fn.registerReturns.keys().hasNext()) add("returns through a copy of ra");
		for (_ in fn.checkedReturns.keys()) add("checked returns");
		final ir = new FunctionIR(fn, image);
		for (block in ir.blocks) {
			if (block.pump) add("loop");
			for (x in block.instructions) {
				final r = instrReason(x.decoded);
				if (r != null && x != block.transfer) add(r);
				else {}
			}
			if (block.transfer != null) {
				final t = block.transfer.decoded;
				switch (t.op) {
					case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
						if (!ir.byAddress.exists(t.target) || !ir.byAddress.exists(t.addr + 8)) add("branch out");
					case J:
						if (!ir.byAddress.exists(t.target)) add("tail call");
					case JR:
						if (t.rs != 31) add("computed jump");
						else if (discovery.raJumpOf(fn.entry, t.addr) != null) add("ra jump");
					case JAL: add("calls");
					case JALR: add("calls through a register");
					case _: add("calls (" + t.op.mnemonic + ")");
				}
			} else {}
		}
		return [for (k => v in counts) '$k $v'];
	}

	static function instrReason(i:Instr):Null<String> {
		return switch (i.op) {
			case SLL | SRL | SRA | SLLV | SRLV | SRAV | ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU
				| ADDI | ADDIU | SLTI | SLTIU | ANDI | ORI | XORI | LUI
				| MFHI | MTHI | MFLO | MTLO | MULT | MULTU | DIV | DIVU
				| LB | LH | LWL | LW | LBU | LHU | LWR | SB | SH | SWL | SW | SWR: null;
			case SYSCALL | BREAK: "trap";
			case MFC0 | MTC0 | RFE: "cop0";
			case MFC2 | CFC2 | MTC2 | CTC2 | LWC2 | SWC2 | COP2CMD: "gte";
			case _: "other";
		};
	}

	static inline function isMemory(op:Op):Bool
		return switch (op) {
			case LB | LH | LWL | LW | LBU | LHU | LWR | SB | SH | SWL | SW | SWR: true;
			case _: false;
		};

	// ---- analysis ------------------------------------------------------------------------------

	/** What the function writes and whether it reaches memory; then the webs and their registers
	    (Sh4Webs): r7 first, r6 too when nothing reaches memory, then r8-r14. */
	function analyze():Void {
		index = [];
		for (k in 0...ir.blocks.length) index.set(ir.blocks[k].addr, k);
		written = 0;
		usesMemory = false;
		for (block in ir.blocks) for (x in block.instructions) {
			written |= (x.writes:Int);
			if (isMemory(x.decoded.op)) usesMemory = true;
			else {}
		}
		written &= ~1;
		final pool = (usesMemory ? [] : ["r6"]).concat(HOMES);
		webs = new Sh4Webs(ir, written, pool, fn.checkedReturns);
		saved = webs.saved;
		checksRa = fn.checkedReturns.keys().hasNext();
		// The accesses the C++ form expects at a port and decodes in software (`*pt`): through the
		// shared routines here too, where the MMU would trap.
		ports = PortBases.analyze(ir, image, _ -> -1);
	}

	// ---- generation ----------------------------------------------------------------------------

	function label(what:String):String return '.L${symbol}_${what}_${labelCount++}';

	function blockLabel(addr:Int):String return '.L${symbol}_b${StringTools.hex(addr, 8)}';

	function exitLabel():String return '.L${symbol}_exit';

	function unwindLabel():String return '.L${symbol}_unwound';

	function generate(shortOk:Map<Int, Bool>):Void {
		asm = new Sh4Asm(shortOk);
		holds = [];
		consts = [];
		asm.onWrite = reg -> holds.remove(reg);
		asm.onLabel = () -> {
			holds = [];
			consts = [];
			clockStored = false;
		};
		clockStored = false;
		labelCount = 0;
		stubs = [];
		// Prologue: the callee-saved registers this function uses, its pinned values, and every
		// home whose value at the entry is needed.
		for (r in saved) asm.op('mov.l\t$r,@-r15');
		if (checksRa) {
			// The entry's $ra, for the checked returns (`entryRa`).
			asm.op('mov.l\t@(36,$CTX),r0');
			asm.op('mov.l\tr0,@-r15');
		} else {}
		asm.op('mov.l\t@(8,$CTX),$CYC');
		if (usesMemory) asm.load(MASK, "0x1FFFFFFF");
		else {}
		for (e in webs.entryLoads) loadField(webs.color[e.web], gregOffset(e.reg));
		for (k in 0...ir.blocks.length) {
			final block = ir.blocks[k];
			asm.label(blockLabel(block.addr));
			if (block.pump) pump(k);
			else {}
			var j = 0;
			while (j < block.body.length) {
				final x = block.body[j].decoded;
				// `lui rt, hi` then `ori`/`addiu rt, rt, lo`: one constant (the C++ form's value
				// regions fold it too); nothing reads rt in between.
				if (x.op == Op.LUI && x.rt != 0 && j + 1 < block.body.length) {
					final y = block.body[j + 1].decoded;
					if ((y.op == Op.ORI || y.op == Op.ADDIU) && y.rs == x.rt && y.rt == x.rt) {
						asm.checkpoint();
						at(block.body[j + 1]);
						final t = target(x.rt, []);
						final v = y.op == Op.ORI ? ((x.immU << 16) | y.immU) : (((x.immU << 16) + y.immS) | 0);
						constant(t, v);
						write(x.rt, t);
						consts.set(x.rt, v);
						j += 2;
						continue;
					} else {}
				} else {}
				// `lwr rt, k(rs)` and `lwl rt, k+3(rs)`, either first: one unaligned word, as the C++
				// form fuses them (PatternMatcher, Memory.lwu).
				if ((x.op == Op.LWR || x.op == Op.LWL) && j + 1 < block.body.length) {
					final y = block.body[j + 1].decoded;
					final r = x.op == Op.LWR ? x : y;
					final l = x.op == Op.LWR ? y : x;
					if (y.op == (x.op == Op.LWR ? Op.LWL : Op.LWR) && y.rt == x.rt && y.rs == x.rs && x.rt != x.rs
						&& x.rt != 0 && l.immS == r.immS + 3) {
						asm.checkpoint();
						useSite = webs.siteOf.get(block.body[j]);
						defSite = webs.siteOf.get(block.body[j + 1]);
						fusedWord(x, y, r);
						j += 2;
						continue;
					} else {}
				} else {}
				at(block.body[j]);
				instruction(x);
				j++;
			}
			final t = block.transfer;
			if (t == null) {
				charge(block.cycles);
				final next = block.addr + block.instructions.length * 4;
				final follows = k + 1 < ir.blocks.length && ir.blocks[k + 1].addr == next;
				if (!follows) asm.jump(blockLabel(next));
				else {}
				continue;
			} else {}
			final d = t.decoded;
			final slot = block.delaySlot == null ? null : block.delaySlot.decoded;
			asm.checkpoint();
			switch (d.op) {
				case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
					// The condition is read before the slot runs, which may change its registers —
					// unless the slot writes none of them: then the slot runs first and the test
					// after it.
					final slotFirst = slot != null && !slot.isNop && ((block.delaySlot.writes:Int) & (t.reads:Int)) == 0;
					if (slotFirst) {
						at(block.delaySlot);
						instruction(slot);
					} else {}
					at(t);
					final cond = condition(d);
					final next = d.addr + 8;
					final follows = k + 1 < ir.blocks.length && ir.blocks[k + 1].addr == next;
					if (cond == ALWAYS || cond == NEVER) {
						if (slot != null && !slotFirst) {
							at(block.delaySlot);
							instruction(slot);
						} else {}
						charge(block.cycles);
						if (cond == ALWAYS) asm.jump(blockLabel(d.target));
						else if (!follows) asm.jump(blockLabel(next));
						else {}
						continue;
					} else {}
					final takenWhenTrue = cond == WHEN_T;
					final hasSlot = slot != null && !slot.isNop;
					if (hasSlot && slotFirst) {
						charge(block.cycles);
						asm.branch(takenWhenTrue, blockLabel(d.target));
					} else if (hasSlot && !modifiesT(slot)) {
						// The slot's code leaves T as the test set it.
						at(block.delaySlot);
						instruction(slot);
						charge(block.cycles);
						asm.branch(takenWhenTrue, blockLabel(d.target));
					} else if (hasSlot) {
						asm.op('movt\tr2');
						r2Locked = true;
						at(block.delaySlot);
						instruction(slot);
						r2Locked = false;
						charge(block.cycles);
						asm.op('tst\tr2,r2');   // T = !condition
						asm.branch(!takenWhenTrue, blockLabel(d.target));
					} else {
						charge(block.cycles);   // `add #imm` leaves T alone
						asm.branch(takenWhenTrue, blockLabel(d.target));
					}
					if (!follows) asm.jump(blockLabel(next));
					else {}
				case J:
					if (slot != null) {
						at(block.delaySlot);
						instruction(slot);
					} else {}
					charge(block.cycles);
					asm.jump(blockLabel(d.target));
				case JR if (d.rs != 31):
					// A switch through its table (the C++ form's `switch`): the target read before the
					// slot runs, kept in r2 across it; each target of this function compared, anything
					// else the way out with a tail jump for the caller to run (Runtime.tail, ADR-0026).
					at(t);
					final tv = read(d.rs, "r3");
					asm.op('mov\t$tv,r2');
					r2Locked = true;
					if (slot != null) {
						at(block.delaySlot);
						instruction(slot);
					} else {}
					r2Locked = false;
					charge(block.cycles);
					final table = discovery.tables.get(d.addr);
					final done:Map<Int, Bool> = [];
					for (target in table.targets) {
						if (done.exists(target) || index.get(target) == null) continue;
						done.set(target, true);
						constant("r0", target);
						asm.op('cmp/eq\tr0,r2');
						asm.branch(true, blockLabel(target));
					}
					for (e in webs.exitStores.get(k)) storeField(webs.color[e.web], gregOffset(e.reg));
					asm.op('mov\t#124,r0');
					asm.op('mov.l\tr2,@(r0,$CTX)');   // pc
					asm.op('add\t#12,r0');
					asm.op('mov.l\tr2,@(r0,$CTX)');   // tailTarget, 136
					asm.load("r1", Std.string(0x5441494C));
					asm.op('mov.l\tr1,@(40,$CTX)');   // unwindToken = TAIL
					asm.jump(exitLabel());
				case JR:
					if (slot != null) {
						at(block.delaySlot);
						instruction(slot);
					} else {}
					charge(block.cycles);
					// This way out's stores: each written register's web here that has an SH-4 register.
					for (e in webs.exitStores.get(k)) storeField(webs.color[e.web], gregOffset(e.reg));
					if (fn.checkedReturns.exists(d.addr)) {
						// A return elsewhere (ADR-0027): $ra here, after the slot, against the entry's.
						at(t);
						final ra = read(31, "r3");
						asm.op('mov.l\t@r15,r0');
						asm.op('cmp/eq\tr0,$ra');
						final same = label("sameRa");
						asm.branch(true, same);
						asm.op('mov\t#127,r0');
						asm.op('add\t#13,r0');
						asm.op('mov.l\t$ra,@(r0,$CTX)');   // returnTarget, 140
						asm.load("r1", Std.string(0x52455455));
						asm.op('mov.l\tr1,@(40,$CTX)');    // unwindToken = RETURN
						asm.label(same, true);
					} else {}
					if (k + 1 < ir.blocks.length) asm.jump(exitLabel());
					else {}
				case _:
					throw 'Sh4Emitter: transfer ${d.op.mnemonic} at ${StringTools.hex(d.addr)}';
			}
		}
		// The ways out's tail: the clock, the entry $ra's slot, the saved registers.
		asm.label(exitLabel());
		if (checksRa) asm.op('add\t#4,r15');
		else {}
		if (saved.length == 0) asm.ret('mov.l\t$CYC,@(8,$CTX)');
		else {
			asm.op('mov.l\t$CYC,@(8,$CTX)');
			popSaved();
		}
		// Out of line: the due pumps and the runtime's paths.
		for (s in stubs) s();
		// After a due pump that unwound: CpuState is the machine's, and nothing of this function's
		// goes over it — the saved registers back, and out.
		if (hasPump()) {
			asm.label(unwindLabel());
			if (checksRa) asm.op('add\t#4,r15');
			else {}
			if (saved.length == 0) asm.ret('nop');
			else popSaved();
		} else {}
	}

	function popSaved():Void {
		var i = saved.length - 1;
		while (i > 0) {
			asm.op('mov.l\t@r15+,${saved[i]}');
			i--;
		}
		asm.ret('mov.l\t@r15+,${saved[0]}');
	}

	function hasPump():Bool {
		for (b in ir.blocks) if (b.pump) return true;
		return false;
	}

	/** The instruction being written: its uses and definitions are its site's. */
	function at(x:InstructionIR):Void {
		final site = webs.siteOf.get(x);
		useSite = site;
		defSite = site;
	}

	/**
		A loop header's pump, as `Emitter.emitPump` writes it: `(cyc - deadline) >= 0`, the deadline
		CpuState's `nextEvent` read where it is now. Due (out of line): the written homes and the
		clock to CpuState, `Runtime.pump`, and on an unwind out with nothing stored over it (the C++
		form's `unwindLine(-1)`); else every home and the clock read again.
	**/
	function pump(k:Int):Void {
		final stub = label("pump");
		final back = label("pumped");
		asm.op('mov\t#64,r0');
		asm.op('mov.l\t@(r0,$CTX),r0');   // nextEvent: past mov.l @(disp,Rn)'s 60 bytes
		asm.op('mov\t$CYC,r1');
		asm.op('sub\tr0,r1');
		asm.op('cmp/pz\tr1');
		asm.branch(true, stub);
		asm.label(back);
		stubs.push(() -> {
			asm.label(stub);
			for (e in webs.pumpStores.get(k)) storeField(webs.color[e.web], gregOffset(e.reg));
			asm.op('mov.l\t$CYC,@(8,$CTX)');
			asm.op('sts.l\tpr,@-r15');
			asm.op('mov.l\t$CTX,@-r15');
			asm.load("r0", "_rx_pump");
			asm.op('jsr\t@r0');
			asm.op('nop');
			asm.op('mov.l\t@r15,$CTX');
			asm.op('mov.l\t@(40,$CTX),r0');
			asm.op('tst\tr0,r0');
			final ok = label("pumpok");
			asm.branch(true, ok);
			asm.load("r0", "_rx_unwinding");
			asm.op('jsr\t@r0');
			asm.op('mov\t#-1,r5');
			asm.op('mov.l\t@r15,$CTX');
			asm.op('tst\tr0,r0');
			asm.op('add\t#4,r15');   // the CpuState popped; leaves T alone
			asm.op('lds.l\t@r15+,pr');
			asm.branch(false, unwindLabel());
			final reload = label("reload");
			asm.jump(reload);
			asm.label(ok);
			asm.op('add\t#4,r15');
			asm.op('lds.l\t@r15+,pr');
			asm.label(reload);
			for (e in webs.pumpLoads.get(k)) loadField(webs.color[e.web], gregOffset(e.reg));
			asm.op('mov.l\t@(8,$CTX),$CYC');
			if (usesMemory) asm.load(MASK, "0x1FFFFFFF");
			else {}
			asm.jump(back);
		});
	}

	/** Whether an instruction's code may change T (a compare, a shift by one, a shared routine):
	    a branch's test cannot wait in T across it. */
	static function modifiesT(i:Instr):Bool {
		return switch (i.op) {
			case SLT | SLTU | SLTI | SLTIU: true;
			case SLL | SRL: (i.shamt & 1) != 0 && shiftSteps(i.shamt) <= 2;   // shll/shlr, by one
			case SRA: i.shamt == 1;
			case DIV | DIVU | LWL | LWR | SWL | SWR: true;
			case _: false;
		};
	}

	/** How many of shll16/8/2/shll a logical shift by `n` takes. */
	static function shiftSteps(n:Int):Int {
		var rest = n;
		var k = 0;
		for (s in [16, 8, 2, 1]) while (rest >= s) {
			rest -= s;
			k++;
		}
		return k;
	}

	/** `cyc = (cyc + n) | 0`. */
	function charge(n:Int):Void {
		if (n == 0) return;
		clockStored = false;
		if (n >= -128 && n <= 127) asm.op('add\t#$n,$CYC');
		else {
			asm.load("r0", Std.string(n));
			asm.op('add\tr0,$CYC');
		}
	}

	static inline var ALWAYS = 0;
	static inline var NEVER = 1;
	static inline var WHEN_T = 2;
	static inline var WHEN_NOT_T = 3;

	/** A branch's test: always or never taken, or T set for it and taken when T is or is not. */
	function condition(d:Instr):Int {
		return switch (d.op) {
			case BEQ | BNE:
				final eq = d.op == Op.BEQ;
				if (d.rs == d.rt) eq ? ALWAYS : NEVER;
				else if (d.rs == 0 || d.rt == 0) {
					final x = read(d.rs == 0 ? d.rt : d.rs, "r1");
					asm.op('tst\t$x,$x');
					eq ? WHEN_T : WHEN_NOT_T;
				} else {
					final a = read(d.rs, "r1");
					final b = read(d.rt, "r3");
					asm.op('cmp/eq\t$a,$b');
					eq ? WHEN_T : WHEN_NOT_T;
				}
			case BLEZ | BGTZ:
				if (d.rs == 0) d.op == Op.BLEZ ? ALWAYS : NEVER;
				else {
					asm.op('cmp/pl\t${read(d.rs, "r1")}');
					d.op == Op.BGTZ ? WHEN_T : WHEN_NOT_T;
				}
			case BLTZ | BGEZ:
				if (d.rs == 0) d.op == Op.BGEZ ? ALWAYS : NEVER;
				else {
					asm.op('cmp/pz\t${read(d.rs, "r1")}');
					d.op == Op.BGEZ ? WHEN_T : WHEN_NOT_T;
				}
			case _: throw 'condition of ${d.op.mnemonic}';
		};
	}

	// ---- registers -----------------------------------------------------------------------------

	function loadField(dest:String, offset:Int):Void {
		if (offset <= 60) asm.op('mov.l\t@($offset,$CTX),$dest');
		else {
			offsetToR0(offset);
			asm.op('mov.l\t@(r0,$CTX),$dest');
		}
	}

	/** r0 = a CpuState offset past `mov.l @(disp,Rn)`'s 60 bytes: `mov #imm` sign-extends 8 bits,
	    so 128 and above go through `extu.b`. */
	function offsetToR0(offset:Int):Void {
		if (offset <= 127) asm.op('mov\t#$offset,r0');
		else {
			asm.op('mov\t#${offset - 256},r0');
			asm.op('extu.b\tr0,r0');
		}
	}

	/** Callers passing r0 for a field past 60 bytes must not hold anything live in r3. Returns
	    the temporary that holds the value afterwards, if one does (r3 when it came through r0). */
	function storeField(src:String, offset:Int):String {
		if (offset <= 60) {
			asm.op('mov.l\t$src,@($offset,$CTX)');
			return src;
		} else {
			var from = src;
			if (from == "r0") {
				asm.op('mov\tr0,r3');
				from = "r3";
			} else {}
			offsetToR0(offset);
			asm.op('mov.l\t$from,@(r0,$CTX)');
			return from;
		}
	}

	/** A register holding guest register `r`: its home, else `tmp` (r1 or r3) — already holding it,
	    or given it from the other temporary or from CpuState — or zero. */
	function read(r:Int, tmp:String, any = false):String {
		if (r == 0) {
			asm.op('mov\t#0,$tmp');
			return tmp;
		} else {}
		final h = webs.color[webs.web(useSite, r, false)];
		if (h != null) return h;
		if (holds.get(tmp) == r) return tmp;
		final other = tmp == "r1" ? "r3" : "r1";
		// `any`: the caller reads the register once and writes neither temporary before it does.
		if (any && holds.get(other) == r) return other;
		if (holds.get(other) == r) asm.op('mov\t$other,$tmp');
		else loadField(tmp, gregOffset(r));
		holds.set(tmp, r);
		return tmp;
	}

	/** Where to compute a value for guest register `r` without disturbing the registers in `avoid`:
	    its home when that is not among them, else `fallback`. */
	function target(r:Int, avoid:Array<String>, fallback = "r3"):String {
		final h = r == 0 ? null : webs.color[webs.web(defSite, r, true)];
		return h != null && avoid.indexOf(h) < 0 ? h : fallback;
	}

	/** The SH-4 register of the web guest register `r` gets here, or null (CpuState). */
	function defHome(r:Int):Null<String> return r == 0 ? null : webs.color[webs.web(defSite, r, true)];

	/** What the temporaries hold of `r` — its value, its bus address — is no longer so. */
	function forget(r:Int):Void {
		consts.remove(r);
		for (t in ["r1", "r2", "r3"]) {
			final v = holds.get(t);
			if (v == r || v == BUS + r) holds.remove(t);
			else {}
		}
	}

	/** Guest register `r` was given a value in its web's SH-4 register: what the temporaries held of it
	    is gone, and a web reaching a way out or a pump from outside every loop goes to CpuState too. */
	function defined(r:Int):Void {
		forget(r);
		final h = defHome(r);
		if (h != null && webs.writeThrough[webs.web(defSite, r, true)]) storeField(h, gregOffset(r));
		else {}
	}

	/** Guest register `r` given the value in `src` (a no-op for $zero). */
	function write(r:Int, src:String):Void {
		if (r == 0) return;
		final h = defHome(r);
		if (h != null) {
			if (h != src) asm.op('mov\t$src,$h');
			else {}
			defined(r);
		} else {
			final now = storeField(src, gregOffset(r));
			forget(r);
			if (now == "r1" || now == "r3") holds.set(now, r);
			else {}
		}
	}

	/** `rd = rs`. */
	function move(rd:Int, rs:Int):Void {
		if (rd == 0 || rd == rs) return;
		final t = target(rd, []);
		if (rs == 0) {
			asm.op('mov\t#0,$t');
			write(rd, t);
		} else write(rd, read(rs, "r1"));
	}

	// ---- instructions --------------------------------------------------------------------------

	function instruction(i:Instr):Void {
		if (i.isNop) return;
		asm.checkpoint();
		switch (i.op) {
			case ADD | ADDU: binary(i, "add", true);
			case SUB | SUBU: binary(i, "sub", false);
			case AND: binary(i, "and", true);
			case OR: binary(i, "or", true);
			case XOR: binary(i, "xor", true);
			case NOR:
				if (i.rd == 0) return;
				final t = target(i.rd, []);
				if (i.rs == 0 || i.rt == 0) {
					final a = read(i.rs == 0 ? i.rt : i.rs, "r1");
					asm.op('not\t$a,$t');
				} else {
					final a = read(i.rs, "r1");
					final b = read(i.rt, "r3");
					asm.op('mov\t$a,r0');
					asm.op('or\t$b,r0');
					asm.op('not\tr0,$t');
				}
				write(i.rd, t);
			case SLT | SLTU:
				if (i.rd == 0) return;
				final a = read(i.rs, "r1");
				final b = read(i.rt, "r3");
				// T = b > a, the operands the other way round.
				asm.op((i.op == Op.SLT ? 'cmp/gt\t' : 'cmp/hi\t') + '$a,$b');
				final t = target(i.rd, []);
				asm.op('movt\t$t');
				write(i.rd, t);
			case ADDI | ADDIU:
				if (i.rt == 0) return;
				if (i.rs == 0) {
					// `li`: the constant itself.
					final t = target(i.rt, []);
					constant(t, i.immS);
					write(i.rt, t);
					consts.set(i.rt, i.immS);
					return;
				} else {}
				final a = read(i.rs, "r1");
				final t = target(i.rt, []);
				if (i.immS >= -128 && i.immS <= 127) {
					if (t != a) asm.op('mov\t$a,$t');
					else {}
					if (i.immS != 0) asm.op('add\t#${i.immS},$t');
					else {}
				} else {
					asm.load("r0", Std.string(i.immS));
					if (t != a) asm.op('mov\t$a,$t');
					else {}
					asm.op('add\tr0,$t');
				}
				write(i.rt, t);
			case SLTI | SLTIU:
				if (i.rt == 0) return;
				final a = read(i.rs, "r1");
				constant("r3", i.immS);
				asm.op((i.op == Op.SLTI ? 'cmp/gt\t' : 'cmp/hi\t') + '$a,r3');
				final t = target(i.rt, []);
				asm.op('movt\t$t');
				write(i.rt, t);
			case ANDI | ORI | XORI:
				if (i.rt == 0) return;
				final opname = i.op == Op.ANDI ? "and" : (i.op == Op.ORI ? "or" : "xor");
				if (i.immU == 0) {
					if (i.op == Op.ANDI) move(i.rt, 0);
					else move(i.rt, i.rs);
					return;
				} else {}
				if (i.rs == 0) {
					// From $zero: 0 for andi, the immediate for ori and xori.
					final t = target(i.rt, []);
					constant(t, i.op == Op.ANDI ? 0 : i.immU);
					write(i.rt, t);
					consts.set(i.rt, i.op == Op.ANDI ? 0 : i.immU);
					return;
				} else {}
				final a = read(i.rs, "r1");
				final h = defHome(i.rt);
				if (h != null && i.immU <= 127) {
					asm.op('mov\t#${i.immU},r3');
					if (h != a) asm.op('mov\t$a,$h');
					else {}
					asm.op('$opname\tr3,$h');
					defined(i.rt);
				} else if (i.immU <= 255) {
					// Through r0, the logic forms' only register for an immediate.
					asm.op('mov\t$a,r0');
					asm.op('$opname\t#${i.immU},r0');
					write(i.rt, "r0");
				} else {
					constant("r3", i.immU);
					final t = h != null ? h : "r1";
					if (t != a) asm.op('mov\t$a,$t');
					else {}
					asm.op('$opname\tr3,$t');
					write(i.rt, t);
				}
			case LUI:
				if (i.rt == 0) return;
				final t = target(i.rt, []);
				constant(t, i.immU << 16);
				write(i.rt, t);
				consts.set(i.rt, i.immU << 16);
			case SLL | SRL | SRA:
				if (i.rd == 0) return;
				final a = read(i.rt, "r1", true);
				final t = target(i.rd, []);
				if (t != a) asm.op('mov\t$a,$t');
				else {}
				shiftImmediate(i.op, i.shamt, t);
				write(i.rd, t);
			case SLLV | SRLV | SRAV:
				if (i.rd == 0) return;
				// Both operands first: a field past 60 bytes is read through r0.
				final a = read(i.rt, "r3");
				final s = read(i.rs, "r1");
				final t = target(i.rd, []);
				if (i.op == Op.SLLV) {
					// shld by s & 31 to the left: shld uses the count's low five bits as they are.
					asm.op('mov\t$s,r0');
					asm.op('and\t#31,r0');
					if (t != a) asm.op('mov\t$a,$t');
					else {}
					asm.op('shld\tr0,$t');
				} else {
					// A right shift by s & 31: shld/shad by -(s & 31), whose low five bits are
					// 32 - (s & 31) — or 0 for a count of 0, a shift by nothing either way.
					asm.op('mov\t$s,r0');
					asm.op('and\t#31,r0');
					asm.op('neg\tr0,r0');
					if (t != a) asm.op('mov\t$a,$t');
					else {}
					asm.op((i.op == Op.SRAV ? 'shad\tr0,' : 'shld\tr0,') + t);
				}
				write(i.rd, t);
			case MULT | MULTU:
				final a = read(i.rs, "r1");
				final b = read(i.rt, "r3");
				asm.op((i.op == Op.MULT ? 'dmuls.l\t' : 'dmulu.l\t') + '$a,$b');
				asm.op('sts\tmacl,r1');
				storeField("r1", offsetOf("lo"));
				asm.op('sts\tmach,r1');
				storeField("r1", offsetOf("hi"));
				holds.remove("r1");
			case DIV | DIVU:
				// The runtime's: division by zero and the one overflow have the machine's answers.
				final b = read(i.rt, "r3");
				if (b != "r3") asm.op('mov\t$b,r3');
				else {}
				final a = read(i.rs, "r1");
				if (a != "r1") asm.op('mov\t$a,r1');
				else {}
				callShared(i.op == Op.DIV ? "_rx_sl_div" : "_rx_sl_divu", null);
			case MFHI | MFLO:
				if (i.rd == 0) return;
				final t = target(i.rd, []);
				final dest = t == "r0" ? "r3" : t;
				loadField(dest, offsetOf(i.op == Op.MFHI ? "hi" : "lo"));
				write(i.rd, dest);
			case MTHI | MTLO:
				final a = read(i.rs, "r1");
				storeField(a, offsetOf(i.op == Op.MTHI ? "hi" : "lo"));
			case LB | LBU | LH | LHU | LW: load(i);
			case SB | SH | SW: store(i);
			case LWL | LWR: unaligned(i);
			case SWL | SWR:
				final v = read(i.rt, "r3");
				if (v != "r3") asm.op('mov\t$v,r3');
				else {}
				address(i);
				callShared(i.op == Op.SWL ? "_rx_sl_swl" : "_rx_sl_swr", null);
			case _:
				throw 'Sh4Emitter: ${i.op.mnemonic} at ${StringTools.hex(i.addr)}';
		}
	}

	/** `rd = rs op rt`, for the two-operand SH-4 forms. */
	function binary(i:Instr, opname:String, commutes:Bool):Void {
		if (i.rd == 0) return;
		// $zero as an operand: a move, a negation or a zero.
		if (i.rt == 0 && opname != "and") {
			move(i.rd, i.rs);
			return;
		} else {}
		if (i.rs == 0 && (opname == "add" || opname == "or" || opname == "xor")) {
			move(i.rd, i.rt);
			return;
		} else {}
		if ((i.rs == 0 || i.rt == 0) && opname == "and") {
			move(i.rd, 0);
			return;
		} else {}
		if (i.rs == 0 && opname == "sub") {
			final b = read(i.rt, "r3");
			final t = target(i.rd, []);
			asm.op('neg\t$b,$t');
			write(i.rd, t);
			return;
		} else {}
		final a = read(i.rs, "r1");
		final b = read(i.rt, "r3");
		final h = defHome(i.rd);
		if (h != null && h != b) {
			if (h != a) asm.op('mov\t$a,$h');
			else {}
			asm.op('$opname\t$b,$h');
			defined(i.rd);
		} else if (h != null) {
			// rd is rt's home: a commuting operation in place, else through r0.
			if (commutes) asm.op('$opname\t$a,$h');
			else {
				asm.op('mov\t$h,r0');
				asm.op('mov\t$a,$h');
				asm.op('$opname\tr0,$h');
			}
			defined(i.rd);
		} else {
			// Into r1, which `a` is or is free to become; `b` is r3 or a home, never r1.
			if (a != "r1") asm.op('mov\t$a,r1');
			else {}
			asm.op('$opname\t$b,r1');
			write(i.rd, "r1");
		}
	}

	/** A constant into `dest`: `mov #imm` when it fits, else from the pool. */
	function constant(dest:String, v:Int):Void {
		if (v >= -128 && v <= 127) asm.op('mov\t#$v,$dest');
		else asm.load(dest, Std.string(v));
	}

	function shiftImmediate(op:Op, n:Int, reg:String):Void {
		if (n == 0) return;
		switch (op) {
			case SLL | SRL:
				final left = op == Op.SLL;
				var rest = n;
				final steps = [];
				for (k in [16, 8, 2, 1]) while (rest >= k) {
					steps.push(k);
					rest -= k;
				}
				if (steps.length <= 2) {
					for (k in steps) asm.op((left ? 'shll' : 'shlr') + (k == 1 ? '' : Std.string(k)) + '\t$reg');
				} else {
					asm.op('mov\t#${left ? n : -n},r0');
					asm.op('shld\tr0,$reg');
				}
			case SRA:
				if (n == 1) asm.op('shar\t$reg');
				else if (n == 16) {
					asm.op('swap.w\t$reg,$reg');
					asm.op('exts.w\t$reg,$reg');
				} else if (n == 24) {
					asm.op('swap.w\t$reg,$reg');
					asm.op('shlr8\t$reg');
					asm.op('exts.b\t$reg,$reg');
				} else {
					asm.op('mov\t#${-n},r0');
					asm.op('shad\tr0,$reg');
				}
			case _:
		}
	}

	// ---- memory ------------------------------------------------------------------------------------

	/** The clock to CpuState before an access that may trap, once while it is unchanged — any
	    access: hand-written code uses even $sp for data (Crash Bandicoot: Warped's vertex decoders
	    load it from a stream), so no base is known to stay in RAM. */
	function clockOut(base:Int):Void {
		if (clockStored) return;
		asm.op('mov.l\t$CYC,@(8,$CTX)');
		clockStored = true;
	}

	/** r1 = (rs + imm) & 0x1FFFFFFF, the bus address. */
	function address(i:Instr):Void {
		final b = read(i.rs, "r1");
		if (b != "r1") asm.op('mov\t$b,r1');
		else {}
		if (i.immS == 0) {}
		else if (i.immS >= -128 && i.immS <= 127) asm.op('add\t#${i.immS},r1');
		else {
			asm.load("r0", Std.string(i.immS));
			asm.op('add\tr0,r1');
		}
		asm.op('and\t$MASK,r1');
		holds.remove("r1");
	}

	/** r1 = rs + imm, the address a shared routine masks itself. */
	function portAddress(i:Instr):Void {
		final b = read(i.rs, "r1");
		if (b != "r1") asm.op('mov\t$b,r1');
		else {}
		if (i.immS == 0) {}
		else if (i.immS >= -128 && i.immS <= 127) asm.op('add\t#${i.immS},r1');
		else {
			asm.load("r0", Std.string(i.immS));
			asm.op('add\tr0,r1');
		}
		holds.remove("r1");
	}

	/** The bus address of guest register `r` in r2, `r & 0x1FFFFFFF`, kept while `r` is unchanged:
	    an access at an offset that is not negative goes from there, as the C++ form's do
	    (recompsx_p0_ld32b: an offset carrying it past 0x1FFFFFFF lands on no page, and the trap
	    takes the address as TEA & 0x1FFFFFFF — the bus address again). */
	function busBase(r:Int):String {
		if (holds.get("r2") == BUS + r) return "r2";
		final c = consts.get(r);
		if (c != null) {
			constant("r2", c & 0x1FFFFFFF);
			holds.set("r2", BUS + r);
			return "r2";
		} else {}
		final b = read(r, "r1");
		asm.op('mov\t$b,r2');
		asm.op('and\t$MASK,r2');
		holds.set("r2", BUS + r);
		return "r2";
	}

	/** An offset into r0 for `@(r0,Rn)`: `mov #imm` to 127, `mov #imm` and `extu.b` to 255, else
	    the pool. */
	function indexR0(off:Int):Void {
		if (off <= 127) asm.op('mov\t#$off,r0');
		else if (off <= 255) {
			asm.op('mov\t#${off - 256},r0');
			asm.op('extu.b\tr0,r0');
		} else asm.load("r0", Std.string(off));
	}

	function load(i:Instr):Void {
		final width = switch (i.op) { case LB | LBU: "b"; case LH | LHU: "w"; case _: "l"; };
		final size = width == "b" ? 1 : (width == "w" ? 2 : 4);
		final dest = i.rt == 0 ? "r3" : target(i.rt, []);
		if (ports.exists(i.addr)) {
			// A port: the shared routine (Memory.portRead*), the address in r1 and the clock in r5;
			// its value comes back sign-extended in r0.
			portAddress(i);
			callShared('_rx_sl_rd' + (size * 8), null);
			asm.op('mov\tr0,$dest');
		} else if (i.immS >= 0 && i.rs != 0 && !r2Locked) {
			final base = busBase(i.rs);
			clockOut(i.rs);
			if (width == "l" && i.immS <= 60 && (i.immS & 3) == 0) asm.access('mov.l\t@(${i.immS},$base),$dest');
			else {
				indexR0(i.immS);
				asm.access('mov.$width\t@(r0,$base),$dest');
			}
		} else {
			address(i);
			clockOut(i.rs);
			asm.access('mov.$width\t@r1,$dest');
		}
		if (i.op == Op.LBU) asm.op('extu.b\t$dest,$dest');
		else if (i.op == Op.LHU) asm.op('extu.w\t$dest,$dest');
		else {}
		if (i.rt != 0) write(i.rt, dest);
		else holds.remove("r3");
		final _ = size;
	}

	function store(i:Instr):Void {
		final width = switch (i.op) { case SB: "b"; case SH: "w"; case _: "l"; };
		// The value first: a field past 60 bytes is read through r0.
		final v = read(i.rt, "r3");
		if (ports.exists(i.addr)) {
			// A port: the shared routine (Memory.portWrite*), the value in r3.
			if (v != "r3") asm.op('mov\t$v,r3');
			else {}
			portAddress(i);
			callShared('_rx_sl_wr' + (width == "b" ? "8" : (width == "w" ? "16" : "32")), null);
			holds.remove("r3");
		} else if (i.immS >= 0 && i.rs != 0 && !r2Locked) {
			final base = busBase(i.rs);
			clockOut(i.rs);
			if (width == "l" && i.immS <= 60 && (i.immS & 3) == 0) asm.access('mov.l\t$v,@(${i.immS},$base)');
			else {
				indexR0(i.immS);
				asm.access('mov.$width\t$v,@(r0,$base)');
			}
		} else {
			address(i);
			clockOut(i.rs);
			asm.access('mov.$width\t$v,@r1');
		}
	}

	/**
		lwl or lwr on its own (`Memory.lwl`/`lwr`): the aligned word read through P0 — RAM through
		the MMU, anything else the trap's word read — and joined with rt's lanes in registers.
	**/
	function unaligned(i:Instr):Void {
		final cur = read(i.rt, "r3");
		if (cur != "r3") asm.op('mov\t$cur,r3');
		else {}
		final b = read(i.rs, "r1");
		if (b != "r1") asm.op('mov\t$b,r1');
		else {}
		if (i.immS == 0) {}
		else if (i.immS >= -128 && i.immS <= 127) asm.op('add\t#${i.immS},r1');
		else {
			asm.load("r0", Std.string(i.immS));
			asm.op('add\tr0,r1');
		}
		// k = a & 3; the aligned word's bus address is (a ^ k) & 0x1FFFFFFF.
		asm.op('mov\tr1,r0');
		asm.op('and\t#3,r0');
		asm.op('xor\tr0,r1');
		asm.op('and\t$MASK,r1');
		clockOut(i.rs);
		asm.access('mov.l\t@r1,r1');   // w
		if (i.op == Op.LWR) {
			// (cur & ~(-1 >>> 8k)) | (w >>> 8k)
			asm.op('shll2\tr0');
			asm.op('shll\tr0');         // 8k
			asm.op('neg\tr0,r0');       // -8k: a right shift
			asm.op('shld\tr0,r1');      // w >>> 8k
			asm.op('mov\t#-1,r2');
			asm.op('shld\tr0,r2');      // -1 >>> 8k
			asm.op('not\tr2,r2');
			asm.op('and\tr2,r3');       // cur's lanes kept
			asm.op('or\tr1,r3');
		} else {
			// (cur & ((1 << 8(3-k)) - 1)) | (w << 8(3-k)); k = 3 keeps none of cur
			asm.op('neg\tr0,r0');
			asm.op('add\t#3,r0');       // 3 - k
			asm.op('shll2\tr0');
			asm.op('shll\tr0');         // s = 8(3-k)
			asm.op('shld\tr0,r1');      // w << s
			asm.op('mov\t#1,r2');
			asm.op('shld\tr0,r2');
			asm.op('add\t#-1,r2');      // (1 << s) - 1
			asm.op('and\tr2,r3');
			asm.op('or\tr1,r3');
		}
		holds.remove("r1");
		holds.remove("r2");
		holds.remove("r3");
		write(i.rt, "r3");
	}

	/**
		A fused `lwr`/`lwl` pair (`first` in program order, `r` the lwr), `Memory.lwu`: in RAM, with the
		word at the lwr's address + 3 in RAM too, `(lo >>> sh) | (hi << (32 - sh))` — lo and hi the
		aligned words, sh the misalignment in bits — or lo when aligned, which is what the two give
		whatever rt held; RAM through P0, which never traps. Anywhere else, or across RAM's end, the
		two through the runtime in their order (`Memory.lwuSlow`).
	**/
	function fusedWord(first:Instr, second:Instr, r:Instr):Void {
		final cur = read(r.rt, "r3");
		if (cur != "r3") asm.op('mov\t$cur,r3');
		else {}
		final b = read(r.rs, "r1");
		if (b != "r1") asm.op('mov\t$b,r1');
		else {}
		if (r.immS == 0) {}
		else if (r.immS >= -128 && r.immS <= 127) asm.op('add\t#${r.immS},r1');
		else {
			asm.load("r0", Std.string(r.immS));
			asm.op('add\tr0,r1');
		}
		final slow = label("fslow");
		final back = label("fback");
		final aligned = label("faligned");
		// RAM, both ends: (a & 0x1F9FFFFF) + 3 below 2 MB (the C++ form's rR + 3 == rL && rL < 2 MB).
		asm.load("r2", "0x1F9FFFFF");
		asm.op('and\tr1,r2');
		asm.op('add\t#3,r2');
		asm.load("r0", "0x200000");
		asm.op('cmp/hs\tr0,r2');
		asm.branch(true, slow);
		asm.op('mov\tr1,r0');
		asm.op('and\t#3,r0');           // k
		asm.op('xor\tr0,r1');
		asm.op('and\t$MASK,r1');        // the first aligned word's bus address
		asm.access('mov.l\t@r1,r3');    // lo
		asm.op('tst\tr0,r0');
		asm.branch(true, aligned);
		asm.access('mov.l\t@(4,r1),r1');   // hi
		asm.op('shll2\tr0');
		asm.op('shll\tr0');             // sh = 8k
		asm.op('neg\tr0,r2');
		asm.op('shld\tr2,r3');          // lo >>> sh
		asm.op('mov\t#32,r2');
		asm.op('sub\tr0,r2');
		asm.op('shld\tr2,r1');          // hi << (32 - sh)
		asm.op('or\tr1,r3');
		asm.label(aligned, true);
		asm.label(back, true);
		holds.remove("r1");
		holds.remove("r2");
		holds.remove("r3");
		write(r.rt, "r3");
		final firstIsR = first.op == Op.LWR;
		final _ = second;
		stubs.push(() -> {
			// r1 = aR, r3 = rt's value before the pair; each routine writes the clock first.
			asm.label(slow);
			if (firstIsR) {
				callShared("_rx_sl_lwr", null);
				asm.op('mov\tr0,r3');
				asm.op('add\t#3,r1');
				callShared("_rx_sl_lwl", null);
			} else {
				asm.op('add\t#3,r1');
				callShared("_rx_sl_lwl", null);
				asm.op('mov\tr0,r3');
				asm.op('add\t#-3,r1');
				callShared("_rx_sl_lwr", null);
			}
			asm.jumpWith(back, 'mov\tr0,r3');
		});
	}

	/**
		A call to one of the shared routines (`sharedRoutines`), which keep every register but r0
		and T: the address or first operand in r1, the value or second in r3, the clock in r5.
		`toR3`, when given, is moved to r3 in the call's delay slot.
	**/
	function callShared(routine:String, toR3:Null<String>):Void {
		asm.op('sts.l\tpr,@-r15');
		asm.load("r0", routine);
		asm.op('jsr\t@r0');
		asm.op(toR3 == null ? 'nop' : 'mov\t$toR3,r3');
		asm.op('lds.l\t@r15+,pr');
	}

	// ---- the shared routines -------------------------------------------------------------------

	/**
		The routines every assembled function shares for what is not RAM, written once (Program puts
		them beside the glue): each keeps every register but r0 and T — the caller's guest
		registers, its pinned values, a branch's condition in r2 — so a site costs a call and no
		saves. In: r1 the address (or a division's dividend), r3 the value to store (or the divisor,
		or lwl/lwr's current value), r4 the CpuState, r5 the clock. Out: r0 a load's value.

		A load or store tests the scratchpad as the C++ form's accessor does (`(a & 0x1FFFFC00) ==
		0x1F800000`, here as the distance from its start) and otherwise calls the accessor itself
		(the glue, `rx_rd32`...), which tests RAM and the scratchpad again — never true there — and
		writes the clock before the port is reached.
	**/
	public static function sharedRoutines():String {
		final b = new StringBuf();
		b.add('\t.pushsection .text.rx_shared,"ax",@progbits\n');
		b.add('\t.align 5\n');
		final save = ["r1", "r2", "r3", "r4", "r5", "r6", "r7"];
		function callC(glue:String, args:Array<String>):Void {
			b.add('\tsts.l\tpr,@-r15\n');
			for (r in save) b.add('\tmov.l\t$r,@-r15\n');
			for (a in args) b.add('\t$a\n');
			b.add('\tmov.l\t.Lrx_sl_k_$glue,r0\n');
			b.add('\tjsr\t@r0\n');
			b.add('\tnop\n');
			var k = save.length - 1;
			while (k >= 0) {
				b.add('\tmov.l\t@r15+,${save[k]}\n');
				k--;
			}
			b.add('\tlds.l\t@r15+,pr\n');
			b.add('\trts\n');
			b.add('\tnop\n');
			b.add('\t.align 2\n');
			b.add('.Lrx_sl_k_$glue:\n\t.long _$glue\n');
			b.add('.Lrx_sl_m_$glue:\n\t.long 0x1FFFFFFF\n');
		}
		function scratch(name:String, body:Array<String>):Void {
			// r0 = the distance from the scratchpad's start; r2 pushed, popped on either path.
			b.add('\tmov.l\tr2,@-r15\n');
			b.add('\tmov.l\t.Lrx_sl_s_$name,r0\n');
			b.add('\tand\tr1,r0\n');
			b.add('\tmov.l\t.Lrx_sl_b_$name,r2\n');
			b.add('\txor\tr2,r0\n');
			b.add('\tmov\t#4,r2\n');
			b.add('\tshll8\tr2\n');
			b.add('\tcmp/hs\tr2,r0\n');
			b.add('\tbt\t.Lrx_sl_slow_$name\n');
			b.add('\tmov.l\t.Lrx_sl_a_$name,r2\n');
			for (l in body) b.add('\t$l\n');
			b.add('\trts\n');
			b.add('\tmov.l\t@r15+,r2\n');
			b.add('\t.align 2\n');
			b.add('.Lrx_sl_s_$name:\n\t.long 0x1FFFFFFF\n');
			b.add('.Lrx_sl_b_$name:\n\t.long 0x1F800000\n');
			b.add('.Lrx_sl_a_$name:\n\t.long _recompsx_mem+0x2000A0\n');
			b.add('.Lrx_sl_slow_$name:\n');
			b.add('\tmov.l\t@r15+,r2\n');
		}
		for (w in [{n: "8", m: "b", glue: "rx_rd8s"}, {n: "16", m: "w", glue: "rx_rd16s"}, {n: "32", m: "l", glue: "rx_rd32"}]) {
			final name = 'rx_sl_rd${w.n}';
			b.add('\t.global _$name\n_$name:\n');
			// Fastmem's glue reaches the scratchpad through the MMU as it reaches everything.
			if (!FASTMEM) scratch(name, ['mov.${w.m}\t@(r0,r2),r0']);
			else {}
			// rx_rd*(ctx, a & 0x1FFFFFFF, cyc)
			callC(w.glue, ['mov\tr5,r6', 'mov.l\t.Lrx_sl_m_${w.glue},r5', 'and\tr1,r5']);
		}
		for (w in [{n: "8", m: "b", glue: "rx_wr8"}, {n: "16", m: "w", glue: "rx_wr16"}, {n: "32", m: "l", glue: "rx_wr32"}]) {
			final name = 'rx_sl_wr${w.n}';
			b.add('\t.global _$name\n_$name:\n');
			if (!FASTMEM) scratch(name, ['mov.${w.m}\tr3,@(r0,r2)']);
			else {}
			// rx_wr*(ctx, a & 0x1FFFFFFF, v, cyc)
			callC(w.glue, ['mov\tr5,r7', 'mov\tr3,r6', 'mov.l\t.Lrx_sl_m_${w.glue},r5', 'and\tr1,r5']);
		}
		// lwl/lwr/swl/swr: the clock written first (the C++ form's clockFirst), then the runtime's.
		for (g in ["rx_lwl", "rx_lwr", "rx_swl", "rx_swr"]) {
			final name = 'rx_sl_${g.substr(3)}';
			b.add('\t.global _$name\n_$name:\n');
			b.add('\tmov.l\tr5,@(8,r4)\n');
			callC(g, ['mov\tr3,r6', 'mov.l\t.Lrx_sl_m_$g,r5', 'and\tr1,r5']);
		}
		for (g in ["rx_div", "rx_divu"]) {
			final name = 'rx_sl_${g.substr(3)}';
			b.add('\t.global _$name\n_$name:\n');
			callC(g, ['mov\tr3,r6', 'mov\tr1,r5']);
		}
		b.add('\t.popsection\n');
		return b.toString();
	}
}

/**
	One function's SH-4 assembly as it is written: instructions (two bytes each), labels, and the
	literal pools its `mov.l`s read — each reaching forward at most 1020 bytes, so a pool goes out
	after an unconditional jump once its first use is far enough back (an island), or at the end;
	and the offsets of all of it, for the next pass's choice of short branches.
**/
class Sh4Asm {
	final lines:Array<String> = [];
	var size = 0;
	final labelAt:Map<String, Int> = [];
	/** The open pool: entries whose island is not written yet, and where the first was used. */
	var open:Array<String> = [];
	var openIndex:Map<String, Int> = [];
	var openFirstUse = -1;
	var islands = 0;
	final poolUses:Array<{at:Int, label:String}> = [];
	/** Conditional branches (their site, target, and whether written short) and `bra`s. */
	final branches:Array<{at:Int, target:String, short:Bool}> = [];
	final bras:Array<{at:Int, target:String}> = [];
	final shortOk:Map<Int, Bool>;
	var branchCount = 0;

	/** Told of every register an instruction writes, and of every label others jump to. */
	public var onWrite:String->Void = null;
	public var onLabel:Void->Void = null;

	public function new(shortOk:Map<Int, Bool>) this.shortOk = shortOk;

	public function bytes():Int return size + 2 * pending.length;

	/** Whether the last line is an instruction a `bra` may take into its delay slot: not a branch,
	    not PC-relative, not a label's target. */
	var lastMovable = false;

	static function movable(text:String):Bool {
		final tab = text.indexOf('\t');
		final m = tab < 0 ? text : text.substr(0, tab);
		// A guest access through r1 never goes into a delay slot: under fastmem it may trap, and a
		// trap there would have its pc at the branch (dc_fastmem.c's trampoline decodes the access).
		if (text.indexOf('@r1,') >= 0 || StringTools.endsWith(text, '@r1')) return false;
		else {}
		return switch (m) {
			case "bt" | "bf" | "bra" | "jsr" | "rts" | "nop" | "lds.l" | "sts.l" | "mova" | "braf" | "bsr": false;
			case _: !(m == "mov.l" && text.indexOf('.L') >= 0);
		};
	}

	/** Whether straight runs are list-scheduled (Sh4Sched) before they are written; set by the
	    emitter (`RECOMPSX_SH4_NOSCHED` turns it off, for comparing). */
	public static var SCHEDULE = Sys.getEnv("RECOMPSX_SH4_NOSCHED") == null;

	/** The straight run not written yet: what the scheduler may reorder, and which are guest accesses. */
	final pending:Array<String> = [];
	final pendingGuest:Array<Bool> = [];
	/** The instruction after a delayed transfer: written where it is, the transfer's slot. */
	var slotNext = false;

	/** A guest access: never moved into a delay slot (a trap there would have its pc at the branch,
	    and dc_fastmem.c's trampoline decodes the access at the pc), and kept in order among the others
	    by the scheduler. */
	public function access(text:String):Void {
		emit(text, true);
	}

	public function op(text:String):Void {
		emit(text, false);
	}

	function emit(text:String, guest:Bool):Void {
		checkImmediate(text);
		if (onWrite != null) {
			final d = destOf(text);
			if (d != null) onWrite(d);
			else {}
		} else {}
		final tab = text.indexOf('\t');
		final m = tab < 0 ? text : text.substr(0, tab);
		final transfer = switch (m) { case "bt" | "bf" | "bra" | "jsr" | "rts" | "braf" | "bsr" | "jmp": true; case _: false; };
		if (slotNext || transfer || !SCHEDULE) {
			commit();
			append(text, guest);
			slotNext = transfer && m != "bt" && m != "bf";
		} else {
			pending.push(text);
			pendingGuest.push(guest);
		}
	}

	/** One line written: its size, and the pool entry it reads, if any. */
	function append(text:String, guest:Bool):Void {
		final pool = text.indexOf('.Lpool_');
		if (pool >= 0) {
			if (openFirstUse < 0) openFirstUse = size;
			else {}
			poolUses.push({at: size, label: text.substr(pool, text.indexOf(',', pool) - pool)});
		} else {}
		lines.push('\t$text');
		size += 2;
		lastMovable = !guest && movable(text);
	}

	/** The straight run written, scheduled; `slot` when a `bra` follows (Sh4Sched). */
	function commit(slot = false):Void {
		if (pending.length == 0) return;
		final order = SCHEDULE ? Sh4Sched.schedule(pending, pendingGuest, slot) : [for (i in 0...pending.length) i];
		for (i in order) append(pending[i], pendingGuest[i]);
		pending.resize(0);
		pendingGuest.resize(0);
	}

	/** `keep`: reached only by running on or with the state it is left in (a memory access's
	    return point, the jump around an island), so what the registers hold still holds. */
	public function label(name:String, keep = false):Void {
		commit();
		slotNext = false;
		lines.push('$name:');
		labelAt.set(name, size);
		lastMovable = false;
		if (!keep && onLabel != null) onLabel();
		else {}
	}

	/** GAS truncates an immediate out of its field without a word: `mov #132` assembles as
	    `mov #-124`. Every one is checked here instead — signed 8 bits for `mov` and `add`,
	    unsigned 8 for the logic forms on r0 and `cmp/eq`'s. */
	static function checkImmediate(text:String):Void {
		checkDisplacement(text);
		final at = text.indexOf('#');
		if (at < 0) return;
		final tab = text.indexOf('\t');
		final mnemonic = text.substr(0, tab);
		var end = at + 1;
		while (end < text.length && text.charAt(end) != ',') end++;
		final v = Std.parseInt(text.substr(at + 1, end - at - 1));
		if (v == null) throw 'Sh4Asm: immediate in "$text"';
		final ok = switch (mnemonic) {
			case "mov" | "add": v >= -128 && v <= 127;
			case "and" | "or" | "xor" | "tst": v >= 0 && v <= 255;
			case "cmp/eq": v >= -128 && v <= 127;
			case _: false;
		};
		if (!ok) throw 'Sh4Asm: immediate out of range in "$text"';
	}

	/** `@(disp,Rn)`: GAS turns a displacement out of its field into something else without a word
	    (`mov.l @(64,r4),r0` came out as two instructions), so each is checked here: mov.l 0-60 in
	    fours, mov.w 0-30 in twos and mov.b 0-15, the last two only with r0. */
	static function checkDisplacement(text:String):Void {
		final at = text.indexOf('@(');
		if (at < 0) return;
		final comma = text.indexOf(',', at);
		final first = text.substr(at + 2, comma - at - 2);
		if (first == "r0" || first == "R0") return;
		final d = Std.parseInt(first);
		if (d == null) throw 'Sh4Asm: displacement in "$text"';
		final tab = text.indexOf('\t');
		final mnemonic = text.substr(0, tab);
		final ok = switch (mnemonic) {
			case "mov.l": d >= 0 && d <= 60 && (d & 3) == 0;
			case "mov.w": d >= 0 && d <= 30 && (d & 1) == 0 && text.indexOf('r0') >= 0;
			case "mov.b": d >= 0 && d <= 15 && text.indexOf('r0') >= 0;
			case _: false;
		};
		if (!ok) throw 'Sh4Asm: displacement out of range in "$text"';
	}

	/** The register an instruction writes, if one: the last operand, for everything but compares,
	    tests, branches, stores and the multiplies (whose results are MACH and MACL). */
	static function destOf(text:String):Null<String> {
		final tab = text.indexOf('\t');
		final mnemonic = tab < 0 ? text : text.substr(0, tab);
		if (tab < 0) return null;
		switch (mnemonic) {
			case "cmp/eq" | "cmp/hs" | "cmp/hi" | "cmp/gt" | "cmp/ge" | "cmp/pl" | "cmp/pz" | "tst" | "bt" | "bf" | "bra" | "jsr" | "rts"
				| "dmuls.l" | "dmulu.l" | "lds.l" | "sts.l" | "nop":
				return null;
			case _:
		}
		final ops = text.substr(tab + 1);
		// The last operand, outside any parentheses.
		var depth = 0;
		var last = 0;
		for (k in 0...ops.length) {
			final c = ops.charAt(k);
			if (c == "(") depth++;
			else if (c == ")") depth--;
			else if (c == "," && depth == 0) last = k + 1;
			else {}
		}
		final d = StringTools.trim(ops.substr(last));
		return ~/^r[0-9]+$/.match(d) ? d : null;
	}

	/** `mov.l` of a pool entry: a number or a symbol (an address). */
	public function load(dest:String, value:String):Void {
		var k = openIndex.get(value);
		if (k == null) {
			k = open.length;
			open.push(value);
			openIndex.set(value, k);
		} else {}
		final name = '.Lpool_${islands}_$k';
		op('mov.l\t$name,$dest');
	}

	/** After an unconditional transfer and its slot, where nothing runs on: the open pool is
	    written here when waiting for the next such place could leave its first use out of reach. */
	public function barrier():Void {
		commit();
		if (open.length > 0 && size - openFirstUse > 520) flush();
		else {}
	}

	/** Between two guest instructions: when the open pool is about to go out of reach and no
	    jump has come, it is written here with a jump around it. */
	public function checkpoint():Void {
		// The run not written yet counts at its end: its first pool use may be anywhere in it.
		final first = openFirstUse >= 0 ? openFirstUse : size;
		if (open.length > 0 && size + 2 * pending.length + 4 * open.length + 160 - first > 1000) {
			commit();
			final over = '.Lover_${islands}';
			op('bra\t$over');
			bras.push({at: size - 2, target: over});
			op('nop');
			flush();
			label(over, true);
		} else {}
	}

	function flush():Void {
		commit();
		if ((size & 3) != 0) {
			lines.push('\t.align 2');
			size += 2;
		} else {}
		for (k in 0...open.length) {
			label('.Lpool_${islands}_$k');
			lines.push('\t.long ${open[k]}');
			size += 4;
		}
		islands++;
		open = [];
		openIndex = [];
		openFirstUse = -1;
	}

	/** `bt`/`bf` to `target` when T is `whenT`: short where the last pass found it in reach,
	    else the opposite test around a `bra`. */
	public function branch(whenT:Bool, target:String):Void {
		commit();
		final id = branchCount++;
		if (shortOk.exists(id)) {
			branches.push({at: size, target: target, short: true});
			op((whenT ? 'bt\t' : 'bf\t') + target);
		} else {
			branches.push({at: size, target: target, short: false});
			final skip = '.Lskip_${id}';
			op((whenT ? 'bf\t' : 'bt\t') + skip);
			bras.push({at: size, target: target});
			op('bra\t$target');
			op('nop');
			label(skip, true);
		}
	}

	public function jump(target:String):Void {
		commit(true);
		if (lastMovable) {
			// The instruction before goes into the slot: it runs before the target either way.
			final prev = lines.pop();
			size -= 2;
			bras.push({at: size, target: target});
			lines.push('\tbra\t$target');
			size += 2;
			lines.push(prev);
			size += 2;
			lastMovable = false;
		} else {
			bras.push({at: size, target: target});
			op('bra\t$target');
			op('nop');
		}
		barrier();
	}

	/** `bra target` with `slot` in its delay slot (checked for reach like every `bra`). */
	public function jumpWith(target:String, slot:String):Void {
		commit();
		bras.push({at: size, target: target});
		op('bra\t$target');
		op(slot);
		barrier();
	}

	/** Ends the code with `rts` (its slot given): a place for an island too. */
	public function ret(slot:String):Void {
		commit();
		op('rts');
		op(slot);
		barrier();
	}

	/** The branches a short form reaches: `bt`/`bf` span -256..+254 bytes from PC + 4. */
	public function reachable():Map<Int, Bool> {
		final ok:Map<Int, Bool> = [];
		for (k in 0...branches.length) {
			final b = branches[k];
			final to = labelAt.get(b.target);
			if (to == null) continue;
			final disp = to - (b.at + 4);
			if (disp >= -256 && disp <= 254) ok.set(k, true);
			else {}
		}
		return ok;
	}

	/** Whether every branch written short reaches its target in this pass's layout. */
	public function shortsReach():Bool {
		for (b in branches) if (b.short) {
			final disp = labelAt.get(b.target) - (b.at + 4);
			if (disp < -256 || disp > 254) return false;
			else {}
		} else {}
		return true;
	}

	/** The text; null when something is out of reach — a pool entry, a `bra` (4 KB either way). */
	public function finish(symbol:String):Null<String> {
		commit();
		if (open.length > 0) flush();
		else {}
		for (u in poolUses) {
			// mov.l @(disp,PC): (PC & ~3) + 4 + disp * 4, disp 0..255.
			final at = labelAt.get(u.label);
			final base = (u.at & ~3) + 4;
			if (at - base > 1020 || at < base) return null;
			else {}
		}
		for (b in bras) {
			final disp = labelAt.get(b.target) - (b.at + 4);
			if (disp < -4096 || disp > 4094) return null;
			else {}
		}
		final out = new StringBuf();
		out.add('\t.pushsection .text.$symbol,"ax",@progbits\n');
		out.add('\t.align 5\n');
		out.add('\t.global _$symbol\n');
		out.add('\t.type _$symbol,@function\n');
		out.add('_$symbol:\n');
		for (l in lines) out.add(l + '\n');
		out.add('\t.size _$symbol, .-_$symbol\n');
		out.add('\t.popsection\n');
		// The pools', the long branches' and the islands' labels are local to this function.
		var text = out.toString();
		for (local in ['.Lpool_', '.Lskip_', '.Lover_']) text = StringTools.replace(text, local, '.L${symbol}_${local.substr(2)}');
		return text;
	}
}
