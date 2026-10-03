import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Span-guarded signature recovery: same guest state and device reads as the original body. */
@:access(ScalarCodegen)
class ScalarMemoryCodegen {
	static function prepare(ctx:CpuState, at:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx, at, 29, opt);
		for (k in 0...48) {
			final addr = (at + k - 16) | 0;
			if (Memory.isPlainMemory(addr)) Memory.write8(addr, (k * 37 + 131) & 255);
			else {}
		}
		Memory.write32(0x80040020, 0x87654321);
	}

	static function referenceValue(kind:Int, addr:Int):Int {
		return switch (kind) {
			case 0: (Memory.read32(addr) + 7) | 0;
			case 1: Memory.read8s((addr + 1) | 0);
			case 2: Memory.read8u((addr + 1) | 0);
			case 3: Memory.read16s((addr + 2) | 0);
			case 4: Memory.read16u((addr + 2) | 0);
			case 5: (Memory.read32(addr) + 29) | 0;
			case 6: (Memory.read32((addr + 4) | 0) - 7) | 0;
			case 7: Memory.read32((addr + 4) | 0);
			case 8: 0x87654321;
			case 9: Memory.read32(addr);
			case _: Memory.read32((addr - 4) | 0);
		};
	}

	static function fifo(ctx:CpuState, opt:Bool, dead:Bool):Void {
		ScalarCodegen.prepare(ctx, 0x1f801801, 0, opt);
		// Device scheduling must belong to this run's CPU, not the preceding reference run.
		ctx.cycles = 0;
		Scheduler.init(ctx);
		cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802, 0x20, 0);
		cd.Cdrom.write8(0x1f801801, 0x19, 0);
		cd.Cdrom.onEvent(ctx);
		if (dead) {
			if (opt) CodegenOptimized.scalarReadDeadFifo(ctx);
			else CodegenReference.scalarReadDeadFifo(ctx);
		} else {
			if (opt) CodegenOptimized.scalarReadFifo(ctx);
			else CodegenReference.scalarReadFifo(ctx);
		}
	}

	static function sliced(ctx:CpuState, frequency:Int):Void {
		Cooperative.every = frequency;
		var slices = 0;
		while (Cooperative.step(ctx, CodegenOptimized.SCALAR_READ_CHAIN, 4)) {
			// A new value arrives while the callee is suspended at its entry checkpoint.
			if (ctx.cycles == 0x7ffffff3) Memory.write32(ctx.a0, 0x76543210);
			else {}
			slices++;
			if (slices > 100) { Conf.expect('memory helper resume progress', 0, 1); return; } else {}
		}
		Conf.expect('memory helper resume consumed', Cooperative.resumeEntry, -1);
	}

	public static function main():Void {
		final a = new CpuState(); final b = new CpuState();
		Runtime.boot(a); Runtime.bindDispatch(ScalarCodegen.dispatch); Cooperative.bind(ScalarCodegen.resume);
		Kernel.vramDump = false; Kernel.reportOps = false;
		// Mirrored RAM, scratchpad and its alias, both sides of a RAM-mirror boundary, and
		// low RAM where an intermediate pointer wraps through negative values.
		for (addr in [0x80040020, 0xa0040020, 0x00640020, 0x1f800040, 0x9f800040, 0x801ffffc, 0x80200000, 0]) {
			for (kind in 0...11) {
				if (addr == 0 && kind == 10) continue;
				else {}
				final fn = CodegenOptimized.SCALAR_READS + (kind << 12);
				prepare(a, addr, false);
				final expected = referenceValue(kind, addr);
				ScalarCodegen.dispatch(fn, a);
				final insns = Runtime.insns; final blocks = Runtime.blocks;
				prepare(b, addr, true); ScalarCodegen.dispatch(fn, b);
				ScalarCodegen.compare(a, b, insns, blocks);
				Conf.expect('memory scalar result', b.v0, expected);
			}
		}
		for (dead in [false, true]) {
			fifo(a, false, dead);
			final insns = Runtime.insns; final blocks = Runtime.blocks;
			final nextByte = Memory.read8u(0x1f801801);
			fifo(b, true, dead);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('MMIO zero-target and overwritten loads both consumed', Memory.read8u(0x1f801801), nextByte);
			Conf.expect('third FIFO byte', nextByte, 0x19);
			Conf.expect('second FIFO byte used only when live', b.v0, dead ? 1 : (0x09 ^ 0x55));
		}
		for (frequency in 0...4) {
			prepare(a, 0x80040020, false); sliced(a, frequency);
			final insns = Runtime.insns; final blocks = Runtime.blocks; final yields = Cooperative.yields;
			prepare(b, 0x80040020, true); sliced(b, frequency);
			ScalarCodegen.compare(a, b, insns, blocks);
			Conf.expect('memory helper safe points unchanged', Cooperative.yields, yields);
			if (frequency == 1) Conf.expect('memory read happens after resumption', b.v0, 0x76543217);
			else {}
		}
		// A due event must halt before the guarded load, exactly as at any function entry.
		for (opt in [false, true]) {
			prepare(b, 0x80040020, opt); b.cycles = 0;
			Scheduler.init(b);
			for (slot in 0...Scheduler.SLOTS) Scheduler.cancel(b, slot);
			Scheduler.schedule(b, Scheduler.VBLANK_START, 0);
			Kernel.haltAt = Kernel.vblankCount + 1;
			ScalarCodegen.dispatch(CodegenOptimized.SCALAR_READS, b);
			Conf.expect('pump precedes memory helper', b.v0, 0x80000001);
			Conf.expect('halt charges no body instructions', Runtime.insns, 0);
		}
		Conf.report('ScalarMemoryCodegen');
	}
}
