import core.CpuState;
import core.Scheduler;

/**
	The scheduler's earliest deadline (`ctx.nextEvent`) and its armed slots against a plain model —
	a search of every armed slot, the lower slot winning a tie — after every step of a random
	sequence of arming, cancelling and firing.

	What it guards is the bookkeeping that makes a stretch of the GPU's list walk a compare: the
	earliest armed slot other than DMA_STEP, kept as the others are armed, cancelled and fired, and
	searched for again only when the one it names changes. Deadlines are drawn a few cycles apart,
	so equal ones are common, a re-armed slot moves both earlier and later, and the walk's slot is
	re-armed most often, as in a frame. The clock starts just short of 2^31, so deadlines straddle
	the wrap. Firing goes through `runDue` with only the walk's slot due — its handler does nothing
	without a list — and every other slot's deadline still ahead.

	The generator is a 32-bit xorshift in plain Int arithmetic: the same sequence on every target.
**/
class SchedulerOrder {
	static var seed = 0x2545F491;

	public static function main():Void {
		Conf.feedName("SchedulerOrder");
		final ctx = new CpuState();
		ctx.cycles = 0x7FFF8000;
		Scheduler.init(ctx);
		final due = new Array<Int>();
		final armed = new Array<Bool>();
		for (slot in 0...Scheduler.SLOTS) {
			Scheduler.cancel(ctx, slot);
			due.push(0);
			armed.push(false);
		}
		// One deadline far ahead that never comes due, so the table is never empty.
		final far = Scheduler.MEMCARD_OP;
		Scheduler.scheduleAt(far, (ctx.cycles + 0x10000000) | 0);
		due[far] = (ctx.cycles + 0x10000000) | 0;
		armed[far] = true;
		final fired0 = Scheduler.fired();
		var fires = 0;
		var differ = 0;
		for (step in 0...200000) {
			final r = next() & 15;
			if (r < 9) {
				// Arm: the walk's slot half the time, any but the far one otherwise.
				final slot = (next() & 1) == 0 ? Scheduler.DMA_STEP : (next() & 0x7FFFFFFF) % (Scheduler.SLOTS - 1);
				// A few cycles either side of now, or exactly another armed slot's deadline.
				var at = (ctx.cycles + (next() & 63) - 8) | 0;
				final other = (next() & 0x7FFFFFFF) % (Scheduler.SLOTS - 1);
				if ((next() & 3) == 0 && armed[other]) at = due[other];
				else {}
				if ((step & 1) == 0) Scheduler.scheduleAt(slot, at);
				else Scheduler.schedule(ctx, slot, at);
				due[slot] = at;
				armed[slot] = true;
			} else if (r < 12) {
				final slot = (next() & 0x7FFFFFFF) % (Scheduler.SLOTS - 1);
				if ((step & 1) == 0) Scheduler.cancel(ctx, slot);
				else Scheduler.cancelSlot(slot);
				armed[slot] = false;
			} else {
				ctx.cycles = (ctx.cycles + (next() & 31)) | 0;
				// Run what is due when that is the walk's stretch alone (or nothing).
				var others = false;
				for (slot in 0...Scheduler.SLOTS) {
					if (slot != Scheduler.DMA_STEP && armed[slot] && reached(ctx.cycles, due[slot])) others = true;
					else {}
				}
				if (!others) {
					if (armed[Scheduler.DMA_STEP] && reached(ctx.cycles, due[Scheduler.DMA_STEP])) {
						armed[Scheduler.DMA_STEP] = false;
						fires++;
					} else {}
					Scheduler.runDue(ctx);
				} else {
					// Move the others past now, as their handlers would have.
					for (slot in 0...Scheduler.SLOTS) {
						if (slot != Scheduler.DMA_STEP && armed[slot] && reached(ctx.cycles, due[slot])) {
							final at = (ctx.cycles + 1 + (next() & 15)) | 0;
							Scheduler.scheduleAt(slot, at);
							due[slot] = at;
						} else {}
					}
				}
			}
			// The model: the earliest armed deadline, the lower slot of a tie.
			var best = 0;
			var slotBest = -1;
			for (slot in 0...Scheduler.SLOTS) {
				if (armed[slot] && (slotBest < 0 || (((due[slot] - best) | 0) < 0))) {
					best = due[slot];
					slotBest = slot;
				} else {}
			}
			Conf.feed(ctx.nextEvent);
			if (ctx.nextEvent != best) differ++;
			else {}
			var bits = 0;
			for (slot in 0...Scheduler.SLOTS) {
				if (Scheduler.isActive(slot)) bits |= 1 << slot;
				else {}
				if (Scheduler.isActive(slot) != armed[slot]) differ++;
				else {}
			}
			Conf.feed(bits);
		}
		Conf.expect("steps where the earliest deadline or an armed slot differs from the model", differ, 0);
		Conf.expect("stretches fired", (Scheduler.fired() - fired0) | 0, fires);
		Conf.feed(fires);
		Conf.report("SchedulerOrder");
	}

	static inline function reached(cycles:Int, deadline:Int):Bool {
		return ((cycles - deadline) | 0) >= 0;
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
