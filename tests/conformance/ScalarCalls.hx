import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Real emitted caller projections vs the full-state path, including observable exits. */
@:access(ScalarCodegen)
class ScalarCalls {
	static var optimized = false;
	static var observed = 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f010) { observed = ctx.t0; return true; } else {}
		return optimized ? ScalarCallsOptimized.dispatch(addr, ctx) : ScalarCallsReference.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function addr(kind:Int):Int return (ScalarCallsOptimized.BASE + (kind << 12)) | 0;
	static function prepare(ctx:CpuState, x:Int, y:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, x, y, opt);
		optimized = opt; observed = 0;
		ctx.a2 = 0x80040000; ctx.a3 = 3;
		Memory.write32(ctx.a2, 0x76543210);
	}
	static function sliced(ctx:CpuState, kind:Int, frequency:Int):Int {
		Cooperative.every = frequency;
		var slices = 0; var trace = 0;
		while (Cooperative.step(ctx, addr(kind), 4)) {
			trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.t0 ^ ctx.v0 ^ ctx.cycles ^ ctx.pc) | 0;
			slices++;
			if (slices > 100) { Conf.expect('call projection suspension progress', 0, 1); return 0; } else {}
		}
		return trace;
	}
	static function due(ctx:CpuState, kind:Int, when:Int):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, when);
		Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(addr(kind), ctx);
	}
	static function fifo(ctx:CpuState):Int {
		ctx.cycles = 0; Scheduler.init(ctx);
		cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0);
		cd.Cdrom.write8(0x1f801801, 0x19, 0);
		cd.Cdrom.onEvent(ctx);
		ctx.a2 = 0x1f801801;
		dispatch(addr(4), ctx);
		return Memory.read8u(ctx.a2);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, 31, 32, -32, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (x in samples) for (y in samples) {
			for (kind in 0...ScalarCallsOptimized.COUNT) {
				prepare(a, x, y, false); dispatch(addr(kind), a);
				final insns = Runtime.insns; final blocks = Runtime.blocks;
				final seen = observed; final stored = Memory.read32(a.a2);
				prepare(b, x, y, true); dispatch(addr(kind), b);
				ScalarCodegen.compare(a, b, insns, blocks);
				Conf.expect('call sees original scratch result', observed, seen);
				Conf.expect('callee store retained', Memory.read32(b.a2), stored);
				final sum = (x + y + (kind == 13 ? 3 : 0)) | 0;
				final expected = switch (kind) {
					case 14: sum;
					case 18: sum << 2;
					case 19: (x - y) | 0;
					case 20: (y - x) | 0;
					case _: sum << 1;
				};
				Conf.expect('projection independent formula', b.v0, expected);
				if (kind == 5) Conf.expect('next call observes scratch', seen, sum); else {}
			}
			// The same callee reached through its public entry still publishes both results.
			prepare(a, x, y, false); dispatch((addr(0) + 128) | 0, a);
			final insns = Runtime.insns; final blocks = Runtime.blocks;
			prepare(b, x, y, true); dispatch((addr(0) + 128) | 0, b);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('public entry publishes scratch output', b.t0, (x + y) | 0);
		}
		for (kind in [0, 1, 7, 12, 13, 14, 17, 18, 19, 20]) for (frequency in 0...4) {
			prepare(a, 0, -7, false); final trace = sliced(a, kind, frequency);
			final insns = Runtime.insns; final blocks = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, 0, -7, true); final actual = sliced(b, kind, frequency);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('same call checkpoints', Cooperative.yields, yields);
			Conf.expect('same state while suspended', actual, trace);
		}
		for (kind in [0, 7]) {
			prepare(a, 99, 101, false); due(a, kind, kind == 0 ? 3 : 8);
			final insns = Runtime.insns; final blocks = Runtime.blocks;
			prepare(b, 99, 101, true); due(b, kind, kind == 0 ? 3 : 8);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('event observes complete state', b.t0, kind == 0 ? 23 : 200);
		}
		prepare(a, 99, 101, false); a.unwindToken = 1; dispatch(addr(0), a);
		final insns = Runtime.insns; final blocks = Runtime.blocks;
		prepare(b, 99, 101, true); b.unwindToken = 1; dispatch(addr(0), b);
		ScalarCodegen.compare(a, b, insns, blocks);
		Conf.expect('unwinding before overwrite retains omitted result', b.t0, 200);
		prepare(a, 99, 101, false); final next = fifo(a);
		final fifoInsns = Runtime.insns; final fifoBlocks = Runtime.blocks;
		prepare(b, 99, 101, true); final actual = fifo(b);
		ScalarCodegen.compare(a, b, fifoInsns, fifoBlocks);
		Conf.expect('zero-target FIFO read retained', actual, next);
		Conf.report('ScalarCalls');
	}
}
