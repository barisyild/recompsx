package core;

/**
	The R3000A's register file, as ordinary fields.

	This is the shared register state at guest calls, returns and scheduler safe points. The
	optimized emitter keeps a function's working registers in Haxe locals and synchronises them
	here at those boundaries (ADR-0007). Named fields avoid runtime register indexing; locals
	also let the host compiler propagate values without aliasing through this shared object.

	`$zero` has no field. It reads as the literal 0 and writes to it are dropped, both decided at
	build time by the emitter, so the most-used register in the instruction set costs nothing at
	all. (A load targeting `$zero` still performs the read: on this machine a load can have side
	effects, since half the address space is hardware registers.)

	`pc` is virtual. Recompiled code has no program counter — control flow is Haxe control flow —
	so it is written only where something needs to know the address: before a runtime dispatch,
	before a kernel call, and when reporting a fault. Keeping it accurate at exactly those points
	costs one store at a boundary and is what makes a trap message able to say where it came from.
**/
class CpuState {
	// General-purpose registers, by their ABI names. $zero is deliberately absent.
	public var at:Int = 0;
	public var v0:Int = 0;  public var v1:Int = 0;
	public var a0:Int = 0;  public var a1:Int = 0;  public var a2:Int = 0;  public var a3:Int = 0;
	public var t0:Int = 0;  public var t1:Int = 0;  public var t2:Int = 0;  public var t3:Int = 0;
	public var t4:Int = 0;  public var t5:Int = 0;  public var t6:Int = 0;  public var t7:Int = 0;
	public var s0:Int = 0;  public var s1:Int = 0;  public var s2:Int = 0;  public var s3:Int = 0;
	public var s4:Int = 0;  public var s5:Int = 0;  public var s6:Int = 0;  public var s7:Int = 0;
	public var t8:Int = 0;  public var t9:Int = 0;
	public var k0:Int = 0;  public var k1:Int = 0;
	public var gp:Int = 0;  public var sp:Int = 0;  public var fp:Int = 0;  public var ra:Int = 0;

	/** The multiply/divide result pair. */
	public var hi:Int = 0;
	public var lo:Int = 0;

	/** Virtual: see the note above. */
	public var pc:Int = 0;

	/**
		Emulated time, in CPU cycles, and the deadline of the next scheduled event.

		Both are plain `Int` and compared by subtraction (`cycles - nextEvent >= 0`), which stays
		correct across wraparound. That works because nothing is ever scheduled more than 2^31
		cycles — about a minute of emulated time — ahead.
	**/
	public var cycles:Int = 0;
	public var nextEvent:Int = 0;

	/**
		Non-zero while an emulated `longjmp` is unwinding.

		The PlayStation kernel offers setjmp/longjmp and games use it, but this project forbids
		exceptions, so the unwind is explicit: `longjmp` restores the saved registers and sets
		this, and generated code returns immediately after any call that analysis says could
		unwind. Frames peel back to the dispatcher holding the matching anchor, which clears it.
	**/
	public var unwindToken:Int = 0;

	/**
		Kept for the HLE thread functions, which do have a depth. Critical sections do not: the
		BIOS implements them by clearing and setting SR bits, with no counter anywhere, and
		delivery is gated on SR alone.
	**/
	public var critDepth:Int = 0;

	/**
		COP0r12, the status register, and COP0r13, cause.

		Bit layout from psx-spx "COP0 Register Summary": SR bit 0 is IEc, the current interrupt
		enable; bits 8..15 are the interrupt mask Im; CAUSE bits 10..15 are the pending field IP,
		masked bit-for-bit by the matching SR bits. The PlayStation's whole interrupt controller
		hangs off one line, IP bit 10.

		Games read and write these directly, so they are kept honest even though delivery is
		actually gated by `critDepth` and the runtime's own state.
	**/
	public var sr:Int = 0;
	public var cause:Int = 0;

	public function new() {}
}
