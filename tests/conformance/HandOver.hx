import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/**
	Hand-overs (the recompiler's Discovery.cutAtEntries; TestHandOver): the same program traced
	with every function carrying the code it reaches (`HandWhole`) and with functions handing over
	at each other's entries (`HandCut`). Every function, from many register values: the CPU state,
	the cycle count, the instruction and block counts, guest memory, a token left (a tail jump, a
	return elsewhere) and its target — and where events are taken (an event due at every cycle
	offset, halting there) and where a slice yields (cooperative slices of every size), which a
	hand-over must keep exactly where the copy had them.
**/
class HandOver {
	static var cut = false;
	static inline var BUF = 0x80040020;      // a2: the word cluster 0 stores
	static inline var RA_WORD = 0x80040040;  // a1: the word clusters 5 and 7 load $ra from
	static inline var ENTRY_RA = 0x8000ffff; // Codegen.reset's $ra

	static function dispatch(addr:Int, ctx:CpuState):Bool {
		return cut ? HandCut.dispatch(addr, ctx) : HandWhole.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void {
		if (cut) HandCut.resume(fn, entry, ctx); else HandWhole.resume(fn, entry, ctx);
	}

	static function prepare(ctx:CpuState, a:Int, b:Int, ra:Int, useCut:Bool):Void {
		cut = useCut;
		Cooperative.reset();
		Codegen.reset(ctx);
		ctx.a0 = a; ctx.a1 = RA_WORD; ctx.a2 = BUF; ctx.a3 = b;
		ctx.v0 = b ^ 0x5a5a; ctx.v1 = -57; ctx.t0 = 23; ctx.t1 = 27; ctx.s0 = -17;
		ctx.t9 = HandWhole.L6;
		// Nothing scheduled: each run starts from the same machine (`due` arms its own event).
		ctx.cycles = 0x7ffffff0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Runtime.insns = 0; Runtime.blocks = 0;
		Kernel.haltAt = 0;
		Memory.write32(BUF, 0);
		Memory.write32(RA_WORD, ra);
	}

	/** What the machine shows after a call. Not `Runtime.blocks`: a hand-over ends a block where
	    the copy ran straight on, so the count of blocks differs where the instructions do not. */
	static function state(ctx:CpuState, vblanks:Int):Array<Int> {
		return [ctx.cycles, ctx.unwindToken, ctx.tailTarget, ctx.returnTarget, ctx.ra, ctx.v0, ctx.v1, ctx.a0, ctx.s0,
			ctx.t0, ctx.t1, Runtime.insns, Memory.read32(BUF), Kernel.vblankCount - vblanks, Cooperative.yields];
	}

	static function same(what:String, a:Array<Int>, b:Array<Int>):Void {
		for (i in 0...a.length) Conf.expect('$what [$i]', b[i], a[i]);
	}

	/** One call, plain. */
	static function plain(addr:Int, x:Int, y:Int, ra:Int):Void {
		final a = new CpuState(); final b = new CpuState();
		var v = Kernel.vblankCount;
		prepare(a, x, y, ra, false); dispatch(addr, a); final sa = state(a, v);
		v = Kernel.vblankCount;
		prepare(b, x, y, ra, true); dispatch(addr, b); final sb = state(b, v);
		Codegen.compare(a, b);
		same('hand-over call', sa, sb);
	}

	/** An event due `offset` cycles in, halting the run where it is taken. */
	static function due(addr:Int, x:Int, offset:Int, ra:Int):Void {
		final a = new CpuState(); final b = new CpuState();
		for (useCut in [false, true]) {
			final ctx = useCut ? b : a;
			prepare(ctx, x, 1, ra, useCut);
			ctx.cycles = 0; Scheduler.init(ctx);
			for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
			Scheduler.schedule(ctx, Scheduler.VBLANK_START, offset);
			Kernel.haltAt = Kernel.vblankCount + 1;
			dispatch(addr, ctx);
		}
		Codegen.compare(a, b);
		Conf.expect('hand-over: where the event was taken', b.cycles, a.cycles);
		Conf.expect('hand-over: token at the event', b.unwindToken, a.unwindToken);
	}

	/** Cooperative slices of `frequency`: yields in the same places, the same end. */
	static function sliced(addr:Int, x:Int, frequency:Int, ra:Int):Void {
		final a = new CpuState(); final b = new CpuState();
		final traces = [];
		for (useCut in [false, true]) {
			final ctx = useCut ? b : a;
			prepare(ctx, x, 3, ra, useCut);
			Cooperative.every = frequency;
			var trace = 0, slices = 0;
			while (Cooperative.step(ctx, addr, 4)) {
				trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.v0 ^ ctx.a0 ^ ctx.cycles) | 0;
				if (++slices > 200) { Conf.expect('hand-over: slices end', 0, 1); break; } else {}
			}
			traces.push(trace);
			traces.push(Cooperative.yields);
			traces.push(Cooperative.resumeEntry);
		}
		Codegen.compare(a, b);
		Conf.expect('hand-over: sliced trace', traces[3], traces[0]);
		Conf.expect('hand-over: yields', traces[4], traces[1]);
		Conf.expect('hand-over: resume consumed', traces[5], traces[2]);
	}

	public static function main():Void {
		final boot = new CpuState();
		Runtime.boot(boot); Runtime.bindDispatch(dispatch); Cooperative.bind(resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		Conf.expect('hand-over: the same functions', HandCut.CALLS.length, HandWhole.CALLS.length);
		// Small counts: G3, H3 and U8 loop a0 times.
		final values = [0, 1, 2, 3, 5, -1, -9];
		// $ra in memory: the entry's (a plain return), a function of the program's, elsewhere.
		final ras = [ENTRY_RA, HandWhole.P6, 0x80012340];
		for (addr in HandWhole.CALLS) {
			for (x in values) for (y in [0, 9]) for (ra in ras) plain(addr, x, y, ra);
			for (x in [0, 2, 5]) for (offset in 0...40) due(addr, x, offset, ENTRY_RA);
			for (x in [1, 4]) for (frequency in 0...5) sliced(addr, x, frequency, ENTRY_RA);
		}
		Conf.report('HandOver');
	}
}
