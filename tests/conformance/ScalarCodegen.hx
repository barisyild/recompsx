import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;

/** Actual emitted scalar helpers vs the unspecialized emitter, plus independent results.
	The same entry checkpoints, instruction accounting and full architectural state are tested.
**/
class ScalarCodegen {
	static var optimized = false;

	static function dispatch(addr:Int, ctx:CpuState):Bool {
		return optimized ? CodegenOptimized.dispatch(addr, ctx) : CodegenReference.dispatch(addr, ctx);
	}

	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }

	static function prepare(ctx:CpuState, a:Int, b:Int, opt:Bool):Void {
		optimized = opt;
		Cooperative.reset();
		Codegen.reset(ctx);
		ctx.a0 = a; ctx.a1 = b; ctx.a2 = 0x76543210; ctx.a3 = -123;
		ctx.v0 = 0x80000001; ctx.v1 = -57;
		ctx.at = 19; ctx.t0 = 23; ctx.t1 = 27; ctx.s0 = -17;
		ctx.hi = 101; ctx.lo = -103;
		ctx.cycles = 0x7ffffff0; ctx.nextEvent = 0x80001000;
		Runtime.insns = 0; Runtime.blocks = 0;
		Kernel.haltAt = 0;
	}

	static function compare(a:CpuState, b:CpuState, insns:Int, blocks:Int):Void {
		Codegen.compare(a, b);
		Conf.expect('scalar next event', b.nextEvent, a.nextEvent);
		Conf.expect('scalar instruction count', Runtime.insns, insns);
		Conf.expect('scalar block count', Runtime.blocks, blocks);
	}

	static function sliced(ctx:CpuState, frequency:Int):Void {
		Cooperative.every = frequency;
		var slices = 0;
		while (Cooperative.step(ctx, CodegenOptimized.SCALAR_CHAIN, 4)) {
			slices++;
			if (slices > 100) { Conf.expect('scalar suspension progress', 0, 1); return; } else {}
		}
		Conf.expect('scalar resume consumed', Cooperative.resumeEntry, -1);
	}

	static function haltAtCall(ctx:CpuState):Void {
		ctx.cycles = 0;
		Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 3);
		Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(CodegenOptimized.SCALAR_CHAIN, ctx);
	}

	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, 31, 32, -32, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (x in samples) for (y in samples) {
			for (kind in 0...CodegenOptimized.SCALAR_COUNT) {
				final addr = CodegenOptimized.SCALAR_OPS + (kind << 12);
				prepare(a, x, y, false); dispatch(addr, a);
				final insns = Runtime.insns; final blocks = Runtime.blocks;
				prepare(b, x, y, true); dispatch(addr, b);
				compare(a, b, insns, blocks);
				Conf.expect('scalar op cycles', b.cycles, 0x7ffffff3);
			}
			// The internal ABI is genuinely state-free and can be called as plain Haxe.
			final expected = ((((x + 7) | 0) << 2) + y) | 0;
			Conf.expect('scalar arithmetic formula', CodegenOptimized.scalarArithmetic_value(x, y), expected);
			Conf.expect('scalar shift zero preserves sign', CodegenOptimized.scalarOp18_value(y), y);
			Conf.expect('scalar variable logical shift wraps', CodegenOptimized.scalarOp25_value(x, y), (y >>> (x & 31)) | 0);
			prepare(a, x, y, false); CodegenReference.scalarOverwrite(a);
			final insns = Runtime.insns; final blocks = Runtime.blocks;
			prepare(b, x, y, true); CodegenOptimized.scalarOverwrite(b);
			compare(a, b, insns, blocks);
			Conf.expect('scalar overwritten result', b.v0, (x + y) | 0);
			prepare(a, x, y, false); CodegenReference.scalarRestored(a);
			final restoredInsns = Runtime.insns; final restoredBlocks = Runtime.blocks;
			prepare(b, x, y, true); CodegenOptimized.scalarRestored(b);
			compare(a, b, restoredInsns, restoredBlocks);
			Conf.expect('restored scratch remains visible', b.t0, 23);
			Conf.expect('restored scratch result', b.v0, (x + 1) | 0);
			prepare(a, x, y, false); CodegenReference.scalarChain(a);
			final chainInsns = Runtime.insns; final chainBlocks = Runtime.blocks;
			prepare(b, x, y, true); CodegenOptimized.scalarChain(b);
			compare(a, b, chainInsns, chainBlocks);
			final first = ((((x + 7) | 0) << 2) + ((y + 3) | 0)) | 0;
			Conf.expect('scalar chain first result', b.a0, first);
			Conf.expect('scalar chain second result', b.v0, ((first - 3) | 0) ^ ((y + 2) | 0));
			Conf.expect('scalar chain cycles wrap', b.cycles, 0x80000000);
			Conf.expect('scalar chain instructions retained', chainInsns, 16);
			Conf.expect('scalar chain blocks retained', chainBlocks, 5);
		}
		for (frequency in 0...4) {
			prepare(a, -123, 32, false); sliced(a, frequency);
			final insns = Runtime.insns; final blocks = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, -123, 32, true); sliced(b, frequency);
			compare(a, b, insns, blocks);
			Conf.expect('same scalar safe points', Cooperative.yields, yields);
		}
		prepare(a, 99, 101, false); haltAtCall(a);
		final insns = Runtime.insns; final blocks = Runtime.blocks;
		prepare(b, 99, 101, true); haltAtCall(b);
		compare(a, b, insns, blocks);
		Conf.expect('due pump halts before scalar body', b.v0, 0x80000001);
		Conf.report('ScalarCodegen');
	}
}
