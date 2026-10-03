package recomp.analysis;

import recomp.ir.Effect;
import recomp.ir.FunctionIR;
import recomp.mips.Op;

/** Conservative semantic inputs, may-writes and effects for a normal function entry.
	Inputs can be overestimated: calls never kill dependencies on incoming values. Preserved
	means never written, not a claim about saved/restored registers. Scheduling observations
	are tracked separately by BoundaryLiveness and must not be inferred from these masks.
**/
class FunctionSummary {
	public static inline final ALL = 0xFFFFFFFE;
	public final entry:Int;
	public var inputs(default, null):Int = 0;
	public var writes(default, null):Int = 0;
	public var effects(default, null):Effect = Effect.NONE;
	public final calls:Array<SummaryCall> = [];
	final ownInputs:Int;
	final ownWrites:Int;
	final ownEffects:Effect;

	public function new(fn:Func, image:Image, raTarget:Int -> Null<Int>, hooked:Bool = false) {
		entry = fn.entry;
		final ir = new FunctionIR(fn, image);
		final flow = new BoundaryLiveness(fn, ir);
		final defs:Map<Int, Int> = [];
		final uses:Map<Int, Int> = [];
		final incoming:Map<Int, Int> = [];
		final outgoing:Map<Int, Int> = [];
		final byBlock:Map<Int, SummaryCall> = [];
		for (b in ir.blocks) {
			var d = 0; var u = 0;
			for (x in b.instructions) {
				u |= (x.reads : Int) & ~d;
				// Calls are classified from the transfer below. In particular, a linking
				// return through ra is not an unknown call (same rule as Discovery/Emitter).
				effects |= (x.effects : Int) & ~(Effect.CALL : Int);
				// An unproved ADD/ADDI/SUB keeps TRAP (projection still refuses it), but it enters
				// no handler: the emitter wraps those operations and raises no overflow exception,
				// so the instruction reads and writes only its own registers. Taken as a trap into
				// unknown code, it made every caller of such a function — Crash 3's renderer
				// helpers — take each span again after the call.
				if ((x.effects.has(Effect.TRAP) && !overflowOnly(x)) || x.effects.has(Effect.UNKNOWN)) {
					u |= ALL & ~d; writes = ALL; effects |= Effect.UNKNOWN;
				}
				d |= (x.writes : Int);
			}
			defs.set(b.addr, d); uses.set(b.addr, u); writes |= d;
			incoming.set(b.addr, 0); outgoing.set(b.addr, ALL);
			// Hand-overs to other functions' entries (Discovery.cutAtEntries) are tail calls: the
			// fall-through or a branch's arm, conditional where the block also continues here.
			if (fn.hops.keys().hasNext()) for (h in handOvers(fn, b)) {
				final c = new SummaryCall(b.addr, h, true, b.successors.length > 0 || b.transfer != null);
				calls.push(c);
				if (!byBlock.exists(b.addr)) byBlock.set(b.addr, c);
				else {}
				effects |= Effect.CALL;
			} else {}
			final x = b.transfer;
			if (x == null) continue;
			final t = x.decoded;
			var target:Null<Int> = null;
			var call = false;
			var tail = false;
			var conditional = false;
			switch (t.op) {
				case JAL | BLTZAL | BGEZAL:
					call = true; target = t.target; conditional = t.op != Op.JAL;
				case J:
					if (!ir.byAddress.exists(t.target)) { call = true; tail = true; target = t.target; }
				case JALR if (t.rs != 31): call = true; tail = t.rd == 0;
				case JR | JALR:
					final ra = t.rs == 31 && t.isRegisterJump ? raTarget(t.addr) : null;
					if (ra != null) {
						if (!ir.byAddress.exists(ra)) { call = true; tail = true; target = ra; }
					} else if (fn.checkedReturns.exists(t.addr)) {
						// Runtime.returnTo/afterCall unwind to an existing continuation, or leave
						// the caller altogether. They do not execute the return target here. In
						// particular, this is not an unknown callee clobbering every cached span.
						effects |= Effect.NONLOCAL_RETURN;
					} else if (t.rs != 31 && !fn.registerReturns.exists(t.addr)) {
						call = true; tail = true;
					}
				case _:
			}
			if (call) {
				final c = new SummaryCall(t.addr, target, tail, conditional);
				c.liveAfter = flow.afterCall.exists(t.addr) ? flow.afterCall.get(t.addr) : ALL;
				calls.push(c); byBlock.set(b.addr, c);
				effects |= Effect.CALL;
			}
		}
		// Must-definitions from local instructions only, intersecting predecessors. Starting
		// at top is necessary for loop-carried paths; entry and disconnected roots start empty.
		var changed = true;
		while (changed) {
			changed = false;
			for (b in ir.blocks) {
				var before = b.addr == fn.entry || b.predecessors.length == 0 ? 0 : ALL;
				for (p in b.predecessors) before &= outgoing.get(p);
				final after = before | defs.get(b.addr);
				incoming.set(b.addr, before);
				if (after != outgoing.get(b.addr)) { outgoing.set(b.addr, after); changed = true; }
			}
		}
		for (b in ir.blocks) {
			inputs |= uses.get(b.addr) & ~incoming.get(b.addr);
			if (byBlock.exists(b.addr)) byBlock.get(b.addr).definedBefore = outgoing.get(b.addr);
		}
		if (hooked) { inputs = ALL; writes = ALL; effects |= Effect.UNKNOWN; }
		ownInputs = inputs; ownWrites = writes; ownEffects = effects;
	}

	public function preserved():Int return ALL & ~writes;

	/** The entries `b` hands over to: its fall-through, a branch's arms, a call's continuation. */
	static function handOvers(fn:Func, b:BlockIR):Array<Int> {
		final out = [];
		final last = b.instructions.length > 0 ? b.instructions[b.instructions.length - 1].decoded : null;
		final end = last == null ? b.addr : last.addr + 4;
		final t = b.transfer == null ? null : b.transfer.decoded;
		if (t == null) {
			if (fn.hops.exists(recomp.Vaddr.canonRam(end))) out.push(recomp.Vaddr.canonRam(end));
			else {}
			return out;
		} else {}
		final after = recomp.Vaddr.canonRam(t.addr + 8);
		switch (t.op) {
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
				if (fn.hops.exists(recomp.Vaddr.canonRam(t.target))) out.push(recomp.Vaddr.canonRam(t.target));
				else {}
				if (fn.hops.exists(after) && out.indexOf(after) < 0) out.push(after);
				else {}
			case JAL | JALR | BLTZAL | BGEZAL:
				if (fn.hops.exists(after)) out.push(after);
				else {}
			case _:
		}
		return out;
	}

	/** A trap that is only arithmetic overflow, which generated code does not raise. */
	static inline function overflowOnly(x:InstructionIR):Bool {
		final op = x.decoded.op;
		return op == Op.ADD || op == Op.ADDI || op == Op.SUB;
	}

	/** Bind callees first, then solve all universes together. Null is an unknown call, not
	    a pure function. The union lattice terminates even for mutually recursive functions. */
	public static function solve(functions:Array<FunctionSummary>):Void {
		var changed = true;
		while (changed) {
			changed = false;
			for (f in functions) {
				var r = f.ownInputs; var w = f.ownWrites; var e:Int = f.ownEffects;
				for (c in f.calls) {
					if (c.callee == null) { r |= ALL & ~c.definedBefore; w = ALL; e |= Effect.UNKNOWN; }
					else { r |= c.callee.inputs & ~c.definedBefore; w |= c.callee.writes; e |= c.callee.effects; }
				}
				if (r != f.inputs || w != f.writes || e != (f.effects : Int)) {
					f.inputs = r; f.writes = w; f.effects = e; changed = true;
				}
			}
		}
	}
}

class SummaryCall {
	public final address:Int;
	public final target:Null<Int>;
	public final tail:Bool;
	public final conditional:Bool;
	public var definedBefore:Int = 0;
	public var liveAfter:Int = FunctionSummary.ALL;
	public var callee:Null<FunctionSummary> = null;
	public function new(address:Int, target:Null<Int>, tail:Bool, conditional:Bool) {
		this.address = address; this.target = target; this.tail = tail; this.conditional = conditional;
	}
	public function requiredOutputs():Int return liveAfter & (callee == null ? FunctionSummary.ALL : callee.writes);
}
