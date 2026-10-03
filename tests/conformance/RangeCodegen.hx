import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Range-proved scalar code vs actual reference output. Unproved overflow cases check that
	specialization is refused, not the runtime's still-unimplemented arithmetic trap behavior. */
@:access(ScalarCodegen)
class RangeCodegen {
	static var optimized = false;
	static function address(kind:Int):Int return (RangeOptimized.BASE + (kind << 12)) | 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		return optimized ? RangeOptimized.dispatch(addr, ctx) : RangeReference.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, x:Int, opt:Bool, kind:Int):Void {
		ScalarCodegen.prepare(ctx, x, -77, opt); optimized = opt;
		if (kind == 8 || kind == 9) {
			ctx.a0 = 0x80040000; Memory.write8(ctx.a0, x & 255);
		} else {}
	}
	static function expected(kind:Int, x:Int):Int {
		return switch (kind) {
			case 0: (x & 65535) + 32767;
			case 1: (0 - (x >> 16)) | 0;
			case 2: (((x & 255) << 16) - 32768) | 0;
			case 3: (((x & 32767) << 1) - 32768) | 0;
			case 4: -98304;
			case 5: (((x | 0x80000000) >>> 1) - 32768) | 0;
			case 6: (x + 1) | 0;
			case 7: (0 - x) | 0;
			case 8 | 9: (x & 255) + 7;
			case 10: 0x7fffffff;
			case 11: (x & 255) + 1;
			case 12: (x & 65535) + 7;
			case 13: (x + 7) | 0;
			case _: 0;
		};
	}
	static function sliced(ctx:CpuState, frequency:Int):Int {
		Cooperative.every = frequency; var n = 0; var trace = 0;
		while (Cooperative.step(ctx, address(12), 4)) {
			trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.v0 ^ ctx.t0 ^ ctx.cycles) | 0;
			n++;
			if (n > 100) { Conf.expect('range resume progress', 0, 1); return 0; } else {}
		}
		return trace;
	}
	static function due(ctx:CpuState):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 3);
		Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(address(12), ctx);
	}
	static function fifo(ctx:CpuState):Int {
		ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		ctx.a0 = 0x1f801801; dispatch(address(9), ctx); return Memory.read8u(ctx.a0);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, -128, 127, 255, 256, -32768, 32767, 65535, 65536,
			0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (x in samples) {
			for (kind in 0...RangeOptimized.COUNT) {
				prepare(a, x, false, kind); dispatch(address(kind), a);
				final insns = Runtime.insns; final blocks = Runtime.blocks;
				prepare(b, x, true, kind); dispatch(address(kind), b);
				ScalarCodegen.compare(a, b, insns, blocks);
				Conf.expect('range arithmetic formula', b.v0, expected(kind, x));
			}
			prepare(a, x, false, 11); a.v0 = x; dispatch((address(11) + 12) | 0, a);
			final insns = Runtime.insns; final blocks = Runtime.blocks;
			prepare(b, x, true, 11); b.v0 = x; dispatch((address(11) + 12) | 0, b);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('interior entry takes arbitrary input', b.v0, (x + 1) | 0);
		}
		for (frequency in 0...4) {
			prepare(a, -1, false, 12); final trace = sliced(a, frequency);
			final insns = Runtime.insns; final blocks = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, -1, true, 12); final actual = sliced(b, frequency);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('range suspension state', actual, trace); Conf.expect('range checkpoints', Cooperative.yields, yields);
		}
		prepare(a, -1, false, 12); due(a);
		final insns = Runtime.insns; final blocks = Runtime.blocks;
		prepare(b, -1, true, 12); due(b);
		ScalarCodegen.compare(a, b, insns, blocks);
		Conf.expect('range event before callee', b.v0, 0x80000001);
		prepare(a, -1, false, 9); final next = fifo(a);
		final fifoInsns = Runtime.insns; final fifoBlocks = Runtime.blocks;
		prepare(b, -1, true, 9); final actual = fifo(b);
		ScalarCodegen.compare(a, b, fifoInsns, fifoBlocks);
		Conf.expect('range memory helper retains IO read', actual, next);
		Conf.report('RangeCodegen');
	}
}
