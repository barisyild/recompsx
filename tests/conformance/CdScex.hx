import cd.Cdrom;
import cd.Iso9660;
import core.CpuState;
import core.Runtime;
import core.TimeBase;

/** Synthetic register transactions; no disc/BIOS assets and no game addresses. */
@:access(cd.Iso9660)
class CdScex {
	static var ctx:CpuState;
	static inline final REG = 0x1f801800;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		// The fixture supplies only medium presence. It never reads a sector.
		Iso9660.mounted = true;
		for (start in [0, 0x7ff00000]) {
			ctx.cycles = start;
			command(0x1c, -1); finish(); // reset head and counters, including cycle wrap
			command(0x19, 4); discard();
			counters(0);                // early query stops the observation
			waitSecond(); counters(0);
			command(0x19, 4); discard();
			waitSecond(); counters(1);  // licensed medium in the lead-in
			counters(1);                // reading the result does not reset it

			// Setloc changes the destination but leaves the head in the lead-in.
			Cdrom.write8(REG, 0, ctx.cycles);
			Cdrom.write8(REG + 2, 0, ctx.cycles);
			Cdrom.write8(REG + 2, 2, ctx.cycles);
			Cdrom.write8(REG + 2, 0, ctx.cycles);
			command(0x02, -1); discard();
			command(0x19, 4); discard();
			waitSecond(); counters(1);

			// SeekP leaves the lead-in, even when seeking to data sector zero.
			command(0x16, -1); finish();
			command(0x19, 4); discard();
			waitSecond(); counters(0);
			command(0x1e, -1); finish(); // ReadTOC returns to the lead-in
			command(0x19, 4); discard();
			waitSecond(); counters(1);
			command(0x03, -1); discard(); // Play is in the program area
			command(0x19, 4); discard();
			waitSecond(); counters(0);
			command(0x08, -1); finish(); // stopped motor is restarted by Test 04
			command(0x19, 4);
			Conf.expect("Test 04 starts motor", Cdrom.read8(REG + 1) & 2, 2);
			discard();
		}
		Iso9660.mounted = false;
		command(0x1c, -1); finish();
		waitSecond(); counters(0);
		Conf.report("CdScex");
	}

	static function waitSecond():Void {
		ctx.cycles = (ctx.cycles + TimeBase.CPU_HZ) | 0;
	}

	static function command(cmd:Int, param:Int):Void {
		Cdrom.write8(REG, 0, ctx.cycles);
		if (param >= 0) Cdrom.write8(REG + 2, param, ctx.cycles);
		else {}
		Cdrom.write8(REG + 1, cmd, ctx.cycles);
		event();
	}

	static function event():Void {
		ctx.cycles = (ctx.cycles + 50000) | 0;
		Cdrom.onEvent(ctx);
	}

	static function discard():Void {
		while ((Cdrom.read8(REG) & 0x20) != 0) Cdrom.read8(REG + 1);
		Cdrom.write8(REG, 1, ctx.cycles);
		Cdrom.write8(REG + 3, 0x1f, ctx.cycles);
		Cdrom.write8(REG, 0, ctx.cycles);
	}

	static function finish():Void { discard(); event(); discard(); }

	static function counters(expected:Int):Void {
		command(0x19, 5);
		Cdrom.write8(REG, 1, ctx.cycles);
		Conf.expect("Test 05 INT3", Cdrom.read8(REG + 3) & 7, 3);
		Conf.expect("total", Cdrom.read8(REG + 1), expected);
		Conf.expect("success", Cdrom.read8(REG + 1), expected);
		Conf.expect("exactly two bytes, no status prefix", Cdrom.read8(REG) & 0x20, 0);
		discard();
	}
}
