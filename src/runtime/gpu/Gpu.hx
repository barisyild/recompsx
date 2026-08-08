package gpu;

import core.Irq;
import core.Runtime;
import core.TimeBase;

/**
	The GPU's register file: the two ports at 1F801810h and 1F801814h, and the state behind them.

	No rasteriser yet. This is the half a game meets first and the half it can hang on — Psy-Q's
	`ResetGraph` sends GP1 commands and then waits on GPUSTAT, and a status word that never changes
	is why Crash Bash printed `GPU timeout` and `VSync: timeout` before this existed. Drawing
	commands are accepted and counted; what they would draw comes later.

	Bit layout and the reset value from psx-spx "GPU Status Register". Two bits earn comment:

	- **26 and 28, ready for a command and ready for DMA, are always set.** Drawing is instant in
	  this model, so the GPU is never busy. A game polling for readiness gets it immediately, which
	  is the honest answer for a machine that has already finished.
	- **31, even/odd,** is computed from the line counter on every read rather than stored. Games
	  poll it to find the field, and a stored value would need a scanline event to update it — this
	  way the answer is always current and costs one division.
**/
class Gpu {
	// GP0(E1h) — texture page and drawing attributes, mirrored in GPUSTAT bits 0..10.
	static var texPage = 0;

	// GP0(E6h) — mask bits, GPUSTAT 11 and 12.
	static var maskSet = false;
	static var maskCheck = false;

	// GP1(08h) — display mode, GPUSTAT 16..23 (minus display-enable).
	static var displayMode = 0;

	// GP1(03h). Note the inversion: the bit means *disabled*.
	static var displayDisabled = true;

	// GP1(04h) — DMA direction, GPUSTAT 29..30.
	static var dmaDirection = 0;

	/** GP0(1Fh) sets it, GP1(02h) clears it, and it drives I_STAT bit 1. */
	static var irqPending = false;

	// Drawing area and offset. Kept because games read them back through GP1(10h).
	static var drawAreaTopLeft = 0;
	static var drawAreaBottomRight = 0;
	static var drawOffset = 0;
	static var textureWindow = 0;

	// Display origin and ranges, which the scanout will want.
	static var displayStart = 0;
	static var displayRangeH = 0;
	static var displayRangeV = 0;

	/** What GP1(10h) left for the next read of the data port. */
	static var readLatch = 0;

	/**
		How many GP0 words have arrived, and how many were commands rather than parameters.

		Deterministic, and the first evidence that a game is drawing at all — a title screen that
		submits nothing is a different problem from one that submits and shows nothing.
	**/
	public static var wordsReceived(default, null) = 0;
	public static var commandsReceived(default, null) = 0;

	/** How many words of the command in progress are still expected. */
	static var pending = 0;

	public static function init():Void {
		reset();
		wordsReceived = 0;
		commandsReceived = 0;
	}

	/** GP1(00h). psx-spx: GPUSTAT becomes 14802000h, which is what these defaults produce. */
	static function reset():Void {
		texPage = 0;
		maskSet = false;
		maskCheck = false;
		displayMode = 0;
		displayDisabled = true;
		dmaDirection = 0;
		irqPending = false;
		drawAreaTopLeft = 0;
		drawAreaBottomRight = 0;
		drawOffset = 0;
		textureWindow = 0;
		displayStart = 0;
		// The retail defaults: a 320x240 window in the middle of the visible area.
		displayRangeH = 0xC60260;
		displayRangeV = 0x3FC10;
		readLatch = 0;
		pending = 0;
	}

	// ---- the two ports ---------------------------------------------------------------------------

	public static function writeGp0(v:Int):Void {
		wordsReceived++;
		if (pending > 0) return consumeParameter();
		else {}
		commandsReceived++;
		command(v);
	}

	static function consumeParameter():Void {
		pending--;
	}

	/**
		A GP0 command word.

		The state-setting commands are implemented because they are what a game's setup depends on.
		Drawing commands are counted and their parameters swallowed, so the port stays in step —
		mis-counting a packet's length would leave the next command word read as a parameter and
		desynchronise everything after it, which is far worse than not drawing.
	**/
	static function command(v:Int):Void {
		final op = v >>> 24;
		if (op == 0xE1) texPage = v & 0x3FFF;
		else if (op == 0xE2) textureWindow = v & 0xFFFFF;
		else if (op == 0xE3) drawAreaTopLeft = v & 0xFFFFF;
		else if (op == 0xE4) drawAreaBottomRight = v & 0xFFFFF;
		else if (op == 0xE5) drawOffset = v & 0x3FFFFF;
		else if (op == 0xE6) setMaskBits(v);
		else if (op == 0x1F) raiseIrq();
		else if (op == 0x00 || op == 0x01 || (op >= 0x03 && op <= 0x1E)) {}   // NOPs
		else pending = parameterCount(op);
	}

	static function setMaskBits(v:Int):Void {
		maskSet = (v & 1) != 0;
		maskCheck = (v & 2) != 0;
	}

	static function raiseIrq():Void {
		irqPending = true;
		Irq.raiseLine(Irq.GPU);
	}

	/**
		How many words follow a drawing command.

		From the command's own bits, which is how the hardware knows: bit 27 makes a polygon a
		quad, 28 makes it gouraud, 26 textures it. Line strips are the exception — they run until a
		terminator rather than a count — and are reported rather than guessed at, because guessing
		a length here desynchronises the port.
	**/
	static function parameterCount(op:Int):Int {
		if (op >= 0x20 && op <= 0x3F) return polygonWords(op);
		else if (op >= 0x40 && op <= 0x5F) return lineWords(op);
		else if (op >= 0x60 && op <= 0x7F) return rectangleWords(op);
		else if (op == 0x02) return 2;                       // fill: colour, then two corners
		else if (op == 0x80) return 3;                       // VRAM to VRAM
		else if (op == 0xA0 || op == 0xC0) return 2;         // transfers: the data follows
		else return unknownCommand(op);
	}

	static function polygonWords(op:Int):Int {
		final vertices = (op & 0x08) != 0 ? 4 : 3;
		var perVertex = 1;                                    // the position
		if ((op & 0x04) != 0) perVertex++;                    // texture coordinate
		if ((op & 0x10) != 0) perVertex++;                    // its own colour
		// The first vertex's colour came in the command word itself when gouraud is off.
		return vertices * perVertex - ((op & 0x10) != 0 ? 1 : 0);
	}

	static function lineWords(op:Int):Int {
		if ((op & 0x08) != 0) return polylineIsOpen(op);
		else return (op & 0x10) != 0 ? 3 : 2;
	}

	static function polylineIsOpen(op:Int):Int {
		Runtime.reportOnce(0x60000000 | op, "GP0 polyline, which runs until its terminator");
		return 0;
	}

	static function rectangleWords(op:Int):Int {
		var n = 1;                                            // position
		if ((op & 0x04) != 0) n++;                            // texture coordinate
		if ((op & 0x18) == 0) n++;                            // variable size
		return n;
	}

	static function unknownCommand(op:Int):Int {
		Runtime.reportOnce(0x61000000 | op, "GP0 command that is not in the table");
		return 0;
	}

	// ---- GP1 -----------------------------------------------------------------------------------

	public static function writeGp1(v:Int):Void {
		final op = (v >>> 24) & 0x3F;
		final arg = v & 0xFFFFFF;
		if (op == 0x00) reset();
		else if (op == 0x01) pending = 0;                     // reset the command buffer
		else if (op == 0x02) irqPending = false;
		else if (op == 0x03) displayDisabled = (arg & 1) != 0;
		else if (op == 0x04) dmaDirection = arg & 3;
		else if (op == 0x05) displayStart = arg & 0x7FFFF;
		else if (op == 0x06) displayRangeH = arg;
		else if (op == 0x07) displayRangeV = arg;
		else if (op == 0x08) displayMode = arg & 0xFF;
		else if (op == 0x09) {}                               // VRAM size, v2 only
		else if (op == 0x10) readLatch = internalRegister(arg);
		else Runtime.reportOnce(0x62000000 | op, "GP1 command that is not in the table");
	}

	/** GP1(10h) — the handful of internal registers a game may read back. */
	static function internalRegister(index:Int):Int {
		final which = index & 0x0F;
		if (which == 2) return textureWindow;
		else if (which == 3) return drawAreaTopLeft;
		else if (which == 4) return drawAreaBottomRight;
		else if (which == 5) return drawOffset;
		else if (which == 7) return 2;                        // GPU version
		else return readLatch;                                // unchanged, as the hardware leaves it
	}

	// ---- reads ------------------------------------------------------------------------------------

	public static function readData():Int {
		return readLatch;
	}

	/**
		GPUSTAT, assembled on every read.

		Nothing here is stored as a status word: it is a view over the state the commands set, plus
		the beam position. That is why a game polling it in a loop sees something that changes
		without any event having to fire.
	**/
	public static function readStatus(cycles:Int):Int {
		var s = texPage & 0x7FF;
		if (maskSet) s |= 1 << 11;
		else {}
		if (maskCheck) s |= 1 << 12;
		else {}
		// Bit 13 is the interlace field, and psx-spx notes it reads 1 whenever interlace is off.
		if ((displayMode & 0x20) == 0) s |= 1 << 13;
		else {}
		s |= (displayMode & 0xFF) << 16;
		if (displayDisabled) s |= 1 << 23;
		else {}
		if (irqPending) s |= 1 << 24;
		else {}
		s |= dmaRequestBit();
		// Never busy: drawing is instant in this model, so readiness is the truthful answer.
		s |= (1 << 26) | (1 << 27) | (1 << 28);
		s |= dmaDirection << 29;
		s |= oddLineBit(cycles);
		return s;
	}

	/** Bit 25 means different things per DMA direction; with DMA off it is simply clear. */
	static function dmaRequestBit():Int {
		if (dmaDirection == 0) return 0;
		else if (dmaDirection == 1) return 1 << 25;
		else return 1 << 25;
	}

	/**
		Bit 31 — the beam's parity, or zero during vblank.

		Computed rather than stored. Games use it to find the field, and a game that spins on it is
		waiting for the beam to move, so the answer has to come from the clock.
	**/
	static function oddLineBit(cycles:Int):Int {
		final line = TimeBase.line(cycles);
		if (line >= TimeBase.DEFAULT_VBLANK_LINE) return 0;
		else return (line & 1) << 31;
	}
}
