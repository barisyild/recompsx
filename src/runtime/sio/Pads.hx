package sio;

import shim.Backend;

/**
	The controllers as the emulated machine sees them: sampled from the backend once per vblank.

	That rhythm is the backend ABI's own (backend_c_api.h: `bp_input_poll` once per emulated
	vertical blank, then stable accessors), and it is what a game meets on the hardware too: a
	pad is read once a frame, by the game's vblank code. Latching here also means a transfer can
	never see the buttons change between the byte that carries the low half and the byte that
	carries the high one.

	**What is plugged in (ADR-0052).** A host pad with sticks (`bp_pad_type` BP_PAD_ANALOG) is a
	DualShock (`DualShock`), and any other a digital pad. A DualShock powers on in digital mode, so a
	game that knows only digital pads sees one either way. A pad that appears, or changes kind, is a
	controller just plugged in. Once a vblank the DualShocks' ANALOG buttons are taken (bit 16 of
	`bp_pad_buttons`, which the pad keeps to itself), and their motors go to the backend when they
	have changed (`bp_pad_rumble`).

	**A headless run has no controllers.** A digest is a function of the disc and the frame count;
	were it a function of the host's keyboard as well, two runs of one build could disagree. So
	while `Kernel.haltAt` is set every port stays empty — which is also exactly the machine every
	digest recorded before controllers existed was measured on. A script (`PadScript`) is the one
	exception, in every run: it is a function of the frame count too.

	**Where the host's four pads are plugged in (ADR-0042).** The backend has four pads. The
	machine has two ports, and a multitap in port 1 (`Multitap`). Pads 0-3 are in the tap's slots
	A-D, so port 1 read as a plain pad is pad 0. Pad 1 is also in port 2, where a two-player game
	without a tap looks for it, until the game uses the tap beyond slot A (`padOnPort`).
**/
class Pads {
	public static inline var PORTS = 2;
	/** The host's pads, the backend ABI's four (backend_c_api.h). */
	public static inline var PADS = 4;

	/** bp_pad_type's BP_PAD_ANALOG: the host's pad has sticks. */
	static inline var TYPE_ANALOG = 2;
	/** bp_pad_buttons' BP_PAD_ANALOG_BUTTON: the DualShock's ANALOG button. */
	static inline var ANALOG_BUTTON = 0x10000;

	/** Per pad: 1 when a controller is plugged in. */
	static var connected:Array<Int>;

	/** Per pad: the buttons held, PS1 bit layout, active high (1 = pressed), low 16 bits. */
	static var buttons:Array<Int>;

	/** Per pad: 1 when the controller is a DualShock, 0 a digital pad. */
	static var dual:Array<Int>;

	/** Per pad, four entries: the sticks LX LY RX RY, 0..255, 80h centred. */
	static var axes:Array<Int>;

	public static function init():Void {
		connected = [for (_ in 0...PADS) 0];
		buttons = [for (_ in 0...PADS) 0];
		dual = [for (_ in 0...PADS) 0];
		axes = [for (_ in 0...(PADS * 4)) 0x80];
		DualShock.init();
		Multitap.init();
	}

	/** Once per vblank: what the host's controllers say now — or a script, when one is set. */
	public static function sample():Void {
		if (PadScript.active) {
			sampleScript();
			return;
		} else {}
		if (kernel.Kernel.haltAt != 0) return;
		else {}
		Backend.inputPoll();
		for (p in 0...PADS) {
			final plugged = Backend.padConnected(p);
			final pressed = Backend.padButtons(p);
			plug(p, plugged, plugged && Backend.padType(p) == TYPE_ANALOG);
			buttons[p] = pressed & 0xFFFF;
			if (dual[p] != 0) {
				for (k in 0...4) axes[p * 4 + k] = Backend.padAxis(p, k) & 0xFF;
				DualShock.press(p, (pressed & ANALOG_BUTTON) != 0 ? 1 : 0);
			} else {}
		}
		report();
	}

	/**
		Pad 0 from the script (PadScript), plugged in — a DualShock with the script's sticks when it
		asks for one (`PadScript.dualShock`), a digital pad otherwise; the others empty — headless or not.
	**/
	static function sampleScript():Void {
		final pressed = PadScript.at(kernel.Kernel.vblankCount);
		for (p in 0...PADS) {
			plug(p, p == 0, p == 0 && PadScript.dualShock);
			buttons[p] = p == 0 ? pressed & 0xFFFF : 0;
		}
		if (dual[0] != 0) {
			for (k in 0...4) axes[k] = PadScript.stick(k);
			DualShock.press(0, (pressed & ANALOG_BUTTON) != 0 ? 1 : 0);
		} else {}
		report();
	}

	/**
		Pad `p` as the host has it now. A controller that appears, or turns into the other kind, is a
		new one, just powered on; its sticks are centred until it reports them.
	**/
	static function plug(p:Int, plugged:Bool, isDual:Bool):Void {
		final on = plugged ? 1 : 0;
		final d = plugged && isDual ? 1 : 0;
		if (on != connected[p] || d != dual[p]) {
			connected[p] = on;
			dual[p] = d;
			for (k in 0...4) axes[p * 4 + k] = 0x80;
			DualShock.reset(p);
		} else {}
	}

	/** The DualShocks' motors, to the backend when they have changed; a pad that is not one has none. */
	static function report():Void {
		for (p in 0...PADS) DualShock.report(p, connected[p] != 0 && dual[p] != 0);
	}

	/** Pad `pad` (0..3), the host's controller of that number. */
	public static inline function isConnected(pad:Int):Bool return connected[pad] != 0;

	public static inline function buttonsOf(pad:Int):Int return buttons[pad];

	/** Whether pad `pad` is a DualShock (`DualShock`) rather than a digital pad. */
	public static inline function isDualShock(pad:Int):Bool return dual[pad] != 0;

	/** Stick axis `axis` of pad `pad`: 0 LX, 1 LY, 2 RX, 3 RY, 0..255, 80h centred. */
	public static inline function axisOf(pad:Int, axis:Int):Int return axes[pad * 4 + axis];

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

	/** A digital pad's state, set directly: for tests, which have no host to sample. */
	public static function set(pad:Int, plugged:Bool, pressed:Int):Void {
		plug(pad, plugged, false);
		buttons[pad] = pressed & 0xFFFF;
	}

	/**
		A DualShock's state, set directly, for tests: its buttons with the ANALOG button as bit 16, and
		its sticks. The button is taken as a vblank's sample takes it, and the motors are not reported.
	**/
	public static function setDualShock(pad:Int, plugged:Bool, pressed:Int, lx:Int, ly:Int, rx:Int, ry:Int):Void {
		plug(pad, plugged, true);
		buttons[pad] = pressed & 0xFFFF;
		if (dual[pad] != 0) {
			axes[pad * 4] = lx & 0xFF;
			axes[pad * 4 + 1] = ly & 0xFF;
			axes[pad * 4 + 2] = rx & 0xFF;
			axes[pad * 4 + 3] = ry & 0xFF;
			DualShock.press(pad, (pressed & ANALOG_BUTTON) != 0 ? 1 : 0);
		} else {}
	}
}
