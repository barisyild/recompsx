package spu;

import core.Runtime;
import shim.RawBuf;
import shim.RawMem;

/**
	The sound processor, as far as its memory is concerned.

	Not a synthesiser yet — no voices, no ADSR, no reverb, and nothing reaches the speakers. What
	is here is the half a game notices *before* it makes any sound: 512 KB of sound RAM, the
	transfer address that says where the next upload lands, and the acknowledgement that an upload
	finished.

	That half is not optional in the way silence is. Psy-Q's libspu uploads its wave data with a
	DMA transfer and then waits — properly, on an event — for the transfer to complete. A machine
	with no SPU at all never sends that acknowledgement, so the game waits forever, having drawn
	nothing, with no error anywhere: it is not stuck on sound, it is stuck on being told that
	sound finished. Crash Bash spends its entire boot in that wait.

	So the registers implemented here are the ones a transfer needs, and the rest still report
	themselves as unimplemented rather than pretending. Voices come later; what they will need is
	already underneath them, because the data really is being written where the game put it.

	Register map from psx-spx "SPU Registers", as recorded in docs/specs/runtime.md section 7.6.
**/
class Spu {
	/** Sound RAM: 512 KB, addressed in 8-byte units by every register that names it. */
	public static inline var RAM_BYTES = 0x80000;

	static inline var BASE = 0x1F801C00;
	static inline var END = 0x1F801E00;

	// The registers this understands. Everything else in the range is still reported.
	static inline var REG_TRANSFER_ADDR = 0x1F801DA6;
	static inline var REG_FIFO = 0x1F801DA8;
	static inline var REG_CONTROL = 0x1F801DAA;
	static inline var REG_TRANSFER_CTRL = 0x1F801DAC;
	static inline var REG_STATUS = 0x1F801DAE;

	public static var ram(default, null):RawBuf;

	/** Where the next transferred halfword goes. Held in bytes; the register counts eights. */
	static var transferAddr = 0;

	static var control = 0;
	static var transferControl = 0;

	/** Halfwords written into sound RAM. The first evidence a game's audio data arrived. */
	public static var written(default, null) = 0;

	public static function init():Void {
		ram = RawMem.alloc(RAM_BYTES);
		transferAddr = 0;
		control = 0;
		transferControl = 0;
		written = 0;
	}

	public static inline function contains(p:Int):Bool {
		return p >= BASE && p < END;
	}

	// ---- registers ------------------------------------------------------------------------------

	public static function read16(p:Int):Int {
		if (p == REG_TRANSFER_ADDR) return (transferAddr >> 3) & 0xFFFF;
		else if (p == REG_CONTROL) return control;
		else if (p == REG_TRANSFER_CTRL) return transferControl;
		else if (p == REG_STATUS) return status();
		else return unhandledRead(p);
	}

	public static function write16(p:Int, v:Int):Void {
		if (p == REG_TRANSFER_ADDR) transferAddr = (v & 0xFFFF) << 3;
		else if (p == REG_FIFO) pushHalfword(v);
		else if (p == REG_CONTROL) control = v & 0xFFFF;
		else if (p == REG_TRANSFER_CTRL) transferControl = v & 0xFFFF;
		else unhandledWrite(p);
	}

	/**
		SPUSTAT, of which only two things are true here.

		The low six bits mirror the control register, which games read back. Bit 10 is "busy", and
		it is always zero because every transfer completes inside the write that started it — a
		game that polls for the transfer to finish finds it already has.
	**/
	static function status():Int {
		return control & 0x3F;
	}

	// ---- transfers ------------------------------------------------------------------------------

	/** One halfword through the manual FIFO at 1F801DA8, which advances the transfer address. */
	public static function pushHalfword(v:Int):Void {
		store16(transferAddr, v);
		transferAddr = (transferAddr + 2) & (RAM_BYTES - 1);
	}

	/**
		A word from DMA channel 4, which is how a game of any size actually loads sound.

		Little-endian halfword order, matching the FIFO: the low half is written first, so a
		transfer through the channel and the same bytes pushed one at a time leave sound RAM
		identical. That equivalence is worth keeping — libspu uses both.
	**/
	public static function dmaWord(v:Int):Void {
		pushHalfword(v & 0xFFFF);
		pushHalfword((v >>> 16) & 0xFFFF);
	}

	static function store16(addr:Int, v:Int):Void {
		final a = addr & (RAM_BYTES - 2);
		RawMem.set8(ram, a, v & 0xFF);
		RawMem.set8(ram, a + 1, (v >>> 8) & 0xFF);
		written++;
	}

	// ---- what is still missing ------------------------------------------------------------------

	static function unhandledRead(p:Int):Int {
		final key = 0x12000000 | (p & 0xFFFF);
		if (!Runtime.alreadyReported(key)) {
			Runtime.reportOnce(key, "read from SPU register " + hex(p) + " — no voices yet");
		} else {}
		return 0;
	}

	static function unhandledWrite(p:Int):Void {
		final key = 0x13000000 | (p & 0xFFFF);
		if (!Runtime.alreadyReported(key)) {
			Runtime.reportOnce(key, "write to SPU register " + hex(p) + " — no voices yet");
		} else {}
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
