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
/**
	**Not an abstract, and not a memory-management annotation either. Both were measured.**

	Wrapping these forty registers in an `abstract` over a typed buffer — the obvious way to make
	the type "free" — is 22% *slower* on JavaScript: 16.85s against 13.75s over three thousand
	frames of the real game, with an identical frame digest, so the comparison is of speed alone.
	Named fields are what let a JIT keep a hot register in a machine register; an index into a
	buffer is a load it cannot promote, however constant the index is.

	The other candidate was `@:unsafePtrType`, which changes how reflaxe.CPP passes this type:
	without it every `ctx` argument is a `std::shared_ptr<CpuState>`, an atomic refcount on each
	of the ~7000 calls a single shard makes, and with it a plain `CpuState*`. That looked like
	free speed and is not: 4.30s of user time against 4.04s for the shared_ptr build, over eight
	runs each — no improvement, inside the noise, if anything worse. This emulator's time goes to
	memory accesses, sound mixing and rasterisation, not to passing an argument. So the pointer
	semantics were not worth taking on for nothing, and the annotation is deliberately absent.

	**That measurement was of speed, on a machine with memory to spare, and it is only half the
	question.** Measured 2026-08-10 on the size axis, against a harness compiled in both shapes:
	the shared_ptr costs **78 bytes more per ctx-passing call site** than a raw pointer, and the
	recompiled Crash Bash has 19,692 of them — about **1.5 MB, 23% of the binary**, and that is a
	floor, since the same harness under-predicts a saving we can check against reality (the
	exception tables) by half. It also *is* the exception cost: with raw pointers,
	`-fno-exceptions` changes the harness by literally nothing, because there is no destructor to
	unwind through. On a Dreamcast, where 16 MB is the whole machine and atomics are not a `lock`
	prefix but a gUSA sequence, both axes point the other way from the desktop's. The annotation
	is still absent because nobody has re-measured it *there* — but "measured and rejected" is now
	the wrong summary of this note. See docs/specs/backend.md §2.1.

	One trap is worth keeping written down, because it compiles and passes every other test:
	`@:valueType` also removes the shared_ptr, by passing **by value**, so a callee's register
	writes never reach the caller and every recompiled function silently loses its results.
	`tests/conformance/CtxPass.hx` exists to catch exactly that — it passes on JavaScript, where a
	class is always a reference, and fails six assertions on C++ the moment the type is wrong.

	**Taken, 2026-08-10, on the size axis: the binary fell 34.5 %.** 7,514,088 bytes to 4,921,528,
	`__text` 6,415,960 to 4,205,552, and `__gcc_except_tab` 227 KB to 19 KB — because what those
	exception tables were mostly *for* was destructing a shared_ptr at each of 19,692 ctx-passing
	call sites. Nothing moved: demo digest `329de455`, game digest `8af4d44b` over 3000 frames
	with all twenty-two counters and the cycle count identical, all 14 conformance tests, both
	targets. It also cost `-fno-exceptions` most of its value — worth 10.3 % before this, 2.8 %
	after — which is the clearest statement of what the shared_ptr actually was.

	The annotation below is what makes every `ctx` argument a `CpuState*`. It is a *pointer*, not
	a value — the entire difference from the trap in the paragraph above, and `CtxPass` is what
	proves that on every build rather than on the day somebody remembers to check. The one
	instance is allocated at boot and never freed, which is what golden rule 7 asks for anyway;
	there is nothing for a refcount to count. `Irq.saved` and `KThreads.image[]` are the only two
	places that hold a second one, and both copy field by field rather than assigning the object,
	so pointer semantics and reference semantics are the same thing there.

	The speed measurement above still stands and was not re-run: it said neutral on x86-64, and
	nothing here should make it worse. On SH-4 neither number has been taken at all — atomics
	there are not a `lock` prefix but a gUSA sequence, so if anything the case is stronger.
**/
@:unsafePtrType
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
