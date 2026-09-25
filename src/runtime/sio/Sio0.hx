package sio;

import core.Runtime;

/**
	SIO0 — the serial port the controllers and memory cards live on.

	This first version is an honest empty port: transmit always ready, every response 0xFF, and
	the /ACK line never pulsing — exactly what the hardware reports with nothing plugged in. That
	is not a placeholder behaviour, it is a real state the libraries are written to meet: libpad
	probes the port, reads 0xFF where a controller ID should be, and reports "no controller";
	libcard does the same for the card. Both give up cleanly and the game carries on.

	It exists now because Crash Bash's device init drives this port *before* it will touch the CD,
	and an unimplemented register that reads as a constant zero looked to libpad like a port that
	was permanently busy — its poll loop never ended. Registers per psx-spx "Controllers and
	Memory Cards" as recorded in docs/specs/runtime.md §7.11.
**/
class Sio0 {
	// 1F801044 JOY_STAT bits.
	static inline var STAT_TX_READY_1 = 0x001;   // ready to take a byte
	static inline var STAT_RX_NOT_EMPTY = 0x002; // a response byte is waiting
	static inline var STAT_TX_READY_2 = 0x004;   // transmission finished

	static var mode = 0;
	static var control = 0;
	static var baud = 0;

	/** One response byte, or -1 when the FIFO is empty. An empty port answers 0xFF per exchange. */
	static var rx = -1;

	/** Bytes the game has pushed out, counted because a probe is the first sign of pad interest. */
	public static var bytesExchanged(default, null) = 0;

	public static function init():Void {
		mode = 0;
		control = 0;
		baud = 0;
		rx = -1;
		bytesExchanged = 0;
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
		JOY_STAT: always ready to transmit, and holding a byte only after an exchange.

		Bit 7, the /ACK level, stays low: an acknowledge is a *device* pulling the line, and there
		is no device. libpad reads exactly this on a real console with an empty port.
	**/
	static function stat():Int {
		var s = STAT_TX_READY_1 | STAT_TX_READY_2;
		if (rx >= 0) s |= STAT_RX_NOT_EMPTY;
		else {}
		return s;
	}

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
		if (r == 0x0) exchange(v);
		else writeWide(addr, v);
	}

	public static function write16(addr:Int, v:Int):Void {
		writeWide(addr, v);
	}

	static inline function writeWide(addr:Int, v:Int):Void {
		final r = addr & 0xF;
		if (r == 0x0) exchange(v);
		else if (r == 0x8) mode = v & 0xFFFF;
		else if (r == 0xA) writeControl(v);
		else if (r == 0xE) baud = v & 0xFFFF;
		else {}
	}

	/**
		A byte out, a byte back — 0xFF, the open-bus answer of a port with nothing on it.

		No SIO interrupt is raised: the interrupt on this port is driven by the device's /ACK, and
		with no device there is no acknowledge. libpad's probe times out on exactly that, which is
		the correct outcome for an empty port rather than a failure of ours.
	**/
	static function exchange(v:Int):Void {
		bytesExchanged++;
		rx = 0xFF;
	}

	static function writeControl(v:Int):Void {
		control = v & 0xFFFF;
		// Bit 6 is a soft reset of the port state.
		if ((v & 0x40) != 0) rx = -1;
		else {}
	}
}
