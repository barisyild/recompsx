import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import core.ScalarResult;
import kernel.Kernel;
import mem.Memory;

/** All results, not ABI-designated v0/v1 alone, survive publication and observation. */
@:access(ScalarCodegen)
class ScalarResults {
	static var optimized = false;
	static function address(kind:Int):Int return (ResultsOptimized.BASE + (kind << 12)) | 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool return optimized ? ResultsOptimized.dispatch(addr, ctx) : ResultsReference.dispatch(addr, ctx);
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, x:Int, y:Int, kind:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, x, y, opt); optimized = opt;
		ctx.ra = x; ctx.sp = x; ctx.t0 = ~y;
		ScalarResult.value1 = 0x13579; ScalarResult.value2 = 0x24680; ScalarResult.accounting = -12345;
		if (kind == 4 || kind == 6) {
			ctx.a0 = 0x80040000; Memory.write32(ctx.a0, x); Memory.write32(ctx.a0 + 4, y); Memory.write8(ctx.a0 + 8, x ^ y);
		} else {}
	}
	static function formulas(ctx:CpuState, x:Int, y:Int, kind:Int):Void {
		switch (kind) {
			case 0: Conf.expect('distinct result v0', ctx.v0, x ^ y); Conf.expect('distinct result t0', ctx.t0, (x + y) | 0);
			case 1:
				Conf.expect('shared value v0', ctx.v0, (x + y) | 0); Conf.expect('shared value v1', ctx.v1, ctx.v0); Conf.expect('shared value t0', ctx.t0, ctx.v0);
				Conf.expect('alias results use no extra word', ScalarResult.value1, 0x13579);
			case 2:
				Conf.expect('copied incoming at', ctx.at, x); Conf.expect('literal output', ctx.v0, 7);
				Conf.expect('overwritten input a0', ctx.a0, (y + 11) | 0); Conf.expect('captured input a1', ctx.a1, x);
				Conf.expect('affine result', ctx.t0, (x + 5) | 0); Conf.expect('computed result', ctx.t1, x ^ y);
				Conf.expect('reconstruction uses no extra word', ScalarResult.value1, 0x13579);
			case 3: Conf.expect('restored word across overflow', ctx.t0, ~y); Conf.expect('remaining output', ctx.v0, x ^ y);
			case 4:
				Conf.expect('first load', ctx.v0, x); Conf.expect('second load', ctx.t0, y); Conf.expect('signed byte', ctx.t1, ((x ^ y) << 24) >> 24);
				Conf.expect('pointer output', ctx.a0, 0x8004000c);
			case 5:
				Conf.expect('CFG first output', ctx.v0, x > 0 ? (x - y) | 0 : (x + y) | 0);
				Conf.expect('CFG second output', ctx.v1, x > 0 ? x : y); Conf.expect('CFG common output', ctx.t0, x ^ y);
			case 6: Conf.expect('same RAM read v0', ctx.v0, x & 255); Conf.expect('same RAM read t0', ctx.t0, x & 255);
			case 7:
				Conf.expect('projection first live output', ctx.v0, (x + y) | 0); Conf.expect('projection second live output', ctx.v1, x ^ y);
				Conf.expect('projection omitted output overwritten', ctx.t0, 41);
			case 8:
				Conf.expect('second callee v0', ctx.v0, x | y); Conf.expect('second callee alias v1', ctx.v1, x | y);
				Conf.expect('first callee retained output', ctx.t0, (x - y) | 0);
			case 9: for (r in 1...31) Conf.expect('full result ABI', ResultsOptimized.reg(ctx, r), x ^ r);
			case _:
				Conf.expect('restored sp', ctx.sp, x); Conf.expect('affine return', ctx.v0, (x - 16) | 0); Conf.expect('affine alias', ctx.t0, ctx.v0);
		}
	}
	static function sliced(ctx:CpuState, kind:Int, frequency:Int):Int {
		Cooperative.every = frequency; var n = 0; var trace = 0;
		while (Cooperative.step(ctx, address(kind), 4)) {
			trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.v0 ^ ctx.v1 ^ ctx.t0 ^ ctx.cycles) | 0; n++;
			if (n > 100) { Conf.expect('result resume progress', 0, 1); return 0; } else {}
		}
		return trace;
	}
	static function due(ctx:CpuState):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 3); Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(address(7), ctx);
	}
	static function fifo(ctx:CpuState):Int {
		ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		ctx.a0 = 0x1f801801; dispatch(address(6), ctx); return Memory.read8u(ctx.a0);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, -128, 255, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (x in samples) for (y in samples) {
			for (kind in 0...ResultsOptimized.COUNT) {
				prepare(a, x, y, kind, false); dispatch(address(kind), a); final ni = Runtime.insns; final nb = Runtime.blocks;
				prepare(b, x, y, kind, true); dispatch(address(kind), b); ScalarCodegen.compare(a, b, ni, nb); formulas(b, x, y, kind);
			}
			Conf.expect('forwarded ordinary return', ResultsForward.results0_value(x, y), x ^ y);
			Conf.expect('forwarded secondary return', ScalarResult.value1, (x + y) | 0);
			for (offset in [8, 20]) {
				prepare(a, x, y, 5, false); dispatch((address(5) + offset) | 0, a); final ni = Runtime.insns; final nb = Runtime.blocks;
				prepare(b, x, y, 5, true); dispatch((address(5) + offset) | 0, b); ScalarCodegen.compare(a, b, ni, nb);
			}
			prepare(a, x, y, 7, false); dispatch((address(7) + 64) | 0, a); final ni = Runtime.insns; final nb = Runtime.blocks;
			prepare(b, x, y, 7, true); dispatch((address(7) + 64) | 0, b); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('public third output retained', b.t0, (x - y) | 0);
		}
		for (kind in [4, 5, 7, 8, 9]) for (frequency in 0...4) {
			prepare(a, 0x7fffffff, -1, kind, false); final trace = sliced(a, kind, frequency);
			final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, 0x7fffffff, -1, kind, true); final actual = sliced(b, kind, frequency); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('result suspension state', actual, trace); Conf.expect('result checkpoints', Cooperative.yields, yields);
		}
		// Exercise the generated guard without dereferencing an invalid aligned-MemA address.
		// Misaligned lw has no portable runtime result until AdEL is emulated; a host may trap.
		for (offset in 0...4) {
			a.a0 = 0x80040000 + offset;
			Conf.expect('multi-load alignment guard', ResultsOptimized.acceptsReadAddress(a) ? 1 : 0, offset == 0 ? 1 : 0);
		}
		for (addr in [0x801ffffc, 0x9f8003fc]) {
			a.a0 = addr; Conf.expect('multi-load boundary guard', ResultsOptimized.acceptsReadAddress(a) ? 1 : 0, 0);
			prepare(a, 13, -17, 4, false); a.a0 = addr; dispatch(address(4), a); final ni = Runtime.insns; final nb = Runtime.blocks;
			prepare(b, 13, -17, 4, true); b.a0 = addr; dispatch(address(4), b); ScalarCodegen.compare(a, b, ni, nb);
		}
		prepare(a, 13, -17, 6, false); final expected = fifo(a); final ni = Runtime.insns; final nb = Runtime.blocks;
		prepare(b, 13, -17, 6, true); final actual = fifo(b); ScalarCodegen.compare(a, b, ni, nb); Conf.expect('two FIFO reads retained', actual, expected);
		prepare(a, 13, -17, 7, false); due(a); final hi = Runtime.insns; final hb = Runtime.blocks;
		prepare(b, 13, -17, 7, true); due(b); ScalarCodegen.compare(a, b, hi, hb);
		Conf.expect('no result ABI read after entry halt', ScalarResult.value1, 0x13579);
		Conf.report('ScalarResults');
	}
}
