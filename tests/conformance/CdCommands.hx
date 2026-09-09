import cd.Cdrom;
import core.CpuState;
import core.Irq;
import core.Runtime;
import kernel.Kernel;

/** Drive transactions that used to stall after a command interrupted an unread sector. */
@:access(cd.Cdrom)
@:access(kernel.Kernel)
class CdCommands {
	static inline var REG = 0x1f801800;

	public static function main():Void {
		Conf.feedName("CdCommands");
		final ctx = new CpuState();
		Runtime.boot(ctx);
		// A command that aborts/restarts a read cannot leave the old held-sector gate closed.
		for (cmd in [0x08, 0x09, 0x0a, 0x1c, 0x06, 0x1b]) {
			Cdrom.init();
			Cdrom.sectorReady = true;
			Cdrom.sectorTaken = false;
			Cdrom.fifoOpen = true;
			Cdrom.sectorPos = 123;
			Cdrom.write8(REG, 0, ctx.cycles);
			Cdrom.write8(REG + 1, cmd, ctx.cycles);
			Conf.expect("old held sector released", Cdrom.sectorReady ? 1 : 0, 0);
			Conf.expect("new transfer is not already taken", Cdrom.sectorTaken ? 1 : 0, 0);
			Conf.expect("FIFO closed", Cdrom.fifoOpen ? 1 : 0, 0);
			Conf.expect("FIFO position reset", Cdrom.sectorPos, 0);
		}
		Cdrom.init();
		Cdrom.write8(REG, 1, ctx.cycles);
		Cdrom.write8(REG + 2, 0x1f, ctx.cycles);
		Cdrom.write8(REG, 0, ctx.cycles);
		Cdrom.write8(REG + 1, 0x08, ctx.cycles); // Stop: ACK followed by DONE
		ctx.cycles = (ctx.cycles + 50000) | 0;
		Cdrom.onEvent(ctx);
		Conf.expect("first response is INT3", Cdrom.currentLevel(), 3);
		Kernel.cdrom(ctx); // No game callback claimed it; HLE acknowledges it.
		Conf.expect("second response is released", Cdrom.currentLevel(), 2);
		Conf.expect("queued response retains I_STAT", Irq.readStat() & (1 << Irq.CDROM), 1 << Irq.CDROM);
		Kernel.cdrom(ctx);
		Conf.expect("completion is acknowledged", Cdrom.currentLevel(), 0);
		Conf.expect("no interrupt remains", Irq.readStat() & (1 << Irq.CDROM), 0);
		Cdrom.acknowledgeUnhandled();
		Conf.expect("empty acknowledgement is harmless", Cdrom.currentLevel(), 0);
		Conf.report("CdCommands");
	}
}
