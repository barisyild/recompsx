import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Full architectural comparisons plus callback observations, not just final return values. */
@:access(ScalarCodegen)
class ValueRegions {
	static var mode = 0;
	static var observations = 0;
	static function address(kind:Int):Int return (ValuesOptimized.BASE + (kind << 12)) | 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f100 || addr == 0x8000f104 || addr == 0x8000f108) {
			observations = ((observations << 5) ^ (observations >>> 27) ^ ctx.v0 ^ ctx.v1 ^ ctx.t0 ^ ctx.a0 ^ ctx.cycles) | 0;
			if (addr == 0x8000f100) { ctx.v1 = 7; ctx.a0 = -123; } else {}
			return true;
		} else {}
		return mode == 0 ? ValuesReference.dispatch(addr, ctx)
			: mode == 1 ? ValuesBaseline.dispatch(addr, ctx) : ValuesOptimized.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, x:Int, y:Int, kind:Int, variant:Int):Void {
		ScalarCodegen.prepare(ctx, x, y, false); mode = variant; observations = 0;
		ctx.a2 = 0x80040000; ctx.a3 = 3;
		for (n in 0...8) Memory.write32(ctx.a2 + (n << 2), (x ^ y) + n | 0);
		if (kind == 4) {
			ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
			cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
			ctx.a3 = 0x1f801801;
		} else {}
	}
	static function run(ctx:CpuState, kind:Int, frequency:Int, offset:Int):Void {
		if (frequency < 0) { dispatch((address(kind) + offset) | 0, ctx); } else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, address(kind), 4)) {
				observations = ((observations << 3) ^ ctx.cycles ^ ctx.v0 ^ ctx.v1 ^ ctx.t0 ^ ctx.a0) | 0;
				if (++slices > 100) { Conf.expect('value region resume progress', 0, 1); return; } else {}
			}
		}
	}
	static function due(ctx:CpuState, variant:Int):Void {
		prepare(ctx, 13, -17, 12, variant); ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 6); Kernel.haltAt = Kernel.vblankCount + 1;
		dispatch(address(12), ctx);
	}
	static function compare(a:CpuState, b:CpuState, x:Int, y:Int, kind:Int, frequency:Int, offset:Int):Void {
		prepare(a, x, y, kind, 0); run(a, kind, frequency, offset);
		final ni = Runtime.insns; final nb = Runtime.blocks; final observed = observations; final yields = Cooperative.yields;
		final word = Memory.read32(a.a2); final nextByte = kind == 4 ? Memory.read8u(a.a3) : 0;
		for (variant in 1...3) {
			prepare(b, x, y, kind, variant); run(b, kind, frequency, offset);
			ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('boundary observations', observations, observed); Conf.expect('boundary suspension count', Cooperative.yields, yields);
			Conf.expect('published store operand', Memory.read32(b.a2), word);
			if (kind == 4) Conf.expect('discarded FIFO load preserved', Memory.read8u(b.a3), nextByte); else {}
		}
		if (offset == 0) switch(kind) {
			case 0: Conf.expect('SSA chain', b.v0, (((x + 7) | 0) ^ y) + y | 0); Conf.expect('restored intermediate', b.t0, ((x + 7) | 0) ^ y);
			case 1: Conf.expect('swap first', b.a0, y); Conf.expect('swap second', b.a1, x); Conf.expect('swap saved', b.t0, x);
			case 2: Conf.expect('common value', b.v1, x ^ y); Conf.expect('common operands', b.t0, ((x ^ y) + (x ^ y)) | 0);
			case 3: Conf.expect('callback output never overwritten by stale state', b.v1, 7); Conf.expect('new region reads callback input', b.a0, -120);
			case 4: Conf.expect('FIFO used second read', b.v0, 9); Conf.expect('all pure instructions charged', b.t0, (x + 6) | 0);
			case 7: Conf.expect('stepped span', b.v1, ((x ^ y) + 3) | 0); Conf.expect('refreshed span', b.t1, ((x ^ y) + 1) | 0);
			case 8: Conf.expect('predicate before slot', b.v0, x == y ? 2 : 1); Conf.expect('slot update', b.a0, (x + 7) | 0);
			case 9: Conf.expect('unproved overflow stays original', b.v0, (x + 1) | 0); Conf.expect('proved overflow-safe part', b.t1, (y & 255) + 7);
			case 11: Conf.expect('bounded regions compose', b.v0, 0x80000029);
			case 12: Conf.expect('loop body values', b.v0, 0x8000000a);
			case _:
		} else {}
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); Runtime.boot(a);
		Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		final samples = [0, 1, -1, 0x7fffffff, 0x80000000, 0x80000001, 0x12345678];
		for (x in samples) for (y in samples) for (kind in 0...ValuesOptimized.COUNT) compare(a, b, x, y, kind, -1, 0);
		for (kind in [3, 8, 12]) for (frequency in 0...4) compare(a, b, 0x7fffffff, -1, kind, frequency, 0);
		for (offset in [16, 28]) compare(a, b, -17, -17, 8, -1, offset);
		due(a, 0); final ni = Runtime.insns; final nb = Runtime.blocks; final observed = observations;
		for (variant in 1...3) {
			due(b, variant); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('due pump after reconstructed values', observations, observed);
			Conf.expect('pump halts before next call', b.unwindToken, Kernel.UNWIND_HALT);
			Conf.expect('last completed pure region remains visible', b.v0, 0x80000004);
		}
		Conf.report('ValueRegions');
	}
}
