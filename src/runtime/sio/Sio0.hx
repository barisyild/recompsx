package sio;

import core.CpuState;
import core.Irq;
import core.Scheduler;

/**
	SIO0 — the serial port the controllers and memory cards live on, and a digital pad on it.

	The port is a byte-at-a-time SPI master: writing DR shifts a byte out while the selected device
	shifts one back, and a device that wants the next byte pulls /ACK low for a moment — the
	interrupt (IRQ7) that libraries drive their transfers from. Registers and timing per psx-spx
	"Serial Interfaces (SIO)" and "Controllers and Memory Cards" (docs/specs/runtime.md §7.11).

	What is plugged in comes from `Pads`, latched once per vblank: a digital pad (SCPH-1080) on
	each port the backend reports, answering the standard read — address 01h, then ID 5A41h and two
	bytes of buttons, active low. An empty port, and the memory card address (81h, no cards yet),
	answer every byte with FFh and never acknowledge: that is how libpad and libcard see nothing
	there and move on, and it is all the port did before controllers existed.

	A digital pad answers every command as it answers 42h (read). It has no configuration mode, so a
	library probing for one (43h) is handed the digital ID and settles for a digital pad.
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

	// What the one deadline in Scheduler.SIO_BYTE means at the moment.
	static inline var IDLE = 0;
	static inline var SHIFTING = 1;        // a byte is on the wire
	static inline var ACK_DUE = 2;         // it has arrived; the device is about to acknowledge
	static inline var ACK_LOW = 3;         // /ACK is low until the deadline

	// Who answered the current selection's address byte.
	static inline var NOBODY = 0;
	static inline var PAD = 1;

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
	/** The answer to the byte on the wire, and whether the device acknowledges it. */
	static var reply = 0xFF;
	static var acks = false;

	/** Bytes the game has pushed out, counted because a probe is the first sign of pad interest. */
	public static var bytesExchanged(default, null) = 0;

	/** Before the scheduler exists: it clears its own slots. */
	public static function init():Void {
		mode = 0;
		control = 0;
		baud = 0;
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
		if ((control & CR_DTR) == 0) {
			reply = 0xFF;
			acks = false;
		} else {
			if (step == 0) address(v);
			else if (device == PAD) padByte();
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
		if (v == 0x01 && Pads.isConnected(port)) {
			device = PAD;
			latched = Pads.buttonsOf(port);
			reply = 0xFF;
			acks = true;
		} else {
			device = NOBODY;
			reply = 0xFF;
			acks = false;
		}
	}

	/** A digital pad after its address: ID 5A41h, then the buttons, active low; no /ACK last. */
	static function padByte():Void {
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
			Scheduler.scheduleAt(Scheduler.SIO_BYTE, (ctx.cycles + ACK_DELAY) | 0);
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
