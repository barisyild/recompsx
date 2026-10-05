package sio;

import core.CpuState;
import core.Irq;
import core.Scheduler;
import shim.RawBuf;
import shim.RawMem;

/**
	SIO0 — the serial port the controllers and memory cards live on, and the pads on it.

	The port is a byte-at-a-time SPI master: writing DR shifts a byte out while the selected device
	shifts one back, and a device that wants the next byte pulls /ACK low for a moment — the
	interrupt (IRQ7) that libraries drive their transfers from. Registers and timing per psx-spx
	"Serial Interfaces (SIO)" and "Controllers and Memory Cards" (docs/specs/runtime.md §7.11).

	What is plugged in comes from `Pads`, latched once per vblank: digital pads (SCPH-1080)
	answering the standard read — address 01h, then ID 5A41h and two bytes of buttons, active low —
	and, for a host pad with sticks, DualShocks (`DualShock`, ADR-0052), which answer the same until
	a game or the player switches them to analog mode. Port 1 has a multitap in it (`Multitap`,
	ADR-0042), which answers for its slot A as a pad does and, asked, for all four slots. The memory
	card in slot 1 (`MemoryCard`) answers at 81h with the read, write and ID commands a Sony card
	has. An empty port, and the card address of an empty slot, answer every byte with FFh and never
	acknowledge: that is how libpad and libcard see nothing there and move on.

	A digital pad answers every command as it answers 42h (read). It has no configuration mode, so a
	library probing for one (43h) is handed the digital ID and settles for a digital pad. A DualShock
	enters configuration mode there.
**/
class Sio0 {
	// SR, 1F801044h.
	static inline var SR_TXRDY = 0x001;    // ready for a new byte
	static inline var SR_RXRDY = 0x002;    // a received byte is waiting
	static inline var SR_TXIDLE = 0x004;   // the last transfer has finished
	static inline var SR_DSR = 0x080;      // /ACK is low
	static inline var SR_IRQ = 0x200;      // interrupt request, sticky until acknowledged

	// CR, 1F80104Ah.
	static inline var CR_TXEN = 0x0001;
	static inline var CR_DTR = 0x0002;     // /CS low on the selected port
	static inline var CR_ACK = 0x0010;     // acknowledge: clear SR.3 and SR.9
	static inline var CR_RESET = 0x0040;
	static inline var CR_DSRIEN = 0x1000;  // interrupt when /ACK goes low
	static inline var CR_PORT = 0x2000;    // the port /CS selects: 0 is port 1, 1 is port 2

	/**
		From the end of a byte to the device pulling /ACK low, and how long it holds it there.

		The BIOS ignores an acknowledge within about 100 cycles of the last clock and gives up
		after 100 us (psx-spx, "Controller and Memory Card Signals"); its driver clears IRQ7 about
		that long after writing a byte, which is why psx-spx warns that an emulated device must not
		acknowledge at once. 170 cycles, 5 us, sits inside that window with room on both sides.
		The low time is psx-spx's "circa 100 clock cycles".
	**/
	static inline var ACK_DELAY = 170;
	static inline var ACK_LENGTH = 100;
	/** A Sony card acknowledges the sixth byte of a read — its 5Ch — about 31000 cycles late
	    (psx-spx, "Memory Card Read/Write Commands"); other makers' cards do not. */
	static inline var ACK_LATE = 31000;

	// What the one deadline in Scheduler.SIO_BYTE means at the moment.
	static inline var IDLE = 0;
	static inline var SHIFTING = 1;        // a byte is on the wire
	static inline var ACK_DUE = 2;         // it has arrived; the device is about to acknowledge
	static inline var ACK_LOW = 3;         // /ACK is low until the deadline

	// Who answered the current selection's address byte.
	static inline var NOBODY = 0;
	static inline var PAD = 1;
	static inline var CARD = 2;
	static inline var TAP_LONG = 3;        // the multitap, all four slots
	static inline var TAP_GARBAGE = 4;     // the multitap, the four bytes after a long read asked again

	static var mode = 0;
	static var control = 0;
	static var baud = 0;

	static var phase = IDLE;
	/** The received byte, or -1 when there is none. */
	static var rx = -1;
	/** A byte written while another was on the wire, or before TXEN; -1 when none waits. */
	static var queued = -1;
	static var irq = false;
	static var ackLow = false;

	/** Which byte of the current /CS selection goes next, the address byte being 0. */
	static var step = 0;
	static var device = NOBODY;
	/** The pad's buttons as of its address byte, so that one transfer reports one moment. */
	static var latched = 0;
	/** Which of the host's pads (`Pads`) the selection reads, while `device` is PAD. */
	static var padIndex = 0;
	/** The selection is a slot-A read through the multitap: what it answers, and its request —
	    whether the third byte was 01h — which the tap acts on at the next one. */
	static var tapAccess = false;
	static var tapKind = 0;
	static var tapRequest = false;
	/** The answer to the byte on the wire, and whether the device acknowledges it, and when. */
	static var reply = 0xFF;
	static var acks = false;
	static var ackExtra = 0;

	// The card's side of a command: which one, its sector, the running checksum, the byte the host
	// sent before this one — the "(pre)" psx-spx says a card echoes — and a write's 128 bytes,
	// which reach the card only once its checksum has been checked.
	static var cardCommand = 0;
	static var cardSector = 0;
	static var cardSum = 0;
	static var cardPrev = 0;
	static var cardGood = false;
	static var staging:RawBuf;

	/** Bytes the game has pushed out, counted because a probe is the first sign of pad interest. */
	public static var bytesExchanged(default, null) = 0;

	/** Before the scheduler exists: it clears its own slots. */
	public static function init():Void {
		mode = 0;
		control = 0;
		baud = 0;
		staging = RawMem.alloc(MemoryCard.FRAME);
		clearTransfer();
		bytesExchanged = 0;
	}

	static function clearTransfer():Void {
		phase = IDLE;
		rx = -1;
		queued = -1;
		irq = false;
		ackLow = false;
		endSelection();
	}

	static function endSelection():Void {
		if (tapAccess) {
			tapAccess = false;
			Multitap.finished(tapKind, tapRequest);
		} else {}
		step = 0;
		device = NOBODY;
	}

	public static function read8(addr:Int):Int {
		final r = addr & 0xF;
		if (r == 0x0) return popRx();
		else return readWide(addr) & 0xFF;
	}

	public static function read16(addr:Int):Int {
		return readWide(addr) & 0xFFFF;
	}

	public static function read32(addr:Int):Int {
		return readWide(addr);
	}

	static inline function readWide(addr:Int):Int {
		final r = addr & 0xF;
		if (r == 0x0) return popRx();
		else if (r == 0x4) return stat();
		else if (r == 0x8) return mode;
		else if (r == 0xA) return control;
		else if (r == 0xE) return baud;
		else return 0;
	}

	/**
		SR. Ready for a byte whenever none is waiting — the hardware takes the next one as soon as
		the current one has started — and idle once nothing is on the wire. The baud timer bits
		(11 and up) read as zero; nothing observed polls them.
	**/
	static function stat():Int {
		var s = 0;
		if (queued < 0) s |= SR_TXRDY;
		else {}
		if (queued < 0 && phase != SHIFTING) s |= SR_TXIDLE;
		else {}
		if (rx >= 0) s |= SR_RXRDY;
		else {}
		if (ackLow) s |= SR_DSR;
		else {}
		if (irq) s |= SR_IRQ;
		else {}
		return s;
	}

	/** DR read: the received byte, or FFh from an empty FIFO, as before. */
	static inline function popRx():Int {
		if (rx < 0) return 0xFF;
		else {
			final b = rx;
			rx = -1;
			return b;
		}
	}

	public static function write8(addr:Int, v:Int):Void {
		final r = addr & 0xF;
		if (r == 0x0) exchange(v & 0xFF);
		else writeWide(addr, v);
	}

	public static function write16(addr:Int, v:Int):Void {
		writeWide(addr, v);
	}

	static inline function writeWide(addr:Int, v:Int):Void {
		final r = addr & 0xF;
		if (r == 0x0) exchange(v & 0xFF);
		else if (r == 0x8) mode = v & 0xFFFF;
		else if (r == 0xA) writeControl(v & 0xFFFF);
		else if (r == 0xE) baud = v & 0xFFFF;
		else {}
	}

	/**
		DR write: a byte out. It goes at once unless one is still on the wire or TXEN is off, in
		which case it waits, and a second write while it waits replaces it (psx-spx, "DR Write
		Notes"). A byte that goes while /ACK is still low for the previous one ends that pulse: a
		driver writes the next byte the moment it sees the acknowledge.
	**/
	static function exchange(v:Int):Void {
		bytesExchanged++;
		if (phase == SHIFTING || (control & CR_TXEN) == 0) queued = v;
		else start(v);
	}

	static function start(v:Int):Void {
		answer(v);
		ackLow = false;
		phase = SHIFTING;
		Scheduler.scheduleAt(Scheduler.SIO_BYTE, (mem.Memory.cycleHint() + byteCycles()) | 0);
	}

	/** A waiting byte goes, if TXEN allows and the wire is free. */
	static function startQueued():Void {
		if (queued >= 0 && phase != SHIFTING && (control & CR_TXEN) != 0) {
			final b = queued;
			queued = -1;
			start(b);
		} else {}
	}

	/**
		CR write. Reset clears the port but keeps the mode and baud rate, which the BIOS writes
		after it. Acknowledge clears the interrupt flag — except while /ACK is still low, a glitch
		psx-spx records (SR.9 is not edge triggered). Letting /CS go, or moving it to the other
		port, ends the conversation: the next byte is an address again.
	**/
	static function writeControl(v:Int):Void {
		if ((v & CR_RESET) != 0) {
			control = 0;
			clearTransfer();
			Scheduler.cancelSlot(Scheduler.SIO_BYTE);
		} else {
			final before = control;
			control = v & ~(CR_ACK | CR_RESET);
			if ((v & CR_ACK) != 0 && !ackLow) irq = false;
			else {}
			if ((control & CR_DTR) == 0 || ((before ^ control) & CR_PORT) != 0) endSelection();
			else {}
			startQueued();
		}
	}

	/** One byte's time on the wire: eight bits at the programmed rate (psx-spx, BR and MR). */
	static function byteCycles():Int {
		final f = mode & 3;
		final factor = f == 2 ? 16 : (f == 3 ? 64 : 1);
		var perBit = (baud * factor) & ~1;
		if (perBit < 1) perBit = 1;
		else {}
		return perBit * 8;
	}

	// ---- the device side -------------------------------------------------------------------------

	/** What the selected device answers the byte `v` with, and whether it acknowledges it. */
	static function answer(v:Int):Void {
		ackExtra = 0;
		if ((control & CR_DTR) == 0) {
			reply = 0xFF;
			acks = false;
		} else {
			if (step == 2 && tapAccess) tapRequest = v == 0x01;
			else {}
			if (step == 0) address(v);
			else if (device == PAD) padByte(v);
			else if (device == CARD) cardByte(v);
			else if (device == TAP_LONG) tapLongByte(v);
			else if (device == TAP_GARBAGE) tapGarbageByte();
			else {
				reply = 0xFF;
				acks = false;
			}
			step++;
		}
	}

	/** The address byte: the device it names answers from now on, or nobody does. */
	static function address(v:Int):Void {
		final port = (control & CR_PORT) != 0 ? 1 : 0;
		device = NOBODY;
		reply = 0xFF;
		acks = false;
		if (port == 0 && Multitap.plugged) tapAddress(v);
		else portAddress(port, v);
	}

	/** A port with a pad or a card in it directly. */
	static function portAddress(port:Int, v:Int):Void {
		final pad = Pads.padOnPort(port);
		if (v == 0x01 && pad >= 0 && Pads.isConnected(pad)) {
			device = PAD;
			choose(pad);
			acks = true;
		} else if (v == 0x81 && MemoryCard.isPresent(port)) {
			device = CARD;
			acks = true;
		} else {}
	}

	/**
		The multitap's addresses: 01h is slot A, answering as `Multitap.next` says; 02h-04h slots
		B-D, each as a pad of its own; 81h slot A's card, the machine's one. An empty slot, and the
		cards of B-D, are answered by nobody.
	**/
	static function tapAddress(v:Int):Void {
		if (v == 0x01) {
			if (Pads.isConnected(0)) {
				tapAccess = true;
				tapKind = Multitap.next();
				tapRequest = false;
				choose(0);
				if (tapKind == Multitap.LONG) {
					Multitap.latch();
					Multitap.used();
					device = TAP_LONG;
				} else if (tapKind == Multitap.GARBAGE) device = TAP_GARBAGE;
				else device = PAD;
				acks = true;
			} else Multitap.aborted();
		} else if (v >= 0x02 && v <= 0x04) {
			if (Pads.isConnected(v - 1)) {
				device = PAD;
				choose(v - 1);
				acks = true;
				Multitap.used();
			} else {}
		} else if (v == 0x81 && MemoryCard.isPresent(0)) {
			device = CARD;
			acks = true;
		} else {}
	}

	/** The pad that answers from the next byte on, its buttons (and a DualShock's sticks) as they are now. */
	static function choose(pad:Int):Void {
		padIndex = pad;
		latched = Pads.buttonsOf(pad);
		if (Pads.isDualShock(pad)) DualShock.select(pad);
		else {}
	}

	/**
		The long read after its address: ID 5A80h, then the four slots' 32 bytes; no /ACK last. Each
		slot's eight bytes are its controller's answer to the eight the host sent in that window of
		the *previous* long read — a command, its TAP byte and six more, as a transfer of its own
		after the address the tap gives it (ADR-0042 amended, ADR-0052). The bytes sent now go to the
		controllers when this read ends (`Multitap.finished`). So libpad configures a DualShock in a
		slot, and drives its motors, through long reads, a read behind.
	**/
	static function tapLongByte(v:Int):Void {
		if (step == 1) {
			reply = 0x80;
			acks = true;
		} else if (step == 2) {
			reply = 0x5A;
			acks = true;
		} else if (step < 3 + Multitap.SLOT_BYTES) {
			reply = Multitap.slotByte(step - 3);
			Multitap.command(step - 3, v);
			acks = step < 2 + Multitap.SLOT_BYTES;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	/** Garbage: the tap's ID, then slot A's ID low byte, and the transfer ends there. */
	static function tapGarbageByte():Void {
		if (step == 1) {
			reply = 0x80;
			acks = true;
		} else if (step == 2) {
			reply = 0x5A;
			acks = true;
		} else if (step == 3) {
			reply = Pads.isDualShock(0) ? DualShock.readAt(0, 0) : 0x41;
			acks = false;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	/** A pad after its address byte, `v` the byte the host sends: a DualShock's answer, or a digital pad's. */
	static function padByte(v:Int):Void {
		if (Pads.isDualShock(padIndex)) {
			final r = DualShock.answer(step, v);
			reply = r & 0xFF;
			acks = (r & DualShock.ACK) != 0;
		} else digitalByte();
	}

	/** A digital pad after its address: ID 5A41h, then the buttons, active low; no /ACK last. */
	static function digitalByte():Void {
		if (step == 1) {
			reply = 0x41;
			acks = true;
		} else if (step == 2) {
			reply = 0x5A;
			acks = true;
		} else if (step == 3) {
			reply = ~latched & 0xFF;
			acks = true;
		} else if (step == 4) {
			reply = (~latched >> 8) & 0xFF;
			acks = false;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	/**
		The memory card after its address (psx-spx, "Memory Card Read/Write Commands"): the
		command byte is answered with FLAG, then a read (52h) is 5Ah 5Dh, the sector's two bytes
		echoed, 5Ch 5Dh, the sector confirmed, its 128 bytes, the checksum and 47h; a write (57h)
		takes the sector, 128 bytes and their checksum, echoing each byte a step late, and ends
		with 5Ch 5Dh and 47h — or 4Eh for a bad checksum, FFh for a sector past 3FFh; the ID
		command (53h) answers 5Ah 5Dh 5Ch 5Dh 04h 00h 00h 80h. The checksum is the sector's two
		bytes and the data XORed together. A read of a sector past 3FFh confirms FFFFh and stops.
		Any other command is answered with FLAG and nothing after it.
	**/
	static function cardByte(v:Int):Void {
		if (step == 1) {
			cardCommand = v;
			reply = MemoryCard.flagByte();
			acks = v == 0x52 || v == 0x57 || v == 0x53;
		} else if (cardCommand == 0x52) cardRead(v);
		else if (cardCommand == 0x57) cardWrite(v);
		else cardId();
		cardPrev = v;
	}

	static function cardRead(v:Int):Void {
		final bad = cardSector > MemoryCard.LAST_SECTOR;
		acks = true;
		if (step == 2) reply = 0x5A;
		else if (step == 3) reply = 0x5D;
		else if (step == 4) reply = 0x00;
		else if (step == 5) {
			cardSector = (cardPrev << 8) | v;
			reply = cardPrev;
		} else if (step == 6) {
			reply = 0x5C;
			ackExtra = ACK_LATE;
		} else if (step == 7) reply = 0x5D;
		else if (step == 8) {
			reply = bad ? 0xFF : (cardSector >> 8) & 0xFF;
			cardSum = reply;
		} else if (step == 9) {
			reply = bad ? 0xFF : cardSector & 0xFF;
			cardSum ^= reply;
			acks = !bad;
		} else if (step < 138 && !bad) {
			reply = MemoryCard.read8(cardSector, step - 10);
			cardSum ^= reply;
		} else if (step == 138 && !bad) reply = cardSum;
		else if (step == 139 && !bad) {
			reply = 0x47;
			acks = false;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	static function cardWrite(v:Int):Void {
		acks = true;
		if (step == 2) reply = 0x5A;
		else if (step == 3) reply = 0x5D;
		else if (step == 4) reply = 0x00;
		else if (step == 5) {
			cardSector = (cardPrev << 8) | v;
			cardSum = cardPrev ^ v;
			reply = cardPrev;
		} else if (step < 134) {
			RawMem.set8(staging, step - 6, v);
			cardSum ^= v;
			reply = cardPrev;
		} else if (step == 134) {
			cardGood = v == (cardSum & 0xFF);
			reply = cardPrev;
		} else if (step == 135) reply = 0x5C;
		else if (step == 136) reply = 0x5D;
		else if (step == 137) {
			reply = cardEnd();
			acks = false;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	/** A write's end byte, and the write itself when it is one the card takes. */
	static function cardEnd():Int {
		var end = 0x47;
		if (cardSector > MemoryCard.LAST_SECTOR) end = 0xFF;
		else if (!cardGood) end = 0x4E;
		else MemoryCard.writeFrame(cardSector, staging, 0);
		return end;
	}

	static function cardId():Void {
		acks = true;
		if (step == 2) reply = 0x5A;
		else if (step == 3) reply = 0x5D;
		else if (step == 4) reply = 0x5C;
		else if (step == 5) reply = 0x5D;
		else if (step == 6) reply = 0x04;
		else if (step == 7) reply = 0x00;
		else if (step == 8) reply = 0x00;
		else if (step == 9) {
			reply = 0x80;
			acks = false;
		} else {
			reply = 0xFF;
			acks = false;
		}
	}

	// ---- the deadline --------------------------------------------------------------------------

	/** Scheduler.SIO_BYTE: a byte has arrived, or the device's /ACK falls, or it rises again. */
	public static function onEvent(ctx:CpuState):Void {
		if (phase == SHIFTING) arrived(ctx);
		else if (phase == ACK_DUE) ackFalls(ctx);
		else if (phase == ACK_LOW) ackRises();
		else {}
	}

	static function arrived(ctx:CpuState):Void {
		rx = reply;
		if (acks) {
			phase = ACK_DUE;
			Scheduler.scheduleAt(Scheduler.SIO_BYTE, (ctx.cycles + ACK_DELAY + ackExtra) | 0);
		} else {
			phase = IDLE;
			startQueued();
		}
	}

	/** /ACK low. The interrupt is its edge: none while an earlier one is still unacknowledged. */
	static function ackFalls(ctx:CpuState):Void {
		ackLow = true;
		if ((control & CR_DSRIEN) != 0 && !irq) {
			irq = true;
			Irq.raise(ctx, Irq.SIO0);
		} else {}
		phase = ACK_LOW;
		Scheduler.scheduleAt(Scheduler.SIO_BYTE, (ctx.cycles + ACK_LENGTH) | 0);
	}

	static function ackRises():Void {
		ackLow = false;
		phase = IDLE;
		startQueued();
	}
}
