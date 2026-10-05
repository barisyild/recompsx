package recomp.codegen;

import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.ir.FunctionIR;
import recomp.mips.Instr;
import recomp.mips.Op;

/**
	ADR-0048 (proposed), its first step: a guest function as SH-4 assembly, which a Dreamcast build
	(`-D recompsx_sh4`) links in place of the function's C++ form for its ordinary entry. The C++
	form stays the definition: every other target compiles it, and on the Dreamcast it still serves
	every entry but 0 and a call that finds a pump due (Program writes the wrapper that chooses).

	The assembly does what the C++ form does, instruction by instruction — the same loads and
	stores in the same order through the same decode (RAM inline, the scratchpad out of line, every
	other address through the runtime's accessor, the clock written first), the same cycle charges
	at the same places, the same registers written — and it is held to that by the game digests on
	the Dreamcast (`scripts/dc-digest.sh`) and the TA hash. What differs is where values live: the
	CpuState pointer, the cycle count and the RAM decode's constants in SH-4 registers for the
	whole function, and the guest registers it uses most in SH-4 registers between its entry and
	its exits, where the C++ form went to CpuState at every read and write.

	This step takes functions that call nothing, trap nothing, touch no coprocessor and have no
	loop (a loop's header pumps): loopless leaves. Anything else is declined, and keeps its C++
	form everywhere.
**/
class Sh4Emitter {
	final image:Image;
	final discovery:Discovery;

	/** Why functions were declined, by reason: the generator reports it. */
	public final declined:Map<String, Int> = [];

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

	// ---- the function --------------------------------------------------------------------------

	var asm:Sh4Asm;
	var ir:FunctionIR;
	var symbol:String;
	/** Guest register -> SH-4 register, for the guest registers held in one. */
	var home:Map<Int, String>;
	/** Guest registers written somewhere in the function: stored back at every exit. */
	var written:Int;
	/** Guest registers whose value at the entry is needed — read before written on some path, or
	    stored at an exit (`written`) before being written on some path: only these homes are loaded
	    in the prologue. */
	var liveIn:Int;
	var usesMemory:Bool;
	/** Whether the function has an lwl or lwr: they keep the RAM test (and its three registers)
	    under fastmem too, for their slow path is the runtime's, by bytes, not a trap's word. */
	var usesUnaligned:Bool;
	var cycReg:String;
	var arenaReg:String;
	var maskReg:String;
	var limReg:String;
	/** Fastmem (ADR-0049): 0x1FFFFFFF, a load's or a store's bus address in P0, where the MMU
	    maps RAM and the scratchpad and anything else traps. */
	var busReg:String;
	/** Whether the clock register has been written to CpuState since it last changed: an access
	    that traps reads it there. */
	var clockStored:Bool;
	var saved:Array<String>;
	var labelCount:Int;
	var stubs:Array<Void->Void>;
	/** Which guest register's current value a temporary (r1, r3) holds, in straight-line code:
	    a register written to CpuState and read again soon after is not loaded back. Every write
	    of a temporary drops what it held (Sh4Asm.onWrite); a label others jump to, all of it. */
	var holds:Map<String, Int> = [];

	static final CTX = "r4";
	/** Temporaries: r0 (indexed addressing, `and #imm`), r1, r3; r2 holds a branch's condition
	    across its delay slot, so nothing a slot emits may use it. */
	static final POOL = ["r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "r13", "r14"];

	/** The accesses as fastmem's (ADR-0049): a Dreamcast build with `RECOMPSX_FASTMEM` links them.
	    Set by the generator (`RECOMPSX_SH4_FASTMEM` for now, an experiment). */
	public static var FASTMEM = Sys.getEnv("RECOMPSX_SH4_FASTMEM") != null;

	public function emit(fn:Func, symbol:String):Null<String> {
		final reason = eligibility(fn);
		if (reason != null) {
			declined.set(reason, (declined.exists(reason) ? declined.get(reason) : 0) + 1);
			if (Sys.getEnv("RECOMPSX_SH4_WHY") != null) Sys.println('sh4: ${fn.name} declined: $reason (all: ${allReasons(fn).join(", ")})');
			else {}
			return null;
		} else {}
		this.symbol = symbol;
		ir = new FunctionIR(fn, image);
		plan();
		liveness(fn);
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
		return text;
	}

	/** Null when this step can emit `fn`, else why not. */
	function eligibility(fn:Func):Null<String> {
		if (fn.hops.keys().hasNext()) return "hands over";
		if (fn.registerReturns.keys().hasNext()) return "returns through a copy of ra";
		if (fn.checkedReturns.keys().hasNext()) return "checked returns";
		final ir = new FunctionIR(fn, image);
		for (block in ir.blocks) {
			if (block.pump) return "loop";
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
						if (t.rs != 31) return "computed jump";
						if (discovery.raJumpOf(fn.entry, t.addr) != null) return "ra jump";
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

	/** Which guest registers get an SH-4 register, and which SH-4 registers the function saves. */
	function plan():Void {
		final uses = [for (_ in 0...32) 0];
		written = 0;
		usesMemory = false;
		usesUnaligned = false;
		arenaReg = null;
		maskReg = null;
		limReg = null;
		busReg = null;
		for (block in ir.blocks) for (x in block.instructions) {
			final d = x.decoded;
			for (r in 1...32) {
				if (x.reads.has(r)) uses[r]++;
				else {}
				if (x.writes.has(r)) {
					uses[r]++;
					written |= 1 << r;
				} else {}
			}
			if (isMemory(d.op)) usesMemory = true;
			else {}
			if (d.op == Op.LWL || d.op == Op.LWR) usesUnaligned = true;
			else {}
		}
		// $ra is read by the return and written by nothing a leaf runs; HI and LO stay in CpuState.
		final pool = POOL.copy();
		cycReg = pool.shift();   // r5: the shared routines read the clock there
		if (usesMemory && FASTMEM) busReg = pool.shift();
		else {}
		if (usesMemory && (!FASTMEM || usesUnaligned)) {
			arenaReg = pool.shift();
			maskReg = pool.shift();
			limReg = pool.shift();
		} else {}
		final order = [for (r in 1...32) if (uses[r] > 0 && r != 31) r];
		order.sort((a, b) -> uses[b] != uses[a] ? uses[b] - uses[a] : a - b);
		home = [];
		for (r in order) {
			if (pool.length == 0) break;
			home.set(r, pool.shift());
		}
		saved = [];
		for (reg in POOL) {
			final n = Std.parseInt(reg.substr(1));
			if (n >= 8 && (reg == cycReg || reg == arenaReg || reg == maskReg || reg == limReg || reg == busReg || [for (h in home) h].indexOf(reg) >= 0))
				saved.push(reg);
			else {}
		}
	}

	/** `liveIn`, by the usual backward pass over the blocks, an exit using every register written. */
	function liveness(fn:Func):Void {
		final n = ir.blocks.length;
		final index:Map<Int, Int> = [];
		for (k in 0...n) index.set(ir.blocks[k].addr, k);
		final use = [for (_ in 0...n) 0];
		final def = [for (_ in 0...n) 0];
		for (k in 0...n) {
			var u = 0;
			var d = 0;
			for (x in ir.blocks[k].instructions) {
				final r:Int = x.reads;
				final w:Int = x.writes;
				u |= r & ~d;
				d |= w;
			}
			use[k] = u & ~1;
			def[k] = d;
		}
		final live = [for (_ in 0...n) 0];
		var changed = true;
		while (changed) {
			changed = false;
			var k = n - 1;
			while (k >= 0) {
				final b = ir.blocks[k];
				var out = 0;
				if (b.transfer != null && b.transfer.decoded.op == Op.JR) out |= written;
				else {}
				for (to in b.successors) {
					final j = index.get(to);
					if (j != null) out |= live[j];
					else {}
				}
				final inn = use[k] | (out & ~def[k]);
				if (inn != live[k]) {
					live[k] = inn;
					changed = true;
				} else {}
				k--;
			}
		}
		final entry = index.get(fn.entry);
		liveIn = entry == null ? -1 : live[entry];
	}

	static inline function isMemory(op:Op):Bool
		return switch (op) {
			case LB | LH | LWL | LW | LBU | LHU | LWR | SB | SH | SWL | SW | SWR: true;
			case _: false;
		};

	// ---- generation ----------------------------------------------------------------------------

	function label(what:String):String return '.L${symbol}_${what}_${labelCount++}';

	function blockLabel(addr:Int):String return '.L${symbol}_b${StringTools.hex(addr, 8)}';

	function generate(shortOk:Map<Int, Bool>):Void {
		asm = new Sh4Asm(shortOk);
		holds = [];
		asm.onWrite = reg -> holds.remove(reg);
		asm.onLabel = () -> {
			holds = [];
			clockStored = false;
		};
		clockStored = false;
		labelCount = 0;
		stubs = [];
		final exit = '.L${symbol}_exit';
		// Prologue: the callee-saved registers this function uses, its pinned values, and every
		// guest register it holds, read once from CpuState.
		for (r in saved) asm.op('mov.l\t$r,@-r15');
		asm.op('mov.l\t@(8,$CTX),$cycReg');
		if (busReg != null) asm.load(busReg, "0x1FFFFFFF");
		else {}
		if (arenaReg != null) {
			asm.load(arenaReg, "_recompsx_mem");
			asm.load(maskReg, "0x1F9FFFFF");
			asm.load(limReg, "0x200000");
		} else {}
		final homed = [for (r in home.keys()) r];
		homed.sort((a, b) -> a - b);
		for (r in homed) if ((liveIn & (1 << r)) != 0) loadField(home.get(r), gregOffset(r));
		else {}
		for (k in 0...ir.blocks.length) {
			final block = ir.blocks[k];
			asm.label(blockLabel(block.addr));
			var j = 0;
			while (j < block.body.length) {
				final x = block.body[j].decoded;
				// `lui rt, hi` then `ori`/`addiu rt, rt, lo`: one constant (the C++ form's value
				// regions fold it too); nothing reads rt in between.
				if (x.op == Op.LUI && x.rt != 0 && j + 1 < block.body.length) {
					final y = block.body[j + 1].decoded;
					if ((y.op == Op.ORI || y.op == Op.ADDIU) && y.rs == x.rt && y.rt == x.rt) {
						asm.checkpoint();
						final t = target(x.rt, []);
						constant(t, y.op == Op.ORI ? ((x.immU << 16) | y.immU) : (((x.immU << 16) + y.immS) | 0));
						write(x.rt, t);
						j += 2;
						continue;
					} else {}
				} else {}
				// `lwr rt, k(rs)` and `lwl rt, k+3(rs)`, either first: one unaligned word, as the C++
				// form fuses them (PatternMatcher, Memory.lwu) — in RAM the one or two aligned words
				// joined, anywhere else the two as they are, in their order.
				if ((x.op == Op.LWR || x.op == Op.LWL) && j + 1 < block.body.length) {
					final y = block.body[j + 1].decoded;
					final r = x.op == Op.LWR ? x : y;
					final l = x.op == Op.LWR ? y : x;
					if (y.op == (x.op == Op.LWR ? Op.LWL : Op.LWR) && y.rt == x.rt && y.rs == x.rs && x.rt != x.rs
						&& x.rt != 0 && l.immS == r.immS + 3) {
						asm.checkpoint();
						fusedWord(x, y, r);
						j += 2;
						continue;
					} else {}
				} else {}
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
					// after it, with nothing held across.
					final slotFirst = slot != null && !slot.isNop && ((block.delaySlot.writes:Int) & (t.reads:Int)) == 0;
					if (slotFirst) instruction(slot);
					else {}
					final cond = condition(d);
					final next = d.addr + 8;
					final follows = k + 1 < ir.blocks.length && ir.blocks[k + 1].addr == next;
					if (cond == ALWAYS || cond == NEVER) {
						if (slot != null && !slotFirst) instruction(slot);
						else {}
						charge(block.cycles);
						if (cond == ALWAYS) asm.jump(blockLabel(d.target));
						else if (!follows) asm.jump(blockLabel(next));
						else {}
						continue;
					} else {}
					final takenWhenTrue = cond == WHEN_T;
					final hasSlot = slot != null && !slot.isNop;
					if (hasSlot && slotFirst) {
						// The slot wrote none of the branch's registers: the test was made after it
						// (above), so T needs no keeping.
						charge(block.cycles);
						asm.branch(takenWhenTrue, blockLabel(d.target));
					} else if (hasSlot) {
						asm.op('movt\tr2');
						instruction(slot);
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
					if (slot != null) instruction(slot);
					else {}
					charge(block.cycles);
					asm.jump(blockLabel(d.target));
				case JR:
					if (slot != null) instruction(slot);
					else {}
					charge(block.cycles);
					if (k + 1 < ir.blocks.length) asm.jump(exit);
					else {}
				case _:
					throw 'Sh4Emitter: transfer ${d.op.mnemonic} at ${StringTools.hex(d.addr)}';
			}
		}
		// The one way out: every register the function wrote, the clock, the saved registers.
		asm.label(exit);
		for (r in homed) if ((written & (1 << r)) != 0) storeField(home.get(r), gregOffset(r));
		else {}
		if (saved.length == 0) asm.ret('mov.l\t$cycReg,@(8,$CTX)');
		else {
			asm.op('mov.l\t$cycReg,@(8,$CTX)');
			var i = saved.length - 1;
			while (i > 0) {
				asm.op('mov.l\t@r15+,${saved[i]}');
				i--;
			}
			asm.ret('mov.l\t@r15+,${saved[0]}');
		}
		// Out of line: the decode's other regions and the runtime's paths.
		for (s in stubs) s();
	}

	/** `cyc = (cyc + n) | 0`. */
	function charge(n:Int):Void {
		if (n == 0) return;
		clockStored = false;
		if (n >= -128 && n <= 127) asm.op('add\t#$n,$cycReg');
		else {
			asm.load("r0", Std.string(n));
			asm.op('add\tr0,$cycReg');
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
	function read(r:Int, tmp:String):String {
		if (r == 0) {
			asm.op('mov\t#0,$tmp');
			return tmp;
		} else {}
		final h = home.get(r);
		if (h != null) return h;
		if (holds.get(tmp) == r) return tmp;
		final other = tmp == "r1" ? "r3" : "r1";
		if (holds.get(other) == r) asm.op('mov\t$other,$tmp');
		else loadField(tmp, gregOffset(r));
		holds.set(tmp, r);
		return tmp;
	}

	/** Where to compute a value for guest register `r` without disturbing the registers in `avoid`:
	    its home when that is not among them, else `fallback`. */
	function target(r:Int, avoid:Array<String>, fallback = "r3"):String {
		final h = r == 0 ? null : home.get(r);
		return h != null && avoid.indexOf(h) < 0 ? h : fallback;
	}

	/** Guest register `r` given the value in `src` (a no-op for $zero). */
	function write(r:Int, src:String):Void {
		if (r == 0) return;
		final h = home.get(r);
		if (h != null) {
			if (h != src) asm.op('mov\t$src,$h');
			else {}
		} else {
			final now = storeField(src, gregOffset(r));
			for (t in ["r1", "r3"]) if (holds.get(t) == r) holds.remove(t);
			else {}
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
				final a = read(i.rs, "r1");
				final b = read(i.rt, "r3");
				// T = b > a, the operands the other way round.
				asm.op((i.op == Op.SLT ? 'cmp/gt\t' : 'cmp/hi\t') + '$a,$b');
				final t = target(i.rd, []);
				asm.op('movt\t$t');
				write(i.rd, t);
			case ADDI | ADDIU:
				if (i.rt == 0) return;
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
				final a = read(i.rs, "r1");
				final h = home.get(i.rt);
				if (h != null && i.immU <= 127) {
					asm.op('mov\t#${i.immU},r3');
					if (h != a) asm.op('mov\t$a,$h');
					else {}
					asm.op('$opname\tr3,$h');
				} else if (i.immU <= 255) {
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
			case SLL | SRL | SRA:
				if (i.rd == 0) return;
				final a = read(i.rt, "r1");
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
				asm.op('mov\t$s,r0');
				asm.op('and\t#31,r0');
				if (i.op != Op.SLLV) asm.op('neg\tr0,r0');
				else {}
				final t = target(i.rd, []);
				if (t != a) asm.op('mov\t$a,$t');
				else {}
				asm.op((i.op == Op.SRAV ? 'shad\tr0,' : 'shld\tr0,') + t);
				write(i.rd, t);
			case MULT | MULTU:
				final a = read(i.rs, "r1");
				final b = read(i.rt, "r3");
				asm.op((i.op == Op.MULT ? 'dmuls.l\t' : 'dmulu.l\t') + '$a,$b');
				asm.op('sts\tmacl,r1');
				storeField("r1", offsetOf("lo"));
				asm.op('sts\tmach,r1');
				storeField("r1", offsetOf("hi"));
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
				loadField(t == "r0" ? "r3" : t, offsetOf(i.op == Op.MFHI ? "hi" : "lo"));
				write(i.rd, t == "r0" ? "r3" : t);
			case MTHI | MTLO:
				final a = read(i.rs, "r1");
				storeField(a, offsetOf(i.op == Op.MTHI ? "hi" : "lo"));
			case LB | LBU | LH | LHU | LW: if (FASTMEM) loadFast(i) else load(i);
			case SB | SH | SW: if (FASTMEM) storeFast(i) else store(i);
			case LWL | LWR:
				// The current value in r3, the address in r1. In RAM inline, as GCC inlines
				// Memory.lwl/lwr's read: the aligned word and the lanes it keeps of rt. Elsewhere
				// the routine, which writes the clock first.
				final cur = read(i.rt, "r3");
				if (cur != "r3") asm.op('mov\t$cur,r3');
				else {}
				address(i);
				final slow = label("uslow");
				final back = label("uback");
				asm.op('mov\tr1,r0');
				asm.op('and\t$maskReg,r0');
				asm.op('cmp/hs\t$limReg,r0');
				asm.branch(true, slow);
				asm.op('mov\tr0,r2');           // r2 = the RAM index
				asm.op('shlr2\tr0');
				asm.op('shll2\tr0');
				asm.op('mov.l\t@(r0,$arenaReg),r0');   // w, the aligned word
				asm.op('mov\tr0,r1');           // r1 = w
				asm.op('mov\tr2,r0');
				asm.op('and\t#3,r0');           // k = a & 3
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
				asm.label(back, true);
				holds.remove("r1");
				holds.remove("r2");
				holds.remove("r3");
				write(i.rt, "r3");
				final routine = i.op == Op.LWL ? "_rx_sl_lwl" : "_rx_sl_lwr";
				stubs.push(() -> {
					asm.label(slow);
					callShared(routine, null);
					asm.jumpWith(back, 'mov\tr0,r3');
				});
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
		final a = read(i.rs, "r1");
		final b = read(i.rt, "r3");
		final h = home.get(i.rd);
		if (h != null && h != b) {
			if (h != a) asm.op('mov\t$a,$h');
			else {}
			asm.op('$opname\t$b,$h');
		} else if (h != null) {
			// rd is rt's home: a commuting operation in place, else through r0.
			if (commutes) asm.op('$opname\t$a,$h');
			else {
				asm.op('mov\t$h,r0');
				asm.op('mov\t$a,$h');
				asm.op('$opname\tr0,$h');
			}
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

	/** r1 = rs + imm, the virtual address (`busAddr` masks its segment bits later). */
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
	}

	/** Fastmem's load: the bus address in r1, the clock where a trap's port reads it, one access —
	    RAM and the scratchpad through the MMU, anything else the trap's emulation of it. */
	function loadFast(i:Instr):Void {
		address(i);
		asm.op('and\t$busReg,r1');
		clockOut();
		final dest = i.rt == 0 ? "r3" : target(i.rt, []);
		final width = switch (i.op) { case LB | LBU: "b"; case LH | LHU: "w"; case _: "l"; };
		asm.op('mov.$width\t@r1,$dest');
		if (i.op == Op.LBU) asm.op('extu.b\t$dest,$dest');
		else if (i.op == Op.LHU) asm.op('extu.w\t$dest,$dest');
		else {}
		write(i.rt, dest);
	}

	/** Fastmem's store, likewise. */
	function storeFast(i:Instr):Void {
		final v = read(i.rt, "r3");
		address(i);
		asm.op('and\t$busReg,r1');
		clockOut();
		final width = switch (i.op) { case SB: "b"; case SH: "w"; case _: "l"; };
		asm.op('mov.$width\t$v,@r1');
	}

	/** The clock to CpuState before an access that may trap, once while it is unchanged. */
	function clockOut():Void {
		if (clockStored) return;
		asm.op('mov.l\t$cycReg,@(8,$CTX)');
		clockStored = true;
	}

	/** The RAM test on the address in r1: r0 = its arena offset, a branch to `notRam` when it is
	    not RAM. The C++ form's: `(phys(a) & 0x1F9FFFFF) < 0x200000`. */
	function ramTest(notRam:String):Void {
		asm.op('mov\tr1,r0');
		asm.op('and\t$maskReg,r0');
		asm.op('cmp/hs\t$limReg,r0');
		asm.branch(true, notRam);
	}

	function load(i:Instr):Void {
		address(i);
		final notRam = label("nr");
		final back = label("back");
		ramTest(notRam);
		final dest = i.rt == 0 ? "r3" : target(i.rt, []);
		final width = switch (i.op) { case LB | LBU: "b"; case LH | LHU: "w"; case _: "l"; };
		asm.op('mov.$width\t@(r0,$arenaReg),$dest');
		asm.label(back, true);
		if (i.op == Op.LBU) asm.op('extu.b\t$dest,$dest');
		else if (i.op == Op.LHU) asm.op('extu.w\t$dest,$dest');
		else {}
		write(i.rt, dest);
		// Not RAM: the shared routine (the scratchpad, else the runtime's accessor), the address in
		// r1; the value comes back sign-extended and `back` extends it as the instruction does.
		final routine = '_rx_sl_rd' + (width == "b" ? "8" : (width == "w" ? "16" : "32"));
		stubs.push(() -> {
			asm.label(notRam);
			callShared(routine, null);
			asm.jumpWith(back, 'mov\tr0,$dest');
		});
	}

	/**
		A fused `lwr`/`lwl` pair (`first` in program order, `r` the lwr): in RAM, with the word at
		`rs + k + 3` in RAM too, `(lo >>> sh) | (hi << (32 - sh))` — lo and hi the aligned words, sh
		the misalignment in bits — or lo when aligned, which is what the two give whatever rt held.
		Anywhere else, or across RAM's end, the two through the runtime in their order.
	**/
	function fusedWord(first:Instr, second:Instr, r:Instr):Void {
		final cur = read(r.rt, "r3");
		if (cur != "r3") asm.op('mov\t$cur,r3');
		else {}
		address(r);                      // r1 = aR, the lwr's address
		final slow = label("fslow");
		final back = label("fback");
		final aligned = label("faligned");
		asm.op('mov\tr1,r0');
		asm.op('and\t$maskReg,r0');     // rR
		asm.op('cmp/hs\t$limReg,r0');
		asm.branch(true, slow);
		asm.op('mov\tr0,r2');
		asm.op('add\t#3,r2');           // rL = rR + 3
		asm.op('cmp/hs\t$limReg,r2');
		asm.branch(true, slow);
		asm.op('mov\tr0,r2');           // r2 = rR
		asm.op('shlr2\tr0');
		asm.op('shll2\tr0');
		asm.op('mov.l\t@(r0,$arenaReg),r3');    // lo
		asm.op('mov\tr2,r0');
		asm.op('and\t#3,r0');
		asm.op('tst\tr0,r0');
		asm.branch(true, aligned);
		asm.op('shll2\tr0');
		asm.op('shll\tr0');             // sh = (rR & 3) * 8
		asm.op('mov\tr0,r1');           // r1 = sh (aR is not needed past the tests)
		asm.op('mov\tr2,r0');
		asm.op('shlr2\tr0');
		asm.op('shll2\tr0');
		asm.op('add\t#4,r0');
		asm.op('mov.l\t@(r0,$arenaReg),r0');    // hi
		asm.op('neg\tr1,r2');
		asm.op('shld\tr2,r3');          // lo >>> sh
		asm.op('mov\t#32,r2');
		asm.op('sub\tr1,r2');
		asm.op('shld\tr2,r0');          // hi << (32 - sh)
		asm.op('or\tr0,r3');
		asm.label(aligned, true);
		asm.label(back, true);
		holds.remove("r1");
		holds.remove("r2");
		holds.remove("r3");
		write(r.rt, "r3");
		final firstIsR = first.op == Op.LWR;
		stubs.push(() -> {
			// Not RAM, or across its end: lwr and lwl as the C++ form's lwuSlow runs them, the clock
			// written first by each routine. r1 = aR, r3 = rt's value before the pair.
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

	function store(i:Instr):Void {
		// The value first: a field past 60 bytes is read through r0, which the test then holds.
		final v = read(i.rt, "r3");
		address(i);
		final notRam = label("nr");
		final back = label("back");
		ramTest(notRam);
		final width = switch (i.op) { case SB: "b"; case SH: "w"; case _: "l"; };
		asm.op('mov.$width\t$v,@(r0,$arenaReg)');
		// The slow path gives the routine the value in r3: past `back`, r3 holds nothing known.
		if (v != "r3") holds.remove("r3");
		else {}
		asm.label(back, true);
		final routine = '_rx_sl_wr' + (width == "b" ? "8" : (width == "w" ? "16" : "32"));
		stubs.push(() -> {
			asm.label(notRam);
			callShared(routine, v == "r3" ? null : v);
			asm.jump(back);
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

	public function bytes():Int return size;

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

	public function op(text:String):Void {
		checkImmediate(text);
		lines.push('\t$text');
		size += 2;
		lastMovable = movable(text);
		if (onWrite != null) {
			final d = destOf(text);
			if (d != null) onWrite(d);
			else {}
		} else {}
	}

	/** `keep`: reached only by running on or with the state it is left in (a memory access's
	    return point, the jump around an island), so what the registers hold still holds. */
	public function label(name:String, keep = false):Void {
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
		if (openFirstUse < 0) openFirstUse = size;
		else {}
		final name = '.Lpool_${islands}_$k';
		poolUses.push({at: size, label: name});
		op('mov.l\t$name,$dest');
	}

	/** After an unconditional transfer and its slot, where nothing runs on: the open pool is
	    written here when waiting for the next such place could leave its first use out of reach. */
	public function barrier():Void {
		if (open.length > 0 && size - openFirstUse > 520) flush();
		else {}
	}

	/** Between two guest instructions: when the open pool is about to go out of reach and no
	    jump has come, it is written here with a jump around it. */
	public function checkpoint():Void {
		if (open.length > 0 && size + 4 * open.length + 160 - openFirstUse > 1000) {
			final over = '.Lover_${islands}';
			op('bra\t$over');
			bras.push({at: size - 2, target: over});
			op('nop');
			flush();
			label(over, true);
		} else {}
	}

	function flush():Void {
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
		bras.push({at: size, target: target});
		op('bra\t$target');
		op(slot);
		barrier();
	}

	/** Ends the code with `rts` (its slot given): a place for an island too. */
	public function ret(slot:String):Void {
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
