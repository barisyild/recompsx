import core.CpuState;
import core.Runtime;
import core.Scheduler;
import mem.Memory;
import kernel.Kernel;
import shim.IntMath;

/** Executes actual generated code. No snapshots substituted for JS/C++ execution. */
class Codegen {
	static var optimized = false;
	static var publishedArgument = 0;
	static var publishedAtPump = 0;
	/** The word an idle wait polls; a vblank callback raises it, as libetc's VSync callback does. */
	static inline var POLL = 0x80040020;

	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f004) {
			publishedAtPump = ctx.v0;
			ctx.v0 = 100;
			ctx.a0 = 3;
			return true;
		} else {}
		if (addr == 0x8000f008) {
			Memory.write32(POLL, (Memory.read32(POLL) + 1) | 0);
			return true;
		} else {}
		if (addr == 0x8000f000) {
			publishedArgument = ctx.a0;
			ctx.s0 = 1234;
			ctx.v0 = 55;
			ctx.pc = 0x80010014;
			ctx.unwindToken = 1;
			return true;
		} else {}
		if (optimized) return CodegenOptimized.dispatch(addr, ctx);
		else return CodegenReference.dispatch(addr, ctx);
	}

	public static function reset(ctx:CpuState):Void {
		Memory.machine = ctx;
		ctx.at = 0; ctx.v0 = 0; ctx.v1 = 0;
		ctx.a0 = 0; ctx.a1 = 0; ctx.a2 = 0; ctx.a3 = 0;
		ctx.t0 = 0; ctx.t1 = 0; ctx.t2 = 0; ctx.t3 = 0;
		ctx.t4 = 0; ctx.t5 = 0; ctx.t6 = 0; ctx.t7 = 0;
		ctx.s0 = 0; ctx.s1 = 0; ctx.s2 = 0; ctx.s3 = 0;
		ctx.s4 = 0; ctx.s5 = 0; ctx.s6 = 0; ctx.s7 = 0;
		ctx.t8 = 0; ctx.t9 = 0; ctx.k0 = 0; ctx.k1 = 0;
		ctx.gp = 0; ctx.sp = 0x801fff00; ctx.fp = 0; ctx.ra = 0x8000ffff;
		ctx.hi = 0; ctx.lo = 0; ctx.pc = 0; ctx.cycles = 0;
		ctx.nextEvent = 0x40000000; ctx.unwindToken = 0; ctx.sr = 0; ctx.cause = 0;
	}

	public static function compare(a:CpuState, b:CpuState):Void {
		Conf.expect("at", b.at, a.at); Conf.expect("v0", b.v0, a.v0); Conf.expect("v1", b.v1, a.v1);
		Conf.expect("a0", b.a0, a.a0); Conf.expect("a1", b.a1, a.a1);
		Conf.expect("a2", b.a2, a.a2); Conf.expect("a3", b.a3, a.a3);
		Conf.expect("t0", b.t0, a.t0); Conf.expect("t1", b.t1, a.t1);
		Conf.expect("t2", b.t2, a.t2); Conf.expect("t3", b.t3, a.t3);
		Conf.expect("t4", b.t4, a.t4); Conf.expect("t5", b.t5, a.t5);
		Conf.expect("t6", b.t6, a.t6); Conf.expect("t7", b.t7, a.t7);
		Conf.expect("s0", b.s0, a.s0); Conf.expect("s1", b.s1, a.s1);
		Conf.expect("s2", b.s2, a.s2); Conf.expect("s3", b.s3, a.s3);
		Conf.expect("s4", b.s4, a.s4); Conf.expect("s5", b.s5, a.s5);
		Conf.expect("s6", b.s6, a.s6); Conf.expect("s7", b.s7, a.s7);
		Conf.expect("t8", b.t8, a.t8); Conf.expect("t9", b.t9, a.t9);
		Conf.expect("k0", b.k0, a.k0); Conf.expect("k1", b.k1, a.k1);
		Conf.expect("gp", b.gp, a.gp); Conf.expect("sp", b.sp, a.sp);
		Conf.expect("fp", b.fp, a.fp); Conf.expect("ra", b.ra, a.ra);
		Conf.expect("hi", b.hi, a.hi); Conf.expect("lo", b.lo, a.lo);
		Conf.expect("cycles", b.cycles, a.cycles); Conf.expect("pc", b.pc, a.pc);
		Conf.expect("unwind", b.unwindToken, a.unwindToken);
		Conf.expect("sr", b.sr, a.sr);
	}

	static function run(ctx:CpuState, kind:Int, sample:Int, opt:Bool):Void {
		optimized = opt;
		reset(ctx);
		ctx.a0 = sample - 8;
		ctx.a1 = IntMath.mul(sample, 0x12345679) | 0;
		switch (kind) {
			case 0 | 17 | 18: ctx.a0 = sample + 1;
			case 5: ctx.t0 = 0x80015014;
			case 21: ctx.t0 = 0x80025014;
			case 6: ctx.a0 = (sample & 1) == 0 ? 0x7fffffff : 0x80000000;
			case 7: ctx.a0 = 0x80040000;
			case 8:
				cd.Cdrom.init();
				cd.Cdrom.write8(0x1f801802, 0x20, 0);
				cd.Cdrom.write8(0x1f801801, 0x19, 0);
				cd.Cdrom.onEvent(ctx);
				ctx.a0 = 0x1f801801;
			case 9: ctx.sr = 0x401;
			case 10 | 11:
				Scheduler.init(ctx);
				for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
				Scheduler.schedule(ctx, Scheduler.VBLANK_START, 8);
				Kernel.haltAt = Kernel.vblankCount + 1;
			case 12:
				ctx.a0 = sample & 3;
				Memory.write32(0x8001c030, 0x8001c03c);
				Memory.write32(0x8001c034, 0x8001c048);
				Memory.write32(0x8001c038, 0x8001c03c);
			case 14: ctx.a0 = sample + 1; ctx.v0 = 0x12345678;
			case 19 | 20:
				ctx.a0 = 0x80040000; ctx.s0 = 0x87654321;
				Memory.write32(ctx.a0, 0x12345678);
			case _:
		}
		final addr = (0x80010000 + (kind << 12)) | 0;
		if (opt) CodegenOptimized.dispatch(addr, ctx);
		else CodegenReference.dispatch(addr, ctx);
	}

	static function runFused(ctx:CpuState, sample:Int, opt:Bool):Void {
		reset(ctx);
		ctx.a0 = sample - 8;
		ctx.a1 = IntMath.mul(sample, 0x12345679) | 0;
		if (opt) CodegenOptimized.fusedPatterns(ctx);
		else CodegenReference.fusedPatterns(ctx);
	}

	static function runStack(ctx:CpuState, opt:Bool):Void {
		reset(ctx);
		if (opt) CodegenOptimized.stackForward(ctx);
		else CodegenReference.stackForward(ctx);
	}

	/**
		An idle wait, the way a game does it: vblanks keep coming, each one's callback raises
		the polled word, and the loop leaves when the word reaches `target` or its timeout runs
		out. The reference build runs every turn; the optimized build skips all but the last of
		each stretch, and `compare` plus the slot and the word say whether that was exact.
	**/
	static function runIdle(ctx:CpuState, opt:Bool, target:Int, timeout:Int, poll:Int, reload:Bool):Void {
		optimized = opt;
		reset(ctx);
		Kernel.haltAt = 0;
		Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, Scheduler.VBLANK_START, 8);
		kernel.KEvents.init();
		final event = kernel.KEvents.open(ctx, Kernel.CLASS_RCNT3, Kernel.SPEC_INTERRUPTED,
			kernel.KEvents.MODE_CALLBACK, 0x8000f008);
		kernel.KEvents.enable(ctx, event);
		// The kernel's vblank handler delivers the event only when the interrupt can be taken,
		// which is what libetc arranges: the line enabled in I_MASK, interrupts on in SR.
		core.Irq.writeMask(1 << core.Irq.VBLANK);
		ctx.sr = 0x401;
		Memory.write32(POLL, 0);
		ctx.a0 = target;
		ctx.a1 = poll;
		ctx.a2 = timeout;
		if (reload) {
			if (opt) CodegenOptimized.idleReload(ctx);
			else CodegenReference.idleReload(ctx);
		} else {
			if (opt) CodegenOptimized.idleWait(ctx);
			else CodegenReference.idleWait(ctx);
		}
	}

	static function runShift(ctx:CpuState, opt:Bool, value:Int):Void {
		reset(ctx);
		ctx.a0 = value;
		ctx.a1 = 32;   // SRLV uses the low five bits: a shift by zero
		if (opt) CodegenOptimized.shiftByZero(ctx);
		else CodegenReference.shiftByZero(ctx);
	}

	static function runDeadWrites(ctx:CpuState, opt:Bool):Void {
		reset(ctx);
		if (opt) CodegenOptimized.deadWrites(ctx);
		else CodegenReference.deadWrites(ctx);
	}

	public static function main():Void {
		final a = new CpuState();
		final b = new CpuState();
		Runtime.boot(a);
		Runtime.bindDispatch(dispatch);
		Kernel.vramDump = false;
		Kernel.reportOps = false;
		reset(b);
		b.a0 = 0x80040000;
		CodegenOptimized.loadSlot(b);
		Conf.expect("delay-slot load retains bus cycles", b.cycles, 8);
		for (kind in 0...22) {
			for (sample in 0...16) {
				run(a, kind, sample, false);
				run(b, kind, sample, true);
				compare(a, b);
				switch (kind) {
					case 0:
						Conf.expect("sum", b.v0, IntMath.div((sample + 1) * (sample + 2), 2));
						Conf.expect("loop slot", b.v1, sample + 1);
						Conf.expect("loop cycles", b.cycles, 4 * (sample + 1) + 3);
					case 1: Conf.expect("latched branch", b.v0, sample == 8 ? 11 : 22);
					case 2:
						Conf.expect("callee args", b.v0, 13); Conf.expect("callee clobber", b.v1, 19);
					case 3 | 4:
						final taken = kind == 3 ? sample < 8 : sample >= 8;
						Conf.expect("conditional call", b.v0, taken ? 13 : 0);
						Conf.expect("conditional resume", b.v1, taken ? 14 : 1);
						Conf.expect("unconditional link", b.ra, (0x80010008 + (kind << 12)) | 0);
					case 5:
						Conf.expect("discarded link", b.ra, 0x8000ffff);
						Conf.expect("latched tail target", b.v0, sample - 4);
						Conf.expect("tail transfer has no continuation", b.v1, 0);
					case 6:
						Conf.expect("folded constant wraps", b.t0, 0);
						Conf.expect("multiply low", b.v1, IntMath.mul(b.a0, b.a1));
					case 7:
						Conf.expect("word load", b.t0, b.a1);
						Conf.expect("five RAM loads plus store and return slot", b.cycles, 38);
						Conf.expect("signed byte", b.v0, (b.a1 << 24) >> 24);
						Conf.expect("signed half", b.t1, (b.a1 << 16) >> 16);
					case 8: Conf.expect("zero load still pops FIFO", b.v0, 0x09);
					case 9: Conf.expect("syscall reload", b.v1, 5);
					case 10 | 11:
						Conf.expect("halt observed", b.unwindToken, Kernel.UNWIND_HALT);
						Conf.expect("registers published to pump", b.v0, 4);
					case 12:
						final index = sample & 3;
						Conf.expect("switch arm", b.v1, index == 3 ? 0 : (index == 1 ? 22 : 11));
					case 13:
						Conf.expect("unwind preserves restored state", b.s0, 1234);
						Conf.expect("published call argument", publishedArgument, 12);
					case 14:
						var expected = 0x12345678;
						for (_ in 0...(sample + 1)) {
							expected ^= expected << 13; expected ^= expected >>> 17; expected ^= expected << 5;
						}
						Conf.expect("mix", b.v0, expected);
					case 15:
						Conf.expect("constant store", Memory.read32(0x80040008), 312);
						Conf.expect("second store", Memory.read32(0x8004000c), 32);
						Conf.expect("RMW store", Memory.read32(0x80040014), 0x20000);
					case 16: Conf.expect("self move cycles", b.cycles, 4);
					case 17:
						Conf.expect("native loop in dispatcher", b.v0,
							IntMath.div((sample + 1) * (sample + 2), 2) + (sample == 0 ? 100 : 200));
					case 18:
						Conf.expect("multiple block loop", b.v0, IntMath.div((sample + 1) * (sample + 2), 2));
						Conf.expect("multiple block cycles", b.cycles, 6 * (sample + 1) + 5);
					case 19:
						Conf.expect("load before redefine", b.v0, 0x78);
						Conf.expect("second load before redefine", b.v1, 0x56);
					case 20:
						Conf.expect("store before redefine", Memory.read32(0x80040000), 0x87654321);
						Conf.expect("redefined register", b.s0, 0x12345678);
					case 21:
						Conf.expect("latched indirect call", b.v1, sample - 3);
						Conf.expect("indirect call link", b.ra, 0x80025008);
				}
			}
		}
		for (sample in 0...16) {
			runFused(a, sample, false);
			runFused(b, sample, true);
			compare(a, b);
			Conf.expect("fused constant formation", b.t6, 0x12345678);
		}
		runStack(a, false);
		runStack(b, true);
		compare(a, b);
		Conf.expect("stack forwarded load", b.t2, 22);
		Conf.expect("stack load after sp change", b.t3, 22);
		Conf.expect("stack reload after sp restore", b.t4, 22);
		runDeadWrites(a, false);
		runDeadWrites(b, true);
		compare(a, b);
		Conf.expect("dead-write result", b.v0, 5);
		for (value in [0x80000000, -1, 0x7fffffff, 0x12345678, 0]) {
			runShift(a, false, value);
			runShift(b, true, value);
			compare(a, b);
			Conf.expect("SRLV by zero is the word", b.v0, value);
			Conf.expect("SRL by zero is the word", b.v1, value);
			Conf.expect("BEQ finds SRLV's result equal", b.t0, 0);
			Conf.expect("BEQ finds SRL's result equal", b.t1, 0);
			Conf.expect("both equalities held", b.t2, 7);
		}
		// Every interior block remains a valid entry with its incoming context untouched.
		for (entry in 0...3) {
			reset(a); reset(b); a.a0 = 5; b.a0 = 5; a.v0 = 100; b.v0 = 100;
			CodegenReference.sumLoop(a, entry);
			CodegenOptimized.sumLoop(b, entry);
			compare(a, b);
			Conf.expect("resume result", b.v0, entry == 0 ? 15 : (entry == 1 ? 115 : 100));
		}
		reset(a); reset(b);
		a.a0 = 1; b.a0 = 1;
		a.cycles = 0x7ffffffe; b.cycles = 0x7ffffffe;
		a.nextEvent = 0x80001000; b.nextEvent = 0x80001000;
		CodegenReference.sumLoop(a); CodegenOptimized.sumLoop(b);
		compare(a, b);
		Conf.expect("cycle wrap", b.cycles, 0x80000005);
		reset(a); reset(b); a.a0 = 5; b.a0 = 5; a.v0 = 100; b.v0 = 100;
		CodegenReference.directCall(a, 1); CodegenOptimized.directCall(b, 1);
		compare(a, b);
		Conf.expect("call-return resume", b.v1, 105);
		for (mode in 0...2) {
			reset(b); b.a0 = 10; b.v0 = 77;
			Scheduler.init(b);
			for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(b, slot);
			Scheduler.schedule(b, Scheduler.VBLANK_END, 1);
			kernel.KEvents.init();
			final event = kernel.KEvents.open(b, 0x1234, 1, kernel.KEvents.MODE_CALLBACK, 0x8000f004);
			kernel.KEvents.enable(b, event);
			kernel.KEvents.post(0x1234, 1);
			if (mode == 0) CodegenReference.sumLoop(b); else CodegenOptimized.sumLoop(b);
			Conf.expect("pump sees current locals", publishedAtPump, 0);
			Conf.expect("reload callback register changes", b.v0, 106);
		}
		// The idle wait: reached after three vblanks; timed out before the second; satisfied on
		// entry; and polling ROM, which is not plain memory, so every turn runs in both builds.
		final idleSlot = 0x801fff00 - 32 + 16;
		for (variant in 0...8) {
			final scenario = variant & 3;
			final reload = variant >= 4;
			final target = scenario == 2 ? 0 : 3;
			final timeout = scenario == 0 ? 200000 : (scenario == 3 ? 3000 : 50);
			final poll = scenario == 3 ? 0xbfc00000 : POLL;
			runIdle(a, false, target, timeout, poll, reload);
			final refSlot = Memory.read32(idleSlot);
			final refPoll = Memory.read32(POLL);
			runIdle(b, true, target, timeout, poll, reload);
			compare(a, b);
			Conf.expect("idle wait slot", Memory.read32(idleSlot), refSlot);
			Conf.expect("idle wait poll", Memory.read32(POLL), refPoll);
			Conf.expect("idle wait result", b.v0, scenario == 1 || scenario == 3 ? 2 : 1);
			Conf.feed(b.cycles);
		}
		Conf.expect("idle turns were skipped", core.IdleLoop.skipped > 0 ? 1 : 0, 1);
		reset(b); b.v0 = 77; b.unwindToken = 1;
		Runtime.call(b, 0x8000f004);
		Conf.expect("no guest entry while unwinding", b.v0, 77);
		Conf.report("Codegen");
	}
}
