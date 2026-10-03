import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Borrowed-span calls against original guest blocks, including public entries and resumes. */
@:access(ScalarCodegen)
class ScalarBorrow {
	static var optimized = false;
	static var unknownCalls = 0;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f020) { unknownCalls++; ctx.a0 = ctx.a1; ctx.s2 = ctx.a1; return true; } else {}
		return optimized ? BorrowOptimized.dispatch(addr, ctx) : BorrowReference.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void {
		if (optimized) BorrowOptimized.resume(fn, entry, ctx); else BorrowReference.resume(fn, entry, ctx);
	}
	static function prepare(ctx:CpuState, at:Int, other:Int, value:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, at, other, opt); optimized = opt; unknownCalls = 0;
		ctx.a2 = value; ctx.a3 = 2; ctx.s0 = ctx.ra; ctx.s2 = at; ctx.s3 = other;
		for (base in [0x80040000, at, other]) for (k in 0...48) {
			final addr = (base + k - 8) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131 + (base == other && other != at ? 17 : 0)) & 255); else {}
		}
	}
	static function memory(at:Int, other:Int, bytes:Array<Int>, record:Bool):Void {
		var i = 0;
		for (base in [at, other]) for (k in 0...48) {
			final addr = (base + k - 8) | 0;
			final value = Memory.isPlainMemory(addr) ? Memory.read8u(addr) : 0;
			if (record) bytes[i] = value; else Conf.expect('borrowed call memory', value, bytes[i]);
			i++;
		}
	}
	static function run(ctx:CpuState, kind:Int, entry:Int, frequency:Int):Int {
		final addr = BorrowOptimized.entryAddress(kind, entry);
		var trace = 0;
		if (frequency < 0) dispatch(addr, ctx); else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, addr, 4)) {
				trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.t0 ^ ctx.a0 ^ ctx.v0 ^ ctx.cycles ^ ctx.pc) | 0;
				if (++slices > 150) { Conf.expect('borrow resume progress', 0, 1); return 0; } else {}
				ctx.a0 = ctx.a1; ctx.s2 = ctx.a1; Memory.write32(ctx.a1, 0xabcdef01);
			}
		}
		return trace;
	}
	static function compare(a:CpuState, b:CpuState, at:Int, other:Int, value:Int, kind:Int, entry:Int, frequency:Int, bytes:Array<Int>):Void {
		prepare(a, at, other, value, false); if (kind >= 16 && entry > 0) a.a0 = other; else {} final trace = run(a, kind, entry, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields; final calls = unknownCalls;
		memory(at, other, bytes, true);
		prepare(b, at, other, value, true); if (kind >= 16 && entry > 0) b.a0 = other; else {} final actual = run(b, kind, entry, frequency);
		ScalarCodegen.compare(a, b, ni, nb); memory(at, other, bytes, false);
		Conf.expect('borrow checkpoints', Cooperative.yields, yields);
		Conf.expect('borrow suspended state', actual, trace);
		Conf.expect('borrow preserves prior unknown call', unknownCalls, calls);
	}
	static function due(ctx:CpuState, kind:Int, at:Int = 3):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, at); Kernel.haltAt = Kernel.vblankCount + 1;
		run(ctx, kind, 0, -1);
	}
	static function fifo(ctx:CpuState, opt:Bool, kind:Int = 0):Int {
		prepare(ctx, 0x1f801801, 0x80045020, 1, opt);
		ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		run(ctx, kind, 0, -1);
		return Memory.read8u(0x1f801801);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); final bytes = [for (_ in 0...96) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		prepare(b, 0x80040020, 0x80045020, -1, true); run(b, 0, 0, -1);
		Conf.expect('borrow independent first byte', b.v0, 171);
		Conf.expect('borrow independent second byte', b.v1, 63);
		prepare(b, 0x80040020, 0x80040020, -1, true); run(b, 8, 0, -1);
		Conf.expect('borrow aliases observe preceding store', b.v0, -1);
		Conf.expect('borrow store remains in guest RAM', Memory.read32(0x80040020), -1);
		// Deduplicated overlay/shard adapters forward both raw spans without dereferencing
		// invalid ones. The owner still owns the slow checkpoint and every selected effect.
		for (other in [0x80040020, 0x80045020]) for (valid in [false, true]) {
			prepare(a, 0x80040020, other, -1, false); dispatch(BorrowReference.BASE + (8 << 12) + 128, a);
			final insns = Runtime.insns; final blocks = Runtime.blocks; memory(0x80040020, other, bytes, true);
			prepare(b, 0x80040020, other, -1, true);
			BorrowForward.f_80148080_withSpans(b, valid ? Memory.span(b.a0, 0, 7) : Memory.spanNone(),
				valid ? Memory.span(b.a1, 0, 7) : Memory.spanNone());
			ScalarCodegen.compare(a, b, insns, blocks); memory(0x80040020, other, bytes, false);
		}
		for (at in [0x80040020, 0xa0040020, 0x1f800040, 0x9f800040, 0x801ffffc, 0x1f8003fc])
			for (other in [at, (at + 4) | 0, at ^ 0x20000000, 0x80045020])
				for (value in [0, -1, 0x80000000, 0x7fffffff, 0x12345678])
					for (kind in 0...BorrowOptimized.COUNT)
						for (entry in 0...BorrowOptimized.entryCount(kind)) compare(a, b, at, other, value, kind, entry, -1, bytes);
		for (kind in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 14, 15, 16, 17, 18, 19, 21, 25, 26, 28, 29, 30, 31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46]) for (value in [0, -1]) for (frequency in 0...4)
			compare(a, b, 0x80040020, 0x80045020, value, kind, 0, frequency, bytes);
		for (kind in [0, 4, 8, 9, 15, 18, 21, 28, 29, 30]) {
			prepare(a, 0x80040020, 0x80045020, -1, false); due(a, kind);
			final ni = Runtime.insns; final nb = Runtime.blocks; memory(0x80040020, 0x80045020, bytes, true);
			prepare(b, 0x80040020, 0x80045020, -1, true); due(b, kind);
			ScalarCodegen.compare(a, b, ni, nb); memory(0x80040020, 0x80045020, bytes, false);
			Conf.expect('due callee retains old result', b.v0, 0x80000001);
		}
		for (kind in 32...BorrowOptimized.COUNT) {
			prepare(a, 0x80040020, 0x80045020, -1, false); dispatch(BorrowReference.BASE+(kind<<12)+128,a);
			final ni = Runtime.insns; final nb = Runtime.blocks; memory(0x80040020, 0x80045020, bytes, true);
			prepare(b, 0x80040020, 0x80045020, -1, true); dispatch(BorrowOptimized.BASE+(kind<<12)+128,b);
			ScalarCodegen.compare(a,b,ni,nb); memory(0x80040020,0x80045020,bytes,false);
		}
		for (kind in 32...BorrowOptimized.COUNT) for (offset in 0...70) {
			prepare(a, 0x80040020, 0x80045020, -1, false); due(a, kind, offset);
			final ni = Runtime.insns; final nb = Runtime.blocks; memory(0x80040020, 0x80045020, bytes, true);
			prepare(b, 0x80040020, 0x80045020, -1, true); due(b, kind, offset);
			ScalarCodegen.compare(a, b, ni, nb); memory(0x80040020, 0x80045020, bytes, false);
		}
		for (kind in [0,33,43]) {
			final next = fifo(a, false, kind); final ni = Runtime.insns; final nb = Runtime.blocks;
			final actual = fifo(b, true, kind); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('borrow fallback preserves FIFO order', actual, next);
			if (kind == 33) Conf.expect('dead outputs still consume both FIFO reads', actual, 0xc0);
			if (kind == 43) Conf.expect('fresh preflight consumes no FIFO bytes', actual, 0x19);
		}
		for (kind in [0, 7, 8, 9,32,33,34,35,38,40,41,42,43,44,45,46]) {
			prepare(a, 0x80040020, 0x80045020, -1, false); a.unwindToken = 1; run(a, kind, 0, -1);
			final insns = Runtime.insns; final blocks = Runtime.blocks; memory(0x80040020, 0x80045020, bytes, true);
			prepare(b, 0x80040020, 0x80045020, -1, true); b.unwindToken = 1; run(b, kind, 0, -1);
			ScalarCodegen.compare(a, b, insns, blocks); memory(0x80040020, 0x80045020, bytes, false);
		}
		Conf.report('ScalarBorrow');
	}
}
