import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Every generated helper is compared with the original instruction stream, including RAM
    aliases, old load values, mixed widths, failed preflight and entry/resume observations. */
@:access(ScalarCodegen)
class ScalarEffects {
	static var optimized = false;
	static function dispatch(addr:Int, ctx:CpuState):Bool
		return optimized ? EffectsOptimized.dispatch(addr, ctx) : EffectsReference.dispatch(addr, ctx);
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void { dispatch(fn, ctx); }
	static function prepare(ctx:CpuState, a:Int, b:Int, x:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, a, b, opt); optimized = opt;
		ctx.a2 = x; ctx.a3 = x ^ 0x67891234; ctx.sp = 0x80042020;
		for (base in [a, b, ctx.sp]) for (k in 0...48) {
			final addr = (base + k - 16) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131) & 255); else {}
		}
	}
	static function memory(ctx:CpuState, a:Int, b:Int, values:Array<Int>, record:Bool):Void {
		var i = 0;
		for (base in [a, b, 0x80042020]) for (k in 0...48) {
			final addr = (base + k - 16) | 0;
			final value = Memory.isPlainMemory(addr) ? Memory.read8u(addr) : 0;
			if (record) values[i] = value; else Conf.expect('ordered memory byte', value, values[i]);
			i++;
		}
	}
	static function run(ctx:CpuState, kind:Int, frequency:Int):Void {
		final fn = EffectsOptimized.BASE + (kind << 12);
		if (frequency < 0) { dispatch(fn, ctx); } else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, fn, 4)) {
				if (++slices > 50) { Conf.expect('effect helper resume progress', 0, 1); return; } else {}
				// A guard taken before resumption would read stale memory here.
				Memory.write32(ctx.a0, 0x10293847);
			}
		}
	}
	static function compare(a:CpuState, b:CpuState, at:Int, other:Int, x:Int, kind:Int, frequency:Int, values:Array<Int>):Void {
		prepare(a, at, other, x, false); final old = Memory.read32(at); run(a, kind, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields; memory(a, at, other, values, true);
		prepare(b, at, other, x, true); run(b, kind, frequency);
		ScalarCodegen.compare(a, b, ni, nb); memory(b, at, other, values, false);
		Conf.expect('effect checkpoints', Cooperative.yields, yields);
		if (frequency < 0) {
			if (kind == 0 || kind == 1) Conf.expect('word written by scalar helper', Memory.read32(at), x); else {}
			if (kind == 1) Conf.expect('return retains load before aliased store', b.v0, old); else {}
			if (kind == 2) Conf.expect('load observes preceding possibly aliased store', b.v0, Memory.read32(other)); else {}
			if (kind == 6) Conf.expect('read-modify-write runs once', Memory.read32(at), (old + 1) | 0); else {}
			if (kind == 11) {
				Conf.expect('stack pointer restored', b.sp, 0x80042020);
				Conf.expect('stack bytes remain observable', Memory.read32(0x80042014), x);
			} else {}
		} else {}
	}
	static function device(ctx:CpuState, opt:Bool, write:Bool, repeated:Bool = false):Void {
		prepare(ctx, 0x80040020, write ? 0x1f801074 : 0x1f801801, 0x123, opt);
		ctx.cycles = 0; Scheduler.init(ctx); Memory.write32(ctx.a0, 41); Memory.write32(0x1f801074, 0);
		cd.Cdrom.init(); cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		run(ctx, repeated ? 30 : write ? 9 : 8, -1);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); final bytes = [for (_ in 0...144) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		for (at in [0x80040020, 0xa0040020, 0x1f800040, 0x9f800040, 0x801ffff8, 0x801ffffc])
			for (other in [at, (at + 4) | 0, at ^ 0x20000000, 0x80045020])
				for (x in [0, 1, -1, 0x7fffffff, 0x80000000, 0x12345678, 0x00008080, 0x00800000])
					for (kind in 0...EffectsOptimized.COUNT) {
						// +2 MB is a RAM mirror; scratchpad has no such mirror.
						if (kind != 31 || (at & 0x1ffffc00) != 0x1f800000) compare(a, b, at, other, x, kind, -1, bytes); else {}
					}
		for (kind in [0, 1, 3, 5, 7, 11, 13, 15, 19, 20, 23, 26, 28, 31]) for (frequency in 0...4) compare(a, b, 0x80040020, 0xa0040020, -1, kind, frequency, bytes);
		for (write in [false, true]) {
			device(a, false, write); final ni = Runtime.insns; final nb = Runtime.blocks;
			final next = Memory.read8u(0x1f801801); final mask = Memory.read32(0x1f801074);
			device(b, true, write); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('failed preflight writes RAM only once', Memory.read32(b.a0), 42);
			Conf.expect('failed preflight retains discarded FIFO read', Memory.read8u(0x1f801801), next);
			Conf.expect('failed preflight retains I/O write', Memory.read32(0x1f801074), mask);
			if (!write) Conf.expect('FIFO second byte', b.v1, 9); else Conf.expect('I/O mask written', mask, 0x123);
		}
		device(a, false, false, true); final repeatedNi = Runtime.insns; final repeatedNb = Runtime.blocks;
		final repeatedNext = Memory.read8u(0x1f801801);
		device(b, true, false, true); ScalarCodegen.compare(a, b, repeatedNi, repeatedNb);
		Conf.expect('repeated FIFO loads stay distinct after failed preflight', b.v1, 9);
		Conf.expect('repeated FIFO loads consume both bytes', Memory.read8u(0x1f801801), repeatedNext);
		prepare(b, 0x80040020, 0x80045020, 31, true);
		Conf.expect('both plain bases accepted', EffectsOptimized.accepts(b) ? 1 : 0, 1);
		b.a1 = 0x80045021;
		Conf.expect('second unaligned base rejected without dereference', EffectsOptimized.accepts(b) ? 1 : 0, 0);
		// A forwarded setter is genuinely Void and still performs its memory effect.
		EffectsForward.effect0_value(57, Memory.span(0x80040020, 0, 3));
		Conf.expect('forwarded void helper', Memory.read32(0x80040020), 57);
		for (opt in [false, true]) {
			prepare(b, 0x80040020, 0x80045020, 13, opt); Memory.write32(b.a0, 71);
			b.cycles = 0; Scheduler.init(b); for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(b, slot);
			Scheduler.schedule(b, Scheduler.VBLANK_START, 0); Kernel.haltAt = Kernel.vblankCount + 1; run(b, 0, -1);
			Conf.expect('pump halts before first scalar store', Memory.read32(b.a0), 71);
			Conf.expect('halt charges no scalar instructions', Runtime.insns, 0);
		}
		Conf.report('ScalarEffects');
	}
}
