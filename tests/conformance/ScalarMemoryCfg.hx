import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import core.ScalarResult;
import kernel.Kernel;
import mem.Memory;

/** Generated predicated memory SSA against the original blocks, at every public entry. */
@:access(ScalarCodegen)
class ScalarMemoryCfg {
	static var optimized = false;
	static function dispatch(addr:Int, ctx:CpuState):Bool return optimized ? MemoryCfgOptimized.dispatch(addr, ctx) : MemoryCfgReference.dispatch(addr, ctx);
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void {
		if (optimized) MemoryCfgOptimized.resume(fn, entry, ctx); else MemoryCfgReference.resume(fn, entry, ctx);
	}
	static function prepare(ctx:CpuState, at:Int, other:Int, x:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, at, other, opt); optimized = opt;
		ctx.a2 = x; ctx.a3 = x ^ 0x80765432; ctx.t0 = (at + 4) | 0;
		ScalarResult.accounting = -12345;
		for (base in [at, other]) for (k in 0...48) {
			final addr = (base + k - 8) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131) & 255); else {}
		}
		// Exercise both outcomes when a branch consumes a loaded value.
		Memory.write32(at, x);
	}
	static function memory(at:Int, other:Int, bytes:Array<Int>, record:Bool):Void {
		var i = 0;
		for (base in [at, other]) for (k in 0...48) {
			final addr = (base + k - 8) | 0;
			final value = Memory.isPlainMemory(addr) ? Memory.read8u(addr) : 0;
			if (record) bytes[i] = value; else Conf.expect('conditional memory byte', value, bytes[i]);
			i++;
		}
	}
	static function run(ctx:CpuState, kind:Int, entry:Int, frequency:Int):Void {
		final addr = MemoryCfgOptimized.entryAddress(kind, entry);
		if (frequency < 0) dispatch(addr, ctx); else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, addr, 4)) {
				if (++slices > 50) { Conf.expect('memory CFG resume progress', 0, 1); return; } else {}
				// Entry work must happen before span capture, branch/load evaluation and effects.
				ctx.a2 ^= 1; Memory.write32(ctx.a0, 0xabcdef01);
			}
		}
	}
	static function compare(a:CpuState, b:CpuState, at:Int, other:Int, x:Int, kind:Int, entry:Int, frequency:Int, bytes:Array<Int>):Void {
		prepare(a, at, other, x, false); run(a, kind, entry, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields; memory(at, other, bytes, true);
		prepare(b, at, other, x, true); run(b, kind, entry, frequency);
		ScalarCodegen.compare(a, b, ni, nb); memory(at, other, bytes, false);
		Conf.expect('memory CFG checkpoints', Cooperative.yields, yields);
		if (entry == 0 && frequency < 0 && kind == 0) {
			Conf.expect('conditional setter independent result', Memory.read32(at), x == 0 ? x : x ^ 0x80765432);
		} else {}
	}
	static function fifo(ctx:CpuState, x:Int, opt:Bool, kind:Int):Void {
		prepare(ctx, 0x80040020, 0x1f801801, x, opt);
		ctx.cycles = 0; Scheduler.init(ctx);
		cd.Cdrom.init(); cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		run(ctx, kind, 0, -1);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); final bytes = [for (_ in 0...96) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		for (at in [0x80040020, 0xa0040020, 0x1f800040, 0x9f800040, 0x801ffffc])
			for (other in [at, (at + 4) | 0, at ^ 0x20000000, 0x80045020])
				for (x in [0, 1, -1, 0x80000000, 0x7fffffff, 0x12345678, 0x80765432])
					for (kind in 0...MemoryCfgOptimized.COUNT)
						for (entry in 0...MemoryCfgOptimized.entryCount(kind)) compare(a, b, at, other, x, kind, entry, -1, bytes);
		for (kind in [0, 3, 4, 5, 6, 8, 13, 16, 17, 18, 20, 21]) for (x in [0, -1]) for (frequency in 0...4)
			compare(a, b, 0x80040020, 0xa0040020, x, kind, 0, frequency, bytes);
		for (kind in [14, 15]) for (x in [0, 1]) {
			fifo(a, x, false, kind); final ni = Runtime.insns; final nb = Runtime.blocks;
			final next = Memory.read8u(0x1f801801); final ram = Memory.read32(a.a0);
			fifo(b, x, true, kind); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('guard fallback retains exactly selected FIFO reads', Memory.read8u(0x1f801801), next);
			Conf.expect('guard fallback does not repeat stores', Memory.read32(b.a0), ram);
			Conf.expect('untaken FIFO load consumes no response', next, x == 0 ? 148 : 9);
		}
		for (opt in [false, true]) {
			prepare(b, 0x80040020, 0x80045020, -1, opt); Memory.write32(b.a0, 71);
			b.cycles = 0; Scheduler.init(b); for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(b, slot);
			Scheduler.schedule(b, Scheduler.VBLANK_START, 0); Kernel.haltAt = Kernel.vblankCount + 1; run(b, 0, 0, -1);
			Conf.expect('due pump before conditional store', Memory.read32(b.a0), 71);
			Conf.expect('entry halt charges no instructions', Runtime.insns, 0);
			Conf.expect('entry halt returns no path accounting', ScalarResult.accounting, -12345);
		}
		Conf.report('ScalarMemoryCfg');
	}
}
