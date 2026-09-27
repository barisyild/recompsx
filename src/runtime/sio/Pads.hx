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
**/
class Pads {
	public static inline var PORTS = 2;

	/** Per port: 1 when a controller is plugged in. */
	static var connected:Array<Int>;

	/** Per port: the buttons held, PS1 bit layout, active high (1 = pressed), low 16 bits. */
	static var buttons:Array<Int>;

	public static function init():Void {
		connected = [for (_ in 0...PORTS) 0];
		buttons = [for (_ in 0...PORTS) 0];
	}

	/** Once per vblank: what the host's controllers say now. */
	public static function sample():Void {
		if (kernel.Kernel.haltAt != 0) return;
		else {}
		Backend.inputPoll();
		for (p in 0...PORTS) {
			connected[p] = Backend.padConnected(p) ? 1 : 0;
			buttons[p] = Backend.padButtons(p) & 0xFFFF;
		}
	}

	public static inline function isConnected(port:Int):Bool return connected[port] != 0;

	public static inline function buttonsOf(port:Int):Int return buttons[port];

	/** A port's state, set directly: for tests, which have no host to sample. */
	public static function set(port:Int, plugged:Bool, pressed:Int):Void {
		connected[port] = plugged ? 1 : 0;
		buttons[port] = pressed & 0xFFFF;
	}
}
