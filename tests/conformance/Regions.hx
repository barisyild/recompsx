import core.CpuState;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import kernel.KEvents;
import mem.Memory;

/** Full machine-state comparisons for region entry, control flow, calls and safe points. */
class Regions {
	static var observed = 0;
	static var unwind = false;

	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (addr == 0x8000f100) {
			observed = ctx.a1;
			ctx.v0 = 44; ctx.v1 = 77; ctx.a0 = 2;
			if (unwind) { ctx.pc = 0x80105000; ctx.unwindToken = 1; } else {}
			return true;
		} else if (addr == 0x8000f104) {
			observed = ctx.v0;
			ctx.v0 = 200; ctx.a0 = 1;
			return true;
		} else return false;
	}

	static function reset(ctx:CpuState, sample:Int):Void {
		Codegen.reset(ctx);
		ctx.a0 = sample & 3; ctx.a1 = (sample >> 2) & 1;
		ctx.v0 = 100; ctx.v1 = 7;
		ctx.cycles = 0x7ffffff0;
		ctx.nextEvent = 0x800ffff0;
		observed = 0;
	}

	static function event(ctx:CpuState, halt:Bool):Void {
		ctx.cycles = 0; ctx.a0 = 4;
		Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, halt ? Scheduler.VBLANK_START : Scheduler.VBLANK_END, 5);
		KEvents.init();
		if (halt) Kernel.haltAt = Kernel.vblankCount + 1;
		else {
			Kernel.haltAt = 0;
			final handle = KEvents.open(ctx, 0x2345, 1, KEvents.MODE_CALLBACK, 0x8000f104);
			KEvents.enable(ctx, handle); KEvents.post(0x2345, 1);
		}
	}

	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch);
		Kernel.vramDump = false; Kernel.reportOps = false;
		for (kind in 0...RegionsOptimized.count()) {
			for (sample in 0...8) for (entry in 0...RegionsOptimized.entries(kind)) {
				reset(a, sample);
				// An interior entry after a zero-count exit would be an unbounded guest loop.
				if (kind == 2 && entry != 0 && a.a0 == 0) a.a0 = 1;
				RegionsReference.run(kind, a, entry);
				final cycles = Memory.cycleHint(); final ra = Memory.raHint(); final argument = observed;
				reset(b, sample);
				if (kind == 2 && entry != 0 && b.a0 == 0) b.a0 = 1;
				RegionsOptimized.run(kind, b, entry);
				Codegen.compare(a, b);
				Conf.expect('cycle hint at original safe point', Memory.cycleHint(), cycles);
				Conf.expect('return-address hint', Memory.raHint(), ra);
				Conf.expect('call observes published locals', observed, argument);
				if (entry == 0) {
					final input = sample & 3;
					switch (kind) {
						case 0:
							Conf.expect('branch condition before slot', b.v0, input == 0 ? 23 : 12);
							Conf.expect('diamond cycles', b.cycles, (0x7ffffff0 + (input == 0 ? 9 : 10)) | 0);
						case 1: Conf.expect('nested branches', b.v0, input == 0 ? 33 : (sample < 4 ? 22 : 11));
						case 2:
							Conf.expect('diamond loop sum', b.v0, (input >> 1) * 7 + ((input + 1) >> 1) * 3);
							Conf.expect('loop exit', b.a0, 0);
						case 3: Conf.expect('cross edge into arm', b.v0, sample >= 4 || input != 0 ? 111 : 122);
						case 5: Conf.expect('call arm result', b.v0, input == 0 ? 34 : 48);
						case 6: Conf.expect('reverse-layout branch', b.v0, input == 0 ? 121 : 111);
						case 7:
							Conf.expect('same-successor slot', b.v0, 101);
							Conf.expect('return slot', b.v1, 8);
						case 8: Conf.expect('unterminated block falls through', b.v0, input == 0 ? 100 : 111);
						case 9: Conf.expect('conditional external exit', b.v0, input == 0 ? 100 : 101);
						case _:
					}
				} else {}
			}
		}
		// The callback changes registers while execution is in a reduced multi-block loop.
		for (halt in 0...2) {
			reset(a, 0); event(a, halt != 0); RegionsReference.diamondLoop(a);
			final published = observed;
			reset(b, 0); event(b, halt != 0); RegionsOptimized.diamondLoop(b);
			Codegen.compare(a, b);
			Conf.expect('pump publication matches', observed, published);
			if (halt == 0) {
				Conf.expect('callback sees current accumulator', observed, 7);
				Conf.expect('callback reload inside region', b.v0, 203);
			} else {
				Conf.expect('halt leaves region immediately', b.unwindToken, Kernel.UNWIND_HALT);
				Conf.expect('halt preserves latest accumulator', b.v0, 7);
			}
		}
		Kernel.haltAt = 0;
		unwind = true;
		reset(a, 1); RegionsReference.callArm(a);
		reset(b, 1); RegionsOptimized.callArm(b);
		Codegen.compare(a, b);
		Conf.expect('unwind leaves choice before join', b.v0, 44);
		Conf.expect('call delay slot argument', observed, 18);
		unwind = false;
		// A recovered table remains a checked computed transfer even after surrounding reduction.
		Memory.write32(0x8001c030, 0x8000f100);
		reset(a, 0); CodegenReference.table(a);
		reset(b, 0); CodegenOptimized.table(b);
		Codegen.compare(a, b);
		Conf.expect('modified table uses dynamic fallback', b.v0, 44);
		Conf.report('Regions');
	}
}
