package recomp.codegen;

import recomp.analysis.Image;
import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Op;

/**
	The loads and stores of a function that reach a port rather than memory, as far as its own code
	shows. On fastmem (ADR-0049) an access to anything but RAM and the scratchpad misses the MMU and
	is emulated through a trap: ~200 cycles of the vector and the trampoline before the port's own
	emulation, where the decode every other target runs costs a compare. Which accesses go where is
	a run-time fact, so this is a guess, and only ever one: both paths emulate every address the
	same way, so a wrong guess costs time, never correctness (Memory's `pt`/`pf` accessors).

	Two shapes, both the PlayStation libraries' own:
	- an address built as a constant (`lui`, then `addiu`/`ori`) whose access lands outside RAM and
	  the scratchpad: `lui v0, 0x1f80; lw v0, 0x1814(v0)`;
	- a pointer loaded from a word of the executable whose initial value is a port: the libraries
	  keep their ports in variables (libetc's I_STAT is `*(u_long *)0x1f801070`), and every access
	  through one trapped — Crash Bandicoot: Warped's interrupt dispatcher ~180 times a frame, Crash
	  Bash's root counters and GPUSTAT ~700 (docs/perf/dreamcast-ledger.md, E-135).
	Pointer arithmetic keeps a pointer (`addiu`, `addu` with one pointer operand), any other write
	forgets it, and a call forgets what its callee may write. Facts flow into a block where every
	predecessor that reaches it agrees; the entry, and a block nothing in the function reaches (a
	resume, a dispatch), know nothing.
**/
class PortBases {
	/** Whether an access at bus address `a` misses fastmem's mapping: neither RAM, its mirrors, nor
	    the scratchpad (Memory.RAM_DECODE_MASK, SCRATCH_MATCH_MASK). */
	public static inline function misses(a:Int):Bool {
		final p = a & 0x1FFFFFFF;
		return (p & 0x1F9FFFFF) >= 0x200000 && (p & 0x1FFFFC00) != 0x1F800000;
	}

	/** Whether a word of the executable is a port's address, as the libraries keep them: the
	    hardware registers and the second expansion region (0x1F801000..0x1F802FFF), through any
	    segment. Narrower than `misses`, since this is a value that may be no pointer at all. */
	public static inline function portWord(w:Int):Bool {
		final p = w & 0x1FFFFFFF;
		return p >= 0x1F801000 && p < 0x1F803000;
	}

	/**
		The addresses of the function's loads and stores whose base register holds a port, mapped to
		true. `callWrites` gives the registers a call (the instruction with its target) may write.
	**/
	public static function analyze(ir:FunctionIR, image:Image, callWrites:InstructionIR->Int):Map<Int, Bool> {
		final n = ir.blocks.length;
		final index:Map<Int, Int> = [];
		for (k in 0...n) index.set(ir.blocks[k].addr, k);
		final inState:Array<Null<State>> = [for (_ in 0...n) null];
		final outState:Array<Null<State>> = [for (_ in 0...n) null];
		var changed = true;
		var rounds = 0;
		while (changed && rounds < 64) {
			changed = false;
			rounds++;
			for (k in 0...n) {
				final block = ir.blocks[k];
				var s:Null<State> = null;
				if (k == 0) s = new State();
				else {
					for (p in block.predecessors) {
						final o = outState[index.get(p)];
						if (o == null) continue;
						else {}
						s = s == null ? o.copy() : s.meet(o);
					}
				}
				// Reached by nothing in the function, yet (or ever: a resume's block).
				if (s == null) s = new State();
				else {}
				if (inState[k] != null && inState[k].same(s)) continue;
				else {}
				inState[k] = s;
				outState[k] = run(block, s.copy(), image, callWrites, null);
				changed = true;
			}
		}
		final found:Map<Int, Bool> = [];
		for (k in 0...n) run(ir.blocks[k], (inState[k] != null ? inState[k] : new State()).copy(), image, callWrites, found);
		return found;
	}

	/** One block from `s`: its body, its delay slot, then its transfer's own effect (a call's
	    writes, a link register). Accesses through a port are added to `found` when it is given. */
	static function run(block:BlockIR, s:State, image:Image, callWrites:InstructionIR->Int,
			found:Null<Map<Int, Bool>>):State {
		for (x in block.body) step(x, s, image, found);
		if (block.delaySlot != null) step(block.delaySlot, s, image, found);
		else {}
		final t = block.transfer;
		if (t != null) {
			switch (t.decoded.op) {
				case JAL | JALR | BLTZAL | BGEZAL:
					s.forget(callWrites(t) | (t.writes : Int));
				case _:
					s.forget((t.writes : Int));
			}
		} else {}
		return s;
	}

	static function step(x:InstructionIR, s:State, image:Image, found:Null<Map<Int, Bool>>):Void {
		final i = x.decoded;
		switch (i.op) {
			case LB | LBU | LH | LHU | LW | LWL | LWR | SB | SH | SW | SWL | SWR | LWC2 | SWC2:
				if (found != null && i.rs != 0 && (s.isPort(i.rs) || (s.isKnown(i.rs) && misses((s.value[i.rs] + i.immS) | 0))))
					found.set(i.addr, true);
				else {}
			case _:
		}
		switch (i.op) {
			case LUI:
				s.setConst(i.rt, i.immU << 16);
			case ADDIU | ADDI:
				if (s.isKnown(i.rs)) s.setConst(i.rt, (s.value[i.rs] + i.immS) | 0);
				else if (s.isPort(i.rs)) s.setPort(i.rt);
				else s.forget(1 << i.rt);
			case ORI:
				if (s.isKnown(i.rs)) s.setConst(i.rt, s.value[i.rs] | i.immU);
				else s.forget(1 << i.rt);
			case ADDU | ADD | OR:
				if (s.isKnown(i.rs) && s.isKnown(i.rt))
					s.setConst(i.rd, i.op == Op.OR ? (s.value[i.rs] | s.value[i.rt]) : ((s.value[i.rs] + s.value[i.rt]) | 0));
				else if (s.isPort(i.rs) != s.isPort(i.rt) && !(i.op == Op.OR && i.rs != 0 && i.rt != 0)) s.setPort(i.rd);
				else s.forget(1 << i.rd);
			case LW:
				if (i.rs != 0 && s.isKnown(i.rs)) {
					final a = (s.value[i.rs] + i.immS) | 0;
					if ((a & 3) == 0 && image.containsWord(a) && portWord(image.readWord(a))) s.setPort(i.rt);
					else s.forget(1 << i.rt);
				} else s.forget(1 << i.rt);
			case _:
				s.forget((x.writes : Int));
		}
	}
}

/** Per register: a constant it is known to hold, or that it holds a port's address. $zero is 0. */
private class State {
	public var known:Int = 1;
	public var port:Int = 0;
	public final value:Array<Int> = [for (_ in 0...32) 0];

	public function new() {}

	public inline function isKnown(r:Int):Bool return (known >>> r) & 1 != 0;

	public inline function isPort(r:Int):Bool return (port >>> r) & 1 != 0;

	public function setConst(r:Int, v:Int):Void {
		if (r == 0) return;
		else {}
		known |= 1 << r;
		port &= ~(1 << r);
		value[r] = v;
	}

	public function setPort(r:Int):Void {
		if (r == 0) return;
		else {}
		known &= ~(1 << r);
		port |= 1 << r;
	}

	public function forget(mask:Int):Void {
		final m = mask & ~1;
		known &= ~m;
		port &= ~m;
	}

	public function copy():State {
		final c = new State();
		c.known = known;
		c.port = port;
		for (r in 0...32) c.value[r] = value[r];
		return c;
	}

	/** What both agree on: a constant both hold, a port both hold. */
	public function meet(o:State):State {
		var k = known & o.known;
		for (r in 1...32) if ((k >>> r) & 1 != 0 && value[r] != o.value[r]) k &= ~(1 << r);
		else {}
		known = k;
		port &= o.port;
		return this;
	}

	public function same(o:State):Bool {
		if (known != o.known || port != o.port) return false;
		else {}
		for (r in 1...32) if ((known >>> r) & 1 != 0 && value[r] != o.value[r]) return false;
		else {}
		return true;
	}
}
