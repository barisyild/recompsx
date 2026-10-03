package core;

import shim.SchedFile;

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
@:headerCode("#include \"recompsx_arena.h\"")
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
	/** Channel 2's ordering-table walk, a stretch of transfer at a time (`dma.Dma`). */
	public static inline var DMA_STEP = 8;
	public static inline var MEMCARD_OP = 9;
	public static inline var SLOTS = 10;

	/*
		The state, in `shim.SchedFile`: words 0-9 are the deadlines, a word a slot, and then

		- NEXT, the armed slot with the earliest deadline (the lower slot of two equal ones), or
		  -1: what `ctx.nextEvent` holds the deadline of. Kept as slots are armed and cancelled,
		  so arming one that is not the earliest costs a compare, and a pump fires it without a
		  search. It was a scan of every armed slot to arm any, two scans to fire one and a third
		  after — some 230 pumps a frame in Crash Bandicoot: Warped, most of them its GPU list's
		  steps.
		- ACTIVE, which slots are armed, a bit a slot.
		- FIRED, how many events have fired. Deterministic, so it belongs in a digest.
		- REST and REST_DUE, the earliest armed slot other than DMA_STEP (as NEXT is chosen), or
		  -1, and its deadline. The list walk's stretches are most of the events a frame (~200 of
		  ~230 in Crash 3's title screen): one fires, the walk arms the next, and the earliest
		  deadline is then the stretch's or REST's — a compare, where it was a scan of every
		  armed slot after every event. REST changes only as the other slots are armed, cancelled
		  and fired, and is searched for again only when the one it names is.

		Flat on purpose, and one array: as an `Array<Int>` and an `Array<Bool>` every read went
		through a reference to a vector and, for the flags, a `std::vector<bool>`'s bit packing —
		measured on the Dreamcast, a third of `runDue`'s time for ten slots scanned four times an
		event — and as a buffer and four statics each was a line of its own. Words 8-15 are one
		line on the Dreamcast (`recompsx_sched` is aligned to one): everything a stretch of the
		walk reads and writes here.
	*/
	static inline var NEXT = 10;
	static inline var ACTIVE = 11;
	static inline var FIRED = 12;
	static inline var REST = 13;
	static inline var REST_DUE = 14;
	static inline var WORDS = 16;

	/**
		The machine's one CpuState, kept so a device can arm a deadline without holding it.

		There is exactly one, created at boot and never replaced, so this is a reference rather than
		state — and it is what lets `scheduleAt` do the whole job instead of half of it.
	**/
	static var owner:CpuState;

	/** How many events have fired. Deterministic, so it belongs in a digest. */
	public static inline function fired():Int {
		return SchedFile.get(FIRED);
	}

	public static function init(ctx:CpuState):Void {
		owner = ctx;
		for (i in 0...WORDS) SchedFile.set(i, 0);
		SchedFile.set(NEXT, -1);
		SchedFile.set(REST, -1);
		// The frame starts now, and vblank is the one deadline that always exists.
		schedule(ctx, VBLANK_START, TimeBase.nextVblankStart(ctx.cycles));
		schedule(ctx, VBLANK_END, TimeBase.nextVblankEnd(ctx.cycles));
	}

	public static function schedule(ctx:CpuState, slot:Int, atCycle:Int):Void {
		scheduleAt(slot, atCycle);
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
		SchedFile.set(slot, atCycle);
		SchedFile.set(ACTIVE, SchedFile.get(ACTIVE) | (1 << slot));
		if (slot != DMA_STEP) restArmed(slot, atCycle);
		else {}
		// Only the earliest deadline can move `nextEvent`: re-arming the slot that holds it (which
		// may move it either way) is a new search, a deadline before it takes its place, and any
		// other changes nothing.
		final next = SchedFile.get(NEXT);
		if (slot == next) recomputeNext(owner);
		else if (next < 0 || beats(atCycle, slot, SchedFile.get(next), next)) {
			SchedFile.set(NEXT, slot);
			owner.nextEvent = atCycle;
		} else {}
	}

	/** REST after `slot`, not DMA_STEP, was armed at `atCycle`: the same three cases as NEXT. */
	static inline function restArmed(slot:Int, atCycle:Int):Void {
		final rest = SchedFile.get(REST);
		if (slot == rest) searchRest();
		else if (rest < 0 || beats(atCycle, slot, SchedFile.get(REST_DUE), rest)) {
			SchedFile.set(REST, slot);
			SchedFile.set(REST_DUE, atCycle);
		} else {}
	}

	/** Whether deadline `a` of slot `sa` comes before deadline `b` of slot `sb`: earlier, or the
	    same cycle and the lower slot — the order `runDue` fires in. */
	static inline function beats(a:Int, sa:Int, b:Int, sb:Int):Bool {
		return earlier(a, b) || (a == b && sa < sb);
	}

	public static function cancel(ctx:CpuState, slot:Int):Void {
		disarm(slot);
		if (slot == SchedFile.get(NEXT)) recomputeNext(ctx);
		else {}
	}

	/** `cancel`, for a device that has no CpuState to hand — the same reason `scheduleAt` exists. */
	public static function cancelSlot(slot:Int):Void {
		disarm(slot);
		if (slot == SchedFile.get(NEXT)) recomputeNext(owner);
		else {}
	}

	/** The slot is no longer armed; if it was REST's, REST is searched for again. */
	static inline function disarm(slot:Int):Void {
		SchedFile.set(ACTIVE, SchedFile.get(ACTIVE) & ~(1 << slot));
		if (slot == SchedFile.get(REST)) searchRest();
		else {}
	}

	public static function isActive(slot:Int):Bool {
		return ((SchedFile.get(ACTIVE) >> slot) & 1) != 0;
	}

	/**
		Runs everything now due, then leaves `ctx.nextEvent` pointing at the next deadline.

		The loop re-checks after each event because an event may schedule another one that is also
		already due — a vblank arriving late enough that the following one has passed too, which
		happens whenever a game spends a long time inside one function without a back-edge.
	**/
	public static function runDue(ctx:CpuState):Void {
		var guard = 0;
		// The earliest deadline is NEXT's; while it has passed, it is the one to fire — the
		// earliest of those due, the lower slot of a tie. Firing may arm anything, so each is
		// followed by a new search, which also leaves `nextEvent` right for when the loop ends.
		while (SchedFile.get(NEXT) >= 0 && reached(ctx.cycles, SchedFile.get(SchedFile.get(NEXT)))) {
			// A runaway would otherwise hang silently; 4096 is far above any real frame's worth.
			guard++;
			if (guard > 4096) return giveUp(ctx);
			else {}
			fire(ctx, SchedFile.get(NEXT));
			recomputeNext(ctx);
		}
		// Nothing was due: a pump asked for by hand (a test sets `nextEvent` itself), so put it back.
		if (guard == 0) recomputeNext(ctx);
		else {}
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

	static inline function fire(ctx:CpuState, slot:Int):Void {
		SchedFile.set(FIRED, (SchedFile.get(FIRED) + 1) | 0);
		// Deactivate before the handler runs, so a handler that re-arms its own slot wins.
		SchedFile.set(ACTIVE, SchedFile.get(ACTIVE) & ~(1 << slot));
		// And no earliest deadline while it runs: `runDue` searches again after every handler,
		// so the one that re-arms its own slot — every stretch of a DMA list walk (~200 a frame),
		// every vblank — takes `scheduleAt`'s store rather than a search of its own first. Nothing
		// a handler runs reads NEXT or `nextEvent`; guest code runs only after the search.
		SchedFile.set(NEXT, -1);
		// The walk's stretch first and in line: it is most of the events. REST never names it.
		if (slot == DMA_STEP) dma.Dma.onEvent(ctx);
		else fireRest(ctx, slot);
	}

	/** Every other slot's handler, out of line: kept out of `runDue`, whose every call is a pump. */
	@:specifier("__attribute__((noinline))")
	static function fireRest(ctx:CpuState, slot:Int):Void {
		// The slot just fired is no longer armed, and it may have been REST.
		if (slot == SchedFile.get(REST)) searchRest();
		else {}
		if (slot == VBLANK_START) onVblankStart(ctx);
		else if (slot == VBLANK_END) onVblankEnd(ctx);
		else if (slot == CD_EVENT) cd.Cdrom.onEvent(ctx);
		else if (slot == SPU_BATCH) spu.Spu.onBatch(ctx.cycles);
		else if (slot == SIO_BYTE) sio.Sio0.onEvent(ctx);
		else if (slot >= TIMER0 && slot <= TIMER2) timers.Timers.onEvent(ctx, slot - TIMER0);
		else unimplemented(ctx, slot);
	}

	static function onVblankStart(ctx:CpuState):Void {
		// The controllers first: a game reads them from its vblank handler, which this wakes.
		// The host's keyboard and mouse, on their way to the machine's own, and what the network
		// sent the i-mode adaptor's phone, come in at the same point (ADR-0040).
		sio.Pads.sample();
		kernel.KKeyboard.sample();
		kernel.KMouse.sample();
		kernel.KIMode.sample();
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
			if (isActive(i) && earlier(SchedFile.get(i), SchedFile.get(worst))) worst = i;
			else {}
		}
		Runtime.reportOnce(0x5C0000FF, "scheduler ran 4096 events without settling: cycles="
			+ ctx.cycles + " earliest slot " + worst + " due " + SchedFile.get(worst)
			+ " active=" + activeMask() + " perFrame=" + TimeBase.cyclesPerFrame());
		// Push every deadline forward so the machine keeps moving rather than wedging here.
		for (i in 0...SLOTS) SchedFile.set(i, (ctx.cycles + 1000000) | 0);
		searchRest();
		recomputeNext(ctx);
	}

	static function activeMask():Int {
		return SchedFile.get(ACTIVE);
	}

	/**
		The soonest deadline, which is what the pump check in generated code compares against:
		the walk's stretch or REST, whichever comes first — the same answer as a search of every
		armed slot, since REST is that search over all but one.
	**/
	static function recomputeNext(ctx:CpuState):Void {
		var slot = SchedFile.get(REST);
		var best = SchedFile.get(REST_DUE);
		if ((SchedFile.get(ACTIVE) & (1 << DMA_STEP)) != 0) {
			final d = SchedFile.get(DMA_STEP);
			if (slot < 0 || beats(d, DMA_STEP, best, slot)) {
				slot = DMA_STEP;
				best = d;
			} else {}
		} else {}
		SchedFile.set(NEXT, slot);
		// Nothing armed should be impossible (vblank re-arms), but a deadline far ahead is the
		// safe answer rather than one in the past, which would spin.
		ctx.nextEvent = slot >= 0 ? best : (ctx.cycles + 0x40000000) | 0;
	}

	/** REST from scratch: the earliest armed slot but DMA_STEP, the lower of two equal ones. */
	static function searchRest():Void {
		var best = 0;
		var slot = -1;
		var bits = SchedFile.get(ACTIVE) & ~(1 << DMA_STEP);
		var i = 0;
		while (bits != 0) {
			if ((bits & 1) != 0) {
				final d = SchedFile.get(i);
				if (slot < 0 || earlier(d, best)) {
					best = d;
					slot = i;
				} else {}
			} else {}
			bits = bits >>> 1;
			i++;
		}
		SchedFile.set(REST, slot);
		SchedFile.set(REST_DUE, best);
	}
}
