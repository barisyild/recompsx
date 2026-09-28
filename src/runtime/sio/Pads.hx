package sio;

import shim.Backend;

/**
	The controllers as the emulated machine sees them: sampled from the backend once per vblank.

	That rhythm is the backend ABI's own (backend_c_api.h: `bp_input_poll` once per emulated
	vertical blank, then stable accessors), and it is what a game meets on the hardware too: a
	pad is read once a frame, by the game's vblank code. Latching here also means a transfer can
	never see the buttons change between the byte that carries the low half and the byte that
	carries the high one.

	**A headless run has no controllers.** A digest is a function of the disc and the frame count;
	were it a function of the host's keyboard as well, two runs of one build could disagree. So
	while `Kernel.haltAt` is set every port stays empty — which is also exactly the machine every
	digest recorded before controllers existed was measured on.

	**Where the host's four pads are plugged in (ADR-0042).** The backend has four pads. The
	machine has two ports, and a multitap in port 1 (`Multitap`). Pads 0-3 are in the tap's slots
	A-D, so port 1 read as a plain pad is pad 0. Pad 1 is also in port 2, where a two-player game
	without a tap looks for it, until the game uses the tap beyond slot A (`padOnPort`).
**/
class Pads {
	public static inline var PORTS = 2;
	/** The host's pads, the backend ABI's four (backend_c_api.h). */
	public static inline var PADS = 4;

	/** Per pad: 1 when a controller is plugged in. */
	static var connected:Array<Int>;

	/** Per pad: the buttons held, PS1 bit layout, active high (1 = pressed), low 16 bits. */
	static var buttons:Array<Int>;

	public static function init():Void {
		connected = [for (_ in 0...PADS) 0];
		buttons = [for (_ in 0...PADS) 0];
		Multitap.init();
	}

	/** Once per vblank: what the host's controllers say now. */
	public static function sample():Void {
		if (kernel.Kernel.haltAt != 0) return;
		else {}
		Backend.inputPoll();
		for (p in 0...PADS) {
			connected[p] = Backend.padConnected(p) ? 1 : 0;
			buttons[p] = Backend.padButtons(p) & 0xFFFF;
		}
	}

	/** Pad `pad` (0..3), the host's controller of that number. */
	public static inline function isConnected(pad:Int):Bool return connected[pad] != 0;

	public static inline function buttonsOf(pad:Int):Int return buttons[pad];

	/**
		The pad a plain read of `port` finds, or -1 for none. Port 1 is pad 0, with or without the
		tap: without it pad 0 is in the port itself, with it in slot A. Port 2 is pad 1, unless the
		game has used the tap beyond slot A, which puts pad 1 in slot B only.
	**/
	public static function padOnPort(port:Int):Int {
		if (port == 0) return 0;
		else if (Multitap.plugged && Multitap.inUse) return -1;
		else return 1;
	}

	/** A pad's state, set directly: for tests, which have no host to sample. */
	public static function set(pad:Int, plugged:Bool, pressed:Int):Void {
		connected[pad] = plugged ? 1 : 0;
		buttons[pad] = pressed & 0xFFFF;
	}
}
