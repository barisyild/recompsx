import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;
import gte.Gte;

/**
	GTE operations and LWL/LWR in recovered scalar bodies (ADR-0044, TestScalarCop) against the
	original guest blocks: the register file in program order, GTE effects on one arm of a CFG, the
	SXY FIFO and the computed registers, unaligned loads at every alignment and across stores, a
	GTE child call and a GTE projection. Every entry; RAM, its mirrors, the scratchpad and the
	boundaries where preflight fails; cooperative slices, entry events, an MMIO fallback and existing
	unwinds. Compared: the CPU state, guest memory and all 64 GTE registers.
**/
@:access(ScalarCodegen)
class ScalarCop {
	static var optimized = false;
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		return optimized ? CopOptimized.dispatch(addr, ctx) : CopReference.dispatch(addr, ctx);
	}
	static function resume(fn:Int, entry:Int, ctx:CpuState):Void {
		if (optimized) CopOptimized.resume(fn, entry, ctx); else CopReference.resume(fn, entry, ctx);
	}
	/** Every GTE register from one seed: control first (what RTPS and SQR read), then data. */
	static function seed(value:Int):Void {
		var x = value ^ 0x5bd1e995;
		for (r in 0...32) {
			x = (shim.IntMath.mul(x, 1103515245) + 12345) | 0;
			// Half the words small, so the transforms both saturate and stay in range.
			Gte.writeControl(r, (r & 1) == 0 ? x : x >> 6);
		}
		for (r in 0...32) {
			x = (shim.IntMath.mul(x, 1103515245) + 12345) | 0;
			Gte.writeData(r, x);
		}
	}
	static function state(into:Array<Int>):Void {
		for (r in 0...32) { into[r] = Gte.readData(r); into[32 + r] = Gte.readControl(r); }
	}
	static function prepare(ctx:CpuState, at:Int, value:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, at, value, opt); optimized = opt;
		ctx.a2 = value ^ 0x13572468; ctx.a3 = (value + (value << 1)) | 0; ctx.s0 = ctx.ra;
		for (k in 0...48) {
			final addr = (at + k - 8) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131 + (value & 7)) & 255); else {}
		}
		seed(value);
	}
	static function memory(at:Int, bytes:Array<Int>, record:Bool):Void {
		for (k in 0...48) {
			final addr = (at + k - 8) | 0;
			final value = Memory.isPlainMemory(addr) ? Memory.read8u(addr) : 0;
			if (record) bytes[k] = value; else Conf.expect('GTE/unaligned helper memory', value, bytes[k]);
		}
	}
	static function run(ctx:CpuState, kind:Int, entry:Int, frequency:Int):Int {
		final addr = CopOptimized.entryAddress(kind, entry);
		var trace = 0;
		if (frequency < 0) dispatch(addr, ctx); else {
			Cooperative.every = frequency; var slices = 0;
			while (Cooperative.step(ctx, addr, 4)) {
				trace = ((trace << 5) ^ (trace >>> 27) ^ ctx.t0 ^ ctx.a0 ^ ctx.v0 ^ ctx.cycles ^ ctx.pc) | 0;
				if (++slices > 150) { Conf.expect('GTE/unaligned resume progress', 0, 1); return 0; } else {}
				// Guest memory and the GTE both change while the callee waits at its entry.
				final p = ctx.a0 & ~3;
				if (Memory.isPlainMemory(p)) Memory.write32(p, (Memory.read32(p) + 0x01010101) | 0); else {}
				Gte.writeData(9, (Gte.readData(9) + 77) | 0);
			}
		}
		return trace;
	}
	static function compare(a:CpuState, b:CpuState, at:Int, value:Int, kind:Int, entry:Int, frequency:Int,
			bytes:Array<Int>, gteA:Array<Int>, gteB:Array<Int>):Void {
		prepare(a, at, value, false); final trace = run(a, kind, entry, frequency);
		final ni = Runtime.insns; final nb = Runtime.blocks; final yields = Cooperative.yields;
		memory(at, bytes, true); state(gteA);
		prepare(b, at, value, true); final actual = run(b, kind, entry, frequency);
		ScalarCodegen.compare(a, b, ni, nb); memory(at, bytes, false); state(gteB);
		for (r in 0...64) Conf.expect('GTE register', gteB[r], gteA[r]);
		Conf.expect('GTE/unaligned checkpoints', Cooperative.yields, yields);
		Conf.expect('GTE/unaligned suspended state', actual, trace);
	}
	static function due(ctx:CpuState, kind:Int, at:Int):Void {
		ctx.cycles = 0; Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, at); Kernel.haltAt = Kernel.vblankCount + 1;
		run(ctx, kind, 0, -1);
	}
	/** LWL/LWR on the CD-ROM's registers: preflight fails and the original reads run, in order. */
	static function fifo(ctx:CpuState, opt:Bool):Int {
		prepare(ctx, 0x1f801800, 1, opt);
		ctx.cycles = 0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0); cd.Cdrom.write8(0x1f801801, 0x19, 0); cd.Cdrom.onEvent(ctx);
		run(ctx, 5, 0, -1);
		return Memory.read8u(0x1f801801);
	}
	public static function main():Void {
		final a = new CpuState(); final b = new CpuState(); final bytes = [for (_ in 0...48) 0];
		final gteA = [for (_ in 0...64) 0]; final gteB = [for (_ in 0...64) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump = false; Kernel.reportOps = false;
		Gte.init();
		final pointers = [0x80040020, 0xa0040020, 0x00040020, 0x1f800040, 0x9f800040, 0x801ffff8, 0x1f8003f8, 0x80200000];
		final unaligned = [0x80040021, 0x80040022, 0x80040023, 0x1f800041, 0x1f800043, 0x801ffffd, 0x801fffff, 0x1f8003fe];
		final numbers = [0, 1, -1, 0x7fff, -32768, 0x12345678, 0x80000000, 0x00ff00ff];
		for (kind in 0...CopOptimized.KINDS) {
			final list = kind == 1 || kind == 7 || kind == 11 ? pointers : (kind == 5 || kind == 6 ? pointers.concat(unaligned) : numbers);
			for (at in list) for (value in [0, -1, 0x80000000, 0x7fffffff, 0x12345678])
				for (entry in 0...CopOptimized.entryCount(kind)) compare(a, b, at, value, kind, entry, -1, bytes, gteA, gteB);
		}
		for (kind in 0...CopOptimized.KINDS) for (value in [0, -1]) for (frequency in 0...4)
			compare(a, b, 0x80040020, value, kind, 0, frequency, bytes, gteA, gteB);
		for (kind in 0...CopOptimized.KINDS) for (offset in 0...40) {
			prepare(a, 0x80040020, -1, false); due(a, kind, offset);
			final ni = Runtime.insns; final nb = Runtime.blocks; memory(0x80040020, bytes, true); state(gteA);
			prepare(b, 0x80040020, -1, true); due(b, kind, offset);
			ScalarCodegen.compare(a, b, ni, nb); memory(0x80040020, bytes, false); state(gteB);
			for (r in 0...64) Conf.expect('GTE register after an entry event', gteB[r], gteA[r]);
		}
		{
			final next = fifo(a, false); final ni = Runtime.insns; final nb = Runtime.blocks;
			final actual = fifo(b, true); ScalarCodegen.compare(a, b, ni, nb);
			Conf.expect('unaligned fallback keeps FIFO order', actual, next);
		}
		for (kind in 0...CopOptimized.KINDS) {
			prepare(a, 0x80040020, -1, false); a.unwindToken = 1; run(a, kind, 0, -1);
			final insns = Runtime.insns; final blocks = Runtime.blocks; memory(0x80040020, bytes, true); state(gteA);
			prepare(b, 0x80040020, -1, true); b.unwindToken = 1; run(b, kind, 0, -1);
			ScalarCodegen.compare(a, b, insns, blocks); memory(0x80040020, bytes, false); state(gteB);
			for (r in 0...64) Conf.expect('GTE register under an existing unwind', gteB[r], gteA[r]);
		}
		// Independent results: the pair is the unaligned word, each half merges into its input.
		prepare(b, 0x80040021, 0, true); dispatch(CopOptimized.entryAddress(5, 0), b);
		Conf.expect('lwr/lwl pair is the unaligned word', b.v0, Memory.read8u(0x80040021) | (Memory.read8u(0x80040022) << 8)
			| (Memory.read8u(0x80040023) << 16) | (Memory.read8u(0x80040024) << 24));
		Conf.report('ScalarCop');
	}
}
