import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import core.ScalarResult;
import kernel.Kernel;
import mem.Memory;

/** Executes real emitted CFG SSA and original bodies, including public interior entries. */
@:access(ScalarCodegen)
class ScalarCfg {
	static var optimized = false;
	static function address(kind:Int):Int return (CfgOptimized.BASE + (kind << 12)) | 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool return optimized ? CfgOptimized.dispatch(addr, ctx) : CfgReference.dispatch(addr, ctx);
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, x:Int, y:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, x, y, opt); optimized = opt;
		ctx.v0 = ~x; ctx.a2 = 0x80040000; Memory.write8(ctx.a2, 173);
		ScalarResult.accounting = -12345;
	}
	static function taken(kind:Int, x:Int, y:Int):Bool {
		return switch (kind) {
			case 1: x != y;
			case 2: x <= 0;
			case 3 | 6: x > 0;
			case 4: x < 0;
			case 5: x >= 0;
			case 7: ~x == y;
			case _: x == y;
		};
	}
	static function expected(kind:Int, x:Int, y:Int):Int {
		final p = taken(kind, x, y);
		return switch (kind) {
			case 6: (p ? (y - 3) | 0 : (x + 7) | 0) ^ 255;
			case 7: (x + (p ? -2 : 8)) | 0;
			case 8 | 15 | 17: 7;
			case 18: p ? 7 : 9;
			case 9 | 10: ((x & 65535) + (p ? -3 : 7)) | 0;
			case 11: p ? 173 : (x + 7) | 0;
			case 13: (x + 7) | 0;
			case 14: (x ^ 1) == y ? (y - 3) | 0 : ((x ^ 1) + 7) | 0;
			case 16:
				final q = x == y ? (y - 3) | 0 : (x + 7) | 0;
				((q ^ 255) + (q > 0 ? -5 : 5)) | 0;
			case _: p ? (y - 3) | 0 : (x + 7) | 0;
		};
	}
	static function sliced(ctx:CpuState, kind:Int, frequency:Int):Int {
		Cooperative.every = frequency; var n = 0; var trace = 0;
		while (Cooperative.step(ctx, address(kind), 4)) {
			trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.v0 ^ ctx.t0 ^ ctx.s1 ^ ctx.cycles) | 0;
			n++;
			if (n > 100) { Conf.expect('CFG resume progress', 0, 1); return 0; } else {}
		}
		return trace;
	}
	static function due(ctx:CpuState):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 3); Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(address(14), ctx);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, 31, -32, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678, ~0x12345678];
		for (x in samples) for (y in samples) {
			for (kind in 0...CfgOptimized.COUNT) {
				prepare(a, x, y, false); dispatch(address(kind), a);
				final insns = Runtime.insns; final blocks = Runtime.blocks;
				prepare(b, x, y, true); dispatch(address(kind), b);
				ScalarCodegen.compare(a, b, insns, blocks);
				Conf.expect('CFG arithmetic formula', b.v0, expected(kind, x, y));
				if (kind <= 10 || kind >= 14) {
					final p = taken(kind, x, y);
					final q = x == y ? (y - 3) | 0 : (x + 7) | 0;
					final count = kind == 15 || kind == 17 ? 4 : (kind == 18 ? (p ? 4 : 6) : kind == 16 ? 4 + (x == y ? 2 : 3) + (q > 0 ? 2 : 3)
						: kind == 14 ? 10 + (x == y ? 4 : 5) + ((x ^ 1) == y ? 4 : 5)
						: (kind == 6 ? 2 : (kind == 9 || kind == 10 ? 8 : 0)) + (p ? 4 : 5));
					Conf.expect('CFG original instructions', Runtime.insns, count);
					Conf.expect('CFG original cycles', b.cycles, (0x7ffffff0 + count) | 0);
					Conf.expect('CFG original blocks', Runtime.blocks, kind == 18 ? (p ? 2 : 3) : kind == 14 ? 7 : (kind == 6 ? 3 : (kind == 9 || kind == 10 || kind == 16 ? 4 : 2)));
				} else {}
				if (kind == 17 || kind == 18) for (offset in (kind == 17 ? [8, 16] : [8, 16, 24, 32])) {
					prepare(a, x, y, false); dispatch((address(kind) + offset) | 0, a);
					final ni = Runtime.insns; final nb = Runtime.blocks;
					prepare(b, x, y, true); dispatch((address(kind) + offset) | 0, b);
					ScalarCodegen.compare(a, b, ni, nb);
					if (kind == 18 && offset == 24) Conf.expect('entry-zero dead arm remains a public entry', b.v0, 99); else {}
				} else {}
				if (kind <= 8 || kind == 16) for (offset in [8, 20]) {
					prepare(a, x, y, false); dispatch((address(kind) + offset) | 0, a);
					final ni = Runtime.insns; final nb = Runtime.blocks;
					prepare(b, x, y, true); dispatch((address(kind) + offset) | 0, b);
					ScalarCodegen.compare(a, b, ni, nb);
				} else {}
				if (kind == 9) {
					// The projected helper is private to the caller. Public dispatch still writes t0.
					prepare(a, x, y, false); dispatch((address(kind) + 64) | 0, a);
					final ni = Runtime.insns; final nb = Runtime.blocks;
					prepare(b, x, y, true); dispatch((address(kind) + 64) | 0, b);
					ScalarCodegen.compare(a, b, ni, nb); Conf.expect('CFG public scratch result', b.t0, x & 65535);
				} else {}
			}
		}
		for (kind in [0, 6, 9, 13, 14, 16, 17, 18]) for (frequency in 0...4) {
			prepare(a, -1, -1, false); final trace = sliced(a, kind, frequency);
			final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, -1, -1, true); final actual = sliced(b, kind, frequency);
			ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('CFG suspension state', actual, trace); Conf.expect('CFG checkpoints', Cooperative.yields, yields);
		}
		prepare(a, 7, 7, false); due(a); final ni = Runtime.insns; final nb = Runtime.blocks;
		prepare(b, 7, 7, true); due(b); ScalarCodegen.compare(a, b, ni, nb);
		Conf.expect('CFG due event precedes helper', b.v0, ~7);
		Conf.expect('CFG no result returned after entry halt', ScalarResult.accounting, -12345);
		Conf.expect('CFG callable without CpuState', CfgOptimized.cfg0_value(7, 7), 4);
		Conf.expect('CFG selected path accounting', ScalarResult.accounting, (2 << 20) | (4 << 10) | 4);
		Conf.expect('CFG second call replaces accounting', CfgOptimized.cfg0_value(7, 8), 14);
		Conf.expect('CFG second path accounting', ScalarResult.accounting, (2 << 20) | (5 << 10) | 5);
		Conf.report('ScalarCfg');
	}
}
