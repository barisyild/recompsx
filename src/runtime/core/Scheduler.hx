package core;

import shim.MemA;
import shim.RawBuf;
import shim.RawMem;

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
	/** Channel 2's ordering-table walk, a stretch of transfer at a time (`dma.Dma`). */
	public static inline var DMA_STEP = 8;
	public static inline var MEMCARD_OP = 9;
	public static inline var SLOTS = 10;

	/**
		The deadlines, a word a slot, and which slots are armed, a bit a slot.

		Flat on purpose: as an `Array<Int>` and an `Array<Bool>` every read went through a
		reference to a vector and, for the flags, a `std::vector<bool>`'s bit packing — measured
		on the Dreamcast, a third of `runDue`'s time for ten slots scanned four times an event.
	**/
	static var due:RawBuf;
	static var activeBits = 0;

	/**
		The armed slot with the earliest deadline (the lower slot of two equal ones), or -1: what
		`ctx.nextEvent` holds the deadline of. Kept as slots are armed and cancelled, so arming one
		that is not the earliest costs a compare, and a pump fires it without a search. It was a
		scan of every armed slot to arm any, two scans to fire one and a third after — some 230
		pumps a frame in Crash Bandicoot: Warped, most of them its GPU list's steps.
	**/
	static var nextSlot = -1;

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
		due = RawMem.alloc(SLOTS << 2);
		activeBits = 0;
		nextSlot = -1;
		fired = 0;
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
		MemA.set32(due, slot << 2, atCycle);
		activeBits |= 1 << slot;
		// Only the earliest deadline can move `nextEvent`: re-arming the slot that holds it (which
		// may move it either way) is a new search, a deadline before it takes its place, and any
		// other changes nothing.
		if (slot == nextSlot) recomputeNext(owner);
		else if (nextSlot < 0 || beats(atCycle, slot, MemA.get32(due, nextSlot << 2), nextSlot)) {
			nextSlot = slot;
			owner.nextEvent = atCycle;
		} else {}
	}

	/** Whether deadline `a` of slot `sa` comes before deadline `b` of slot `sb`: earlier, or the
	    same cycle and the lower slot — the order `runDue` fires in. */
	static inline function beats(a:Int, sa:Int, b:Int, sb:Int):Bool {
		return earlier(a, b) || (a == b && sa < sb);
	}

	public static function cancel(ctx:CpuState, slot:Int):Void {
		activeBits &= ~(1 << slot);
		if (slot == nextSlot) recomputeNext(ctx);
		else {}
	}

	/** `cancel`, for a device that has no CpuState to hand — the same reason `scheduleAt` exists. */
	public static function cancelSlot(slot:Int):Void {
		activeBits &= ~(1 << slot);
		if (slot == nextSlot) recomputeNext(owner);
		else {}
	}

	public static function isActive(slot:Int):Bool {
		return ((activeBits >> slot) & 1) != 0;
	}

	/**
		Runs everything now due, then leaves `ctx.nextEvent` pointing at the next deadline.

		The loop re-checks after each event because an event may schedule another one that is also
		already due — a vblank arriving late enough that the following one has passed too, which
		happens whenever a game spends a long time inside one function without a back-edge.
	**/
	public static function runDue(ctx:CpuState):Void {
		var guard = 0;
		// The earliest deadline is `nextSlot`'s; while it has passed, it is the one to fire — the
		// earliest of those due, the lower slot of a tie. Firing may arm anything, so each is
		// followed by a new search, which also leaves `nextEvent` right for when the loop ends.
		while (nextSlot >= 0 && reached(ctx.cycles, MemA.get32(due, nextSlot << 2))) {
			// A runaway would otherwise hang silently; 4096 is far above any real frame's worth.
			guard++;
			if (guard > 4096) return giveUp(ctx);
			else {}
			fire(ctx, nextSlot);
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

	static function fire(ctx:CpuState, slot:Int):Void {
		fired++;
		// Deactivate before the handler runs, so a handler that re-arms its own slot wins.
		activeBits &= ~(1 << slot);
		// And no earliest deadline while it runs: `runDue` searches again after every handler,
		// so the one that re-arms its own slot — every stretch of a DMA list walk (~200 a frame),
		// every vblank — takes `scheduleAt`'s store rather than a search of its own first. Nothing
		// a handler runs reads `nextSlot` or `nextEvent`; guest code runs only after the search.
		nextSlot = -1;
		if (slot == VBLANK_START) onVblankStart(ctx);
		else if (slot == VBLANK_END) onVblankEnd(ctx);
		else if (slot == CD_EVENT) cd.Cdrom.onEvent(ctx);
		else if (slot == SPU_BATCH) spu.Spu.onBatch(ctx.cycles);
		else if (slot == SIO_BYTE) sio.Sio0.onEvent(ctx);
		else if (slot == DMA_STEP) dma.Dma.onEvent(ctx);
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
			if (((activeBits >> i) & 1) != 0 && earlier(MemA.get32(due, i << 2), MemA.get32(due, worst << 2))) worst = i;
			else {}
		}
		Runtime.reportOnce(0x5C0000FF, "scheduler ran 4096 events without settling: cycles="
			+ ctx.cycles + " earliest slot " + worst + " due " + MemA.get32(due, worst << 2)
			+ " active=" + activeMask() + " perFrame=" + TimeBase.cyclesPerFrame());
		// Push every deadline forward so the machine keeps moving rather than wedging here.
		for (i in 0...SLOTS) MemA.set32(due, i << 2, (ctx.cycles + 1000000) | 0);
		recomputeNext(ctx);
	}

	static function activeMask():Int {
		return activeBits;
	}

	/** The soonest deadline, which is what the pump check in generated code compares against. */
	static function recomputeNext(ctx:CpuState):Void {
		var best = 0;
		var slot = -1;
		var bits = activeBits;
		var i = 0;
		while (bits != 0) {
			if ((bits & 1) != 0) {
				final d = MemA.get32(due, i << 2);
				if (slot < 0 || earlier(d, best)) {
					best = d;
					slot = i;
				} else {}
			} else {}
			bits = bits >>> 1;
			i++;
		}
		nextSlot = slot;
		// Nothing armed should be impossible (vblank re-arms), but a deadline far ahead is the
		// safe answer rather than one in the past, which would spin.
		ctx.nextEvent = slot >= 0 ? best : (ctx.cycles + 0x40000000) | 0;
	}
}
