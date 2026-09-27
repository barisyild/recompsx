package kernel;

import core.CpuState;
import core.Irq;
import mem.Memory;
import sio.Pads;

/**
	The BIOS's controller driver: B(12h) InitPAD, B(13h) StartPAD, B(14h) StopPAD, B(15h) PAD_init
	and B(16h) PAD_dr — for games built on libetc's `PadInit`/`PadRead`, which call these, rather
	than on libpad, which drives SIO0 itself.

	On hardware, StartPAD puts a handler in interrupt chain 2 that, on every vblank, clocks both
	ports through SIO0 and writes what came back into the two buffers InitPAD was handed:
	status (00h read, FFh no answer), ID, then the data halfwords. Under HLE that handler is not
	game code, so it is this class, and the controllers come from `sio.Pads` — the state the SIO0
	device would have clocked out — instead of from register traffic nobody would see.

	Behaviour follows psx-spx "BIOS Joypad Functions" and OpenBIOS, whose sio0/pad.c and
	sio0/driver.c (MIT License, Copyright (c) 2020 PCSX-Redux authors; nugget commit
	d93840921b5ad7ed515e95b0e414f1b1e2038b1a) this is adapted from — keeping the quirks games
	were written against: InitPAD zero-fills the buffers, so until the first vblank a pad reads
	"okay, every button pressed"; a port that does not answer only gets FFh in its status byte,
	its old data left in place; and PAD_init's type check, its FFh-fill undone by InitPAD's
	zero-fill, and PAD_dr's byte-swapped halfwords.

	The one liberty is where in the interrupt the buffers are written: at its start, before the
	game's own chains, where the BIOS writes them from chain 2. A handler in chain 0 or 1 therefore
	sees this vblank's buttons rather than the previous one's — input a frame sooner, and nothing
	a game can tell from a player being quicker.
**/
class KPads {
	/** psx-spx: the handler stores up to 22h bytes a pad, whatever size InitPAD was given. */
	static inline var BUFFER = 0x22;

	static var buffers:Array<Int>;
	static var sizes:Array<Int>;
	/** InitPAD has run (OpenBIOS `s_padStarted`) and StartPAD has put the handler in its chain. */
	static var initialised = false;
	static var running = false;

	/** PAD_init's hidden buffers — only PAD_dr reads them, so they live here — and its target. */
	static var hidden:Array<Int>;
	static var usingHidden = false;
	static var buttonDest = 0;

	public static function init():Void {
		buffers = [0, 0];
		sizes = [0, 0];
		hidden = [for (_ in 0...(2 * BUFFER)) 0];
		initialised = false;
		running = false;
		usingHidden = false;
		buttonDest = 0;
	}

	/** B(12h) InitPAD(buf1, siz1, buf2, siz2): remember the buffers and zero them. */
	public static function initPad(buf1:Int, siz1:Int, buf2:Int, siz2:Int):Int {
		buffers[0] = buf1;
		buffers[1] = buf2;
		sizes[0] = siz1;
		sizes[1] = siz2;
		usingHidden = false;
		buttonDest = 0;
		fill(0, 0);
		fill(1, 0);
		initialised = true;
		return 1;
	}

	/** B(13h) StartPAD: the handler goes in, and vblank is unmasked and its old edge cleared. */
	public static function startPad():Int {
		running = true;
		Irq.writeStat(~(1 << Irq.VBLANK));
		Irq.unmask(Irq.VBLANK);
		return 1;
	}

	/** B(14h) StopPAD: the handler comes out. */
	public static function stopPad():Int {
		running = false;
		return 0;
	}

	/**
		B(15h) PAD_init(type, buttonDest): InitPAD and StartPAD on buffers of the BIOS's own, and
		from then on PAD_dr's answer written to `buttonDest` every vblank. Only types 20000000h and
		20000001h are accepted; anything else returns 0 and changes nothing.
	**/
	public static function padInit(type:Int, dest:Int):Int {
		if (type != 0x20000000 && type != 0x20000001) return 0;
		else {}
		// The FFh-fill the BIOS does first is undone by the zero-fill of its own InitPAD call.
		for (i in 0...(2 * BUFFER)) hidden[i] = 0;
		initialised = true;
		usingHidden = true;
		buttonDest = dest;
		startPad();
		return 2;
	}

	/**
		B(16h) PAD_dr: both pads' buttons from PAD_init's buffers, pad 1 in the low halfword and
		pad 2 in the high, each with its bytes swapped; FFFFh (nothing pressed) for a pad that is
		absent or not a digital pad. Also written to `buttonDest`, even when that is 0.
	**/
	public static function padDr():Int {
		final word = (highLevel(0) & 0xFFFF) | ((highLevel(1) & 0xFFFF) << 16);
		Memory.write32(buttonDest, word);
		return word;
	}

	/** OpenBIOS `alterUserPadData`, reading the hidden buffer for `pad`. ID 23h (NeGcon) aside. */
	static function highLevel(pad:Int):Int {
		final at = pad * BUFFER;
		if (hidden[at] != 0) return 0xFFFF;
		else {}
		final id = hidden[at + 1];
		if (id == 0x41) return (hidden[at + 2] << 8) | hidden[at + 3];
		else if (id == 0x23) {
			var h = ((hidden[at + 2] << 8) | hidden[at + 3]) | 0x07C7;
			if (hidden[at + 5] > 0x10) h &= ~0x40;
			else {}
			if (hidden[at + 6] > 0x10) h &= ~0x80;
			else {}
			return h;
		} else return 0xFFFF;
	}

	/**
		A vblank reached the CPU: what the BIOS's chain-2 handler would do. Called by
		`Kernel.onInterrupt` with the lines pending at entry.
	**/
	public static function onInterrupt(atEntry:Int):Void {
		if (running && initialised && (atEntry & (1 << Irq.VBLANK)) != 0) {
			readPad(0);
			readPad(1);
			if (usingHidden && buttonDest != 0) padDr();
			else {}
		} else {}
	}

	/**
		One port, as OpenBIOS `readPad` leaves its buffer: a digital pad writes status 00h, ID 41h
		and its two button bytes (active low); a port nobody answers only gets status FFh.
	**/
	static function readPad(pad:Int):Void {
		if (!Pads.isConnected(pad)) {
			put(pad, 0, 0xFF);
		} else {
			final pressed = Pads.buttonsOf(pad);
			put(pad, 1, 0x41);
			put(pad, 2, ~pressed & 0xFF);
			put(pad, 3, (~pressed >> 8) & 0xFF);
			put(pad, 0, 0x00);
		}
	}

	static function put(pad:Int, index:Int, v:Int):Void {
		if (usingHidden) hidden[pad * BUFFER + index] = v;
		else if (buffers[pad] != 0) Memory.write8(buffers[pad] + index, v);
		else {}
	}

	/** InitPAD's zero-fill, over the size the game gave. */
	static function fill(pad:Int, v:Int):Void {
		final base = buffers[pad];
		if (base != 0) {
			for (i in 0...sizes[pad]) Memory.write8(base + i, v);
		} else {}
	}
}
