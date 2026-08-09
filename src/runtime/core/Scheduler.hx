package core;

/**
	When the machine's subsystems next need attention.

	A fixed array of deadlines, one slot per source, and a cached minimum. No allocation, no
	sorting, no container to iterate — at a dozen slots a linear rescan beats a heap, and the
	portable subset forbids allocating after init anyway (ADR-0005 §5).

	Two events due on the same cycle fire in **slot order**. Not "whichever the container yields
	first": an arbitrary order between two targets is precisely the kind of divergence this
	project exists to not have.

	One slot is always armed — vblank re-arms itself the moment it fires — so `nextEvent` is
	always a real deadline and the pump check never has to special-case an empty table.
**/
class Scheduler {
	// Slot identities. Order matters: it is the tie-break when two deadlines coincide, so the
	// list runs from the most structural (the frame itself) to the most incidental.
	public static inline var VBLANK_START = 0;
	public static inline var VBLANK_END = 1;
	public static inline var TIMER0 = 2;
	public static inline var TIMER1 = 3;
	public static inline var TIMER2 = 4;
	public static inline var SPU_BATCH = 5;
	public static inline var CD_EVENT = 6;
	public static inline var SIO_BYTE = 7;
	public static inline var DMA_IRQ = 8;
	public static inline var MEMCARD_OP = 9;
	public static inline var SLOTS = 10;

	static var due:Array<Int>;
	static var active:Array<Bool>;

	/**
		The machine's one CpuState, kept so a device can arm a deadline without holding it.

		There is exactly one, created at boot and never replaced, so this is a reference rather than
		state — and it is what lets `scheduleAt` do the whole job instead of half of it.
	**/
	static var owner:CpuState;

	/** How many events have fired. Deterministic, so it belongs in a digest. */
	public static var fired(default, null) = 0;

	public static function init(ctx:CpuState):Void {
		owner = ctx;
		due = [for (_ in 0...SLOTS) 0];
		active = [for (_ in 0...SLOTS) false];
		fired = 0;
		// The frame starts now, and vblank is the one deadline that always exists.
		schedule(ctx, VBLANK_START, TimeBase.nextVblankStart(ctx.cycles));
		schedule(ctx, VBLANK_END, TimeBase.nextVblankEnd(ctx.cycles));
	}

	public static function schedule(ctx:CpuState, slot:Int, atCycle:Int):Void {
		scheduleAt(slot, atCycle);
		recomputeNext(ctx);
	}

	/**
		The same, for a device that has no CpuState to hand.

		It recomputes `nextEvent` like every other path, and the version that did not cost a day.
		The reasoning for skipping it — "a device arming itself from a register write has until the
		next pump to be noticed" — sounded thrifty and was wrong: `nextEvent` still pointed at the
		next vblank, so a CD-ROM deadline fifty thousand cycles away went unnoticed for a whole
		frame. libcd polls for its second interrupt a handful of times and gives up long before
		that, so `Init` answered INT3, never delivered INT2 in time, and the library restarted its
		initialisation forever.

		A deadline nobody looks at is not scheduled. There is no cheap version of this.
	**/
	public static function scheduleAt(slot:Int, atCycle:Int):Void {
		due[slot] = atCycle;
		active[slot] = true;
		recomputeNext(owner);
	}

	public static function cancel(ctx:CpuState, slot:Int):Void {
		active[slot] = false;
		recomputeNext(ctx);
	}

	public static function isActive(slot:Int):Bool {
		return active[slot];
	}

	/**
		Runs everything now due, then leaves `ctx.nextEvent` pointing at the next deadline.

		The loop re-checks after each event because an event may schedule another one that is also
		already due — a vblank arriving late enough that the following one has passed too, which
		happens whenever a game spends a long time inside one function without a back-edge.
	**/
	public static function runDue(ctx:CpuState):Void {
		var guard = 0;
		while (true) {
			final slot = earliestDue(ctx.cycles);
			if (slot < 0) break;
			else {}
			// A runaway would otherwise hang silently; 4096 is far above any real frame's worth.
			guard++;
			if (guard > 4096) return giveUp(ctx);
			else {}
			fire(ctx, slot);
		}
		recomputeNext(ctx);
	}

	/**
		Compares two cycle counts across wraparound.

		`(a - b) | 0` and not `a - b`. The subtraction is what makes the comparison survive the
		counter passing 2^31, and it only wraps if it is made to: C++ wraps `-` and JavaScript does
		not, so without the `| 0` a deadline just past the wrap reads as long overdue on one target
		and correctly future on the other. ADR-0004, and this function is where forgetting it cost
		a scheduler that fired the same event four thousand times.
	**/
	static inline function reached(cycles:Int, deadline:Int):Bool {
		return ((cycles - deadline) | 0) >= 0;
	}

	static inline function earlier(a:Int, b:Int):Bool {
		return ((a - b) | 0) < 0;
	}

	/** The lowest-numbered slot whose deadline has passed, or -1. Slot order is the tie-break. */
	static function earliestDue(cycles:Int):Int {
		var best = -1;
		var bestDue = 0;
		for (i in 0...SLOTS) {
			if (active[i] && reached(cycles, due[i]) && (best < 0 || earlier(due[i], bestDue))) {
				best = i;
				bestDue = due[i];
			} else {}
		}
		return best;
	}

	static function fire(ctx:CpuState, slot:Int):Void {
		fired++;
		// Deactivate before the handler runs, so a handler that re-arms its own slot wins.
		active[slot] = false;
		if (slot == VBLANK_START) onVblankStart(ctx);
		else if (slot == VBLANK_END) onVblankEnd(ctx);
		else if (slot == CD_EVENT) cd.Cdrom.onEvent(ctx);
		else if (slot == SPU_BATCH) spu.Spu.onBatch(ctx.cycles);
		else unimplemented(ctx, slot);
	}

	static function onVblankStart(ctx:CpuState):Void {
		Irq.raise(ctx, Irq.VBLANK);
		// The frame counter belongs here, at the event, not where the kernel delivers it.
		//
		// It used to be incremented in the kernel's own vblank handling, which is a fallback: it
		// runs only for what the game did not deal with itself. So the better a game's interrupt
		// handler works, the fewer frames the counter saw — and once Crash Bash's handler started
		// acknowledging its own vblanks, the count stopped moving entirely while the game ran
		// perfectly well. A frame happened whether or not anyone needed the kernel's help.
		kernel.Kernel.onFrame(ctx);
		// Re-arm immediately: this is the slot that guarantees the table is never empty.
		schedule(ctx, VBLANK_START, TimeBase.nextVblankStart(ctx.cycles));
	}

	static function onVblankEnd(ctx:CpuState):Void {
		schedule(ctx, VBLANK_END, TimeBase.nextVblankEnd(ctx.cycles));
	}

	static function unimplemented(ctx:CpuState, slot:Int):Void {
		Runtime.reportOnce(0x5C000000 | slot, "scheduler slot " + slot + " has no handler");
	}

	static function giveUp(ctx:CpuState):Void {
		// Say which slot and which deadline, or this is a message that only tells you to go and
		// add the message you actually needed.
		var worst = 0;
		for (i in 0...SLOTS) {
			if (active[i] && earlier(due[i], due[worst])) worst = i;
			else {}
		}
		Runtime.reportOnce(0x5C0000FF, "scheduler ran 4096 events without settling: cycles="
			+ ctx.cycles + " earliest slot " + worst + " due " + due[worst]
			+ " active=" + activeMask() + " perFrame=" + TimeBase.cyclesPerFrame());
		// Push every deadline forward so the machine keeps moving rather than wedging here.
		for (i in 0...SLOTS) due[i] = (ctx.cycles + 1000000) | 0;
		recomputeNext(ctx);
	}

	static function activeMask():Int {
		var m = 0;
		for (i in 0...SLOTS) {
			if (active[i]) m |= 1 << i;
			else {}
		}
		return m;
	}

	/** The soonest deadline, which is what the pump check in generated code compares against. */
	static function recomputeNext(ctx:CpuState):Void {
		var best = 0;
		var have = false;
		for (i in 0...SLOTS) {
			if (active[i] && (!have || earlier(due[i], best))) {
				best = due[i];
				have = true;
			} else {}
		}
		// Nothing armed should be impossible (vblank re-arms), but a deadline far ahead is the
		// safe answer rather than one in the past, which would spin.
		ctx.nextEvent = have ? best : (ctx.cycles + 0x40000000) | 0;
	}
}
