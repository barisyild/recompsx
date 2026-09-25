package kernel;

import core.CpuState;
import core.Runtime;

/**
	The BIOS event system.

	This is how a PlayStation game learns that anything happened. A game opens an event for a
	class (vblank, CD, controller) and a spec, and then either polls it or is called back. Psy-Q's
	`VSync()` is `WaitEvent` on the vblank event, which is exactly where Crash Bash stops without
	this.

	Numeric constants and the delivery semantics were taken from **OpenBIOS**, pcsx-redux
	`src/mips/openbios/kernel/events.c` and `src/mips/common/kernel/events.h`, which are MIT
	licensed (Copyright (c) 2020 PCSX-Redux authors) and reproduce the retail BIOS deliberately —
	including its quirks. psx-spx documents the functions but not the numeric status values, and
	guessing those would have produced an event system that looks right and never fires.

	The control blocks live in runtime state rather than in emulated RAM. The real kernel keeps
	them at a known address and a game could read them; nothing observed so far does, and moving
	them into RAM later changes nothing about the behaviour here.
**/
class KEvents {
	// Modes: what delivery does to an event that is listening.
	public static inline var MODE_CALLBACK = 0x1000;
	public static inline var MODE_NO_CALLBACK = 0x2000;

	// Status. Note that DISABLED and MODE_CALLBACK share a value and ENABLED shares one with
	// MODE_NO_CALLBACK — the BIOS reuses the numbers in two unrelated fields, which is confusing
	// to read and faithful to reproduce.
	public static inline var FREE = 0x0000;
	public static inline var DISABLED = 0x1000;
	public static inline var ENABLED = 0x2000;
	public static inline var PENDING = 0x4000;

	// Classes, one per interrupt source plus the card ones.
	public static inline var CLASS_VBLANK = 0xF0000001;
	public static inline var CLASS_GPU = 0xF0000002;
	public static inline var CLASS_CDROM = 0xF0000003;
	public static inline var CLASS_DMA = 0xF0000004;
	public static inline var CLASS_RTC0 = 0xF0000005;
	public static inline var CLASS_RTC1 = 0xF0000006;
	public static inline var CLASS_CONTROLLER = 0xF0000008;
	public static inline var CLASS_SPU = 0xF0000009;
	public static inline var CLASS_PIO = 0xF000000A;
	public static inline var CLASS_SIO = 0xF000000B;
	public static inline var CLASS_CARD = 0xF0000011;
	public static inline var CLASS_BU = 0xF4000001;

	/** Descriptors are this plus the slot index — what OpenEvent hands back. */
	static inline var DESCRIPTOR_BASE = 0xF1000000;

	/** Retail sizes this from the configuration block. Generous here; exhaustion is reported. */
	static inline var COUNT = 32;

	static var evClass:Array<Int>;
	static var evSpec:Array<Int>;
	static var evMode:Array<Int>;
	static var evHandler:Array<Int>;
	static var evFlags:Array<Int>;

	/** Deterministic counters, so a conformance digest can watch the event system work. */
	public static var delivered(default, null) = 0;
	public static var callbacks(default, null) = 0;

	public static function init():Void {
		evClass = [for (_ in 0...COUNT) 0];
		evSpec = [for (_ in 0...COUNT) 0];
		evMode = [for (_ in 0...COUNT) 0];
		evHandler = [for (_ in 0...COUNT) 0];
		evFlags = [for (_ in 0...COUNT) FREE];
		postedClass = [for (_ in 0...POST_MAX) 0];
		postedSpec = [for (_ in 0...POST_MAX) 0];
		postedCount = 0;
		delivered = 0;
		callbacks = 0;
	}

	// ---- the API the kernel vectors expose ---------------------------------------------------

	/** `OpenEvent(class, spec, mode, func)` -> descriptor, or -1 when the table is full. */
	public static function open(ctx:CpuState, cls:Int, spec:Int, mode:Int, handler:Int):Int {
		final slot = freeSlot();
		if (slot < 0) return full();
		else {}
		evClass[slot] = cls;
		evSpec[slot] = spec;
		evMode[slot] = mode;
		evHandler[slot] = handler;
		// Opened but not listening: a game calls EnableEvent when it is ready to hear about it.
		evFlags[slot] = DISABLED;
		// What a game listens for is the shortest description of what it expects to happen, and a
		// game stuck waiting is stuck on one of these. Named once each, so the list is the set of
		// promises the kernel has made.
		final noteKey = 0x55100000 | slot;
		if (!Runtime.alreadyReported(noteKey)) {
			Runtime.noteOnce(noteKey, "OpenEvent " + hex(DESCRIPTOR_BASE | slot)
				+ ": class " + hex(cls) + " spec " + hex(spec) + " mode " + hex(mode)
				+ (handler != 0 ? " callback " + hex(handler) : " polled"));
		} else {}
		return DESCRIPTOR_BASE | slot;
	}

	/** `CloseEvent`. Always 1, as the BIOS does, even for a descriptor that was never open. */
	public static function close(ctx:CpuState, ev:Int):Int {
		final slot = slotOf(ev);
		if (slot >= 0) evFlags[slot] = FREE;
		else {}
		return 1;
	}

	public static function enable(ctx:CpuState, ev:Int):Int {
		final slot = slotOf(ev);
		if (slot >= 0) evFlags[slot] = ENABLED;
		else {}
		return 1;
	}

	public static function disable(ctx:CpuState, ev:Int):Int {
		final slot = slotOf(ev);
		if (slot >= 0) evFlags[slot] = DISABLED;
		else {}
		return 1;
	}

	/**
		`TestEvent` — has it fired since last asked?

		Consumes the answer: a pending event is put back to enabled, so a polling loop sees one
		true per delivery rather than true forever.
	**/
	public static function test(ctx:CpuState, ev:Int):Int {
		final slot = slotOf(ev);
		if (slot < 0) return 0;
		else {}
		if (evFlags[slot] == PENDING) return consume(slot);
		else return 0;
	}

	static function consume(slot:Int):Int {
		evFlags[slot] = ENABLED;
		return 1;
	}

	/**
		`WaitEvent` — the one that matters, and the one that cannot block.

		On hardware this spins until the event fires; there is no thread here to suspend, so the
		spin becomes emulated time moving forward. Each turn jumps straight to the next scheduled
		deadline and runs it (ADR-0005 §3), so waiting a frame costs a handful of iterations
		rather than millions.

		Already pending answers immediately. Disabled answers 0 without waiting, which is what
		stops a game deadlocking on an event it never enabled.
	**/
	public static function wait(ctx:CpuState, ev:Int):Int {
		final slot = slotOf(ev);
		if (slot < 0) return 0;
		else {}
		if (evFlags[slot] == PENDING) return consume(slot);
		else if (evFlags[slot] != ENABLED) return 0;
		else return spin(ctx, slot);
	}

	/** Five emulated seconds is far past any legitimate wait; a longer one is a missing subsystem. */
	static inline var WAIT_LIMIT_CYCLES = 5 * core.TimeBase.CPU_HZ;

	static function spin(ctx:CpuState, slot:Int):Int {
		final started = ctx.cycles;
		while (evFlags[slot] != PENDING) {
			Runtime.idleToNextEvent(ctx);
			if (((ctx.cycles - started) | 0) > WAIT_LIMIT_CYCLES) return gaveUp(slot);
			else {}
		}
		return consume(slot);
	}

	static function gaveUp(slot:Int):Int {
		// Named, because the whole point of the watchdog is to say which event never arrived.
		Runtime.reportOnce(0x55000000 | slot,
			"WaitEvent gave up on class " + hex(evClass[slot]) + " spec " + hex(evSpec[slot])
			+ " — nothing delivers it yet");
		return 0;
	}

	/**
		`DeliverEvent(class, spec)` — tell everyone listening.

		Only events that are *enabled* hear it: pending ones are already raised, disabled ones
		asked not to be told. A callback event runs its handler and stays enabled; a polled event
		goes pending and waits to be asked.
	**/
	public static function deliver(ctx:CpuState, cls:Int, spec:Int):Void {
		for (i in 0...COUNT) {
			if (evFlags[i] == ENABLED && evClass[i] == cls && evSpec[i] == spec) deliverTo(ctx, i);
			else {}
		}
	}

	static function deliverTo(ctx:CpuState, slot:Int):Void {
		delivered++;
		if (evMode[slot] == MODE_NO_CALLBACK) evFlags[slot] = PENDING;
		else if (evMode[slot] == MODE_CALLBACK && evHandler[slot] != 0) runCallback(ctx, slot);
		else {}
	}

	// The handler is ordinary game code. This only ever runs from inside Irq.dispatch, where the
	// registers are already saved, or from a kernel call the game made itself.
	static function runCallback(ctx:CpuState, slot:Int):Void {
		callbacks++;
		Runtime.call(ctx, evHandler[slot]);
	}

	/**
		An event raised by a device rather than by the kernel's own interrupt handling.

		Queued rather than delivered, because the device that raised it has no `CpuState` to hand:
		a DMA transfer runs inside a store instruction in recompiled code, and an event in callback
		mode has to be able to call back into that same code. Doing it there would re-enter the
		game from the middle of one of its own instructions. So it waits for the next pump, which
		is the same rule every other re-entry in this runtime follows.

		Fixed capacity, and a full queue reports rather than growing: nothing allocates after boot,
		and a device raising more than a handful of events between two pump points is a fault worth
		hearing about rather than absorbing.
	**/
	public static function post(cls:Int, spec:Int):Void {
		if (postedCount >= POST_MAX) return postOverflow();
		else {}
		postedClass[postedCount] = cls;
		postedSpec[postedCount] = spec;
		postedCount++;
	}

	/** Hands the queued device events to the game. Called from the pump, and nowhere else. */
	public static function drain(ctx:CpuState):Void {
		if (postedCount == 0) return;
		else {}
		final n = postedCount;
		// Cleared first: a callback that raises another event must queue it, not be consumed by
		// this loop and lose its place.
		postedCount = 0;
		for (i in 0...n) deliver(ctx, postedClass[i], postedSpec[i]);
	}

	static inline var POST_MAX = 16;
	static var postedClass:Array<Int>;
	static var postedSpec:Array<Int>;
	static var postedCount = 0;

	static function postOverflow():Void {
		Runtime.reportOnce(0x57000000, "more than " + POST_MAX + " device events between two "
			+ "pump points — one is being dropped");
	}

	/** `UnDeliverEvent` — take back a delivery the game has not consumed yet. */
	public static function undeliver(ctx:CpuState, cls:Int, spec:Int):Void {
		for (i in 0...COUNT) {
			if (evFlags[i] == PENDING && evClass[i] == cls && evSpec[i] == spec) evFlags[i] = ENABLED;
			else {}
		}
	}

	// ---- plumbing -----------------------------------------------------------------------------

	/** How many event slots are unused — what `get_free_EvCB_slot` reports. */
	public static function freeSlotCount():Int {
		var n = 0;
		for (i in 0...COUNT) {
			if (evFlags[i] == FREE) n++;
			else {}
		}
		return n;
	}

	static function freeSlot():Int {
		for (i in 0...COUNT) {
			if (evFlags[i] == FREE) return i;
			else {}
		}
		return -1;
	}

	static function full():Int {
		Runtime.reportOnce(0x55FFFFFF, "OpenEvent with all " + COUNT + " event slots in use");
		return -1;
	}

	/** Descriptors carry the slot in their low half; anything else is not one. */
	static function slotOf(ev:Int):Int {
		final slot = ev & 0xFFFF;
		if ((ev & 0xFFFF0000) != (DESCRIPTOR_BASE >>> 0 & 0xFFFF0000) || slot >= COUNT) {
			return badDescriptor(ev);
		} else {
			return slot;
		}
	}

	static function badDescriptor(ev:Int):Int {
		Runtime.reportOnce(0x56000000, "event descriptor " + hex(ev) + " is not one we handed out");
		return -1;
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
