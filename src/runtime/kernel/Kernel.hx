package kernel;

import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import mem.Memory;
import shim.Backend;

/**
	The PlayStation kernel, high-level emulated.

	This is the one part of the machine recompsx does not recompile. The BIOS is in ROM, not in
	the game, so there is nothing to translate — and reimplementing it natively means no BIOS image
	is ever needed, which is what lets a recompiled game be distributed as an ordinary program.

	Games reach it three ways, all of which land here: the A0/B0/C0 vectors (`jr` through a
	register holding 0xA0, with the function number in $t1), `syscall` for the handful of
	operations that use it, and `break` for the divide-by-zero guards Psy-Q emits.

	Function numbers and semantics come from psx-spx "BIOS Function Summary", with OpenBIOS
	(MIT, pcsx-redux `src/mips/openbios`) settling the numeric details psx-spx leaves in prose.
	Never from memory — golden rule 6. An unimplemented call reports once and returns, because a
	stub that halted would only ever show the first gap.
**/
class Kernel {
	public static function init():Void {
		KEvents.init();
		KHandlers.init();
		KLib.init();
		KFiles.init();
		KThreads.init();
		KTables.init();
		KTimers.init();
		// Every table is built here rather than at its declaration: reflaxe emits a statement
		// block at namespace scope for a static initialised with a comprehension, which is not
		// valid C++ — and nothing may allocate after boot anyway.
		autoAck = [for (_ in 0...11) true];
		clearRCnt = [true, true, true, true];
		lastError = 0;
		drivers = 0;
		hookEntryInt = 0;
		clearPad = true;
	}

	/** A BIOS call through one of the three vectors. `fn` is the value in $t1. */
	public static function call(ctx:CpuState, vector:Int, fn:Int):Void {
		if (vector == 0xA0) a0(ctx, fn);
		else if (vector == 0xB0) b0(ctx, fn);
		else if (vector == 0xC0) c0(ctx, fn);
		else reportCall(ctx, vector, fn);
	}

	// ---- A0 ------------------------------------------------------------------------------------

	static function a0(ctx:CpuState, fn:Int):Void {
		// The C library occupies most of this table; ask it first and fall through if it declines.
		if (KLib.call(ctx, fn)) return;
		else if (KFiles.callA0(ctx, fn)) return;
		else {}
		// InitHeap(addr, size): the game gives the kernel a region of its own RAM to allocate in.
		if (fn == 0x39) KHeap.init(ctx.a0, ctx.a1);
		// FlushCache: no cache to invalidate under static recompilation — but this is where a game
		// says it has finished writing code, and on a real machine it has to, because code in RAM
		// is invisible to the instruction cache until it does. That makes it the one point where
		// looking at every window is *complete*: whatever the loader was, whatever it did, it ends
		// here. See kernel.OverlayMgr.
		else if (fn == 0x44) flushCache();
		else if (fn == 0x13) ctx.v0 = KThreads.setjmp(ctx, ctx.a0);
		else if (fn == 0x14) KThreads.longjmp(ctx, ctx.a0, ctx.a1);
		else if (fn >= 0x46 && fn <= 0x4E) gpuHelper(ctx, fn);
		else if (fn == 0x45) noteOnce(0xA0045, "A0(45h) init_a0_b0_c0_vectors — the tables are ours");
		else if (fn == 0x52) ctx.v0 = ctx.sp;                       // GetSysSp
		else if (fn == 0x06 || fn == 0x3A) exitGame(ctx);
		else if (fn == 0x54 || fn == 0x71) ctx.v0 = cdDeviceInit();
		else if (fn == 0x55 || fn == 0x70) ctx.v0 = buInit();
		else if (fn == 0x56 || fn == 0x72) ctx.v0 = removeCdDevice();
		else if (fn == 0x40 || fn == 0x4F || fn == 0x50 || fn == 0x53) systemError(ctx, 0xA0, fn);
		else if (returnsZero(fn)) ctx.v0 = 0;
		else reportCall(ctx, 0xA0, fn);
	}

	// ---- B0 ------------------------------------------------------------------------------------

	static function b0(ctx:CpuState, fn:Int):Void {
		if (KFiles.callB0(ctx, fn)) return;
		else {}
		if (fn == 0x07) ctx.v0 = deliverEvent(ctx);
		else if (fn == 0x08) ctx.v0 = KEvents.open(ctx, ctx.a0, ctx.a1, ctx.a2, ctx.a3);
		else if (fn == 0x09) ctx.v0 = KEvents.close(ctx, ctx.a0);
		else if (fn == 0x0A) ctx.v0 = KEvents.wait(ctx, ctx.a0);
		else if (fn == 0x0B) ctx.v0 = KEvents.test(ctx, ctx.a0);
		else if (fn == 0x0C) ctx.v0 = KEvents.enable(ctx, ctx.a0);
		else if (fn == 0x0D) ctx.v0 = KEvents.disable(ctx, ctx.a0);
		else if (fn == 0x20) ctx.v0 = undeliverEvent(ctx);
		else if (fn == 0x19) ctx.v0 = hookEntry(ctx);
		else if (fn == 0x4A || fn == 0x4B) ctx.v0 = cardInit(fn);
		else if (fn == 0x5B) ctx.v0 = changeClearPad(ctx);
		else if (fn == 0x00) ctx.v0 = KHeap.malloc(ctx.a0);         // alloc_kernel_memory
		else if (fn == 0x01) ctx.v0 = freeKernelMemory(ctx);
		else if (fn >= 0x02 && fn <= 0x06) ctx.v0 = KTimers.call(ctx, fn);
		else if (fn == 0x0E) ctx.v0 = KThreads.openTh(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x0F) ctx.v0 = KThreads.closeTh(ctx, ctx.a0);
		else if (fn == 0x10) ctx.v0 = KThreads.changeTh(ctx, ctx.a0);
		else if (fn == 0x17) ctx.v0 = returnFromException(ctx);
		else if (fn == 0x18) ctx.v0 = resetEntryInt();
		else if (fn == 0x38) exitGame(ctx);
		else if (fn == 0x3B) ctx.v0 = putcB0(ctx);
		else if (fn == 0x3D) ctx.v0 = putcharB0(ctx);
		else if (fn == 0x3F) ctx.v0 = putsB0(ctx);
		else if (fn == 0x3A || fn == 0x3C) ctx.v0 = -1;             // getc/getchar: no input exists
		else if (fn == 0x47) ctx.v0 = addDrv(ctx);
		else if (fn == 0x48) ctx.v0 = delDrv(ctx);
		else if (fn == 0x49) ctx.v0 = printDevices();
		else if (fn == 0x54) ctx.v0 = lastError;
		else if (fn == 0x55) ctx.v0 = lastError;
		else if (fn == 0x56) ctx.v0 = KTables.c0Table();
		else if (fn == 0x57) ctx.v0 = KTables.b0Table();
		else if (fn == 0x59) ctx.v0 = testDevice(ctx);
		else if (isSystemErrorB0(fn)) systemError(ctx, 0xB0, fn);
		else reportCall(ctx, 0xB0, fn);
	}

	static function deliverEvent(ctx:CpuState):Int {
		KEvents.deliver(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	static function undeliverEvent(ctx:CpuState):Int {
		KEvents.undeliver(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	// ---- C0 ------------------------------------------------------------------------------------

	static function c0(ctx:CpuState, fn:Int):Void {
		if (fn == 0x02) ctx.v0 = enqIntRP(ctx);
		else if (fn == 0x03) ctx.v0 = deqIntRP(ctx);
		else if (fn == 0x0A) ctx.v0 = changeClearRCnt(ctx);
		// The kernel's own installers. Under HLE the handlers they would install are native, so
		// these are acknowledgements rather than no-ops: the thing they set up already exists.
		else if (fn == 0x00) ctx.v0 = installed("EnqueueTimerAndVblankIrqs");
		else if (fn == 0x01) ctx.v0 = installed("EnqueueSyscallHandler");
		else if (fn == 0x06 || fn == 0x07) ctx.v0 = installed("exception handlers");
		else if (fn == 0x09) ctx.v0 = installed("SysInitKernelVariables");
		else if (fn == 0x0C) ctx.v0 = installed("InitDefInt");
		else if (fn == 0x12) ctx.v0 = installed("InstallDevices");
		else if (fn == 0x04) ctx.v0 = KEvents.freeSlotCount();
		else if (fn == 0x05) ctx.v0 = 0;                            // get_free_TCB_slot
		else if (fn == 0x08) ctx.v0 = sysInitMemory(ctx);
		else if (fn == 0x0D) ctx.v0 = setIrqAutoAck(ctx);
		else if (fn == 0x13) ctx.v0 = flushStdInOut();
		else if (fn == 0x19) ioAbort(ctx);
		else if (fn == 0x1A) ctx.v0 = setCardFindMode(ctx);
		else if (fn == 0x1D) ctx.v0 = cardFindMode;
		else if (fn == 0x1C) ctx.v0 = installed("AdjustA0Table");
		else if (fn >= 0x0E && fn <= 0x11) ctx.v0 = 0;
		else if (fn == 0x14) ctx.v0 = 0;
		else reportCall(ctx, 0xC0, fn);
	}

	static function enqIntRP(ctx:CpuState):Int {
		KHandlers.enqueue(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	static function deqIntRP(ctx:CpuState):Int {
		KHandlers.dequeue(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	/**
		`ChangeClearRCnt(timer, flag)` — whether the kernel's own handler acknowledges a timer IRQ.

		Returns the previous setting, which callers save and put back.
	**/
	static function changeClearRCnt(ctx:CpuState):Int {
		final t = ctx.a0 & 3;
		final was = clearRCnt[t] ? 1 : 0;
		clearRCnt[t] = ctx.a1 != 0;
		return was;
	}

	static var clearRCnt:Array<Bool>;

	// ---- the rest of the surface ------------------------------------------------------------------

	/**
		What `_get_errno` reports.

		Named `lastError` and not `errno`, which would be the obvious choice and does not compile:
		`errno` is a *macro* in C's `<errno.h>` — `#define errno (*__error())` — so the generated
		C++ expands it in the middle of a field declaration. A whole class of identifier is unsafe
		this way, not just reserved words.
	**/
	public static var lastError = 0;

	/**
		Addresses that psx-spx lists as "returns 0".

		Real entries in the table that do nothing, kept apart from the ones we simply have not
		written: a game calling one of these is getting the hardware's answer, not a stub's.
	**/
	static function returnsZero(fn:Int):Bool {
		return (fn >= 0x57 && fn <= 0x5A) || (fn >= 0x73 && fn <= 0x77)
			|| (fn >= 0x79 && fn <= 0x7B) || fn == 0x7D || fn == 0x7F;
	}

	static function isSystemErrorB0(fn:Int):Bool {
		return (fn >= 0x1A && fn <= 0x1F) || (fn >= 0x21 && fn <= 0x23)
			|| fn == 0x2A || fn == 0x2B || fn == 0x52 || fn == 0x5A;
	}

	/**
		The BIOS error handler.

		On hardware it prints and hangs the machine. Reporting and continuing is more useful during
		bring-up and cannot be less correct — a game that reaches it has already gone wrong, and
		hanging would only hide whatever it does next.
	**/
	static function systemError(ctx:CpuState, vector:Int, fn:Int):Void {
		Runtime.reportOnce(0x5D000000 | (vector << 8) | fn,
			"SystemError via " + vectorName(vector) + "(" + hex2(fn) + ")");
	}

	static function exitGame(ctx:CpuState):Void {
		Runtime.note("the game called exit(" + ctx.a0 + ")");
		Backend.requestQuit();
	}

	/**
		The GPU helpers, A0(46h..4Eh).

		They are thin: the kernel writes a word to a GPU port and returns. Written through the
		memory map rather than to a GPU object, so the moment the GPU register file exists these
		start working with no change here — and until then the unimplemented-register report says
		exactly which port a game wanted.
	**/
	static inline var GP0 = 0x1F801810;
	static inline var GP1 = 0x1F801814;

	static function gpuHelper(ctx:CpuState, fn:Int):Void {
		if (fn == 0x48) Memory.write32(GP1, ctx.a0);                // SendGP1Command
		else if (fn == 0x49) Memory.write32(GP0, ctx.a0);           // GPU_cw
		else if (fn == 0x4A) sendWords(ctx.a0, ctx.a1);             // GPU_cwp
		else if (fn == 0x4D) ctx.v0 = Memory.read32(GP1);           // GetGPUStatus
		else if (fn == 0x4E) ctx.v0 = 0;                            // gpu_sync: drawing is instant
		else reportCall(ctx, 0xA0, fn);
	}

	static function sendWords(src:Int, count:Int):Void {
		var i = 0;
		while (i < count) {
			Memory.write32(GP0, Memory.read32(src + (i << 2)));
			i++;
		}
	}

	static function freeKernelMemory(ctx:CpuState):Int {
		KHeap.free(ctx.a0);
		return 0;
	}

	/**
		`_96_init` — arm the CD.

		It does not only register a device: on hardware it installs the CD BIOS handlers *and*
		unmasks the CD line, because the handlers it installs are the ones that will be called.
		A game never touches I_MASK for the CD itself, which is why leaving that out looked like a
		controller that answered into a disconnected wire — nineteen interrupts raised, none
		delivered, and libcd reporting `NoIntr` about a command it had understood perfectly.
	**/
	static function cdDeviceInit():Int {
		Irq.unmask(Irq.CDROM);
		noteOnce(0xA0054, "A0(54h) _96_init — CD device registered and its interrupt unmasked");
		return 0;
	}

	/**
		`ReturnFromException` — which never returns.

		On hardware this is a **longjmp**, not a return. OpenBIOS makes it explicit
		(`kernel/handlers.c`, MIT, Copyright (c) 2019 PCSX-Redux authors): the exception dispatcher
		holds a `JmpBuf` whose `ra` is `returnFromException` and whose `sp` is a dedicated exception
		stack, and a handler that has claimed an interrupt jumps back through it. Its own frame is
		abandoned.

		Treating it as an ordinary return — which is what this did — leaves the recompiled handler
		running on into code that is unreachable on a real machine. The instructions after the call
		exist in the binary, so they translate and they execute, and the further they run the less
		the failure looks like anything to do with exceptions.

		So it raises the unwind instead. Frames peel back to `KHandlers.callElement`, which is the
		anchor this jump lands on, exactly as the dispatcher's `JmpBuf` is on hardware.
	**/
	static function returnFromException(ctx:CpuState):Int {
		ctx.unwindToken = UNWIND_FROM_EXCEPTION;
		return 0;
	}

	/**
		The token value that means "a handler claimed its interrupt", as distinct from a game's own
		`longjmp`. `KHandlers` clears this one; anything else it lets travel further out.
	**/
	public static inline var UNWIND_FROM_EXCEPTION = 0x52464558;   // 'RFEX'

	static function resetEntryInt():Int {
		hookEntryInt = 0;
		return 0;
	}

	static function putcB0(ctx:CpuState):Int {
		KLib.putchar(ctx.a0);
		return ctx.a0 & 0xFF;
	}

	static function putcharB0(ctx:CpuState):Int {
		KLib.putchar(ctx.a0);
		return ctx.a0 & 0xFF;
	}

	static function putsB0(ctx:CpuState):Int {
		KLib.puts(ctx.a0);
		return 0;
	}

	/**
		`AddDrv` / `DelDrv` — the device table.

		Games install drivers for the CD and the memory card. The structures are theirs and stay in
		their memory; what the kernel owns is the list, and a count is enough to answer `testdevice`
		honestly until the device layers exist.
	**/
	static var drivers = 0;

	static function addDrv(ctx:CpuState):Int {
		drivers++;
		noteOnce(0xB0047, "B0(47h) AddDrv — a game installed its own device driver");
		return 1;
	}

	static function delDrv(ctx:CpuState):Int {
		if (drivers > 0) drivers--;
		else {}
		return 1;
	}

	static function printDevices():Int {
		Runtime.note("installed devices: tty, and " + drivers + " the game added");
		return 0;
	}

	static function testDevice(ctx:CpuState):Int {
		return 0;
	}

	static function sysInitMemory(ctx:CpuState):Int {
		KHeap.init(ctx.a0, ctx.a1);
		return 0;
	}

	/** `SetIrqAutoAck(irq, flag)` — whether the kernel acknowledges a line on the game's behalf. */
	static var autoAck:Array<Bool>;

	static function setIrqAutoAck(ctx:CpuState):Int {
		final irq = ctx.a0;
		if (irq < 0 || irq >= 11) return 0;
		else {}
		final was = autoAck[irq] ? 1 : 0;
		autoAck[irq] = ctx.a1 != 0;
		return was;
	}

	static function flushStdInOut():Int {
		KLib.flushTty();
		return 0;
	}

	static function ioAbort(ctx:CpuState):Void {
		Runtime.reportOnce(0x5D000001, "_ioabort — the kernel gave up on an I/O operation");
	}

	static var cardFindMode = 0;

	static function setCardFindMode(ctx:CpuState):Int {
		final was = cardFindMode;
		cardFindMode = ctx.a0;
		return was;
	}

	static function installed(what:String):Int {
		Runtime.noteOnce(0x5E000000 + what.length, what + " — already native under HLE");
		return 0;
	}

	// ---- devices ---------------------------------------------------------------------------------

	/**
		`HookEntryInt(addr)` — a hook the kernel runs after its own exception handling.

		Games install one to get a look at every interrupt before the priority chains do. Stored
		and honoured; the structure it points at is the game's, so we only keep the pointer.
	**/
	static var hookEntryInt = 0;

	static function flushCache():Void {
		noteOnce(0xA0044, "A0(44h) FlushCache — no cache to flush; looking at the overlay windows");
		OverlayMgr.rescan();
	}

	static function hookEntry(ctx:CpuState):Int {
		hookEntryInt = ctx.a0;
		// The buffer's address alone says nothing; where it resumes names the function, which is
		// what turns "the hook did not do what I expected" into a disassembly question.
		noteOnce(0xB0019, "B0(19h) HookEntryInt — game installed an exception hook at "
			+ hex8(ctx.a0) + ", resuming at " + hex8(mem.Memory.read32(ctx.a0))
			+ " with sp " + hex8(mem.Memory.read32(ctx.a0 + 4)));
		return 0;
	}

	/**
		`_bu_init` and the card starters.

		Registering devices that do not exist yet. They report themselves as handled rather than
		missing, because a game calling them is doing normal setup, not asking for anything: the
		work only begins when it opens a `bu00:` file, and that is where the honest failure is.
	**/
	/** `_bu_init` — the same for the memory card, which lives on the serial port. */
	static function buInit():Int {
		Irq.unmask(Irq.SIO0);
		noteOnce(0xA0070, "A0(70h) _bu_init — memory card device registered, SIO0 unmasked");
		return 0;
	}

	static function cardInit(fn:Int):Int {
		noteOnce(0xB0000 | fn, (fn == 0x4A ? "B0(4Ah) InitCARD2" : "B0(4Bh) StartCARD2")
			+ " — no card layer yet");
		return 0;
	}

	/**
		`_96_remove` — detach the CD device.

		Does nothing, and that is the correct behaviour rather than a gap. psx-spx records that
		this function does not work on real hardware, because it removes its handler with
		SysDeqIntRP, which can only ever remove the first element of a chain. Games ship against
		the broken version; making it work would detach a CD device that every console keeps
		attached.
	**/
	static function removeCdDevice():Int {
		noteOnce(0xA0072, "A0(72h) _96_remove — does nothing, as on hardware (SysDeqIntRP bug)");
		return 0;
	}

	/**
		`ChangeClearPAD(flag)` — whether the kernel's pad handler acknowledges the interrupt itself.

		Kept because the pad layer will need it: a game that takes over acknowledgement and then
		finds the kernel has already done it reads the controller a frame late.
	**/
	static var clearPad = true;

	static function changeClearPad(ctx:CpuState):Int {
		clearPad = ctx.a0 != 0;
		noteOnce(0xB005B, "B0(5Bh) ChangeClearPAD");
		return 0;
	}

	// ---- what the interrupt controller hands us -------------------------------------------------

	/**
		An interrupt reached the CPU: turn hardware bits into kernel events.

		On hardware this work is done by the BIOS's own handlers sitting in the priority chains.
		Under HLE those handlers are not game code, so the delivery is ours: the game's chains run
		first — they are the ones that may acknowledge the hardware — and whatever is still
		pending afterwards becomes an event.

		Called from `Irq.dispatch`, which has already saved the registers.
	**/
	public static function onInterrupt(ctx:CpuState):Void {
		KHandlers.runChains(ctx);

		// The game's own epilogue runs BEFORE the kernel acknowledges anything.
		//
		// `HookEntryInt` installs a JmpBuf the exception dispatcher leaves through, and a library
		// that installs one is asking to be the exception epilogue. Its whole job is to look at
		// I_STAT and decide what happened — so acknowledging first, as this used to, handed it a
		// register with every pending bit already cleared. libetc's vblank counter never
		// incremented and `VSync` timed out against a handler that was running perfectly and
		// being shown nothing.
		if (hookEntryInt != 0) KThreads.enterJmpBuf(ctx, hookEntryInt);
		else {}

		// Whatever the game did not claim is the kernel's to deliver and clear.
		deliverPending(ctx);
	}

	/**
		Turns each pending hardware line into the kernel event that stands for it.

		On hardware the BIOS's own handlers do this, and under HLE they are not game code, so it
		falls here. Missing a line does not look like a missing line: libcd's `CdSync` waits on the
		CDROM *event*, so a controller that raised nineteen interrupts nobody translated reported
		itself as `NoIntr` — a library waiting on a message the kernel never sent.
	**/
	static function deliverPending(ctx:CpuState):Void {
		final live = Irq.stat & Irq.mask;
		if ((live & (1 << Irq.VBLANK)) != 0) vblank(ctx);
		else {}
		if ((live & (1 << Irq.CDROM)) != 0) cdrom(ctx);
		else {}
		if ((live & (1 << Irq.SPU)) != 0) line(ctx, Irq.SPU, KEvents.CLASS_SPU);
		else {}
		if ((live & (1 << Irq.GPU)) != 0) line(ctx, Irq.GPU, KEvents.CLASS_GPU);
		else {}
		if ((live & (1 << Irq.DMA)) != 0) line(ctx, Irq.DMA, KEvents.CLASS_DMA);
		else {}
		if ((live & (1 << Irq.SIO0)) != 0) line(ctx, Irq.SIO0, KEvents.CLASS_CONTROLLER);
		else {}
	}

	/**
		The CD, whose event carries *which* answer arrived.

		Every other source has one thing to say. The CD-ROM has five, and libcd branches on them:
		an acknowledgement is not a completion and neither is a sector. psx-spx "BIOS Event
		Summary" maps the controller's INT levels onto these specs.
	**/
	static function cdrom(ctx:CpuState):Void {
		KEvents.deliver(ctx, KEvents.CLASS_CDROM, specForCdInt(cd.Cdrom.currentLevel()));
		Irq.writeStat(~(1 << Irq.CDROM));
	}

	static function specForCdInt(level:Int):Int {
		if (level == 3) return 0x0010;        // acknowledged
		else if (level == 2) return 0x0020;   // the slow part completed
		else if (level == 1) return 0x0040;   // a sector is ready
		else if (level == 4) return 0x0080;   // end of the data
		else return 0x8000;                   // error
	}

	static function line(ctx:CpuState, bit:Int, cls:Int):Void {
		KEvents.deliver(ctx, cls, SPEC_INTERRUPTED);
		Irq.writeStat(~(1 << bit));
	}

	/**
		Vblank: deliver the class, and acknowledge on the game's behalf.

		The kernel's own vblank handler acks the controller, so a game that only opened an event
		never has to touch I_STAT. Acknowledging here is what stops the same vblank being
		re-delivered on the next pump, forever.
	**/
	static function vblank(ctx:CpuState):Void {
		KEvents.deliver(ctx, KEvents.CLASS_VBLANK, SPEC_INTERRUPTED);
		KEvents.deliver(ctx, CLASS_RCNT3, SPEC_INTERRUPTED);
		Irq.writeStat(~(1 << Irq.VBLANK));
	}

	/**
		A frame boundary, counted at the event rather than at delivery.

		Called by the scheduler for every vblank the machine has, including the ones a game handles
		entirely by itself. Everything that measures progress hangs off this: the heartbeat, and
		the one VRAM dump that says what was actually drawn.
	**/
	public static function onFrame(ctx:CpuState):Void {
		vblankCount++;
		// The display latches its window here, which is where a game swaps buffers. A pure read of
		// VRAM and two registers: it cannot change what the machine does, so a headless target
		// dropping it on the floor stays bit-identical to one drawing it.
		gpu.Scanout.present();
		heartbeat(ctx);
	}

	/** The spec every hardware-interrupt event is opened with. */
	public static inline var SPEC_INTERRUPTED = 0x0002;

	/** Vblank doubles as root counter 3, which is what libetc's VSync actually waits on. */
	public static inline var CLASS_RCNT3 = 0xF2000003;

	/** Frames elapsed. Deterministic, and the first number a bring-up session watches. */
	public static var vblankCount(default, null) = 0;

	/**
		A line per emulated second, because a game's main loop never returns.

		Without it a bring-up run is silent once the startup log stops, and silence looks the same
		whether the machine is running a hundred frames a second or wedged in a spin. Every number
		here is deterministic, so two runs that disagree have diverged.
	**/
	/** Set by a launcher that wants the first drawn frame written out. */
	public static var vramDump = false;
	static var dumped = false;

	static function heartbeat(ctx:CpuState):Void {
		// Late, not at the first pixel: the opening clear arrives thousands of frames before the
		// rest of the display list, and a census taken at the clear describes only the clear.
		if (vramDump && !dumped && vblankCount >= 8000) takeFrame();
		else {}
		if (vblankCount % 60 != 0) return;
		else {}
		core.Runtime.note("frame " + vblankCount
			+ " | events " + core.Scheduler.fired
			+ " | irqs " + core.Irq.delivered
			+ " | handlers " + KHandlers.calls
			+ " | claims " + KHandlers.claims + " | hooks " + KThreads.hookEntries
			+ " | delivered " + KEvents.delivered + "/" + KEvents.callbacks + "cb"
			+ " | dma " + dma.Dma.wordsToGpu + "w/" + dma.Dma.listsWalked + "list/"
			+ dma.Dma.wordsFromCd + "cdw"
			+ " | gpu " + gpu.Gpu.wordsReceived + "w/" + gpu.Gpu.commandsReceived + "c/" + gpu.Gpu.primitives + "prim/" + gpu.Gpu.pixels + "px/" + gpu.Gpu.uploaded + "up"
			+ " | cd " + cd.Cdrom.commands + "cmd/" + cd.Cdrom.sectorsDelivered + "sec/"
			+ cd.Cdrom.raised + "irq/" + cd.Cdrom.swallowed + "drop"
			// Which code was last at a loop header. Every pump point records the return address,
			// so this names the function the game is spending its time inside — the one number
			// that turns "nothing is happening" into an address to disassemble.
			+ " | spu " + spu.Spu.written + "hw/" + spu.Spu.keyedOn + "kon/"
			+ spu.Spu.samplesOut + "smp/" + spu.Spu.nonSilent + "loud "
			+ spu.Spu.settings()
			+ " | in ra=" + hex8(mem.Memory.raHint));
	}

	/**
		Writes VRAM out once, the first time anything has been drawn into it.

		A pixel counter says the rasteriser ran; only the bytes say what it drew. One megabyte,
		1024x512 halfwords, exactly as `gpu.Vram` holds it — no conversion here, so what lands on
		disc is the emulated framebuffer itself and any disagreement is the emulator's, not the
		dumper's.
	**/
	public static var reportOps = false;

	static function takeFrame():Void {
		dumped = true;
		if (reportOps) reportOpcodes();
		else {}
		Backend.storageWrite("vram.bin", gpu.Vram.data, gpu.Vram.BYTES);
		Runtime.note("wrote vram.bin at frame " + vblankCount + " — "
			+ gpu.Gpu.pixels + " pixels from " + gpu.Gpu.primitives + " primitives");
	}

	/** Every GP0 opcode the frame contained, with its count. */
	static function reportOpcodes():Void {
		for (op in 0...256) {
			if (gpu.Gpu.opCount[op] > 0) {
				Runtime.note("gp0 op 0x" + StringTools.hex(op, 2) + " x" + gpu.Gpu.opCount[op]);
			} else {}
		}
	}

	// ---- syscall / break -------------------------------------------------------------------------

	/**
		`syscall`.

		The function is selected by **$a0**, not by the instruction's 20-bit code field — compilers
		emit that field as 0 essentially always. Reporting the code field said "syscall 0" for
		every call, which is a diagnostic that cannot distinguish anything.
	**/
	public static function syscall(ctx:CpuState, code:Int):Void {
		if (ctx.a0 == 1) enterCritical(ctx);
		else if (ctx.a0 == 2) exitCritical(ctx);
		else Runtime.reportOnce(0x51000000 | (ctx.a0 & 0xFFFF), "syscall a0=" + ctx.a0);
	}

	/**
		`EnterCriticalSection` / `ExitCriticalSection`.

		**Not a nesting counter.** psx-spx is unambiguous: SYS(01h) clears SR bits and SYS(02h)
		sets them. There is no depth anywhere, and the return value is what makes that workable —
		Enter reports whether interrupts *were* on, so the caller can decide whether its own Exit
		should happen at all. Psy-Q code is written to that idiom.

		This started life as a counter here, on the reasoning that nesting ought to work properly.
		It cost an afternoon: Crash Bash enters four times, is told "were enabled" only on the
		first, exits once — and on real hardware that single exit turns interrupts back on, while
		the counter sat at three and delivered nothing for the rest of the run. Improving on the
		hardware is a bug whenever a game can tell, and the game could.

		The bit numbers psx-spx gives, 2 and 10, look wrong until you notice the BIOS runs this
		*inside* a syscall exception, where bit 2 is IEp — the value that becomes IEc on return.
		No exception is taken under HLE, so the equivalent is to drive IEc itself.
	**/
	static function enterCritical(ctx:CpuState):Void {
		ctx.v0 = (ctx.sr & Irq.SR_IEC) != 0 ? 1 : 0;
		ctx.sr = ctx.sr & ~(Irq.SR_IEC | Irq.SR_IM_HW);
		noteOnce(0x51000001, "SYS(01h) EnterCriticalSection");
	}

	static function exitCritical(ctx:CpuState):Void {
		ctx.sr = ctx.sr | Irq.SR_IEC | Irq.SR_IM_HW;
		noteOnce(0x51000002, "SYS(02h) ExitCriticalSection");
	}

	/** `break`. Psy-Q emits `break 0x400` after a divide as its divide-by-zero check. */
	public static function brk(ctx:CpuState, code:Int):Void {
		Runtime.reportOnce(0x52000000 | code, "break " + code);
	}

	// ---- plumbing -------------------------------------------------------------------------------

	static function reportCall(ctx:CpuState, vector:Int, fn:Int):Void {
		Runtime.reportOnce((vector << 16) | (fn & 0xFFFF), vectorName(vector) + "(" + hex2(fn) + ")");
	}

	static function noteOnce(key:Int, what:String):Void {
		Runtime.noteOnce(key, what);
	}

	static function vectorName(v:Int):String {
		if (v == 0xA0) return "A0";
		if (v == 0xB0) return "B0";
		if (v == 0xC0) return "C0";
		return "vector " + v;
	}

	static function hex8(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}

	static function hex2(v:Int):String {
		final digits = "0123456789abcdef";
		return "0x" + digits.charAt((v >> 4) & 0xF) + digits.charAt(v & 0xF);
	}
}
