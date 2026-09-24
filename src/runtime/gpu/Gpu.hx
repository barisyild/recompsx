package gpu;

import core.Irq;
import core.Runtime;
import core.TimeBase;
import shim.Backend;

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

	/** GP1(05h) writes — how often the game moves the displayed window. */
	public static var flips(default, null) = 0;

	/** A polygon's vertices, decoded once per packet. Allocated at boot, never per primitive. */
	static var vx:Array<Int>;
	static var vy:Array<Int>;
	static var vc:Array<Int>;
	static var vu:Array<Int>;
	static var vv:Array<Int>;

	/**
		The texture the primitive being rasterised reads from, decoded once per packet.

		Carried in statics rather than through the call, because a textured triangle needs fifteen
		numbers and the portable subset has no structs to pass them in. Set immediately before
		`triangle`, read only inside it.
	**/
	static var texEnabled = false;
	static var texRaw = false;
	static var texDepth = 0;        // 0 = 4bpp indexed, 1 = 8bpp indexed, 2 = 15bpp direct
	static var texBaseX = 0;        // in halfwords
	static var texBaseY = 0;
	static var clutX = 0;
	static var clutY = 0;

	/**
		Whether the primitive blends with what is already there, and how.

		The mode is GPU state — GP0(E1h) bits 5-6 — which a textured polygon may override for
		itself through its own texpage word. Whether blending happens at all is the command's own
		bit 1, and for a textured pixel the texel gets the final say through its bit 15.
	**/
	static var semiMode = 0;
	static var semiTransparent = false;

	/** The command word and its parameters, gathered until the packet is whole. */
	static var packet:Array<Int>;
	static var packetLen = 0;

	/** Primitives actually rasterised, and pixels written. The proof a frame exists. */
	public static var primitives(default, null) = 0;
	public static var pixels(default, null) = 0;

	/**
		Whether primitives are handed to the backend instead of being rasterised here.

		**False on every path that hashes anything, and that is the point.** A backend with a
		rasteriser of its own can draw a PlayStation scene far faster than a 200 MHz console can
		draw it in software, but the pixels it produces are its own — near enough to look right,
		not near enough to be the same bytes. So this is a fork in *presentation* and never in
		state: everything the emulated machine can observe (GP0 parsing, GPUSTAT, interrupts,
		cycle costs, uploads, VRAM-to-VRAM copies) happens identically either way, and only the
		rasterised pixels go elsewhere.

		Nothing turns it on by itself. A host has to ask, with `--video-hw`, *and* its backend has
		to answer `BP_CAP_GPU_DRAW`; the JavaScript shim answers no by construction, so the
		reference target cannot take this path even by accident. Headless digest runs therefore
		never see it. See docs/decisions/ADR-0011.
	**/
	public static var hw = false;

	public static function init():Void {
		packet = [for (_ in 0...32) 0];
		vx = [for (_ in 0...4) 0];
		vy = [for (_ in 0...4) 0];
		vc = [for (_ in 0...4) 0];
		vu = [for (_ in 0...4) 0];
		vv = [for (_ in 0...4) 0];
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
		semiMode = 0;
		semiTransparent = false;
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

	/**
		One pixel of a CPU-to-VRAM upload, obeying the mask settings.

		A copy is affected by GP0(E6) exactly as a drawn primitive is — psx-spx, "Mask/Round" — and
		this is not a fine point for the game that needs it. Crash Bash's warning screen writes its
		text in two passes: the letters first, in white with bit 15 set, then a black pass over the
		whole cell. On hardware the second pass is a masked copy: with mask-check on, it skips every
		pixel whose bit 15 is already set, so the white letters survive and the black only fills the
		gaps around them. Ignore the check — as this did — and the black pass erases the letters,
		leaving one stray column per glyph. The text was there in VRAM the whole time, drawn and
		then overwritten, which is why it read as thin strokes rather than as nothing.
	**/
	static function putTexel(p:Int):Void {
		if (xferI >= xferW * xferH) return;
		else {}
		final x = (xferX + (xferI % xferW)) & 1023;
		final y = (xferY + shim.IntMath.div(xferI, xferW)) & 511;
		if (maskCheck && (Vram.get(x, y) & 0x8000) != 0) {
			xferI++;
			uploaded++;
			return;
		} else {}
		Vram.set(x, y, maskSet ? p | 0x8000 : p);
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
		xferLeft = (xferW * xferH + 1) >> 1;
		// Told once, here, rather than per texel: the rectangle is known the moment the transfer
		// is armed, and a backend caching decoded textures needs the region, not the pixels.
		if (hw) Backend.gpuDirty(xferX, xferY, xferW, xferH);
		else {}
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
		// The copy lands in emulated VRAM in both modes — it is state, not presentation — but a
		// backend holding a decoded copy of that region now holds a stale one.
		if (hw) Backend.gpuDirty(dx0, dy0, w, h);
		else {}
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

		// Vertex words sit at a fixed stride once the command word is past; with gouraud the
		// first vertex's colour was the command word itself and each later vertex is preceded by
		// its own. The three arrays are allocated once at boot — these used to be array literals,
		// which is an allocation per polygon, and this game submits three million of them.
		var i = 1;
		final n = quad ? 4 : 3;
		for (v in 0...n) {
			if (gouraud && v > 0) {
				vc[v] = packet[i] & 0xFFFFFF;
				i++;
			} else {
				vc[v] = packet[0] & 0xFFFFFF;
			}
			vx[v] = sx(packet[i]);
			vy[v] = sy(packet[i]);
			i++;
			if (textured) {
				vu[v] = packet[i] & 0xFF;
				vv[v] = (packet[i] >>> 8) & 0xFF;
				// The palette rides on the first vertex's word and the texture page on the
				// second; the rest carry nothing in their high half.
				if (v == 0) setClut(packet[i] >>> 16);
				else if (v == 1) setTexPage(packet[i] >>> 16);
				else {}
				i++;
			} else {}
		}
		texEnabled = textured;
		texRaw = (op & 0x01) != 0;
		semiTransparent = (op & 0x02) != 0;
		triangle(0, 1, 2);
		if (quad) triangle(1, 2, 3);
		else {}
	}

	/** GP0's palette attribute: X in sixteens, Y in lines. */
	static function setClut(attr:Int):Void {
		clutX = (attr & 0x3F) << 4;
		clutY = (attr >>> 6) & 0x1FF;
	}

	/** The texture page a primitive names for itself, in the same layout GP0(E1h) uses. */
	static function setTexPage(attr:Int):Void {
		texBaseX = (attr & 0x0F) << 6;
		texBaseY = ((attr >>> 4) & 1) << 8;
		semiMode = (attr >>> 5) & 3;
		texDepth = (attr >>> 7) & 3;
	}

	/**
		GP0(E1h) — the page, the blend mode and the depth, for everything that does not say
		otherwise.

		An untextured primitive has no texpage word of its own, so this is where its blend mode
		comes from; a textured polygon carries its own and overrides all three.
	**/
	static function setDrawMode(v:Int):Void {
		texPage = v & 0x3FFF;
		setTexPage(v & 0x1FF);
	}

	static function drawRect(op:Int):Void {
		semiTransparent = (op & 0x02) != 0;
		texEnabled = false;
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
		semiTransparent = false;
		texEnabled = false;
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
	static function triangle(ia:Int, ib0:Int, ic0:Int):Void {
		// The hardware fork. Taken before the winding is normalised, because that is a rasteriser's
		// business and a backend with culling disabled does not care which way round the vertices
		// arrive. Both rejects below are kept so the primitive counter means the same thing in
		// either mode — a heartbeat that counted differently would make the two incomparable.
		if (hw) {
			final hx0 = vx[ia], hy0 = vy[ia];
			final hx1 = vx[ib0], hy1 = vy[ib0];
			final hx2 = vx[ic0], hy2 = vy[ic0];
			final loX = hx0 < hx1 ? (hx0 < hx2 ? hx0 : hx2) : (hx1 < hx2 ? hx1 : hx2);
			final hiX = hx0 > hx1 ? (hx0 > hx2 ? hx0 : hx2) : (hx1 > hx2 ? hx1 : hx2);
			final loY = hy0 < hy1 ? (hy0 < hy2 ? hy0 : hy2) : (hy1 < hy2 ? hy1 : hy2);
			final hiY = hy0 > hy1 ? (hy0 > hy2 ? hy0 : hy2) : (hy1 > hy2 ? hy1 : hy2);
			if (hiX - loX > 1023 || hiY - loY > 511) return;
			else {}
			if (edge(hx0, hy0, hx1, hy1, hx2, hy2) == 0) return;
			else {}
			primitives++;
			Backend.gpuState(texBaseX, texBaseY, texDepth, clutX, clutY, semiMode,
				(texEnabled ? 1 : 0) | (semiTransparent ? 2 : 0) | (texRaw ? 4 : 0),
				textureWindow, drawAreaTopLeft & 0x3FF, (drawAreaTopLeft >>> 10) & 0x1FF);
			Backend.gpuTri(hx0, hy0, vc[ia], vu[ia], vv[ia],
				hx1, hy1, vc[ib0], vu[ib0], vv[ib0],
				hx2, hy2, vc[ic0], vu[ic0], vv[ic0]);
			return;
		} else {}

		// One winding, decided here, so that everything downstream has a single case to handle.
		// A clockwise triangle is the same triangle with two vertices exchanged, and exchanging
		// them carries the colour and the texture coordinate along, so nothing else notices.
		var ib = ib0, ic = ic0;
		if (edge(vx[ia], vy[ia], vx[ib], vy[ib], vx[ic], vy[ic]) < 0) {
			ib = ic0;
			ic = ib0;
		} else {}
		final a = ia, b = ib, c = ic;
		final x0 = vx[a], y0 = vy[a], c0 = vc[a];
		final x1 = vx[b], y1 = vy[b], c1 = vc[b];
		final x2 = vx[c], y2 = vy[c], c2 = vc[c];
		var minX = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
		var maxX = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
		var minY = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
		var maxY = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
		if (maxX - minX > 1023 || maxY - minY > 511) return;
		else {}

		// Read once into locals rather than through the four ignored-argument accessors that used
		// to stand here. Those made JavaScript and reflaxe.CPP disagree about the *lower* two
		// clamps — same vertices, same area, same clip values, different bounding box — which is
		// 0.3% of every pixel this rasteriser writes. See PROGRESS.md, upstream defect 10.
		final clipLeft = drawAreaTopLeft & 0x3FF;
		final clipTop = (drawAreaTopLeft >>> 10) & 0x1FF;
		final clipRight = drawAreaBottomRight & 0x3FF;
		final clipBottom = (drawAreaBottomRight >>> 10) & 0x1FF;
		if (minX < clipLeft) minX = clipLeft;
		else {}
		if (minY < clipTop) minY = clipTop;
		else {}
		if (maxX > clipRight) maxX = clipRight;
		else {}
		if (maxY > clipBottom) maxY = clipBottom;
		else {}

		final area = edge(x0, y0, x1, y1, x2, y2);
		if (area == 0) return;
		else {}
		primitives++;

		// The edge function is linear in x and y, so stepping it costs an add where evaluating it
		// costs two multiplies. Six multiplies a pixel over a bounding box is what a scene of three
		// million triangles spends most of its time on, and none of them are necessary: one
		// evaluation per edge at the top-left corner, then `stepX` along a row and `stepY` down.
		//
		// Identical integers, not an approximation — the same values the three calls produced,
		// arrived at by addition. The digest is the proof and it does not move.
		final stepX0 = y1 - y2, stepY0 = x2 - x1;
		final stepX1 = y2 - y0, stepY1 = x0 - x2;
		final stepX2 = y0 - y1, stepY2 = x1 - x0;
		// The fill rule. A pixel lying exactly on a shared edge is claimed by one of the two
		// triangles that meet there, never both and never neither: the edge belongs to whichever
		// of them has it as a top or a left edge, and the two traverse it in opposite directions,
		// so exactly one qualifies. Without this, every seam is drawn twice — invisible on an
		// opaque surface, because the second write puts back what the first did, and a bright line
		// along every polygon diagonal the moment the surface blends with what is behind it.
		var row0 = edge(x1, y1, x2, y2, minX, minY) + (topLeft(x1, y1, x2, y2) ? 0 : -1);
		var row1 = edge(x2, y2, x0, y0, minX, minY) + (topLeft(x2, y2, x0, y0) ? 0 : -1);
		var row2 = edge(x0, y0, x1, y1, minX, minY) + (topLeft(x0, y0, x1, y1) ? 0 : -1);

		if (texEnabled) {
			texturedSpans(a, b, c, x0, y0, c0, x1, y1, c1, x2, y2, c2,
				minX, maxX, minY, maxY, area, row0, row1, row2,
				stepX0, stepX1, stepX2, stepY0, stepY1, stepY2);
		} else if (c0 == c1 && c1 == c2) {
			flatSpans(minX, maxX, minY, maxY, area, row0, row1, row2,
				stepX0, stepX1, stepX2, stepY0, stepY1, stepY2, colourOf(c0));
		} else {
			shadedSpans(x0, y0, c0, x1, y1, c1, x2, y2, c2, minX, maxX, minY, maxY, area,
				row0, row1, row2, stepX0, stepX1, stepX2, stepY0, stepY1, stepY2);
		}
	}

	/** One colour over the whole triangle: no interpolation to do, so none is paid for. */
	static function flatSpans(minX:Int, maxX:Int, minY:Int, maxY:Int, area:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int, colour:Int):Void {
		var r0 = row0, r1 = row1, r2 = row2;
		var y = minY;
		while (y <= maxY) {
			var w0 = r0, w1 = r1, w2 = r2;
			var x = minX;
			var pixel = Vram.rowStart(y) + minX;
			while (x <= maxX) {
				if (inside(w0, w1, w2, area)) plotMaybeSemiLinear(pixel, colour);
				else {}
				w0 = (w0 + stepX0) | 0; w1 = (w1 + stepX1) | 0; w2 = (w2 + stepX2) | 0;
				x++; pixel++;
			}
			r0 = (r0 + stepY0) | 0; r1 = (r1 + stepY1) | 0; r2 = (r2 + stepY2) | 0;
			y++;
		}
	}

	/**
		Gouraud shading: each channel a plane through the three vertex colours.

		Colour varies linearly across a triangle, so each channel is stepped exactly as the edge
		functions are — one division per channel per triangle to find the two gradients, then an
		add per pixel. Ten fractional bits, which is enough that the rounding error accumulated
		across a full-width span stays under one level of the 255, and few enough that every
		intermediate stays inside 32 bits: the bounding-box reject above caps coordinate
		differences at 1023 by 511, so a gradient numerator cannot exceed about half a million.

		Gradients are clamped to one full colour range per pixel. Anything steeper is a sliver
		whose colour saturates within a pixel anyway, and the clamp is what keeps a degenerate
		triangle from producing an intermediate that wraps. `IntMath.mul` throughout so that if one
		ever does wrap, it wraps the same way on both targets.

		Without this the whole scene is faceted: every polygon Crash Bash draws but one in a
		thousand asks for shading, and painting all three vertices in the first one's colour turns
		a smooth surface into flat plates.
	**/
	static function shadedSpans(x0:Int, y0:Int, c0:Int, x1:Int, y1:Int, c1:Int,
			x2:Int, y2:Int, c2:Int, minX:Int, maxX:Int, minY:Int, maxY:Int, area:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int):Void {
		final ax = x1 - x0, ay = y1 - y0;
		final bx = x2 - x0, by = y2 - y0;

		final r0 = c0 & 0xFF, g0 = (c0 >>> 8) & 0xFF, b0 = (c0 >>> 16) & 0xFF;
		final dr1 = (c1 & 0xFF) - r0, dg1 = ((c1 >>> 8) & 0xFF) - g0, db1 = ((c1 >>> 16) & 0xFF) - b0;
		final dr2 = (c2 & 0xFF) - r0, dg2 = ((c2 >>> 8) & 0xFF) - g0, db2 = ((c2 >>> 16) & 0xFF) - b0;

		final drdx = gradient(shim.IntMath.mul(dr1, by) - shim.IntMath.mul(dr2, ay), area);
		final drdy = gradient(shim.IntMath.mul(dr2, ax) - shim.IntMath.mul(dr1, bx), area);
		final dgdx = gradient(shim.IntMath.mul(dg1, by) - shim.IntMath.mul(dg2, ay), area);
		final dgdy = gradient(shim.IntMath.mul(dg2, ax) - shim.IntMath.mul(dg1, bx), area);
		final dbdx = gradient(shim.IntMath.mul(db1, by) - shim.IntMath.mul(db2, ay), area);
		final dbdy = gradient(shim.IntMath.mul(db2, ax) - shim.IntMath.mul(db1, bx), area);

		final ox = minX - x0, oy = minY - y0;
		var rRow = start(r0, drdx, ox, drdy, oy);
		var gRow = start(g0, dgdx, ox, dgdy, oy);
		var bRow = start(b0, dbdx, ox, dbdy, oy);

		var e0 = row0, e1 = row1, e2 = row2;
		var y = minY;
		while (y <= maxY) {
			var w0 = e0, w1 = e1, w2 = e2;
			var r = rRow, g = gRow, b = bRow;
			var x = minX;
			var pixel = Vram.rowStart(y) + minX;
			while (x <= maxX) {
				if (inside(w0, w1, w2, area)) {
					plotMaybeSemiLinear(pixel, pack555(r >> CFRAC, g >> CFRAC, b >> CFRAC));
				} else {}
				w0 = (w0 + stepX0) | 0; w1 = (w1 + stepX1) | 0; w2 = (w2 + stepX2) | 0;
				r = (r + drdx) | 0; g = (g + dgdx) | 0; b = (b + dbdx) | 0;
				x++; pixel++;
			}
			e0 = (e0 + stepY0) | 0; e1 = (e1 + stepY1) | 0; e2 = (e2 + stepY2) | 0;
			rRow = (rRow + drdy) | 0; gRow = (gRow + dgdy) | 0; bRow = (bRow + dbdy) | 0;
			y++;
		}
	}

	/**
		A textured triangle: the same interpolation, with U and V carried alongside the colour.

		Texture coordinates are linear in screen space on this hardware — there is no perspective
		correction, which is why PlayStation textures swim on large polygons — so they step exactly
		as the colour channels do, and the same gradient clamp keeps a sliver from wrapping an
		intermediate. Eight-bit coordinates, so a numerator has the same bound the colours do.

		Two rules decide a texel's fate. `0x0000` is fully transparent and the pixel is skipped
		entirely, which is how every cut-out shape on the PlayStation is drawn. Otherwise the texel
		is modulated by the interpolated vertex colour, `texel * colour / 128`, so 0x80 is
		unchanged, below it darkens and above it brightens — unless the command's raw-texture bit
		is set, in which case the texel is written as it was fetched.
	**/
	static function texturedSpans(ia:Int, ib:Int, ic:Int,
			x0:Int, y0:Int, c0:Int, x1:Int, y1:Int, c1:Int, x2:Int, y2:Int, c2:Int,
			minX:Int, maxX:Int, minY:Int, maxY:Int, area:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int):Void {
		final ax = x1 - x0, ay = y1 - y0;
		final bx = x2 - x0, by = y2 - y0;

		final r0 = c0 & 0xFF, g0 = (c0 >>> 8) & 0xFF, b0 = (c0 >>> 16) & 0xFF;
		final dr1 = (c1 & 0xFF) - r0, dg1 = ((c1 >>> 8) & 0xFF) - g0, db1 = ((c1 >>> 16) & 0xFF) - b0;
		final dr2 = (c2 & 0xFF) - r0, dg2 = ((c2 >>> 8) & 0xFF) - g0, db2 = ((c2 >>> 16) & 0xFF) - b0;
		final u0 = vu[ia], v0 = vv[ia];
		final du1 = vu[ib] - u0, dv1 = vv[ib] - v0;
		final du2 = vu[ic] - u0, dv2 = vv[ic] - v0;

		final drdx = gradient(shim.IntMath.mul(dr1, by) - shim.IntMath.mul(dr2, ay), area);
		final drdy = gradient(shim.IntMath.mul(dr2, ax) - shim.IntMath.mul(dr1, bx), area);
		final dgdx = gradient(shim.IntMath.mul(dg1, by) - shim.IntMath.mul(dg2, ay), area);
		final dgdy = gradient(shim.IntMath.mul(dg2, ax) - shim.IntMath.mul(dg1, bx), area);
		final dbdx = gradient(shim.IntMath.mul(db1, by) - shim.IntMath.mul(db2, ay), area);
		final dbdy = gradient(shim.IntMath.mul(db2, ax) - shim.IntMath.mul(db1, bx), area);
		final dudx = gradient(shim.IntMath.mul(du1, by) - shim.IntMath.mul(du2, ay), area);
		final dudy = gradient(shim.IntMath.mul(du2, ax) - shim.IntMath.mul(du1, bx), area);
		final dvdx = gradient(shim.IntMath.mul(dv1, by) - shim.IntMath.mul(dv2, ay), area);
		final dvdy = gradient(shim.IntMath.mul(dv2, ax) - shim.IntMath.mul(dv1, bx), area);

		final ox = minX - x0, oy = minY - y0;
		var rRow = start(r0, drdx, ox, drdy, oy);
		var gRow = start(g0, dgdx, ox, dgdy, oy);
		var bRow = start(b0, dbdx, ox, dbdy, oy);
		var uRow = start(u0, dudx, ox, dudy, oy);
		var vRow = start(v0, dvdx, ox, dvdy, oy);

		var e0 = row0, e1 = row1, e2 = row2;
		var y = minY;
		while (y <= maxY) {
			var w0 = e0, w1 = e1, w2 = e2;
			var r = rRow, g = gRow, b = bRow, u = uRow, v = vRow;
			var x = minX;
			var pixel = Vram.rowStart(y) + minX;
			while (x <= maxX) {
				if (inside(w0, w1, w2, area)) {
					shadeTexelLinear(pixel, u >> CFRAC, v >> CFRAC, r >> CFRAC, g >> CFRAC, b >> CFRAC);
				} else {}
				w0 = (w0 + stepX0) | 0; w1 = (w1 + stepX1) | 0; w2 = (w2 + stepX2) | 0;
				r = (r + drdx) | 0; g = (g + dgdx) | 0; b = (b + dbdx) | 0;
				u = (u + dudx) | 0; v = (v + dvdx) | 0;
				x++; pixel++;
			}
			e0 = (e0 + stepY0) | 0; e1 = (e1 + stepY1) | 0; e2 = (e2 + stepY2) | 0;
			rRow = (rRow + drdy) | 0; gRow = (gRow + dgdy) | 0; bRow = (bRow + dbdy) | 0;
			uRow = (uRow + dudy) | 0; vRow = (vRow + dvdy) | 0;
			y++;
		}
	}

	/** One textured pixel: fetch, drop it if the texel is transparent, modulate, write. */
	static function shadeTexel(x:Int, y:Int, u:Int, v:Int, r:Int, g:Int, b:Int):Void {
		final t = texel(u, v);
		if (t == 0) return;
		else {}
		// Bit 15 of a texel means "blend me" — but only for a command that asked to blend at all;
		// for an opaque command the same bit means nothing and the texel is drawn as it is.
		final blend = semiTransparent && (t & 0x8000) != 0;
		final c = texRaw ? t & 0x7FFF : modulate(t, r, g, b);
		if (blend) plotSemi(x, y, c);
		else plot(x, y, c);
	}

	/** Textured span variant with a precomputed, in-bounds VRAM index. */
	static inline function shadeTexelLinear(index:Int, u:Int, v:Int, r:Int, g:Int, b:Int):Void {
		final t = texel(u, v);
		if (t == 0) {}
		else {
			final blend = semiTransparent && (t & 0x8000) != 0;
			final c = texRaw ? t & 0x7FFF : modulate(t, r, g, b);
			if (blend) plotSemiLinear(index, c);
			else plotLinear(index, c);
		}
	}

	/**
		`texel * colour / 128`, per channel, back into a 15-bit word.

		The texel's five bits are widened to eight before the multiply and narrowed after, so the
		rounding happens once rather than twice.
	**/
	static inline function modulate(t:Int, r:Int, g:Int, b:Int):Int {
		final tr = (t & 0x1F) << 3, tg = ((t >>> 5) & 0x1F) << 3, tb = ((t >>> 10) & 0x1F) << 3;
		return pack555(shim.IntMath.mul(tr, r) >> 7, shim.IntMath.mul(tg, g) >> 7,
			shim.IntMath.mul(tb, b) >> 7);
	}

	/**
		One texel out of the current page, through the texture window and any palette.

		Three storage formats share the page: four-bit and eight-bit indices into a CLUT elsewhere
		in VRAM, and fifteen-bit colour stored directly. Indexed formats pack several pixels into
		one halfword — four nibbles or two bytes, lowest bits leftmost — so the coordinate selects
		both the halfword and the field within it.

		The window is applied first, because it is what makes a small tile repeat across a page:
		psx-spx gives it as `(coord AND NOT(mask*8)) OR ((offset AND mask)*8)`, and the repeat is
		the masking-off of the high bits rather than anything stored in VRAM.
	**/
	static function texel(u:Int, v:Int):Int {
		final mx = textureWindow & 0x1F;
		final my = (textureWindow >>> 5) & 0x1F;
		final tu = ((u & ~(mx << 3)) | ((textureWindow >>> 10) & 0x1F & mx) << 3) & 0xFF;
		final tv = ((v & ~(my << 3)) | ((textureWindow >>> 15) & 0x1F & my) << 3) & 0xFF;
		if (texDepth == 2) return Vram.get((texBaseX + tu) & 1023, (texBaseY + tv) & 511);
		else {}
		if (texDepth == 1) {
			final w = Vram.get((texBaseX + (tu >> 1)) & 1023, (texBaseY + tv) & 511);
			return palette((w >>> ((tu & 1) << 3)) & 0xFF);
		} else {}
		final w = Vram.get((texBaseX + (tu >> 2)) & 1023, (texBaseY + tv) & 511);
		return palette((w >>> ((tu & 3) << 2)) & 0x0F);
	}

	static inline function palette(index:Int):Int {
		return Vram.get((clutX + index) & 1023, clutY & 511);
	}

	/** Ten fractional bits: fine enough to hide banding, coarse enough to stay inside an Int. */
	static inline var CFRAC = 10;
	static inline var CGRAD_MAX = 255 << CFRAC;

	static inline function gradient(numerator:Int, area:Int):Int {
		final g = shim.IntMath.div(shim.IntMath.mul(numerator, 1 << CFRAC), area);
		return g > CGRAD_MAX ? CGRAD_MAX : (g < -CGRAD_MAX ? -CGRAD_MAX : g);
	}

	static inline function start(base:Int, dx:Int, ox:Int, dy:Int, oy:Int):Int {
		return ((base << CFRAC) + shim.IntMath.mul(dx, ox) + shim.IntMath.mul(dy, oy)) | 0;
	}

	/** Three 8-bit channels, clamped, into the 15-bit word VRAM holds. */
	static inline function pack555(r:Int, g:Int, b:Int):Int {
		final rc = r < 0 ? 0 : (r > 255 ? 255 : r);
		final gc = g < 0 ? 0 : (g > 255 ? 255 : g);
		final bc = b < 0 ? 0 : (b > 255 ? 255 : b);
		return (rc >> 3) | ((gc >> 3) << 5) | ((bc >> 3) << 10);
	}

	/**
		Inside the triangle, biases included. Winding is normalised before we get here, so the
		three tests all point the same way and `area` is only along to keep the call shape.
	**/
	static inline function inside(w0:Int, w1:Int, w2:Int, area:Int):Bool {
		return w0 >= 0 && w1 >= 0 && w2 >= 0;
	}

	/**
		Whether a directed edge is a top or a left edge of the triangle on its inside.

		With screen coordinates running down the page and the winding normalised so that the
		interior lies where all three edge functions are non-negative: a horizontal edge travelling
		right has the interior below it, which makes it the top; any edge travelling upwards has
		the interior to its right, which makes it a left edge.
	**/
	static inline function topLeft(ax:Int, ay:Int, bx:Int, by:Int):Bool {
		final dy = by - ay;
		return dy < 0 || (dy == 0 && bx > ax);
	}

	static inline function edge(ax:Int, ay:Int, bx:Int, by:Int, cx:Int, cy:Int):Int {
		return shim.IntMath.mul(bx - ax, cy - ay) - shim.IntMath.mul(by - ay, cx - ax);
	}

	static function fillRect(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		// No `primitives++` here in either mode: both callers count for themselves.
		if (hw) {
			Backend.gpuState(0, 0, 0, 0, 0, semiMode, semiTransparent ? 2 : 0, 0,
				drawAreaTopLeft & 0x3FF, (drawAreaTopLeft >>> 10) & 0x1FF);
			Backend.gpuRect(x, y, w, h, colour, semiTransparent ? 1 : 0, semiMode);
			return;
		} else {}
		// Drawing clips at the viewport edge; it does not wrap like a VRAM transfer. Clip once
		// here so the inner loop can use a linear VRAM index without repeating coordinate checks.
		final left = x < 0 ? 0 : x;
		final top = y < 0 ? 0 : y;
		final right0 = x + w;
		final bottom0 = y + h;
		final right = right0 > 1024 ? 1024 : right0;
		final bottom = bottom0 > 512 ? 512 : bottom0;
		if (left >= right || top >= bottom) return;
		else {}
		final count = right - left;
		if (!semiTransparent && !maskCheck) {
			final value = maskSet ? colour | 0x8000 : colour;
			var row = Vram.rowStart(top) + left;
			var j = top;
			while (j < bottom) {
				Vram.fillLinear(row, count, value);
				row += Vram.WIDTH;
				j++;
			}
			pixels += count * (bottom - top);
		} else {
			var row = Vram.rowStart(top) + left;
			var j = top;
			while (j < bottom) {
				var i = 0;
				while (i < count) {
					plotMaybeSemiLinear(row + i, colour);
					i++;
				}
				row += Vram.WIDTH;
				j++;
			}
		}
	}

	/** The caller has clipped the pixel, so no coordinate masks or bounds checks are needed. */
	static inline function plotMaybeSemiLinear(index:Int, colour:Int):Void {
		if (semiTransparent) plotSemiLinear(index, colour);
		else plotLinear(index, colour);
	}

	static function plotSemiLinear(index:Int, colour:Int):Void {
		final back = Vram.getLinear(index);
		if (!(maskCheck && (back & 0x8000) != 0)) {
			final c = blendWith(back, colour);
			Vram.setLinear(index, maskSet ? c | 0x8000 : c);
			pixels++;
		} else {}
	}

	static inline function plotLinear(index:Int, colour:Int):Void {
		if (!(maskCheck && (Vram.getLinear(index) & 0x8000) != 0)) {
			Vram.setLinear(index, maskSet ? colour | 0x8000 : colour);
			pixels++;
		} else {}
	}

	/** Whichever of the two the current primitive asked for. One predictable branch a pixel. */
	static inline function plotMaybeSemi(x:Int, y:Int, colour:Int):Void {
		if (semiTransparent) plotSemi(x, y, colour);
		else plot(x, y, colour);
	}

	/**
		A pixel blended into what is already in the framebuffer.

		The four modes are the whole of PlayStation transparency, and each is one line of
		arithmetic on five-bit channels (psx-spx, "Semi Transparency"): half and half, additive,
		subtractive, and a quarter added. Additive is the common one — every spark, flame, glow and
		lens flare on the machine is a dark texture added to the background, which is why a build
		without blending draws them as **black squares over the picture** rather than as light.

		The mask check is read once and used for both the test and the blend source: the pixel
		underneath is both what decides whether we may write and what we are blending with.
	**/
	static function plotSemi(x:Int, y:Int, colour:Int):Void {
		if (x >= 0 && x < 1024 && y >= 0 && y < 512) {
			final back = Vram.get(x, y);
			if (!(maskCheck && (back & 0x8000) != 0)) {
				final c = blendWith(back, colour);
				Vram.set(x, y, maskSet ? c | 0x8000 : c);
				pixels++;
			} else {}
		} else {}
	}

	static function blendWith(back:Int, front:Int):Int {
		final br = back & 0x1F, bg = (back >>> 5) & 0x1F, bb = (back >>> 10) & 0x1F;
		final fr = front & 0x1F, fg = (front >>> 5) & 0x1F, fb = (front >>> 10) & 0x1F;
		if (semiMode == 0) return sat555((br + fr) >> 1, (bg + fg) >> 1, (bb + fb) >> 1);
		else if (semiMode == 1) return sat555(br + fr, bg + fg, bb + fb);
		else if (semiMode == 2) return sat555(br - fr, bg - fg, bb - fb);
		else return sat555(br + (fr >> 2), bg + (fg >> 2), bb + (fb >> 2));
	}

	/** Three five-bit channels, clamped to 0..31, packed. */
	static inline function sat555(r:Int, g:Int, b:Int):Int {
		final rc = r < 0 ? 0 : (r > 31 ? 31 : r);
		final gc = g < 0 ? 0 : (g > 31 ? 31 : g);
		final bc = b < 0 ? 0 : (b > 31 ? 31 : b);
		return rc | (gc << 5) | (bc << 10);
	}

	/**
		One pixel of a drawn primitive, obeying the mask settings.

		A polygon, rectangle or line respects GP0(E6) the same way an upload does — bit-15-check
		skips a pixel the game has protected, bit-15-set marks each written pixel. Crash Bash's
		warning screen is where it shows: it draws the text first, with the mask bit set on every
		letter, and then draws the red "no" circle straight over it with mask-check on. On hardware
		the circle skips the letters and passes behind them; without the check the circle painted
		over the text, cutting each word where it crossed. Same rule as `putTexel` and `blend`,
		which is why they now share it.
	**/
	static inline function plot(x:Int, y:Int, colour:Int):Void {
		if (x >= 0 && x < 1024 && y >= 0 && y < 512) {
			if (!(maskCheck && (Vram.get(x, y) & 0x8000) != 0)) {
				Vram.set(x, y, maskSet ? colour | 0x8000 : colour);
				pixels++;
			} else {}
		} else {}
	}


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
		if (op == 0xE1) setDrawMode(v);
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
		else if (op == 0x05) { displayStart = arg & 0x7FFFF; flips++; }
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
