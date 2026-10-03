import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Differential full-state checks at every public block, and calls that mutate live values. */
@:access(ScalarCodegen)
class ValueCfg {
	static var mode = 0;
	static var observed = 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f100) {
			observed = ((observed << 3) ^ ctx.v0 ^ ctx.v1 ^ ctx.a0 ^ ctx.cycles) | 0;
			ctx.v0 = 44; ctx.v1 = -77; ctx.a0 = 2;
			return true;
		} else {}
		return mode == 0 ? ValueCfgReference.dispatch(addr, ctx)
			: mode == 1 ? ValueCfgBaseline.dispatch(addr, ctx) : ValueCfgOptimized.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, x:Int, y:Int, kind:Int, entry:Int, variant:Int):Void {
		ScalarCodegen.prepare(ctx, x, y, false); mode = variant; observed = 0;
		// Keep legacy loop fixtures finite while testing pure arithmetic at full signed edges.
		if (kind == 2 || kind == 4) ctx.a0 = (x & 3) + 1; else {}
		ctx.a2 = 0x80040000; ctx.a3 = 3;
		for (n in 0...8) Memory.write32(ctx.a2 + (n << 2), ((x ^ y) + n) | 0);
		ctx.t0 = ctx.a2; // Valid incoming base for span fixture's public interior entries.
	}
	static function run(ctx:CpuState, kind:Int, entry:Int, frequency:Int):Void {
		if (frequency < 0) {
			switch(mode) {
				case 0: ValueCfgReference.run(kind, ctx, entry);
				case 1: ValueCfgBaseline.run(kind, ctx, entry);
				case _: ValueCfgOptimized.run(kind, ctx, entry);
			}
		} else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, ValueCfgOptimized.BASE + (kind << 12), 4)) {
				observed = ((observed << 1) ^ ctx.v0 ^ ctx.v1 ^ ctx.cycles) | 0;
				if (++slices > 100) { Conf.expect('CFG resume progress', 0, 1); return; } else {}
			}
		}
	}
	static function compare(a:CpuState, b:CpuState, x:Int, y:Int, kind:Int, entry:Int, frequency:Int):Void {
		prepare(a, x, y, kind, entry, 0); run(a, kind, entry, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final trace = observed; final yields = Cooperative.yields;
		final word = Memory.read32(0x80040000);
		for (variant in 1...3) {
			prepare(b, x, y, kind, entry, variant); run(b, kind, entry, frequency);
			ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('CFG boundary trace', observed, trace); Conf.expect('CFG yield count', Cooperative.yields, yields);
			Conf.expect('CFG store sees published value', Memory.read32(0x80040000), word);
		}
		if (kind == 18 && entry == 0) {
			Conf.expect('call writes not overwritten by cached state', b.v0, 47);
			Conf.expect('second call result survives region', b.v1, -77);
		} else {}
	}
	static function due(ctx:CpuState, variant:Int):Void {
		prepare(ctx, 13, 13, 20, 0, variant); ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 8); Kernel.haltAt = Kernel.vblankCount + 1;
		run(ctx, 20, 0, -1);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); Runtime.boot(a);
		Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (kind in 0...ValueCfgOptimized.COUNT) for (entry in 0...ValueCfgOptimized.entries(kind))
			for (x in samples) for (y in samples) compare(a, b, x, y, kind, entry, -1);
		for (kind in [0, 18, 19, 20, 21]) for (frequency in 0...4) compare(a, b, -1, -1, kind, 0, frequency);
		due(a, 0); final ni = Runtime.insns; final nb = Runtime.blocks; final trace = observed;
		for (variant in 1...3) {
			due(b, variant); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('CFG pump sees published state', observed, trace);
			Conf.expect('CFG loop pump halts', b.unwindToken, Kernel.UNWIND_HALT);
		}
		Conf.report('ValueCfg');
	}
}
