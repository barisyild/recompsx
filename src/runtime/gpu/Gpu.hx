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

	// The scanout reads these; nothing else outside this class may.
	public static inline function displayOrigin():Int return displayStart;
	public static inline function displayModeBits():Int return displayMode;
	public static inline function displayOn():Bool return !displayDisabled;

	/**
		How many GP0 words have arrived, and how many were commands rather than parameters.

		Deterministic, and the first evidence that a game is drawing at all — a title screen that
		submits nothing is a different problem from one that submits and shows nothing.
	**/
	public static var wordsReceived(default, null) = 0;
	public static var commandsReceived(default, null) = 0;

	/** How many words of the command in progress are still expected. */
	static var pending = 0;

	/**
		A CPU-to-VRAM transfer in flight: GP0(A0h) is a header followed by raw pixel data, and the
		data's length is only known once the size word has arrived. So the packet machinery cannot
		size it up front the way it does a polygon — the transfer arms itself when its header is
		complete and swallows halfwords straight into the framebuffer after that.

		This is how a game gets an image onto the screen without drawing anything: fonts, logos and
		loading screens are uploads, not primitives. Counting the words and discarding them, which
		is what this did, renders a game that draws nothing as a game that shows nothing — and the
		two look identical from outside.
	**/
	static var xferLeft = 0;
	static var xferX = 0;
	static var xferY = 0;
	static var xferW = 0;
	static var xferH = 0;
	static var xferI = 0;

	/** Pixels delivered by upload rather than by rasterisation. */
	public static var uploaded(default, null) = 0;

	/** The command word and its parameters, gathered until the packet is whole. */
	static var packet:Array<Int>;
	static var packetLen = 0;

	/** Primitives actually rasterised, and pixels written. The proof a frame exists. */
	public static var primitives(default, null) = 0;
	public static var pixels(default, null) = 0;

	public static function init():Void {
		packet = [for (_ in 0...32) 0];
		opCount = [for (_ in 0...256) 0];
		Vram.init();
		reset();
		wordsReceived = 0;
		commandsReceived = 0;
		primitives = 0;
		pixels = 0;
		uploaded = 0;
		xferLeft = 0;
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
		if (xferLeft > 0) return transferWord(v);
		else {}
		if (pending > 0) return consumeParameter(v);
		else {}
		commandsReceived++;
		packetLen = 0;
		push(v);
		command(v);
		if (pending == 0) draw();
		else {}
	}

	static function consumeParameter(v:Int):Void {
		push(v);
		pending--;
		if (pending == 0) draw();
		else {}
	}

	/**
		Two pixels a word, left to right and top to bottom, wrapping at the rectangle's edge.

		Coordinates wrap within VRAM rather than clipping: the hardware's transfer is a blit into a
		1024x512 torus and games rely on it, notably when uploading a texture page that straddles
		the right edge.
	**/
	static function transferWord(v:Int):Void {
		xferLeft--;
		putTexel(v & 0xFFFF);
		putTexel((v >>> 16) & 0xFFFF);
	}

	static function putTexel(p:Int):Void {
		if (xferI >= xferW * xferH) return;
		else {}
		final x = (xferX + (xferI % xferW)) & 1023;
		final y = (xferY + Std.int(xferI / xferW)) & 511;
		Vram.set(x, y, p);
		xferI++;
		uploaded++;
	}

	/** Arms the transfer once its header words are in. */
	static function beginTransfer():Void {
		xferX = packet[1] & 0x3FF;
		xferY = (packet[1] >>> 16) & 0x1FF;
		xferW = packet[2] & 0xFFFF;
		xferH = (packet[2] >>> 16) & 0xFFFF;
		if (xferW == 0) xferW = 1024;
		else {}
		if (xferH == 0) xferH = 512;
		else {}
		xferI = 0;
		// Two pixels to a word, rounded up: an odd-width rectangle pads its last word.
		xferLeft = Std.int((xferW * xferH + 1) / 2);
	}

	static function push(v:Int):Void {
		if (packetLen < 32) packet[packetLen] = v;
		else {}
		if (packetLen < 32) packetLen++;
		else {}
	}

	/**
		Turns a completed packet into pixels.

		Flat and gouraud polygons, rectangles and the fill command, all untextured for now: a solid
		triangle is what proves the path from a game's ordering table to VRAM is whole, and
		texturing is a lookup added onto the same span loop afterwards.
	**/
	static function draw():Void {
		final op = packet[0] >>> 24;
		if (op >= 0x20 && op <= 0x3F) drawPolygon(op);
		else if (op >= 0x60 && op <= 0x7F) drawRect(op);
		else if (op == 0x02) drawFill();
		else if (op == 0xA0) beginTransfer();
		else if (op == 0x80) copyWithinVram();
		else {}
	}

	/**
		GP0(80h) — a rectangle of VRAM copied somewhere else in VRAM.

		Three words: the command, the source corner, the destination corner, then the size. It is
		the cheapest thing the GPU can do, and for a game built around pre-rendered artwork it is
		most of what the GPU is asked to do at all: upload the images once, then blit pieces of them
		into the visible framebuffer every frame. Crash Bash's boot sequence is nearly nothing else
		— seven thousand of these per eight thousand frames, against a single rectangle.

		Which is why its absence looked like a working emulator. The uploads landed, the ordering
		tables were built and walked, the packets arrived and were correctly sized and skipped, and
		the screen stayed black: every part of the path worked except the one that moves pixels.

		Zero width or height means the full 1024 or 512, and the copy wraps, because VRAM is a torus
		to the GPU and games rely on it. Copied through a row buffer would be tidier, but the
		overlapping case has to behave like hardware — which copies in increasing order — and doing
		it directly is both simpler and what the hardware does.
	**/
	static function copyWithinVram():Void {
		final sx0 = packet[1] & 0x3FF;
		final sy0 = (packet[1] >>> 16) & 0x1FF;
		final dx0 = packet[2] & 0x3FF;
		final dy0 = (packet[2] >>> 16) & 0x1FF;
		final w = ((packet[3] - 1) & 0x3FF) + 1;
		final h = (((packet[3] >>> 16) - 1) & 0x1FF) + 1;
		for (y in 0...h) {
			for (x in 0...w) {
				final src = Vram.get((sx0 + x) & 0x3FF, (sy0 + y) & 0x1FF);
				blend(dx0, dy0, x, y, src);
			}
		}
		copies++;
	}

	/** One copied pixel, honouring the mask bits exactly as a drawn one does. */
	static function blend(dx0:Int, dy0:Int, x:Int, y:Int, src:Int):Void {
		final dx = (dx0 + x) & 0x3FF;
		final dy = (dy0 + y) & 0x1FF;
		if (maskCheck && (Vram.get(dx, dy) & 0x8000) != 0) return;
		else {}
		Vram.set(dx, dy, maskSet ? src | 0x8000 : src);
		pixels++;
	}

	/** VRAM-to-VRAM rectangles copied. */
	public static var copies(default, null) = 0;

	static inline function colourOf(word:Int):Int {
		// 24-bit BGR to the 15-bit word VRAM holds.
		return ((word >>> 3) & 0x1F) | (((word >>> 11) & 0x1F) << 5) | (((word >>> 19) & 0x1F) << 10);
	}

	static inline function sx(word:Int):Int {
		// 11-bit signed, plus the drawing offset.
		return signed11(word & 0x7FF) + signed11(drawOffset & 0x7FF);
	}

	static inline function sy(word:Int):Int {
		return signed11((word >>> 16) & 0x7FF) + signed11((drawOffset >>> 11) & 0x7FF);
	}

	static inline function signed11(v:Int):Int {
		return (v & 0x400) != 0 ? v - 0x800 : v;
	}

	static function drawPolygon(op:Int):Void {
		final gouraud = (op & 0x10) != 0;
		final textured = (op & 0x04) != 0;
		final quad = (op & 0x08) != 0;
		final colour = colourOf(packet[0]);

		// Vertex words sit at a fixed stride once the command word is past; with gouraud the
		// first vertex's colour was the command word itself.
		var i = 1;
		final xs = [0, 0, 0, 0];
		final ys = [0, 0, 0, 0];
		final n = quad ? 4 : 3;
		for (v in 0...n) {
			if (gouraud && v > 0) i++;
			xs[v] = sx(packet[i]);
			ys[v] = sy(packet[i]);
			i++;
			if (textured) i++;
		}
		triangle(xs[0], ys[0], xs[1], ys[1], xs[2], ys[2], colour);
		if (quad) triangle(xs[1], ys[1], xs[2], ys[2], xs[3], ys[3], colour);
		else {}
	}

	static function drawRect(op:Int):Void {
		final colour = colourOf(packet[0]);
		final textured = (op & 0x04) != 0;
		var i = 1;
		final x = sx(packet[i]);
		final y = sy(packet[i]);
		i++;
		if (textured) i++;
		var w = 1;
		var h = 1;
		final size = (op >>> 3) & 3;
		if (size == 0) { w = packet[i] & 0x3FF; h = (packet[i] >>> 16) & 0x1FF; }
		else if (size == 2) { w = 8; h = 8; }
		else if (size == 3) { w = 16; h = 16; }
		else {}
		fillRect(x, y, w, h, colour);
		primitives++;
	}

	static function drawFill():Void {
		final colour = colourOf(packet[0]);
		final x = packet[1] & 0x3F0;
		final y = (packet[1] >>> 16) & 0x1FF;
		final w = ((packet[2] & 0x3FF) + 0xF) & ~0xF;
		final h = (packet[2] >>> 16) & 0x1FF;
		fillRect(x, y, w, h, colour);
		primitives++;
	}

	/**
		A solid triangle, by half-space test over its bounding box.

		Not the fastest way and not the shape the final rasteriser will keep — a span walk with
		incremental edge functions is — but it is the one whose correctness is obvious, which is
		what a first render needs. Degenerate and oversized triangles are dropped exactly as the
		hardware drops them: anything wider than 1023 or taller than 511 is not drawn at all.
	**/
	static function triangle(x0:Int, y0:Int, x1:Int, y1:Int, x2:Int, y2:Int, colour:Int):Void {
		var minX = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
		var maxX = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
		var minY = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
		var maxY = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
		if (maxX - minX > 1023 || maxY - minY > 511) return;
		else {}

		final clip = clipBox();
		if (minX < clipX0(clip)) minX = clipX0(clip);
		else {}
		if (minY < clipY0(clip)) minY = clipY0(clip);
		else {}
		if (maxX > clipX1(clip)) maxX = clipX1(clip);
		else {}
		if (maxY > clipY1(clip)) maxY = clipY1(clip);
		else {}

		final area = edge(x0, y0, x1, y1, x2, y2);
		if (area == 0) return;
		else {}
		primitives++;
		var y = minY;
		while (y <= maxY) {
			var x = minX;
			while (x <= maxX) {
				final w0 = edge(x1, y1, x2, y2, x, y);
				final w1 = edge(x2, y2, x0, y0, x, y);
				final w2 = edge(x0, y0, x1, y1, x, y);
				if (inside(w0, w1, w2, area)) plot(x, y, colour);
				else {}
				x++;
			}
			y++;
		}
	}

	static inline function inside(w0:Int, w1:Int, w2:Int, area:Int):Bool {
		return area > 0 ? (w0 >= 0 && w1 >= 0 && w2 >= 0) : (w0 <= 0 && w1 <= 0 && w2 <= 0);
	}

	static inline function edge(ax:Int, ay:Int, bx:Int, by:Int, cx:Int, cy:Int):Int {
		return shim.IntMath.mul(bx - ax, cy - ay) - shim.IntMath.mul(by - ay, cx - ax);
	}

	static function fillRect(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		var j = 0;
		while (j < h) {
			var i = 0;
			while (i < w) {
				plot(x + i, y + j, colour);
				i++;
			}
			j++;
		}
	}

	static inline function plot(x:Int, y:Int, colour:Int):Void {
		if (x >= 0 && x < 1024 && y >= 0 && y < 512) {
			Vram.set(x, y, colour);
			pixels++;
		} else {}
	}

	// The draw area, packed as it arrives: X in bits 0..9, Y in 10..18.
	static inline function clipBox():Int return 0;
	static inline function clipX0(_:Int):Int return drawAreaTopLeft & 0x3FF;
	static inline function clipY0(_:Int):Int return (drawAreaTopLeft >>> 10) & 0x1FF;
	static inline function clipX1(_:Int):Int return drawAreaBottomRight & 0x3FF;
	static inline function clipY1(_:Int):Int return (drawAreaBottomRight >>> 10) & 0x1FF;

	/**
		A GP0 command word.

		The state-setting commands are implemented because they are what a game's setup depends on.
		Drawing commands are counted and their parameters swallowed, so the port stays in step —
		mis-counting a packet's length would leave the next command word read as a parameter and
		desynchronise everything after it, which is far worse than not drawing.
	**/
	/** How many of each GP0 opcode arrived. A drawable command that never becomes a primitive is
		a rasteriser dropping work, which looks exactly like a game that draws nothing. */
	public static var opCount:Array<Int>;

	static function command(v:Int):Void {
		final op = v >>> 24;
		if (opCount != null) opCount[op]++;
		else {}
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
