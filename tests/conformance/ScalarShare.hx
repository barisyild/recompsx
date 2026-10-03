import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/**
	Memory projections shared within one class (ProjectionShare, ADR-0044) against the original
	guest blocks: equal call sites that run an earlier site's pair, the pairs kept apart by one
	difference, and two shared sites in one function. Every public entry of every caller, mirrored
	and boundary addresses, MMIO fallback, cooperative slices, entry events and existing unwinds.
**/
@:access(ScalarCodegen)
class ScalarShare {
	static var optimized = false;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		return optimized ? ShareOptimized.dispatch(addr, ctx) : ShareReference.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void {
		if (optimized) ShareOptimized.resume(fn, entry, ctx); else ShareReference.resume(fn, entry, ctx);
	}
	static function prepare(ctx:CpuState, at:Int, value:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, at, 0x80045020, opt); optimized = opt;
		ctx.a2 = value; ctx.s0 = ctx.ra;
		for (k in 0...48) {
			final addr = (at + k - 8) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131 + (value & 7)) & 255); else {}
		}
	}
	static function memory(at:Int, bytes:Array<Int>, record:Bool):Void {
		for (k in 0...48) {
			final addr = (at + k - 8) | 0;
			final value = Memory.isPlainMemory(addr) ? Memory.read8u(addr) : 0;
			if (record) bytes[k] = value; else Conf.expect('shared projection memory', value, bytes[k]);
		}
	}
	static function run(ctx:CpuState, kind:Int, entry:Int, frequency:Int):Int {
		final addr = ShareOptimized.entryAddress(kind, entry);
		var trace = 0;
		if (frequency < 0) dispatch(addr, ctx); else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, addr, 4)) {
				trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.t0 ^ ctx.a0 ^ ctx.v0 ^ ctx.cycles ^ ctx.pc) | 0;
				if (++slices > 150) { Conf.expect('shared projection resume progress', 0, 1); return 0; } else {}
				Memory.write32(ctx.a0, (Memory.read32(ctx.a0) + 0x01010101) | 0);
			}
		}
		return trace;
	}
	static function compare(a:CpuState, b:CpuState, at:Int, value:Int, kind:Int, entry:Int, frequency:Int, bytes:Array<Int>):Void {
		prepare(a, at, value, false); final trace = run(a, kind, entry, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields;
		memory(at, bytes, true);
		prepare(b, at, value, true); final actual = run(b, kind, entry, frequency);
		ScalarCodegen.compare(a, b, ni, nb); memory(at, bytes, false);
		Conf.expect('shared projection checkpoints', Cooperative.yields, yields);
		Conf.expect('shared projection suspended state', actual, trace);
	}
	static function due(ctx:CpuState, kind:Int, at:Int):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, at); Kernel.haltAt = Kernel.vblankCount + 1;
		run(ctx, kind, 0, -1);
	}
	static function fifo(ctx:CpuState, opt:Bool, kind:Int):Int {
		prepare(ctx, 0x1f801801, 1, opt);
		ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		run(ctx, kind, 0, -1);
		return Memory.read8u(0x1f801801);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); final bytes = [for (_ in 0...48) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		for (at in [0x80040020, 0xa0040020, 0x00040020, 0x1f800040, 0x9f800040, 0x801ffffc, 0x1f8003fc])
			for (value in [0, -1, 0x80000000, 0x7fffffff, 0x12345678])
				for (kind in 0...ShareOptimized.KINDS)
					for (entry in 0...ShareOptimized.entryCount(kind)) compare(a, b, at, value, kind, entry, -1, bytes);
		for (kind in 0...ShareOptimized.KINDS) for (value in [0, -1]) for (frequency in 0...4)
			compare(a, b, 0x80040020, value, kind, 0, frequency, bytes);
		for (kind in 0...ShareOptimized.KINDS) for (offset in 0...40) {
			prepare(a, 0x80040020, -1, false); due(a, kind, offset);
			final ni = Runtime.insns; final nb = Runtime.blocks; memory(0x80040020, bytes, true);
			prepare(b, 0x80040020, -1, true); due(b, kind, offset);
			ScalarCodegen.compare(a, b, ni, nb); memory(0x80040020, bytes, false);
		}
		for (kind in 0...ShareOptimized.KINDS) {
			final next = fifo(a, false, kind); final ni = Runtime.insns; final nb = Runtime.blocks;
			final actual = fifo(b, true, kind); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('shared projection fallback keeps FIFO order', actual, next);
		}
		for (kind in 0...ShareOptimized.KINDS) {
			prepare(a, 0x80040020, -1, false); a.unwindToken = 1; run(a, kind, 0, -1);
			final insns = Runtime.insns; final blocks = Runtime.blocks; memory(0x80040020, bytes, true);
			prepare(b, 0x80040020, -1, true); b.unwindToken = 1; run(b, kind, 0, -1);
			ScalarCodegen.compare(a, b, insns, blocks); memory(0x80040020, bytes, false);
		}
		Conf.report('ScalarShare');
	}
}
