package kernel;

import core.CpuState;
import core.Irq;
import core.Runtime;
import mem.Memory;
import shim.RawBuf;
import shim.RawMem;
import sio.MemoryCard;

/**
	The BIOS's memory card driver and its backup unit, high-level emulated: B(4Ah) InitCARD2,
	B(4Bh) StartCARD2, B(4Ch) StopCARD2, B(4Dh) _card_info_subfunc, B(4Eh) _card_write, B(4Fh)
	_card_read, B(50h) _new_card, B(58h) _card_chan, B(5Ch) _card_status, B(5Dh) _card_wait,
	A(55h)/A(70h) _bu_init, A(ABh) _card_info, A(ACh) _card_load, A(ADh) _card_auto and the
	A(A7h..AAh) callbacks — everything a libcard game calls — and the primitives the `bu` device
	(`KBu`) is built on.

	Adapted from OpenBIOS: `openbios/sio0/driver.c` (MIT License, Copyright (c) 2020 PCSX-Redux
	authors), `openbios/sio0/card.c` and `openbios/card/backupunit.c` (MIT License, Copyright (c)
	2021 PCSX-Redux authors), pcsx-redux/nugget — keeping the retail behaviour games were written
	against, quirks included: one sector per slot every second vblank, the slots taking turns;
	HwCARD events that stay ready only until the next vblank; the "new card" latch that turns the
	first read, write or probe after an insertion into an EvSpNEW until someone writes; the
	backup unit's SwCARD events raised only while one of its own operations is pending; and a
	`_bu_init` that spins through a directory load per slot before it returns.

	The one liberty is how a sector moves: on hardware the vblank sends the address byte and the
	rest follows over IRQ7s for about 7 ms, and here the whole exchange happens at the vblank, with
	the card model (`sio.MemoryCard`) rather than register traffic nobody would see. A slot with no
	card answers nothing, as on hardware, and the next vblank calls it a timeout.

	Waits — `_card_wait`, `_bu_init`, and the synchronous `bu` calls — spin the way
	`KEvents.wait` does: emulated time moves to the next deadline, so vblanks, and the game's own
	interrupt handlers, run while the kernel waits.
**/
class KCard {
	// What _card_status answers (psx-spx "BIOS Memory Card Functions").
	public static inline var READY = 0x01;
	static inline var READING = 0x02;
	static inline var WRITING = 0x04;
	/** psx-spx's "busy/info"; OpenBIOS stores 00h, and bit 0 clear is what a game tests. */
	static inline var PROBING = 0x08;
	static inline var TIMED_OUT = 0x11;
	static inline var FAILED = 0x21;

	public static inline var OP_READ = 1;
	public static inline var OP_WRITE = 2;
	static inline var OP_INFO = 3;

	// Event specs (psx-spx "BIOS Event Summary"; OpenBIOS common/kernel/events.h).
	public static inline var SPEC_DONE = 0x0004;
	public static inline var SPEC_TIMEOUT = 0x0100;
	static inline var SPEC_UNKNOWN = 0x0200;
	public static inline var SPEC_NEW = 0x2000;
	public static inline var SPEC_ERROR = 0x8000;

	// The backup unit's operations in progress, OpenBIOS `g_buOperation`.
	public static inline var BU_IDLE = 0;
	static inline var BU_INFO = 1;
	public static inline var BU_READ = 2;
	public static inline var BU_WRITE = 3;
	static inline var BU_LOAD = 4;
	static inline var BU_WRITE_DONE = 7;

	/** Five emulated seconds for one sector: far past any real wait, as in `KEvents`. */
	static inline var WAIT_LIMIT_CYCLES = 5 * core.TimeBase.CPU_HZ;

	// ---- the low-level driver: OpenBIOS sio0/driver.c and sio0/card.c ----------------------------

	/** Each slot's status, OpenBIOS `g_mcFlags`: READY, or the operation it has queued or failed. */
	static var status:Array<Int>;
	static var operation:Array<Int>;
	/** The device id each slot's operation was asked for: 00h or 10h, plus a multitap's 1..3. */
	static var device:Array<Int>;
	static var sector:Array<Int>;
	/** Where a sector goes or comes from: a guest address, or the backup unit's own buffer. */
	static var target:Array<Int>;
	static var toKernel:Array<Bool>;
	/** The slot whose turn it is, OpenBIOS `g_mcPortFlipping`, and the last to finish. */
	static var turn = 0;
	static var lastPort = 0;
	/** An operation was started and nobody has answered: an empty slot, found out a vblank later. */
	static var inProgress = false;
	/** B(50h) _new_card: the next operation ignores the "new card" latch. */
	static var newCardAllowed = false;
	static var started = false;
	static var initialised = false;
	static var staging:RawBuf;

	// ---- the backup unit: OpenBIOS card/backupunit.c ---------------------------------------------

	/** What the synchronous waits watch: the last operation's outcome, OpenBIOS
	    `g_mcOverallSuccess` and `g_mcErrors` (0 error, 1 timeout, 2 new card, 3 write error). */
	static var overallSuccess = false;
	static var errors:Array<Int>;
	public static var buOperation:Array<Int>;
	static var autoFormat = 0;
	static var loadState:Array<Int>;
	static var loadSector:Array<Int>;
	/** The backup unit's sector buffer, 128 bytes a slot — OpenBIOS `g_buBuffer`. */
	public static var buffers:RawBuf;
	/**
		The directory the backup unit keeps, 15 entries a slot of 32 bytes each, laid out as the
		first 32 bytes of a directory frame: state (32 bits), size (32), next (16), name (22).
		OpenBIOS `g_buDirEntries`.
	**/
	public static var entries:RawBuf;
	/** The broken-sector list, 20 a slot; -1 for none. OpenBIOS `g_buBroken`. */
	public static var broken:Array<Int>;

	// A `bu` file's asynchronous transfer, one a slot: OpenBIOS card/device.c `g_buOp*`.
	static var opStart:Array<Int>;
	static var opCount:Array<Int>;
	static var opBuffer:Array<Int>;
	static var opFd:Array<Int>;

	/**
		Whether sectors are moving: the game waits in a card call, or a sector is queued, or one of
		the backup unit's transfers is under way — never for a probe alone, which a game may make
		every few frames. Presentation reads it (`BP_PRESENT_FAST`): such a frame need not be held
		to the video rate. Updated at each vblank; emulated state never reads it.
	**/
	public static var moving(default, null) = false;
	static var waits = 0;

	public static function init():Void {
		moving = false;
		waits = 0;
		status = [READY, READY];
		operation = [0, 0];
		device = [0, 0];
		sector = [0, 0];
		target = [0, 0];
		toKernel = [false, false];
		turn = 0;
		lastPort = 0;
		inProgress = false;
		newCardAllowed = false;
		started = false;
		initialised = false;
		staging = RawMem.alloc(MemoryCard.FRAME);
		overallSuccess = false;
		errors = [0, 0, 0, 0];
		buOperation = [BU_IDLE, BU_IDLE];
		autoFormat = 0;
		loadState = [0, 0];
		loadSector = [0, 0];
		buffers = RawMem.alloc(2 * MemoryCard.FRAME);
		entries = RawMem.alloc(2 * 15 * 32);
		broken = [for (_ in 0...40) -1];
		opStart = [0, 0];
		opCount = [0, 0];
		opBuffer = [0, 0];
		opFd = [0, 0];
	}

	/** The slot a device id names: 00h..0Fh slot 1, 10h..1Fh slot 2, as OpenBIOS divides. */
	public static inline function portOf(id:Int):Int return ((id < 0 ? id + 15 : id) >> 4) & 1;

	// ---- the calls ---------------------------------------------------------------------------------

	/** A0 functions of ours; false for any other. */
	public static function callA0(ctx:CpuState, fn:Int):Bool {
		final ours = fn == 0x55 || fn == 0x70 || fn == 0x97 || (fn >= 0xA7 && fn <= 0xAD);
		if (ours) named(0xA0, fn, ctx.a0);
		else {}
		if (fn == 0x55 || fn == 0x70) ctx.v0 = buInitAll(ctx);
		else if (fn == 0xAB) ctx.v0 = cardInfo(ctx.a0);
		else if (fn == 0xAC) ctx.v0 = readToc(ctx.a0);
		else if (fn == 0xAD) ctx.v0 = setAutoFormat(ctx.a0);
		else if (fn == 0xA7) completed(ctx);
		else if (fn == 0xA8) failedWith(ctx, 0, SPEC_ERROR);
		else if (fn == 0xA9) failedWith(ctx, 1, SPEC_TIMEOUT);
		else if (fn == 0xAA) failedWith(ctx, 2, SPEC_NEW);
		else if (fn == 0x97) ctx.v0 = 1;    // AddMemCardDevice: `bu` is always there
		else return false;
		return true;
	}

	/** B0 functions of ours; false for any other. */
	public static function callB0(ctx:CpuState, fn:Int):Bool {
		if ((fn >= 0x4A && fn <= 0x50) || fn == 0x58 || fn == 0x5C || fn == 0x5D) named(0xB0, fn, ctx.a0);
		else {}
		if (fn == 0x4A) ctx.v0 = initCard(ctx.a0);
		else if (fn == 0x4B) ctx.v0 = startCard();
		else if (fn == 0x4C) ctx.v0 = stopCard();
		else if (fn == 0x4D) ctx.v0 = probe(ctx.a0);
		else if (fn == 0x4E) ctx.v0 = queue(ctx.a0, ctx.a1, OP_WRITE, ctx.a2, false);
		else if (fn == 0x4F) ctx.v0 = queue(ctx.a0, ctx.a1, OP_READ, ctx.a2, false);
		else if (fn == 0x50) newCardAllowed = true;
		else if (fn == 0x58) ctx.v0 = device[lastPort];
		else if (fn == 0x5C) ctx.v0 = status[ctx.a0 & 1];
		else if (fn == 0x5D) ctx.v0 = waitSlot(ctx, ctx.a0 & 1);
		else return false;
		return true;
	}

	/** The first call of each: what a game's card code does is the first thing bring-up asks. */
	static function named(vector:Int, fn:Int, arg:Int):Void {
		final key = 0x6C000000 | (vector << 8) | fn;
		if (!Runtime.alreadyReported(key)) {
			Runtime.noteOnce(key, (vector == 0xA0 ? "A0(" : "B0(") + StringTools.hex(fn, 2) + "h) "
				+ nameOf(vector, fn) + ", first with " + StringTools.hex(arg, 2) + "h");
		} else {}
	}

	static function nameOf(vector:Int, fn:Int):String {
		var name = "?";
		if (vector == 0xA0) {
			if (fn == 0x55 || fn == 0x70) name = "_bu_init";
			else if (fn == 0xAB) name = "_card_info";
			else if (fn == 0xAC) name = "_card_load";
			else if (fn == 0xAD) name = "_card_auto";
			else if (fn == 0x97) name = "AddMemCardDevice";
			else name = "bufs_cb";
		} else {
			if (fn == 0x4A) name = "InitCARD2";
			else if (fn == 0x4B) name = "StartCARD2";
			else if (fn == 0x4C) name = "StopCARD2";
			else if (fn == 0x4D) name = "_card_info_subfunc";
			else if (fn == 0x4E) name = "_card_write";
			else if (fn == 0x4F) name = "_card_read";
			else if (fn == 0x50) name = "_new_card";
			else if (fn == 0x58) name = "_card_chan";
			else if (fn == 0x5C) name = "_card_status";
			else name = "_card_wait";
		}
		return name;
	}

	/**
		B(4Ah) InitCARD2(padEnable): both slots ready, the rotation back at slot 1. `padEnable` is
		the flag InitPAD sets too — whether the shared vblank handler reads the pads. Returns
		whether it had run before.
	**/
	public static function initCard(padEnable:Int):Int {
		inProgress = false;
		turn = 0;
		status[0] = READY;
		status[1] = READY;
		KPads.setReading(padEnable != 0);
		final was = initialised ? 1 : 0;
		initialised = true;
		return was;
	}

	/** B(4Bh) StartCARD2: the shared pad and card handler into its chain, vblank unmasked. */
	public static function startCard():Int {
		newCardAllowed = false;
		KPads.install(true);
		Irq.unmask(Irq.VBLANK);
		started = true;
		return 1;
	}

	/** B(4Ch) StopCARD2: the shared handler comes out — which stops the pads too. */
	public static function stopCard():Int {
		KPads.install(false);
		started = false;
		return 1;
	}

	/**
		B(4Fh) _card_read / B(4Eh) _card_write: one sector queued for the slot's next turn. 0 when
		the slot is busy or the sector is out of range — which lets 400h through, as the BIOS does.
	**/
	public static function queue(id:Int, sec:Int, op:Int, buf:Int, kernelBuffer:Bool):Int {
		final port = portOf(id);
		if ((status[port] & READY) == 0 || sec < 0 || sec > 0x400) return 0;
		else {}
		device[port] = id;
		sector[port] = sec;
		target[port] = buf;
		toKernel[port] = kernelBuffer;
		operation[port] = op;
		status[port] = op == OP_READ ? READING : WRITING;
		return 1;
	}

	static inline function readKernel(id:Int, sec:Int):Bool return queue(id, sec, OP_READ, 0, true) != 0;

	static inline function writeKernel(id:Int, sec:Int):Bool return queue(id, sec, OP_WRITE, 0, true) != 0;

	/** B(4Dh) _card_info_subfunc: the probe — address, 'R', and the FLAG and ID1 that come back. */
	public static function probe(id:Int):Int {
		final port = portOf(id);
		if ((status[port] & READY) == 0) return 0;
		else {}
		device[port] = id;
		sector[port] = 0;
		target[port] = 0;
		toKernel[port] = false;
		operation[port] = OP_INFO;
		status[port] = PROBING;
		return 1;
	}

	/** B(5Dh) _card_wait(slot): until the slot is ready again; its status. */
	static function waitSlot(ctx:CpuState, port:Int):Int {
		final began = ctx.cycles;
		waits++;
		while ((status[port] & READY) == 0 && !stuck(ctx, began)) Runtime.idleToNextEvent(ctx);
		waits--;
		return status[port];
	}

	// ---- the vblank ----------------------------------------------------------------------------------

	/**
		A vblank reached the CPU: what the shared chain-2 handler does after the pads, when
		StartCARD2 has run (OpenBIOS `firstStageCardAction`). Called by `Kernel.onInterrupt` on the
		kernel's stack, since the events it delivers may call back into the game.
	**/
	public static function onInterrupt(ctx:CpuState, atEntry:Int):Void {
		if (started && KPads.installed() && (atEntry & (1 << Irq.VBLANK)) != 0) tick(ctx);
		else {}
	}

	static function tick(ctx:CpuState):Void {
		KEvents.undeliver(ctx, KEvents.CLASS_CARD, SPEC_DONE);
		KEvents.undeliver(ctx, KEvents.CLASS_CARD, SPEC_ERROR);
		KEvents.undeliver(ctx, KEvents.CLASS_CARD, SPEC_TIMEOUT);
		KEvents.undeliver(ctx, KEvents.CLASS_CARD, SPEC_UNKNOWN);
		KEvents.undeliver(ctx, KEvents.CLASS_CARD, SPEC_NEW);
		if (inProgress) timedOut(ctx);
		else {
			turn = 1 - turn;
			if ((status[turn] & READY) == 0) run(ctx, turn);
			else {}
		}
		moving = waits > 0 || transferring(0) || transferring(1);
	}

	static function transferring(port:Int):Bool {
		final op = buOperation[port];
		return ((status[port] & READY) == 0 && operation[port] != OP_INFO)
			|| (op != BU_IDLE && op != BU_INFO);
	}

	/** Nobody answered last time: the slot is empty. The rotation does not move this vblank. */
	static function timedOut(ctx:CpuState):Void {
		inProgress = false;
		newCardAllowed = false;
		status[turn] = TIMED_OUT;
		lastPort = turn;
		failedWith(ctx, 1, SPEC_TIMEOUT);
		KEvents.deliver(ctx, KEvents.CLASS_CARD, SPEC_TIMEOUT);
	}

	static function run(ctx:CpuState, port:Int):Void {
		// A multitap's cards answer at 82h..84h, and there are none.
		if (!MemoryCard.isPresent(port) || (device[port] & 0x0F) != 0) inProgress = true;
		else if (operation[port] == OP_READ) read(ctx, port);
		else if (operation[port] == OP_WRITE) write(ctx, port);
		else info(ctx, port);
	}

	/** A read: FLAG checked for a new card, then the sector — which past 3FFh the card refuses. */
	static function read(ctx:CpuState, port:Int):Void {
		if (!newCardAllowed && (MemoryCard.flagByte() & MemoryCard.FLAG_NEW) != 0) newCard(ctx, port);
		else if (sector[port] > MemoryCard.LAST_SECTOR) failed(ctx, port);
		else {
			MemoryCard.readFrame(sector[port], staging, 0);
			toTarget(port);
			succeeded(ctx, port);
		}
	}

	/** A write: the same check, then the sector. FLAG.2, a previous write's failure, never rises. */
	static function write(ctx:CpuState, port:Int):Void {
		if (!newCardAllowed && (MemoryCard.flagByte() & MemoryCard.FLAG_NEW) != 0) newCard(ctx, port);
		else if (sector[port] > MemoryCard.LAST_SECTOR) failed(ctx, port);
		else {
			fromTarget(port);
			MemoryCard.writeFrame(sector[port], staging, 0);
			succeeded(ctx, port);
		}
	}

	/** The probe: FLAG.2 is an error and FLAG.3 a new card — both leaving the slot ready — else done. */
	static function info(ctx:CpuState, port:Int):Void {
		final flag = MemoryCard.flagByte();
		if (!newCardAllowed && (flag & 0x04) != 0) {
			newCardAllowed = false;
			status[port] = READY;
			lastPort = port;
			failedWith(ctx, 0, SPEC_ERROR);
			KEvents.deliver(ctx, KEvents.CLASS_CARD, SPEC_ERROR);
		} else if (!newCardAllowed && (flag & MemoryCard.FLAG_NEW) != 0) newCard(ctx, port);
		else succeeded(ctx, port);
	}

	static function succeeded(ctx:CpuState, port:Int):Void {
		newCardAllowed = false;
		status[port] = READY;
		lastPort = port;
		completed(ctx);
		KEvents.deliver(ctx, KEvents.CLASS_CARD, SPEC_DONE);
	}

	static function failed(ctx:CpuState, port:Int):Void {
		newCardAllowed = false;
		status[port] = FAILED;
		lastPort = port;
		failedWith(ctx, 0, SPEC_ERROR);
		KEvents.deliver(ctx, KEvents.CLASS_CARD, SPEC_ERROR);
	}

	static function newCard(ctx:CpuState, port:Int):Void {
		newCardAllowed = false;
		status[port] = READY;
		lastPort = port;
		failedWith(ctx, 2, SPEC_NEW);
		KEvents.deliver(ctx, KEvents.CLASS_CARD, SPEC_NEW);
	}

	static function toTarget(port:Int):Void {
		if (toKernel[port]) {
			for (i in 0...MemoryCard.FRAME) RawMem.set8(buffers, (port << 7) + i, RawMem.get8(staging, i));
		} else {
			final at = target[port];
			for (i in 0...MemoryCard.FRAME) Memory.write8((at + i) | 0, RawMem.get8(staging, i));
		}
	}

	static function fromTarget(port:Int):Void {
		if (toKernel[port]) {
			for (i in 0...MemoryCard.FRAME) RawMem.set8(staging, i, RawMem.get8(buffers, (port << 7) + i));
		} else {
			final at = target[port];
			for (i in 0...MemoryCard.FRAME) RawMem.set8(staging, i, Memory.read8u((at + i) | 0));
		}
	}

	// ---- the backup unit's callbacks: A(A7h..AAh) ------------------------------------------------------

	/**
		A(A7h) bufs_cb_0, OpenBIOS `buLowLevelOpCompleted`: an operation finished, which moves on
		whatever the backup unit had pending on that slot — the next sector of a `bu` file's
		asynchronous transfer, or of a directory load — and raises SwCARD when it is done.
	**/
	static function completed(ctx:CpuState):Void {
		overallSuccess = true;
		final id = device[lastPort];
		final port = portOf(id);
		final op = buOperation[port];
		if (op == BU_IDLE) {}
		else if (op == BU_WRITE_DONE) {
			KEvents.deliver(ctx, opFd[port], SPEC_DONE);
			KBu.advance(opFd[port], MemoryCard.FRAME);
			finish(ctx, port, SPEC_DONE);
		} else if (op == BU_INFO || op == 8) finish(ctx, port, SPEC_DONE);
		else if (op == BU_READ) nextRead(ctx, port, id);
		else if (op == BU_WRITE || op == 6) nextWrite(ctx, port, id);
		else if (op == BU_LOAD) loadStep(ctx, port, id);
		else fail(ctx, port);
	}

	/** A(A8h..AAh) bufs_cb_1..3: an error, a timeout, a new card; SwCARD if the unit was busy. */
	static function failedWith(ctx:CpuState, index:Int, spec:Int):Void {
		errors[index] = 1;
		final port = portOf(device[lastPort]);
		if (buOperation[port] != BU_IDLE) finish(ctx, port, spec);
		else {}
	}

	/** OpenBIOS `buFinishAndTrigger`. */
	static function finish(ctx:CpuState, port:Int, spec:Int):Void {
		buOperation[port] = BU_IDLE;
		loadState[port] = 0;
		loadSector[port] = 0;
		KEvents.deliver(ctx, KEvents.CLASS_BU, spec);
	}

	static function fail(ctx:CpuState, port:Int):Void {
		overallSuccess = false;
		errors[0] = 1;
		finish(ctx, port, SPEC_ERROR);
	}

	static function nextRead(ctx:CpuState, port:Int, id:Int):Void {
		opCount[port]--;
		if (opCount[port] == 0) {
			finish(ctx, port, SPEC_DONE);
			KEvents.deliver(ctx, opFd[port], SPEC_DONE);
		} else {
			opBuffer[port] = (opBuffer[port] + MemoryCard.FRAME) | 0;
			KBu.advance(opFd[port], MemoryCard.FRAME);
			opStart[port]++;
			if (queue(id, fileSector(port, KBu.firstBlock(opFd[port]), opStart[port]), OP_READ, opBuffer[port], false) == 0)
				fail(ctx, port);
			else {}
		}
	}

	static function nextWrite(ctx:CpuState, port:Int, id:Int):Void {
		buOperation[port] = BU_WRITE;
		opCount[port]--;
		if (opCount[port] == 0) {
			// The last sector is confirmed with a probe, and its completion is what finishes.
			overallSuccess = false;
			if (cardInfo(id) == 0) {
				errors[0] = 1;
				finish(ctx, port, SPEC_ERROR);
			} else {}
			buOperation[port] = BU_WRITE_DONE;
		} else {
			opBuffer[port] = (opBuffer[port] + MemoryCard.FRAME) | 0;
			KBu.advance(opFd[port], MemoryCard.FRAME);
			opStart[port]++;
			if (queue(id, fileSector(port, KBu.firstBlock(opFd[port]), opStart[port]), OP_WRITE, opBuffer[port], false) == 0)
				fail(ctx, port);
			else {}
		}
	}

	/**
		Starts a `bu` file's asynchronous transfer of `count` sectors from the file's `first`: its
		first sector now, each of the others when the one before it completes. False when the
		slot would not take the first.
	**/
	public static function startTransfer(ctx:CpuState, fd:Int, id:Int, write:Bool, first:Int, count:Int, buf:Int):Bool {
		final port = portOf(id);
		buOperation[port] = write ? BU_WRITE : BU_READ;
		opStart[port] = first;
		opCount[port] = count;
		opBuffer[port] = buf;
		opFd[port] = fd;
		resetStatus(ctx);
		var ok = true;
		if (count == 0) {
			overallSuccess = true;
			finish(ctx, port, SPEC_DONE);
		} else {
			ok = queue(id, fileSector(port, KBu.firstBlock(fd), first), write ? OP_WRITE : OP_READ, buf, false) != 0;
		}
		return ok;
	}

	// ---- the backup unit's calls -------------------------------------------------------------------

	/** A(ABh) _card_info(port): the probe, with SwCARD to say how it went. 1 queued, 0 busy. */
	public static function cardInfo(id:Int):Int {
		final port = portOf(id);
		buOperation[port] = BU_INFO;
		final queued = probe(id);
		if (queued == 0) buOperation[port] = BU_IDLE;
		else {}
		return queued != 0 ? 1 : 0;
	}

	/** A(ADh) _card_auto(flag): format a card without "MC" when it is next initialised. */
	static function setAutoFormat(flag:Int):Int {
		final was = autoFormat;
		autoFormat = flag;
		return was;
	}

	/**
		A(55h)/A(70h) _bu_init: both slots' directories read into the backup unit — which, as on
		hardware, spins through a directory load per card before it returns (OpenBIOS
		`initBackupUnit`).
	**/
	static function buInitAll(ctx:CpuState):Int {
		// The kernel has armed SIO0's line here since before there were cards (e468132), and games
		// that drive their pads through SIO0 have run with it since. OpenBIOS's driver unmasks it
		// only while a transfer runs, so after a card operation it would be masked again; which
		// the retail BIOS leaves is an open question (PROGRESS.md), and changing it is not this.
		Irq.unmask(Irq.SIO0);
		buOperation[0] = BU_IDLE;
		buOperation[1] = BU_IDLE;
		autoFormat = 0;
		resetStatus(ctx);
		for (i in 0...30) {
			clearEntry(i);
			setState(i, MemoryCard.FREE);
			setNext(i, -1);
		}
		buInit(ctx, 0x00);
		buInit(ctx, 0x10);
		return 0;
	}

	/**
		OpenBIOS `buInit`: frame 0 must say "MC" (else a format, if `_card_auto` asked for one); a
		write of it to frame 63 clears the card's "new card" latch; then the directory and the
		broken-sector list, every frame checked. 1, or 0 with the slot's directory emptied.
	**/
	public static function buInit(ctx:CpuState, id:Int):Int {
		final port = portOf(id);
		newCardAllowed = true;
		if (!readKernel(id, 0) || !waitStatus(ctx)) return buInitFailed(port);
		else {}
		if (bufferByte(port, 0) != 0x4D || bufferByte(port, 1) != 0x43) {
			return autoFormat != 0 ? format(ctx, id) : buInitFailed(port);
		} else {}
		newCardAllowed = true;
		writeKernel(id, 0x3F);
		waitStatus(ctx);
		for (i in 0...15) {
			clearEntry(port * 15 + i);
			setState(port * 15 + i, MemoryCard.FREE);
		}
		for (i in 0...15) {
			if (!readKernel(id, i + 1) || !waitStatus(ctx) || !checksumOk(port)) return buInitFailed(port);
			else {}
			entryFromBuffer(port, i);
		}
		correctChains(port, true);
		for (i in 0...20) {
			if (!readKernel(id, i + 16) || !waitStatus(ctx) || !checksumOk(port)) return buInitFailed(port);
			else {}
			broken[port * 20 + i] = RawMem.get32(buffers, port << 7);
		}
		return 1;
	}

	/** What a slot that failed to initialise is left with: an all-zero directory — no free
	    block in it — and no broken sectors. */
	static function buInitFailed(port:Int):Int {
		forget(port);
		return 0;
	}

	public static function forget(port:Int):Void {
		for (i in 0...15) clearEntry(port * 15 + i);
		for (i in 0...20) broken[port * 20 + i] = -1;
	}

	/** Whether `_card_auto` asked for a card without "MC" to be formatted. */
	public static inline function formatsBlankCards():Bool return autoFormat != 0;

	/**
		A(ACh) _card_load(port): the same directory read, asynchronously, finishing with SwCARD —
		0004h, or 2000h for a card without "MC". Unlike `_bu_init` it writes nothing, so a changed
		card answers "new card" first. 1 queued, 0 busy.
	**/
	static function readToc(id:Int):Int {
		final port = portOf(id);
		buOperation[port] = BU_LOAD;
		if (readKernel(id, 0)) {
			loadState[port] = 1;
			return 1;
		} else {
			buOperation[port] = BU_IDLE;
			return 0;
		}
	}

	static function loadStep(ctx:CpuState, port:Int, id:Int):Void {
		final state = loadState[port];
		if (state == 1) {
			if (bufferByte(port, 0) != 0x4D || bufferByte(port, 1) != 0x43) {
				overallSuccess = false;
				errors[2] = 1;
				finish(ctx, port, SPEC_NEW);
			} else {
				for (i in 0...15) {
					clearEntry(port * 15 + i);
					setNext(port * 15 + i, -1);
					setState(port * 15 + i, MemoryCard.FREE);
				}
				if (!readKernel(id, 1)) fail(ctx, port);
				else {
					loadSector[port] = 0;
					loadState[port] = 2;
				}
			}
		} else if (state == 2) {
			if (checksumOk(port)) entryFromBuffer(port, loadSector[port]);
			else {}
			loadSector[port]++;
			if (loadSector[port] < 15) {
				if (!readKernel(id, loadSector[port] + 1)) fail(ctx, port);
				else {}
			} else {
				correctChains(port, false);
				for (i in 0...20) broken[port * 20 + i] = -1;
				if (!readKernel(id, 16)) finish(ctx, port, SPEC_ERROR);
				else {}
				loadSector[port] = 0;
				loadState[port] = 3;
			}
		} else if (state == 3) {
			if (checksumOk(port)) broken[port * 20 + loadSector[port]] = RawMem.get32(buffers, port << 7);
			else {}
			loadSector[port]++;
			if (loadSector[port] < 20) {
				if (!readKernel(id, loadSector[port] + 16)) fail(ctx, port);
				else {}
			} else finish(ctx, port, SPEC_DONE);
		} else {}
	}

	/**
		OpenBIOS `buFormat`: "MC", fifteen free entries and an empty broken-sector list written to
		the card, each frame waited for. The broken-sector frames are written from the buffer the
		last entry went through, so their bytes 04h..1Fh are that entry's — FFFFh at 08h, which is
		psx-spx's "some cards have FFFFh at 08h-09h".
	**/
	public static function format(ctx:CpuState, id:Int):Int {
		final port = portOf(id);
		final b = port << 7;
		for (i in 0...MemoryCard.FRAME) RawMem.set8(buffers, b + i, 0);
		RawMem.set8(buffers, b, 0x4D);
		RawMem.set8(buffers, b + 1, 0x43);
		sealBuffer(port);
		newCardAllowed = true;
		if (!writeKernel(id, 0)) return 0;
		else {}
		waitStatus(ctx);
		for (i in 0...15) {
			final e = port * 15 + i;
			clearEntry(e);
			setState(e, MemoryCard.FREE);
			setNext(e, -1);
			entryToBuffer(port, i);
			sealBuffer(port);
			if (!writeKernel(id, i + 1)) return 0;
			else {}
			waitIndex(ctx);
		}
		for (i in 0...20) {
			broken[port * 20 + i] = -1;
			RawMem.set32(buffers, b, -1);
			sealBuffer(port);
			if (!writeKernel(id, i + 16)) return 0;
			else {}
			waitIndex(ctx);
		}
		return 1;
	}

	/**
		OpenBIOS `buWriteTOC`: the entries marked in `marks` written back — the ones marked 52h
		first, then the one marked 51h, the file's head — each pass confirmed with a probe. True
		when anything failed.
	**/
	public static function writeToc(ctx:CpuState, id:Int, marks:Array<Int>):Bool {
		return !writeTocPass(ctx, id, marks, MemoryCard.MIDDLE) || !writeTocPass(ctx, id, marks, MemoryCard.FIRST);
	}

	static function writeTocPass(ctx:CpuState, id:Int, marks:Array<Int>, want:Int):Bool {
		final port = portOf(id);
		var ok = true;
		for (i in 0...15) {
			if (ok && marks[i] == want) {
				entryToBuffer(port, i);
				sealBuffer(port);
				ok = writeKernel(id, i + 1) && waitStatus(ctx);
			} else {}
		}
		return ok && cardInfo(id) != 0 && waitStatus(ctx);
	}

	// ---- waiting ---------------------------------------------------------------------------------

	/** OpenBIOS `mcResetStatus`: the outcome forgotten, the SwCARD events taken back. */
	public static function resetStatus(ctx:CpuState):Void {
		overallSuccess = false;
		for (i in 0...4) errors[i] = 0;
		KEvents.undeliver(ctx, KEvents.CLASS_BU, SPEC_DONE);
		KEvents.undeliver(ctx, KEvents.CLASS_BU, SPEC_ERROR);
		KEvents.undeliver(ctx, KEvents.CLASS_BU, SPEC_NEW);
		KEvents.undeliver(ctx, KEvents.CLASS_BU, SPEC_TIMEOUT);
	}

	/** OpenBIOS `mcWaitForStatus`: until an operation succeeds or fails; whether it succeeded. */
	public static function waitStatus(ctx:CpuState):Bool {
		return waitIndex(ctx) == 0;
	}

	/** OpenBIOS `mcWaitForStatusAndReturnIndex`: 0 for success, else 1 + the error's index. */
	public static function waitIndex(ctx:CpuState):Int {
		final began = ctx.cycles;
		waits++;
		while (!overallSuccess && firstError() < 0 && !stuck(ctx, began)) Runtime.idleToNextEvent(ctx);
		waits--;
		if (!overallSuccess && firstError() < 0) errors[1] = 1;
		else {}
		final index = overallSuccess ? 0 : firstError() + 1;
		resetStatus(ctx);
		return index;
	}

	static function firstError():Int {
		var found = -1;
		for (i in 0...4) {
			if (found < 0 && errors[i] != 0) found = i;
			else {}
		}
		return found;
	}

	/**
		Whether a wait can no longer end: the driver is stopped, so no vblank will move it; the run
		is being unwound; or five emulated seconds have gone by. On hardware the first is a hang
		for ever; here it is reported and treated as a timeout.
	**/
	static function stuck(ctx:CpuState, began:Int):Bool {
		var gaveUp = false;
		if (ctx.unwindToken != 0) gaveUp = true;
		else if (!started || !KPads.installed()) {
			Runtime.reportOnce(0x6D000002, "a memory card wait with the card driver stopped "
				+ "(StartCARD2 not called, or StopPAD/StopCARD2 since) — treated as a timeout");
			gaveUp = true;
		} else if (((ctx.cycles - began) | 0) > WAIT_LIMIT_CYCLES) {
			Runtime.reportOnce(0x6D000003, "a memory card wait did not end in five seconds — "
				+ "are interrupts off? Treated as a timeout");
			gaveUp = true;
		} else {}
		return gaveUp;
	}

	// ---- the directory the backup unit keeps ----------------------------------------------------------

	/**
		The sector of a file's `rel`th frame, following its chain from dir index `block`: OpenBIOS
		`buRelativeToAbsoluteSector`, then `buGetReallocated`. Past the chain's end that is -1 —
		which the remapping then finds among the list's empty entries, so a transfer run past a
		file's end reads and writes frame 36, as the BIOS's does.
	**/
	public static function fileSector(port:Int, block:Int, rel:Int):Int {
		var b = block;
		var r = rel;
		var ok = b >= 0 && b < 15;
		while (ok && r > 0x3F) {
			b = nextOf(port * 15 + b);
			r -= 0x40;
			ok = b >= 0 && b < 15;
		}
		final absolute = ok ? b * 64 + r + 0x40 : -1;
		final moved = reallocated(port, absolute);
		return moved >= 0 ? moved : absolute;
	}

	/** OpenBIOS `buGetReallocated`: the frame a listed broken sector's data lives in, or -1. */
	static function reallocated(port:Int, sec:Int):Int {
		var found = -1;
		for (i in 0...20) {
			if (found < 0 && broken[port * 20 + i] == sec) found = i + 36;
			else {}
		}
		return found;
	}

	/**
		OpenBIOS's two passes over a freshly read directory. The first frees any file whose chain
		runs into an entry of the wrong kind (`buValidateEntryAndCorrect`); the second frees every
		entry no file's chain reaches. `deleted` also counts deleted files as files, as `_bu_init`
		does and `_card_load` does not.
	**/
	static function correctChains(port:Int, deleted:Bool):Void {
		final base = port * 15;
		for (i in 0...15) validateEntry(port, i);
		final reached = [for (_ in 0...15) 0];
		for (i in 0...15) {
			final s = stateAt(base + i);
			if (s == MemoryCard.FIRST || (deleted && s == 0xA1)) {
				reached[i] = 1;
				var blocks = blocksOf(base + i);
				var next = nextOf(base + i);
				blocks--;
				while (blocks > 0 && next >= 0 && next < 15) {
					reached[next]++;
					next = nextOf(base + next);
					blocks--;
				}
			} else {}
		}
		for (i in 0...15) {
			if (reached[i] == 0) {
				setSize(base + i, 0);
				setState(base + i, MemoryCard.FREE);
				setNext(base + i, -1);
			} else {}
		}
	}

	static function validateEntry(port:Int, i:Int):Void {
		final base = port * 15;
		final s = stateAt(base + i);
		final mask = s == MemoryCard.FIRST ? 0xA0 : (s == 0xA1 ? 0x50 : -1);
		var blocks = blocksOf(base + i) - 1;
		var next = nextOf(base + i);
		if (mask >= 0 && blocks > 0 && next != -1) {
			var ptr = next;
			var count = blocks;
			var mismatch = false;
			var walking = true;
			while (walking) {
				if (ptr < 0 || ptr >= 15) walking = false;
				else if ((stateAt(base + ptr) & 0xF0) == mask) {
					mismatch = true;
					walking = false;
				} else {
					ptr = nextOf(base + ptr);
					count--;
					walking = count >= 0 && ptr != -1;
				}
			}
			if (mismatch) {
				RawMem.set8(entries, (base + i) * 32 + 0x0A, 0);
				setState(base + i, MemoryCard.FREE);
				setSize(base + i, 0);
				setNext(base + i, -1);
				while (blocks > 0 && next >= 0 && next < 15) {
					final e = base + next;
					next = nextOf(e);
					blocks--;
					setState(e, MemoryCard.FREE);
					setSize(e, 0);
					setNext(e, -1);
				}
			} else {}
		} else {}
	}

	/** A file's size in blocks, rounding as OpenBIOS's signed shift does. */
	static function blocksOf(e:Int):Int {
		var size = sizeAt(e);
		if (size < 0) size = (size + 0x1FFF) | 0;
		else {}
		return size >> 13;
	}

	public static inline function stateAt(e:Int):Int return RawMem.get32(entries, e * 32);

	public static inline function setState(e:Int, v:Int):Void RawMem.set32(entries, e * 32, v);

	public static inline function sizeAt(e:Int):Int return RawMem.get32(entries, e * 32 + 4);

	public static inline function setSize(e:Int, v:Int):Void RawMem.set32(entries, e * 32 + 4, v);

	/** The next entry's index, sign-extended: FFFFh is -1. */
	public static inline function nextOf(e:Int):Int return (RawMem.get16(entries, e * 32 + 8) << 16) >> 16;

	public static inline function setNext(e:Int, v:Int):Void RawMem.set16(entries, e * 32 + 8, v & 0xFFFF);

	public static inline function nameByte(e:Int, i:Int):Int return RawMem.get8(entries, e * 32 + 0x0A + i);

	public static inline function setNameByte(e:Int, i:Int, v:Int):Void RawMem.set8(entries, e * 32 + 0x0A + i, v);

	static function clearEntry(e:Int):Void {
		for (i in 0...32) RawMem.set8(entries, e * 32 + i, 0);
	}

	static inline function bufferByte(port:Int, i:Int):Int return RawMem.get8(buffers, (port << 7) + i);

	static function entryFromBuffer(port:Int, i:Int):Void {
		final e = (port * 15 + i) * 32;
		for (k in 0...32) RawMem.set8(entries, e + k, RawMem.get8(buffers, (port << 7) + k));
	}

	/** An entry's 32 bytes over the start of the buffer, whose other bytes stay as they were. */
	static function entryToBuffer(port:Int, i:Int):Void {
		final e = (port * 15 + i) * 32;
		for (k in 0...32) RawMem.set8(buffers, (port << 7) + k, RawMem.get8(entries, e + k));
	}

	static function sealBuffer(port:Int):Void {
		final b = port << 7;
		var x = 0;
		for (k in 0...0x7F) x ^= RawMem.get8(buffers, b + k);
		RawMem.set8(buffers, b + 0x7F, x);
	}

	static function checksumOk(port:Int):Bool {
		final b = port << 7;
		var x = 0;
		for (k in 0...0x7F) x ^= RawMem.get8(buffers, b + k);
		return RawMem.get8(buffers, b + 0x7F) == x;
	}
}
