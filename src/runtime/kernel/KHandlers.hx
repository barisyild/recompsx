package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;

/**
	The kernel's interrupt handler priority chains.

	Psy-Q's libraries — libetc, libcd, libpad — do not poll. They hand the kernel a chain element
	and let it call them, so this is not an optional corner of the BIOS: it is how a real game
	receives a vblank at all.

	Layout of a chain element, from psx-spx "SysEnqIntRP":

	    +00h  next     pointer to the next element, 0 to end. Written by the kernel.
	    +04h  func2    called only if func1 returned non-zero
	    +08h  func1    called first
	    +0Ch  unused

	Four chains, 0 the highest priority. The kernel walks them in order and, within a chain,
	follows `next`. Both functions are ordinary game code, so calling them means re-entering
	recompiled functions — which is why this only ever runs from `Irq.dispatch`, with registers
	saved around it.

	The elements themselves live in emulated RAM because the game allocated them there and can
	read them back. Only the chain heads are ours.
**/
class KHandlers {
	static inline var CHAINS = 4;
	static inline var OFF_NEXT = 0x00;
	static inline var OFF_FUNC2 = 0x04;
	static inline var OFF_FUNC1 = 0x08;

	/** Head of each priority chain, as an emulated address. 0 = empty. */
	static var head:Array<Int>;

	/** How many handler functions have been called. Deterministic, so a digest can watch it. */
	public static var calls(default, null) = 0;

	public static function init():Void {
		head = [for (_ in 0...CHAINS) 0];
		calls = 0;
		claims = 0;
	}

	/**
		`SysEnqIntRP(priority, element)` — insert at the head of a chain.

		At the head, not the tail: that is what the kernel does, and it means the most recently
		installed handler for a priority runs first. Games install in an order that assumes it.
	**/
	public static function enqueue(ctx:CpuState, priority:Int, element:Int):Void {
		if (priority < 0 || priority >= CHAINS || element == 0) {
			Runtime.reportOnce(0x53000000 | (priority & 0xFF),
				"SysEnqIntRP with priority " + priority + " and element " + hex(element));
		} else {
			Memory.write32(element + OFF_NEXT, head[priority]);
			head[priority] = element;
			// Which library installed what, once per element. The chain is where every driver
			// meets the machine, so this line is the register of who is listening.
			final noteKey = 0x53100000 | (element & 0xFFFF);
			if (!Runtime.alreadyReported(noteKey)) {
				Runtime.noteOnce(noteKey,
					"SysEnqIntRP chain " + priority + ": element " + hex(element)
					+ " verifier " + hex(Memory.read32(element + OFF_FUNC1))
					+ " handler " + hex(Memory.read32(element + OFF_FUNC2)));
			} else {}
		}
	}

	/**
		`SysDeqIntRP(priority, element)` — remove an element, but only if it is first.

		This reproduces a documented BIOS bug rather than fixing it. psx-spx records that
		SysDeqIntRP can only ever remove the first element of a chain, because walking further
		reads an uninitialised stack slot. Games are built against the broken version:
		`A0(72h) _96_remove` is documented as not working *because* of it, so a correct
		implementation here would make the CD device actually detach and diverge from every real
		console.

		Fidelity beats correctness whenever a game can tell the difference, and here it can.
	**/
	public static function dequeue(ctx:CpuState, priority:Int, element:Int):Void {
		if (priority < 0 || priority >= CHAINS) {
			Runtime.reportOnce(0x54000000, "SysDeqIntRP with priority " + priority);
		} else if (head[priority] == element && element != 0) {
			head[priority] = Memory.read32(element + OFF_NEXT);
		} else {
			// The bug: anything but the first element is left in place.
			Runtime.noteOnce(0x54000001,
				"SysDeqIntRP could not remove a non-first element — reproducing the BIOS bug");
		}
	}

	/**
		Walks every chain, calling handlers, in priority order.

		Called only from `Irq.dispatch`. `next` is re-read from RAM each step rather than cached,
		because a handler is free to rearrange the chain it is standing in — which is exactly what
		a game does when it deinstalls itself from inside its own callback.
	**/
	public static function runChains(ctx:CpuState):Void {
		for (p in 0...CHAINS) runChain(ctx, p);
	}

	static function runChain(ctx:CpuState, priority:Int):Void {
		var element = head[priority];
		var guard = 0;
		while (element != 0) {
			// A game that links a chain into a cycle would otherwise hang the machine here.
			guard++;
			if (guard > 64) return tooLong(priority);
			else {}

			final next = Memory.read32(element + OFF_NEXT);
			callElement(ctx, element);
			element = next;
		}
	}

	/**
		One element: func1 first, and func2 only if func1 claimed the interrupt.

		"Claimed" is `v0 != 0` — the verifier's answer, in the register a MIPS function returns in.
	**/
	static function callElement(ctx:CpuState, element:Int):Void {
		final func1 = Memory.read32(element + OFF_FUNC1);
		final func2 = Memory.read32(element + OFF_FUNC2);
		if (func1 == 0) return;
		else {}

		calls++;
		ctx.v0 = 0;
		Runtime.call(ctx, func1);
		if (claimed(ctx)) return;
		else {}
		if (ctx.v0 != 0 && func2 != 0) runSecond(ctx, func2);
		else {}
	}

	static function runSecond(ctx:CpuState, func2:Int):Void {
		calls++;
		Runtime.call(ctx, func2);
		claimed(ctx);
	}

	/**
		Did the handler end by claiming the interrupt?

		A handler that has dealt with an interrupt leaves through `ReturnFromException`, which on
		hardware is a longjmp into the dispatcher — so this function is where that jump lands. The
		token is cleared here and nowhere else: a game's own `longjmp` carries a different value and
		is left to travel further out, which is what keeps the two mechanisms from eating each
		other's unwinds.
	**/
	static function claimed(ctx:CpuState):Bool {
		if (ctx.unwindToken != Kernel.UNWIND_FROM_EXCEPTION) return false;
		else {}
		ctx.unwindToken = 0;
		claims++;
		return true;
	}

	/** How many interrupts a game handler said it had dealt with. */
	public static var claims(default, null) = 0;

	static function tooLong(priority:Int):Void {
		Runtime.reportOnce(0x54000002 | priority,
			"interrupt chain " + priority + " is longer than 64 elements or is a loop");
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
