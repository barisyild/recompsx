import core.CpuState;
import core.Scheduler;
import core.TimeBase;
import shim.IntMath;

/**
	The beam's line as `TimeBase.line` keeps it, and timer 1 counting hblanks as `Timers` folds it,
	each against the arithmetic written out here, along a random walk of the cycle counter.

	`line` keeps the line it found last with the cycles it lasts for, so that a poll of GPUSTAT
	within it is a compare (ledger E-109). The walk moves the clock a few cycles, a few thousand
	or up to a frame at a time, from just short of 2^31: across the wrap, where intoFrame's frames
	start again from another phase, and across zero, a frame boundary on both sides. It forgets the
	kept line now and then, as every frame does.

	Timer 1 counts hblanks from a mode write (mode bit 8): at cycle c the counter is
	floor((c - w) / line) for the write at w, modulo 0x10000 free-running and modulo target + 1
	when it resets at its target — what its fold has to keep giving, a line at a time by a compare
	and a longer gap by a divide. The counter is started again every thousand steps, with each of
	those wraps in turn. Both targets alike; the generator is a 32-bit xorshift in plain Int
	arithmetic.
**/
class BeamLine {
	static var seed = 0x6F1C2B3D;

	public static function main():Void {
		Conf.feedName("BeamLine");
		final ctx = new CpuState();
		Scheduler.init(ctx);
		timers.Timers.init();
		for (region in 0...2) {
			TimeBase.setRegion(region == 1);
			TimeBase.forgetLine();
			Conf.feedName(region == 1 ? "pal" : "ntsc");
			walkLines();
			walkTimer();
		}
		Conf.report("BeamLine");
	}

	static function walkLines():Void {
		final perLine = TimeBase.cyclesPerLine();
		final perFrame = TimeBase.cyclesPerFrame();
		final last = IntMath.div(perFrame, perLine) - 1;
		var c = 0x7FF00000;
		var differ = 0;
		var wraps = 0;
		for (step in 0...300000) {
			final before = c;
			c = (c + stride(perFrame)) | 0;
			if (before >= 0 && c < 0) wraps++;
			else {}
			if ((next() & 1023) == 0) TimeBase.forgetLine();
			else {}
			final got = TimeBase.line(c);
			var into = IntMath.mod(c, perFrame);
			if (into < 0) into += perFrame;
			else {}
			var want = IntMath.div(into, perLine);
			if (want > last) want = last;
			else {}
			if (got != want) differ++;
			else {}
			Conf.feed(got);
		}
		Conf.expect("lines that differ from the arithmetic", differ, 0);
		Conf.feed(wraps);
	}

	static function walkTimer():Void {
		final perLine = TimeBase.cyclesPerLine();
		final perFrame = TimeBase.cyclesPerFrame();
		final targets = [0, 100, 262, 0x1234];
		var c = 0x7FF00000;
		var w = c;
		var wrapAt = 0x10000;
		var differ = 0;
		for (step in 0...300000) {
			if (step % 1000 == 0) {
				final target = targets[IntMath.div(step, 1000) & 3];
				timers.Timers.write(0x1F801118, target, c);
				timers.Timers.write(0x1F801114, target == 0 ? 0x100 : 0x108, c);
				w = c;
				wrapAt = target == 0 ? 0x10000 : target + 1;
			} else {}
			c = (c + stride(perFrame)) | 0;
			final got = timers.Timers.read(0x1F801110, c);
			// Under 2^31 cycles since the write (a thousand steps of at most a frame): a quotient of
			// non-negative numbers.
			final want = IntMath.mod(IntMath.div((c - w) | 0, perLine), wrapAt);
			if (got != want) differ++;
			else {}
			Conf.feed(got);
		}
		Conf.expect("counter values that differ from the arithmetic", differ, 0);
	}

	/** A few cycles most of the time, a few thousand often, up to a frame now and then. */
	static function stride(perFrame:Int):Int {
		final r = next() & 15;
		if (r < 10) return next() & 255;
		else if (r < 14) return next() & 4095;
		else return IntMath.mod(next() & 0x7FFFFFFF, perFrame);
	}

	static function next():Int {
		var x = seed;
		x = (x ^ (x << 13)) | 0;
		x = x ^ (x >>> 17);
		x = (x ^ (x << 5)) | 0;
		seed = x;
		return x;
	}
}
