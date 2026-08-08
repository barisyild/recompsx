package cd;

import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import core.TimeBase;
import shim.RawBuf;
import shim.RawMem;

/**
	The CD-ROM controller, at the register level.

	This is the part that matters, and finding that out cost a working file layer. Psy-Q's libcd
	does not use the kernel's `open`/`read` — it drives these four registers directly, so a game
	with a perfectly good filesystem underneath it still reads nothing until the controller answers.
	Almost every commercial PlayStation game is built this way.

	The shape is a small state machine with a mailbox. The CPU writes a command and its parameters;
	the controller answers some cycles later by pushing bytes into the response FIFO and raising an
	interrupt with a *level* — INT3 for "acknowledged", INT2 for "the slow part finished", INT1 for
	"a sector is ready", INT5 for "that was an error". Only one interrupt is outstanding at a time
	and the next waits until the CPU acknowledges, which is why the queue exists.

	Register map and the command table are from psx-spx "CDROM Registers" and "CDROM Commands", as
	recorded in docs/specs/runtime.md §7.7. Latencies are **defined constants** rather than measured
	ones: they only have to be consistent, and a constant is reproducible where a measurement is
	not.
**/
class Cdrom {
	// Latencies, in CPU cycles. docs/specs/runtime.md §7.7.
	static inline var ACK = 50000;
	static inline var SEEK_BASE = 564480;
	static inline var INIT_TIME = 2000000;
	static inline var PAUSE_TIME = 1000000;
	static inline var GETID_TIME = 451584;
	static inline var SECTOR_1X = 451584;
	static inline var SECTOR_2X = 225792;

	// Interrupt levels the controller can raise.
	static inline var INT1_DATA = 1;
	static inline var INT2_DONE = 2;
	static inline var INT3_ACK = 3;
	static inline var INT5_ERROR = 5;

	// Status byte bits, psx-spx "CDROM Status".
	static inline var ST_ERROR = 0x01;
	static inline var ST_MOTOR = 0x02;
	static inline var ST_SEEK_ERROR = 0x04;
	static inline var ST_SHELL_OPEN = 0x10;
	static inline var ST_READING = 0x20;
	static inline var ST_SEEKING = 0x40;
	static inline var ST_PLAYING = 0x80;

	static inline var FIFO = 16;
	static inline var SECTOR_BYTES = 2048;

	static var index = 0;
	static var status = ST_MOTOR;
	static var mode = 0;

	// Parameters the CPU has written, and the answer waiting to be read back.
	static var param:Array<Int>;
	static var paramCount = 0;
	static var response:Array<Int>;
	static var responseCount = 0;
	static var responseRead = 0;

	/** The interrupt level being reported, 0 when none, and the one queued behind it. */
	static var currentInt = 0;
	static var queuedInt = 0;
	static var queuedResponse:Array<Int>;
	static var queuedCount = 0;

	static var irqEnable = 0;

	/**
		The first answer, waiting out its acknowledgement delay.

		Separate from the queue, which holds the *second* answer to a slow command. Both exist
		because a command produces up to two interrupts and neither may be raised inside the
		register write that asked for it — see `respond`.
	**/
	/** True between a command write and the first answer reaching the CPU. */
	static var busy = false;

	static var pendingInt = 0;
	static var pendingResponse:Array<Int>;
	static var pendingCount = 0;

	/** The cycle count as of the last register access, so a response can be dated. */
	static var now = 0;

	// Where the head is and what it is doing.
	static var seekLba = 0;
	static var readLba = 0;
	static var reading = false;

	/** The sector just delivered, and how much of it the CPU has taken. */
	static var sector:RawBuf;
	static var sectorPos = 0;
	static var sectorReady = false;

	/** Deterministic counters — sectors delivered is the first sign the game is loading. */
	public static var sectorsDelivered(default, null) = 0;
	public static var commands(default, null) = 0;

	public static function init():Void {
		param = [for (_ in 0...FIFO) 0];
		response = [for (_ in 0...FIFO) 0];
		queuedResponse = [for (_ in 0...FIFO) 0];
		pendingResponse = [for (_ in 0...FIFO) 0];
		pendingInt = 0;
		pendingCount = 0;
		now = 0;
		sector = RawMem.alloc(SECTOR_BYTES);
		index = 0;
		status = ST_MOTOR;
		mode = 0;
		paramCount = 0;
		responseCount = 0;
		responseRead = 0;
		currentInt = 0;
		queuedInt = 0;
		queuedCount = 0;
		irqEnable = 0;
		seekLba = 0;
		readLba = 0;
		reading = false;
		busy = false;
		sectorPos = 0;
		sectorReady = false;
		sectorsDelivered = 0;
		commands = 0;
		raised = 0;
		swallowed = 0;
	}

	// ---- diagnostic trace ------------------------------------------------------------------------
	//
	// Bounded, and removed once the dialogue is understood. Five hypotheses about why libcd never
	// sees its interrupt have died to measurement; this stops the guessing by recording the actual
	// conversation: every register access, every response, every acknowledgement, in order.
	static var traceLeft = 60;

	public static inline function tracing():Bool return traceLeft > 0;

	/** True while an interrupt is latched — the window where the handler's reads matter. */
	public static inline function intLatched():Bool return currentInt != 0;

	public static function tnote(what:String):Void {
		if (traceLeft <= 0) return;
		else {}
		traceLeft--;
		Runtime.note("cd# " + what);
	}

	// ---- the four registers ----------------------------------------------------------------------

	/**
		Who reads these registers from ordinary code.

		A handler reading the controller is expected. Anything reading it *outside* interrupt
		dispatch is a driver polling — and since libcd installs no chain element, opens no event
		and does not carry the exception hook, polling is the only door left. The caller's return
		address names the function, which turns the rest into a disassembly question.
	**/
	static var pollTrace = 20;

	public static function readPolled(addr:Int, ra:Int):Int {
		if (pollTrace > 0 && !Irq.dispatching()) {
			pollTrace--;
			Runtime.note("cdpoll r " + StringTools.hex(addr, 8) + ".idx" + index
				+ " from ra=" + StringTools.hex(ra, 8) + " int=" + currentInt);
		} else {}
		return read8(addr);
	}

	public static function read8(addr:Int):Int {
		final reg = addr & 3;
		if (reg == 0) return statusRegister();
		else if (reg == 1) return popResponse();
		else if (reg == 2) return popData();
		else return read1803();
	}

	public static function write8(addr:Int, v:Int, cycles:Int):Void {
		now = cycles;
		final reg = addr & 3;
		if (reg == 0) index = v & 3;
		else if (reg == 1) write1801(v, cycles);
		else if (reg == 2) write1802(v);
		else write1803(v);
	}

	/**
		1F801800 read: the index, plus the flags the CPU polls before touching anything else.

		Bit 5, "parameter FIFO has room", and bit 3, "it is empty", are both true here because the
		FIFO is never actually full — a game that checks before writing gets a yes and proceeds,
		which is the behaviour it is checking for.
	**/
	static function statusRegister():Int {
		var s = index;
		s |= 0x08;                                   // parameter FIFO empty
		s |= 0x10;                                   // room for a parameter
		if (responseRead < responseCount) s |= 0x20; // a response byte is waiting
		else {}
		if (sectorReady && sectorPos < SECTOR_BYTES) s |= 0x40;   // data is waiting
		else {}
		// Bit 7, BUSYSTS: a command has been written and the controller has not answered it yet.
		//
		// It was never set, and a controller that is never busy is one that never visibly *took*
		// a command. libcd writes a command and watches this bit go up and come down again — that
		// transition is its acknowledgement that the drive heard it at all, and without it the
		// library re-issues the same command forever, which is exactly the loop the trace shows.
		if (busy) s |= 0x80;
		else {}
		return s;
	}

	static function popResponse():Int {
		if (responseRead >= responseCount) return emptyResponse();
		else {}
		final b = response[responseRead];
		responseRead++;
		tnote("r resp -> " + b);
		return b;
	}

	static function emptyResponse():Int {
		tnote("r resp -> EMPTY");
		return 0;
	}

	static function popData():Int {
		if (!sectorReady || sectorPos >= SECTOR_BYTES) return 0;
		else {}
		final b = RawMem.get8(sector, sectorPos);
		sectorPos++;
		return b;
	}

	/** 1F801803 reads the interrupt enable on index 0 and the pending flags on index 1. */
	static function read1803():Int {
		final v = (index & 1) == 0 ? irqEnable | 0xE0 : currentInt | 0xE0;
		tnote("r 1803." + index + " -> " + v);
		return v;
	}

	static function write1801(v:Int, cycles:Int):Void {
		if (index == 0) execute(v, cycles);
		else Runtime.reportOnce(0x64000000 | index, "CD write to 1801 with index " + index);
	}

	static function write1802(v:Int):Void {
		if (index == 0) pushParam(v);
		else if (index == 1) setIrqEnable(v);
		else {}   // the volume registers, which mean nothing without audio
	}

	static function setIrqEnable(v:Int):Void {
		irqEnable = v & 0x1F;
		tnote("irqEnable := " + irqEnable);
	}

	static function pushParam(v:Int):Void {
		if (paramCount < FIFO) param[paramCount] = v & 0xFF;
		else {}
		if (paramCount < FIFO) paramCount++;
		else {}
	}

	/**
		1F801803 writes: acknowledge on index 1, request data on index 0.

		Acknowledging is what lets the next interrupt through, so this is where a queued one is
		released. A game that stops acknowledging stops receiving, exactly as on hardware.
	**/
	static function write1803(v:Int):Void {
		if (index == 0) requestData(v);
		else if (index == 1) acknowledge(v);
		else {}
	}

	static function requestData(v:Int):Void {
		// Bit 7 loads the sector just delivered into the data FIFO; clearing it discards it.
		if ((v & 0x80) != 0) sectorPos = 0;
		else sectorReady = false;
	}

	static function acknowledge(v:Int):Void {
		tnote("ack " + v + " (int was " + currentInt + ")");
		if ((v & 0x40) != 0) paramCount = 0;
		else {}
		if ((v & 0x07) == 0) return;
		else {}
		currentInt = 0;
		// The queued second answer goes through the scheduler like the first, and for the same
		// reason: releasing it here delivers it *inside* the driver's acknowledging write, before
		// that driver has finished handling the answer it was acknowledging. The first response
		// was moved off this path days ago; this one was left behind, so every two-interrupt
		// command — Init, Reset, SeekL, GetID — handed its completion to a library still mid-ack.
		if (queuedInt != 0) schedule(now, ACK);
		else {}
	}

	static function releaseQueued():Void {
		tnote("INT " + queuedInt + " released from the queue");
		responseCount = queuedCount;
		responseRead = 0;
		for (i in 0...queuedCount) response[i] = queuedResponse[i];
		currentInt = queuedInt;
		queuedInt = 0;
		raise();
	}

	// ---- commands ----------------------------------------------------------------------------------

	/**
		A command word.

		Every one answers INT3 first — an acknowledgement that it was understood — and the ones that
		take real time follow with INT2 or a stream of INT1s later. Splitting it that way is not
		decoration: libcd waits on the first and then on the second, and a controller that answered
		once would leave it waiting forever.
	**/
	static function execute(cmd:Int, cycles:Int):Void {
		busy = true;
		tnote("cmd 0x" + StringTools.hex(cmd, 2) + " params=" + paramCount);
		commands++;
		if (cmd == 0x01) ackWith1(status);                      // Getstat
		else if (cmd == 0x02) setloc();
		else if (cmd == 0x06 || cmd == 0x1B) startReading(cycles);
		else if (cmd == 0x09) pause(cycles);
		else if (cmd == 0x0A) initCommand(cycles);
		else if (cmd == 0x0B || cmd == 0x0C) ackWith1(status);  // Mute / Demute
		else if (cmd == 0x0E) setmode();
		else if (cmd == 0x13) getTn();
		else if (cmd == 0x14) getTd();
		else if (cmd == 0x15 || cmd == 0x16) seek(cycles);
		else if (cmd == 0x19) test();
		else if (cmd == 0x1A) getId(cycles);
		else if (cmd == 0x1E) readToc(cycles);
		else unknownCommand(cmd);
		paramCount = 0;
	}

	static function unknownCommand(cmd:Int):Void {
		Runtime.reportOnce(0x65000000 | cmd, "CD command " + cmd + " is not implemented");
		errorWith(0x40);
	}

	/** `Setloc mm,ss,ff` in BCD — the head's destination, not a seek in itself. */
	static function setloc():Void {
		if (paramCount < 3) return errorWith(0x20);
		else {}
		final m = fromBcd(param[0]);
		final s = fromBcd(param[1]);
		final f = fromBcd(param[2]);
		// Two seconds of lead-in sit before sector zero on every disc.
		seekLba = (m * 60 + s - 2) * 75 + f;
		if (seekLba < 0) seekLba = 0;
		else {}
		ackWith1(status);
	}

	static function setmode():Void {
		if (paramCount < 1) return errorWith(0x20);
		else {}
		mode = param[0];
		ackWith1(status);
	}

	static function seek(cycles:Int):Void {
		readLba = seekLba;
		status |= ST_SEEKING;
		// The second answer follows the first; both go through the event, in order.
		queue(INT2_DONE, seekDone(), 1);
		ackWith1(status);
	}

	static function seekDone():Int {
		status &= ~ST_SEEKING;
		return status;
	}

	static function startReading(cycles:Int):Void {
		readLba = seekLba;
		reading = true;
		status = (status | ST_READING) & ~ST_SEEKING;
		ackWith1(status);
	}

	static function pause(cycles:Int):Void {
		reading = false;
		status &= ~(ST_READING | ST_SEEKING | ST_PLAYING);
		queue(INT2_DONE, status, 1);
		ackWith1(status);
	}

	static function initCommand(cycles:Int):Void {
		mode = 0;
		reading = false;
		status = ST_MOTOR;
		queue(INT2_DONE, status, 1);
		ackWith1(status);
	}

	/** `Test 20h` reports the controller's date and version, which is all any game asks it for. */
	static function test():Void {
		if (paramCount >= 1 && param[0] == 0x20) return testVersion();
		else {}
		errorWith(0x10);
	}

	static function testVersion():Void {
		response[0] = 0x94; response[1] = 0x09; response[2] = 0x19; response[3] = 0xC0;
		respond(INT3_ACK, 4);
	}

	/**
		`GetID` — what disc is in the drive.

		The licensed-disc answer, with the region string a game checks before it will run at all.
		A disc that is not there answers INT5, and a game meets that as an ordinary condition.
	**/
	static function getId(cycles:Int):Void {
		ackWith1(status);
		if (!Iso9660.mounted) return queueNoDisc(cycles);
		else {}
		queuedResponse[0] = 0x02; queuedResponse[1] = 0x00;
		queuedResponse[2] = 0x20; queuedResponse[3] = 0x00;
		queuedResponse[4] = 0x53; queuedResponse[5] = 0x43;   // 'S' 'C'
		queuedResponse[6] = 0x45; queuedResponse[7] = 0x41;   // 'E' 'A'
		queuedInt = INT2_DONE;
		queuedCount = 8;
	}

	static function queueNoDisc(cycles:Int):Void {
		queuedResponse[0] = 0x08; queuedResponse[1] = 0x40;
		queuedInt = INT5_ERROR;
		queuedCount = 2;
	}

	/**
		`GetTN` — the first and last track numbers, in BCD.

		A single-track data disc, which is what a mounted image is: one track, numbered one. Games
		ask before anything else because it tells them whether there is audio on the disc, and libcd
		gives up on the whole drive if it does not get an answer.
	**/
	static function getTn():Void {
		response[0] = status;
		response[1] = 0x01;
		response[2] = 0x01;
		respond(INT3_ACK, 3);
	}

	/**
		`GetTD` — where a track starts, as minutes and seconds in BCD.

		Track 0 means the end of the disc, which is how a game finds its length; track 1 starts at
		the two-second lead-in every disc carries. Seconds are what the command reports — frames are
		not part of the answer.
	**/
	static function getTd():Void {
		final track = paramCount >= 1 ? fromBcd(param[0]) : 0;
		final lba = track == 0 ? discSectors() : 0;
		final total = lba + 150;                     // back to absolute MSF, lead-in included
		response[0] = status;
		response[1] = toBcd(Std.int(total / (60 * 75)));
		response[2] = toBcd(Std.int(total / 75) % 60);
		respond(INT3_ACK, 3);
	}

	/** The image's length in sectors, which is where the one track ends. */
	static function discSectors():Int {
		return Iso9660.totalSectors();
	}

	static inline function toBcd(v:Int):Int {
		return Std.int(v / 10) * 16 + (v % 10);
	}

	static function readToc(cycles:Int):Void {
		queue(INT2_DONE, status, 1);
		ackWith1(status);
	}

	// ---- the event that delivers ------------------------------------------------------------------

	static inline function sectorInterval():Int {
		// Mode bit 7 is double speed.
		return (mode & 0x80) != 0 ? SECTOR_2X : SECTOR_1X;
	}

	static function schedule(cycles:Int, delay:Int):Void {
		Scheduler.scheduleAt(Scheduler.CD_EVENT, (cycles + delay) | 0);
	}

	/**
		The controller's own deadline came round.

		Either a queued second answer is due, or a sector is. Reading re-arms itself, which is what
		makes `ReadN` a stream rather than a single answer.
	**/
	public static function onEvent(ctx:CpuState):Void {
		now = ctx.cycles;
		// The first answer, then the second, then sectors — each waits for the CPU to have
		// acknowledged the one before, because only one interrupt is outstanding at a time.
		if (pendingInt != 0 && currentInt == 0) return deliverPending();
		else if (pendingInt != 0) return schedule(ctx.cycles, ACK);
		else if (queuedInt != 0 && currentInt == 0) return releaseQueued();
		else if (queuedInt != 0) return schedule(ctx.cycles, ACK);
		else {}
		if (reading) deliverSector(ctx);
		else {}
	}

	static function deliverSector(ctx:CpuState):Void {
		if (currentInt != 0) return schedule(ctx.cycles, ACK);   // the CPU has not caught up
		else {}
		if (!Iso9660.rawSector(readLba, sector)) return readFailed();
		else {}
		sectorReady = true;
		sectorPos = 0;
		readLba++;
		sectorsDelivered++;
		respond(INT1_DATA, statusOnly());
		schedule(ctx.cycles, sectorInterval());
	}

	static function readFailed():Void {
		reading = false;
		status = (status | ST_ERROR) & ~ST_READING;
		Runtime.reportOnce(0x66000000, "CD read past the end of the image at LBA " + readLba);
		errorWith(0x10);
	}

	static function statusOnly():Int {
		response[0] = status;
		return 1;
	}

	// ---- answering --------------------------------------------------------------------------------

	static function ackWith1(b:Int):Void {
		response[0] = b;
		respond(INT3_ACK, 1);
	}

	static function errorWith(code:Int):Void {
		response[0] = status | ST_ERROR;
		response[1] = code;
		respond(INT5_ERROR, 2);
	}

	/**
		Answers a command — later, never now.

		This used to set the response and raise the interrupt inside the register write that issued
		the command, and libcd never saw any of it. Hardware always takes cycles to answer, and
		libcd arms its wait *after* writing the command: an interrupt raised before that arrives to
		an empty room. Nineteen were raised and acknowledged by nobody, while the library reported
		`NoIntr` about commands it had understood perfectly.

		So every answer is deferred by the acknowledgement latency and delivered from the
		scheduler. Deferring is not a fidelity nicety here; it is the difference between a
		controller that works and one that does not.
	**/
	static function respond(level:Int, count:Int):Void {
		tnote("-> INT" + level + " deferred, bytes " + bytesOf(response, count));
		for (i in 0...count) pendingResponse[i] = response[i];
		pendingInt = level;
		pendingCount = count;
		schedule(now, ACK);
	}

	/** Moves a deferred answer into the FIFO and rings the bell. */
	static function deliverPending():Void {
		busy = false;
		tnote("INT " + pendingInt + " delivered, " + pendingCount + " bytes");
		responseCount = pendingCount;
		responseRead = 0;
		for (i in 0...pendingCount) response[i] = pendingResponse[i];
		currentInt = pendingInt;
		pendingInt = 0;
		raise();
	}

	static function queue(level:Int, first:Int, count:Int):Void {
		tnote("-> INT" + level + " queued, first byte " + first);
		queuedResponse[0] = first;
		queuedInt = level;
		queuedCount = count;
	}

	/** Which answer is outstanding, so the kernel can say what kind of event it is. */
	public static function currentLevel():Int return currentInt;

	static function raise():Void {
		if ((irqEnable & currentInt) != 0) fire();
		else dropped();
	}

	static function fire():Void {
		raised++;
		Irq.raiseLine(Irq.CDROM);
	}

	/** An answer nobody will hear. Worth counting: it is the difference between a controller that
		is silent and one that is shouting into a disconnected wire. */
	static function dropped():Void {
		swallowed++;
		Runtime.reportOnce(0x67000000,
			"CD interrupt dropped: level " + currentInt + " but irqEnable is " + irqEnable);
	}

	public static var raised(default, null) = 0;
	public static var swallowed(default, null) = 0;

	static function bytesOf(a:Array<Int>, n:Int):String {
		var out = "";
		for (i in 0...n) out += (i > 0 ? "," : "") + StringTools.hex(a[i], 2);
		return out;
	}

	static inline function fromBcd(v:Int):Int {
		return ((v >> 4) & 0xF) * 10 + (v & 0xF);
	}
}
