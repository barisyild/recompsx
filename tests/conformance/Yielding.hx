import core.CpuState;
import core.Runtime;
import core.Cooperative;
import core.Scheduler;
import kernel.Kernel;
import kernel.KEvents;
import mem.Memory;

/** Real generated continuations, including callers already pending when the leaf yields again. */
class Yielding {
	static var callbackBlocked = false;
	static var shadowed = false;
	static function resumePinned(fn:Int, entry:Int, ctx:CpuState):Void {
		if (CodegenOptimized.dispatch(fn, ctx)) return;
		else {}
		RegionsOptimized.dispatch(fn, ctx);
	}
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		if (shadowed && addr == 0x80026000) {
			ctx.v0 = -99; // another body now owns the same address
			return true;
		} else if (addr == 0x8000f000) {
			ctx.a0 = 1; ctx.pc = 0x80011000; ctx.unwindToken = 1;
			return true;
		} else if (addr == 0x8000f104) {
			callbackBlocked = Cooperative.blocked > 0;
			ctx.a0 = 3;
			CodegenOptimized.sumLoop(ctx);
			return true;
		} else if (addr == 0x8000f100) {
			ctx.v0 = 44; ctx.a0 = 2;
			return true;
		} else if (CodegenOptimized.dispatch(addr, ctx)) return true;
		else return RegionsOptimized.dispatch(addr, ctx);
	}

	static function reset(ctx:CpuState, input:Int):Void {
		Cooperative.reset();
		Codegen.reset(ctx);
		ctx.a0 = input; ctx.a1 = input & 1;
		ctx.cycles = 0x7ffffff0; ctx.nextEvent = 0x800ffff0;
		Kernel.haltAt = 0;
	}

	static function sliced(ctx:CpuState, addr:Int, every:Int):Void {
		Cooperative.every = every;
		var slices = 0;
		while (Cooperative.step(ctx, addr, 7)) {
			slices++;
			if (slices > 10000) { Conf.expect('slice progress', 1, 0); return; } else {}
		}
		Conf.expect('resume descriptor consumed', Cooperative.resumeEntry, -1);
	}

	static function event(ctx:CpuState, halt:Bool):Void {
		ctx.cycles = 0; ctx.a0 = 4;
		Scheduler.init(ctx);
		for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx, slot);
		Scheduler.schedule(ctx, halt ? Scheduler.VBLANK_START : Scheduler.VBLANK_END, 5);
		KEvents.init(); callbackBlocked = false;
		if (halt) Kernel.haltAt = Kernel.vblankCount + 1;
		else {
			final handle = KEvents.open(ctx, 0x2345, 1, KEvents.MODE_CALLBACK, 0x8000f104);
			KEvents.enable(ctx, handle); KEvents.post(0x2345, 1);
		}
	}

	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(dispatch);
		Kernel.vramDump = false; Kernel.reportOps = false;
		for (kind in 0...RegionsOptimized.count()) for (input in 1...4) for (frequency in 0...3) {
			final addr = 0x80100000 + (kind << 12);
			reset(a, input); Runtime.callAndResume(a, addr);
			final hint = Memory.cycleHint(); final ra = Memory.raHint();
			reset(b, input); sliced(b, addr, frequency);
			Codegen.compare(a, b);
			Conf.expect('same pump timing hint', Memory.cycleHint(), hint);
			Conf.expect('same pump ra hint', Memory.raHint(), ra);
		}
		for (kind in [0, 2, 3, 4, 5, 12, 18, 21, 22, 23]) for (frequency in 0...3) {
			final addr = 0x80010000 + (kind << 12);
			Memory.write32(0x8001c030, 0x8001c03c);
			Memory.write32(0x8001c034, 0x8001c048);
			Memory.write32(0x8001c038, 0x8001c03c);
			reset(a, 2); a.t0 = kind == 5 ? 0x80015014 : 0x80025014;
			Runtime.callAndResume(a, addr);
			final hint = Memory.cycleHint(); final ra = Memory.raHint();
			reset(b, 2); b.t0 = kind == 5 ? 0x80015014 : 0x80025014;
			sliced(b, addr, frequency);
			Codegen.compare(a, b);
			Conf.expect('call pump hint', Memory.cycleHint(), hint);
			Conf.expect('call ra hint', Memory.raHint(), ra);
			if (kind == 22) {
				Conf.expect('nested result', b.v0, 116);
				Conf.expect('call and return slots once', b.s0, 20);
				Conf.expect('call and loop slots once', b.v1, 6);
				Conf.expect('suspension exercised', Cooperative.yields > 0 ? 1 : 0, 1);
				if (frequency > 0) Conf.expect('multiple suspensions', Cooperative.yields > 1 ? 1 : 0, 1);
				else {}
			} else if (kind == 23) Conf.expect('longjmp discards pending callers', b.v0, 22);
			else {}
		}
		for (halt in 0...2) {
			reset(a, 1); event(a, halt != 0); Runtime.callAndResume(a, 0x80102000);
			reset(b, 1); event(b, halt != 0); sliced(b, 0x80102000, 1);
			Codegen.compare(a, b);
			if (halt == 0) Conf.expect('callback remains atomic', callbackBlocked ? 1 : 0, 1);
			else Conf.expect('halt ends slices', b.unwindToken, Kernel.UNWIND_HALT);
			Conf.expect('atomic nesting restored', Cooperative.blocked, 0);
		}
		// Normal address dispatch changes after suspension; pinned continuation dispatch must
		// retain the active body, just as the original native call stack would.
		reset(b, 2); Cooperative.bind(resumePinned); Cooperative.every = 1;
		Conf.expect('suspend before replacing address owner', Cooperative.step(b, 0x80026000, 7) ? 1 : 0, 1);
		shadowed = true;
		sliced(b, 0x80026000, 1);
		Conf.expect('active body remains pinned', b.v0, 116);
		shadowed = false;
		Conf.report('Yielding');
	}
}
