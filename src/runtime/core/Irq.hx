package core;

import kernel.Kernel;

/**
	The interrupt controller, and delivery of interrupts into recompiled code.

	Two halves that are easy to confuse. `I_STAT`/`I_MASK` at 0x1F801070 are the *hardware*
	controller: subsystems raise bits, the game acknowledges them by writing. COP0's SR decides
	whether the CPU is listening at all. An interrupt reaches the game only when both agree, and
	when the runtime is somewhere it is safe to call into (ADR-0005 §4).

	Delivery means calling a recompiled game function. That is why it happens only at pump points,
	where the emulated CPU state is whole, and why the registers are saved around it: on hardware
	the BIOS preserves them, and under HLE nothing does unless this does.
**/
class Irq {
	// I_STAT / I_MASK bit assignments, psx-spx "Interrupt Registers".
	public static inline var VBLANK = 0;
	public static inline var GPU = 1;
	public static inline var CDROM = 2;
	public static inline var DMA = 3;
	public static inline var TIMER0 = 4;
	public static inline var TIMER1 = 5;
	public static inline var TIMER2 = 6;
	public static inline var SIO0 = 7;
	public static inline var SIO1 = 8;
	public static inline var SPU = 9;
	public static inline var PIO = 10;

	/** COP0 SR bit 0: the CPU is listening at all. */
	public static inline var SR_IEC = 0x00000001;

	/** COP0 SR bit 10: the mask bit for the one line the PlayStation's controller drives. */
	public static inline var SR_IM_HW = 0x00000400;

	/** COP0 CAUSE bit 10: that same line, pending. */
	public static inline var CAUSE_IP_HW = 0x00000400;

	public static var stat(default, null) = 0;
	public static var mask(default, null) = 0;

	/** How many interrupts have actually been delivered into game code. Deterministic. */
	public static var delivered(default, null) = 0;

	/** True while a game handler is running. Delivery is closed then; see `dispatch`. */
	static var inHandler = false;

	/** Whether interrupt dispatch is on the stack — the difference between a driver's own poll
		and a handler's read of the same register. */
	public static inline function dispatching():Bool return inHandler;

	/** Registers saved around a handler. Allocated once — nothing allocates after init. */
	static var saved:CpuState;

	public static function init():Void {
		stat = 0;
		mask = 0;
		delivered = 0;
		inHandler = false;
		saved = new CpuState();
	}

	/**
		A subsystem's line went high.

		Edge-triggered: the bit latches and stays until the game acknowledges it, which is what
		lets a game that was inside a critical section still see the vblank it missed.
	**/
	public static function raise(ctx:CpuState, bit:Int):Void {
		raiseLine(bit);
	}

	/**
		The same, for a device that has no reason to hold a CpuState.

		Raising a line is a property of the machine, not of the CPU — the GPU does not know or care
		what the processor is doing when its interrupt goes high.
	**/
	public static function raiseLine(bit:Int):Void {
		stat |= 1 << bit;
	}

	// ---- the memory-mapped registers -------------------------------------------------------

	public static function readStat():Int {
		if ((stat & (1 << CDROM)) != 0 && cd.Cdrom.tracing()) {
			cd.Cdrom.tnote("I_STAT read -> " + stat + " (mask " + mask + ")");
		} else {}
		return stat;
	}
	public static function readMask():Int return mask;

	/**
		Writing I_STAT acknowledges: bits *cleared* in the written value are cleared in the status.

		Not an assignment. A game acknowledging vblank writes a value with bit 0 low and every
		other bit high, and expects its other pending interrupts to survive.
	**/
	public static function writeStat(v:Int):Void {
		stat = stat & v;
	}

	/**
		Enables one line without disturbing the others.

		For the kernel's device initialisers, which arm a source on the game's behalf. A game that
		calls `_96_init` never writes I_MASK for the CD itself and would be within its rights to
		read the register back and find its own bits untouched.
	**/
	public static function unmask(bit:Int):Void {
		mask |= 1 << bit;
	}

	public static function writeMask(v:Int):Void {
		mask = v;
		Runtime.noteOnce(0x5A100000 | (v & 0x7FF), "I_MASK set to " + hex(v)
			+ " — lines now enabled: " + names(v));
	}

	/** Which sources the game is listening to, by name, because a bitmask is not a diagnosis. */
	static function names(v:Int):String {
		var out = "";
		if ((v & (1 << VBLANK)) != 0) out += "vblank ";
		if ((v & (1 << GPU)) != 0) out += "gpu ";
		if ((v & (1 << CDROM)) != 0) out += "cdrom ";
		if ((v & (1 << DMA)) != 0) out += "dma ";
		if ((v & (1 << TIMER0)) != 0) out += "timer0 ";
		if ((v & (1 << TIMER1)) != 0) out += "timer1 ";
		if ((v & (1 << TIMER2)) != 0) out += "timer2 ";
		if ((v & (1 << SIO0)) != 0) out += "sio0 ";
		if ((v & (1 << SPU)) != 0) out += "spu ";
		return out == "" ? "(none)" : out;
	}

	static function hex(v:Int):String {
		final d = "0123456789abcdef";
		return "0x" + d.charAt((v >> 8) & 0xF) + d.charAt((v >> 4) & 0xF) + d.charAt(v & 0xF);
	}

	/** What the game would see in CAUSE: the controller's line, folded into IP bit 10. */
	public static function causeBits():Int {
		return (stat & mask) != 0 ? CAUSE_IP_HW : 0;
	}

	// ---- delivery ---------------------------------------------------------------------------

	/** Anything pending and unmasked at the controller. */
	public static inline function pending():Bool {
		return (stat & mask) != 0;
	}

	/**
		Whether an interrupt may be delivered right now.

		Three conditions, and each is a different kind of "no": the controller has nothing
		(`pending`); the CPU is not listening (SR — which is also how a critical section says so,
		because that is all one is); or we are already inside a handler.

		That last one is not an optimisation. Without it a handler's own back-edges would pump,
		deliver again, and recurse until the host stack died — with a cause that looks like
		anything but an interrupt.
	**/
	public static function deliverable(ctx:CpuState):Bool {
		return pending()
			&& !inHandler
			&& (ctx.sr & SR_IEC) != 0
			&& (ctx.sr & SR_IM_HW) != 0;
	}

	/**
		Runs the game's handlers for whatever is pending.

		Called from `Runtime.pump`, never from anywhere else, because this is where recompiled
		code gets re-entered and only a pump point guarantees the CPU state is consistent.
	**/
	public static function dispatch(ctx:CpuState):Void {
		if (!deliverable(ctx)) return blocked(ctx);
		else {}
		// A line raised *during* a handler used to wait for the next pump, which is an unbounded
		// delay: pumps happen where recompiled code happens to check, and a game sitting in a
		// wait loop between them can leave a controller's answer undelivered for thousands of
		// cycles. Hardware has no gap — returning from the exception with a line still pending
		// and unmasked re-enters the vector immediately — so this loops instead.
		var rounds = 0;
		while (true) {
			inHandler = true;
			delivered++;
			saveRegisters(ctx);
			ctx.cause = (ctx.cause & ~CAUSE_IP_HW) | causeBits();
			Kernel.onInterrupt(ctx);
			restoreRegisters(ctx);
			inHandler = false;
			rounds++;
			if (!deliverable(ctx)) return;
			else {}
			// A handler that leaves its own line asserted would otherwise spin here forever. Eight
			// is far past any real chain — the machine has six lines — so reaching it means a
			// handler is not clearing what it was called for, which is worth saying once.
			if (rounds >= MAX_ROUNDS) return handlerStorm();
			else {}
		}
	}

	static inline var MAX_ROUNDS = 8;

	static function handlerStorm():Void {
		Runtime.reportOnce(0x5A000005, MAX_ROUNDS + " interrupt deliveries without the lines "
			+ "clearing — a handler is not acknowledging what it was called for");
	}

	/**
		Says why an interrupt that is waiting is not being delivered.

		Once per reason, not once per pump. "Nothing is happening" is the least useful thing a
		bring-up log can say, and the four reasons are genuinely different problems: a game that
		never unmasked the line, one still inside a critical section, one that never enabled
		interrupts in SR, and a bug of ours.
	**/
	static function blocked(ctx:CpuState):Void {
		if (!pending()) return;
		else {}
		if ((ctx.sr & SR_IEC) == 0) Runtime.reportOnce(0x5A000002,
			"interrupt pending but SR.IEc is clear — the CPU is not listening");
		else if ((ctx.sr & SR_IM_HW) == 0) Runtime.reportOnce(0x5A000003,
			"interrupt pending but SR bit 10 is clear — the hardware line is masked off");
		else {}
		// `inHandler` is deliberately not a reason any more. It was reported when a line raised
		// inside a handler had to wait for the next pump; `dispatch` now delivers it before it
		// returns, so reaching here re-entrantly is a pump from inside emulated handler code —
		// ordinary, and nothing to say about.
	}

	// A handler is an ordinary recompiled function and will use registers freely. On hardware the
	// BIOS saves and restores them; here this does. `pc` and `cycles` are deliberately not
	// restored: time really did pass, and pc is only meaningful at a boundary anyway.
	static function saveRegisters(ctx:CpuState):Void {
		saved.at = ctx.at;
		saved.v0 = ctx.v0; saved.v1 = ctx.v1;
		saved.a0 = ctx.a0; saved.a1 = ctx.a1; saved.a2 = ctx.a2; saved.a3 = ctx.a3;
		saved.t0 = ctx.t0; saved.t1 = ctx.t1; saved.t2 = ctx.t2; saved.t3 = ctx.t3;
		saved.t4 = ctx.t4; saved.t5 = ctx.t5; saved.t6 = ctx.t6; saved.t7 = ctx.t7;
		saved.s0 = ctx.s0; saved.s1 = ctx.s1; saved.s2 = ctx.s2; saved.s3 = ctx.s3;
		saved.s4 = ctx.s4; saved.s5 = ctx.s5; saved.s6 = ctx.s6; saved.s7 = ctx.s7;
		saved.t8 = ctx.t8; saved.t9 = ctx.t9;
		saved.k0 = ctx.k0; saved.k1 = ctx.k1;
		saved.gp = ctx.gp; saved.sp = ctx.sp; saved.fp = ctx.fp; saved.ra = ctx.ra;
		saved.hi = ctx.hi; saved.lo = ctx.lo;
	}

	static function restoreRegisters(ctx:CpuState):Void {
		ctx.at = saved.at;
		ctx.v0 = saved.v0; ctx.v1 = saved.v1;
		ctx.a0 = saved.a0; ctx.a1 = saved.a1; ctx.a2 = saved.a2; ctx.a3 = saved.a3;
		ctx.t0 = saved.t0; ctx.t1 = saved.t1; ctx.t2 = saved.t2; ctx.t3 = saved.t3;
		ctx.t4 = saved.t4; ctx.t5 = saved.t5; ctx.t6 = saved.t6; ctx.t7 = saved.t7;
		ctx.s0 = saved.s0; ctx.s1 = saved.s1; ctx.s2 = saved.s2; ctx.s3 = saved.s3;
		ctx.s4 = saved.s4; ctx.s5 = saved.s5; ctx.s6 = saved.s6; ctx.s7 = saved.s7;
		ctx.t8 = saved.t8; ctx.t9 = saved.t9;
		ctx.k0 = saved.k0; ctx.k1 = saved.k1;
		ctx.gp = saved.gp; ctx.sp = saved.sp; ctx.fp = saved.fp; ctx.ra = saved.ra;
		ctx.hi = saved.hi; ctx.lo = saved.lo;
	}
}
