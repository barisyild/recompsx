package sio;

import shim.Backend;

/**
	The DualShock (SCPH-1200): what a host pad with sticks is plugged in as (ADR-0052). Two sticks,
	two motors, and the configuration commands that turn them on, as nocash's psx-spx describes them
	("Controllers - Standard Digital/Analog Controllers", "- Configuration Commands", "- Vibration/
	Rumble Control").

	It powers on as the real one does, in digital mode with its LED off: a read answers as a digital
	pad's does — ID 5A41h and two bytes of buttons, L3 and R3 released — so a game that knows only
	digital pads sees one. Its ANALOG button (bit 16 of the host's buttons, `press`) turns analog mode
	on and off: ID 5A73h, and after the buttons the sticks, RX RY LX LY, 00h left or up, 80h centred,
	FFh right or down. A game that knows the DualShock finds it with command 43h, whose fourth byte
	01h enters configuration mode: ID 5AF3h and nine bytes to every command. There 44h sets the mode
	and may lock it against the button, 45h-4Ch answer the pad's constants, and 4Dh says which bytes
	of a read drive which motor, answering with the mapping it replaces. Back in normal mode, a read's
	bytes drive the motors as mapped: the small motor on bit 0 of its byte, the large one at the
	byte's speed. A pad never configured rumbles the old way: its small motor runs while a read's
	fourth byte is 40h..7Fh and its fifth is odd.

	In normal mode it takes 42h and 43h only, and in configuration mode 40h-4Fh. Any other command is
	answered with the ID — shifted out before the command came in — and not acknowledged, so the
	transfer ends there (as DuckStation's analog controller ends it, ADR-0052). Each byte is answered
	from the pad's state before that byte arrives, as the wire does, and a transfer keeps the form its
	command byte found. The motors are output only. The backend hears of
	them once a vblank, when they change (`report`, bp_pad_rumble), and the large one as the real
	motor turns: not below about 50h from rest, and down to about 38h once running.

	Not modelled (psx-spx): the watchdog that resets a pad left unread for a second after
	configuration mode; the 00h a configured pad sends in place of 5Ah once the player has pressed
	ANALOG; and the longer digital read that a motor mapped past the fifth byte makes.
**/
class DualShock {
	/** What a transfer answers in, fixed at its command byte. */
	static inline var DIGITAL = 0;    // ID 5A41h, five bytes
	static inline var ANALOG = 1;     // ID 5A73h, nine bytes
	static inline var CONFIG = 2;     // ID 5AF3h, nine bytes

	/** Set in `answer`'s result when the pad acknowledges the byte. */
	public static inline var ACK = 0x100;

	/** The large motor starts turning from rest at about this speed, and stops below `KEEP`. */
	static inline var START = 0x50;
	static inline var KEEP = 0x38;

	/** The bytes of a read 4Dh can map, the fourth to the ninth. */
	static inline var MAPPED = 6;

	/** Report every change of the motors to the log as well (`--log-rumble`). */
	public static var logMotors = false;

	/** Per pad: 1 in analog mode (LED red), 0 in digital mode. */
	static var analog:Array<Int>;
	/** Per pad: 1 in configuration mode. */
	static var config:Array<Int>;
	/** Per pad: 1 while 44h has locked the mode, so that the ANALOG button does nothing. */
	static var locked:Array<Int>;
	/** Per pad: 1 once configuration mode has been entered. The old one-motor rumble is then off. */
	static var configured:Array<Int>;
	/** Per pad, `MAPPED` entries: what the fourth to ninth bytes of a read drive (4Dh). 00h is the
	    small motor, 01h the large one, FFh nothing. */
	static var mapping:Array<Int>;
	/** Per pad: the motors as the game last drove them. The small one is 0 or 1, the large one 0..255. */
	static var small:Array<Int>;
	static var large:Array<Int>;
	/** Per pad: whether the large motor is turning. */
	static var turning:Array<Int>;
	/** Per pad: the motors as the backend last heard of them. */
	static var shownSmall:Array<Int>;
	static var shownLarge:Array<Int>;
	/** Per pad: the ANALOG button at the last sample, so that a press is its edge. */
	static var button:Array<Int>;

	// The transfer on the wire. SIO0 carries one at a time.
	static var pad = 0;
	static var form = DIGITAL;
	static var command = 0;
	/** The command is not one the pad takes in its mode: nothing after its ID is answered. */
	static var rejected = false;
	/** The fourth byte the host sent: 43h's request, 44h's mode, 46h-4Ch's index. */
	static var argument = 0;
	/** The buttons and the sticks as of the address byte, so that one transfer reports one moment.
	    The sticks are in a read's order: RX RY LX LY. */
	static var held = 0;
	static var sticks:Array<Int>;

	public static function init():Void {
		analog = [for (_ in 0...Pads.PADS) 0];
		config = [for (_ in 0...Pads.PADS) 0];
		locked = [for (_ in 0...Pads.PADS) 0];
		configured = [for (_ in 0...Pads.PADS) 0];
		mapping = [for (_ in 0...(Pads.PADS * MAPPED)) 0xFF];
		small = [for (_ in 0...Pads.PADS) 0];
		large = [for (_ in 0...Pads.PADS) 0];
		turning = [for (_ in 0...Pads.PADS) 0];
		shownSmall = [for (_ in 0...Pads.PADS) 0];
		shownLarge = [for (_ in 0...Pads.PADS) 0];
		button = [for (_ in 0...Pads.PADS) 0];
		sticks = [0x80, 0x80, 0x80, 0x80];
		pad = 0;
		form = DIGITAL;
		command = 0;
		argument = 0;
		held = 0;
	}

	/** Pad `p` has just been plugged in: the controller as it powers on. */
	public static function reset(p:Int):Void {
		analog[p] = 0;
		config[p] = 0;
		locked[p] = 0;
		configured[p] = 0;
		for (k in 0...MAPPED) mapping[p * MAPPED + k] = 0xFF;
		small[p] = 0;
		large[p] = 0;
		turning[p] = 0;
		button[p] = 0;
	}

	/**
		Once a vblank (`Pads.sample`): pad `p`'s ANALOG button, `down` 1 while it is held. A press
		toggles the mode unless the game has locked it, and resets the pad as the button does on the
		real one: out of configuration mode, the motors stopped and unmapped.
	**/
	public static function press(p:Int, down:Int):Void {
		if (down != 0 && button[p] == 0 && locked[p] == 0) {
			analog[p] = analog[p] ^ 1;
			config[p] = 0;
			stopMotors(p);
		} else {}
		button[p] = down;
	}

	static function stopMotors(p:Int):Void {
		for (k in 0...MAPPED) mapping[p * MAPPED + k] = 0xFF;
		small[p] = 0;
		large[p] = 0;
	}

	/**
		Once a vblank (`Pads.sample`): pad `p`'s motors as they turn now, to the backend when that
		changed. `present` is false for a pad that is not a DualShock, whose motors are still.
	**/
	public static function report(p:Int, present:Bool):Void {
		var s = 0;
		var l = 0;
		if (present) {
			final v = large[p];
			if (v >= START) turning[p] = 1;
			else if (v < KEEP) turning[p] = 0;
			else {}
			s = small[p];
			l = turning[p] != 0 ? v : 0;
		} else {
			turning[p] = 0;
		}
		if (s != shownSmall[p] || l != shownLarge[p]) {
			shownSmall[p] = s;
			shownLarge[p] = l;
			Backend.padRumble(p, s, l);
			if (logMotors) Backend.log(Backend.LOG_INFO, "pad " + p + " motors: small " + s + ", large " + l
				+ " (vblank " + kernel.Kernel.vblankCount + ")");
			else {}
		} else {}
	}

	/** The motors as the game drives them: the small one 0 or 1, the large one 0..255. */
	public static inline function smallMotor(p:Int):Int return small[p];

	public static inline function largeMotor(p:Int):Int return large[p];

	/** The motors as the backend last heard of them (`report`). */
	public static inline function shownSmallMotor(p:Int):Int return shownSmall[p];

	public static inline function shownLargeMotor(p:Int):Int return shownLarge[p];

	/** 1 when pad `p` is in analog mode. */
	public static inline function isAnalog(p:Int):Int return analog[p];

	// ---- a transfer ------------------------------------------------------------------------------

	/** The address byte has selected pad `p`; the transfer reports its buttons and sticks as they are now. */
	public static function select(p:Int):Void {
		pad = p;
		command = 0;
		argument = 0;
		rejected = false;
		form = DIGITAL;
		held = Pads.buttonsOf(p);
		sticks[0] = Pads.axisOf(p, 2);
		sticks[1] = Pads.axisOf(p, 3);
		sticks[2] = Pads.axisOf(p, 0);
		sticks[3] = Pads.axisOf(p, 1);
	}

	/**
		Byte `step` of the selected pad's transfer, 1 being the command byte, with `v` the byte the host
		sends: the answer in bits 0-7, and `ACK` when the pad acknowledges it. A transfer's last byte
		(the fifth in digital mode, the ninth otherwise) is not acknowledged, and nothing after it is
		answered; nor is anything after a command the pad does not take.
	**/
	public static function answer(step:Int, v:Int):Int {
		var r = 0xFF;
		if (step == 1) {
			command = v;
			form = config[pad] != 0 ? CONFIG : (analog[pad] != 0 ? ANALOG : DIGITAL);
			rejected = form == CONFIG ? (v < 0x40 || v > 0x4F) : (v != 0x42 && v != 0x43);
			r = rejected ? idOf(form) : (idOf(form) | ACK);
		} else if (rejected) {
			r = 0xFF;
		} else if (step == 2) {
			r = 0x5A | ACK;
		} else {
			final last = form == DIGITAL ? 4 : 8;
			if (step <= last) {
				if (step == 3) argument = v;
				else {}
				final b = form == CONFIG ? configByte(step, v) : readByte(step, v);
				r = step < last ? (b | ACK) : b;
			} else {}
		}
		return r;
	}

	static inline function idOf(f:Int):Int return f == CONFIG ? 0xF3 : (f == ANALOG ? 0x73 : 0x41);

	/**
		A read's byte `step` (3 on) in the transfer's form: the buttons, active low, then the sticks.
		42h's bytes drive the motors; outside configuration mode, 43h's fourth byte 01h enters it.
	**/
	static function readByte(step:Int, v:Int):Int {
		if (command == 0x42) drive(step, v);
		else if (command == 0x43 && form != CONFIG && step == 3 && v == 0x01) enter();
		else {}
		// L3 and R3 are read in analog mode only (psx-spx); configuration mode's 42h reads them too.
		final pressed = form == DIGITAL ? held & ~0x0006 : held;
		var r = 0;
		if (step == 3) r = ~pressed & 0xFF;
		else if (step == 4) r = (~pressed >> 8) & 0xFF;
		else r = sticks[step - 5];
		return r;
	}

	static function enter():Void {
		config[pad] = 1;
		configured[pad] = 1;
	}

	/** A read's byte `step` as the motors take it. */
	static function drive(step:Int, v:Int):Void {
		if (configured[pad] == 0) {
			// The old way: the small motor alone, on while the fourth byte is 40h..7Fh and the fifth odd.
			if (step == 4) small[pad] = (argument & 0xC0) == 0x40 && (v & 1) != 0 ? 1 : 0;
			else {}
		} else {
			final m = mapping[pad * MAPPED + step - 3];
			if (m == 0x00) small[pad] = v & 1;
			else if (m == 0x01) large[pad] = v;
			else {}
		}
	}

	/**
		Configuration mode's byte `step` (3 on) of `command`, whose fourth byte was `argument`:
		  42h  the buttons and the sticks in any mode, and the motors driven;
		  43h  00h, the fourth byte 00h back to normal mode (01h stays);
		  44h  00h, the fourth byte the mode (00h digital, 01h analog, others ignored), the fifth
		       the lock (03h in its low bits locks, anything else unlocks);
		  45h  01h 02h, the mode, 02h 01h 00h: a PlayStation analog pad, two modes, two motors, one
		       list of motors that may run together;
		  46h  the motor `argument` is: 00h 00h then 01h 02h 00h 0Ah for the small one, 01h 01h 01h
		       14h for the large one, zeros for any other;
		  47h  00h 00h 02h 00h 01h 00h for list 0, zeros for any other;
		  48h  00h 00h 00h 00h 01h 00h for 0 and 1, zeros otherwise;
		  4Ch  00h 00h 00h and the mode's ID nibble — 04h for mode 0, 07h for mode 1 — zeros otherwise;
		  4Dh  the old mapping out, byte for byte, as the new one comes in;
		and zeros for anything else (40h, 41h, 49h-4Bh, 4Eh, 4Fh; psx-spx).
	**/
	static function configByte(step:Int, v:Int):Int {
		final c = command;
		var r = 0x00;
		if (c == 0x42) r = readByte(step, v);
		else if (c == 0x43) {
			if (step == 3) config[pad] = v == 0x01 ? 1 : 0;
			else {}
		} else if (c == 0x44) {
			if (step == 3 && v <= 0x01) analog[pad] = v;
			else if (step == 4) locked[pad] = (v & 3) == 3 ? 1 : 0;
			else {}
		} else if (c == 0x45) r = status(step);
		else if (c == 0x46) r = actuator(step);
		else if (c == 0x47) {
			if (argument == 0 && step == 5) r = 0x02;
			else if (argument == 0 && step == 7) r = 0x01;
			else {}
		} else if (c == 0x48) {
			if (argument <= 1 && step == 7) r = 0x01;
			else {}
		} else if (c == 0x4C) {
			if (step == 6 && argument == 0) r = 0x04;
			else if (step == 6 && argument == 1) r = 0x07;
			else {}
		} else if (c == 0x4D) {
			final at = pad * MAPPED + step - 3;
			r = mapping[at];
			mapping[at] = v;
		} else {}
		return r;
	}

	static function status(step:Int):Int {
		var r = 0x00;
		if (step == 3) r = 0x01;
		else if (step == 4) r = 0x02;
		else if (step == 5) r = analog[pad];
		else if (step == 6) r = 0x02;
		else if (step == 7) r = 0x01;
		else {}
		return r;
	}

	static function actuator(step:Int):Int {
		var r = 0x00;
		if (argument == 0) {
			if (step == 5) r = 0x01;
			else if (step == 6) r = 0x02;
			else if (step == 8) r = 0x0A;
			else {}
		} else if (argument == 1) {
			if (step == 5 || step == 6 || step == 7) r = 0x01;
			else if (step == 8) r = 0x14;
			else {}
		} else {}
		return r;
	}

	// ---- reads made elsewhere ----------------------------------------------------------------------

	/** How many bytes pad `p` answers a read with after its address: 4 in digital mode, 8 otherwise. */
	public static function readLength(p:Int):Int return (config[p] != 0 || analog[p] != 0) ? 8 : 4;

	/**
		Byte `k` of pad `p`'s answer to a read, from its ID's low byte (k = 0) on — 5Ah, the buttons,
		the sticks — as the BIOS's pad handler (`kernel.KPads`) and a multitap's long read
		(`Multitap.latch`) take it, `readLength` bytes of it. It drives no motor and changes no mode:
		neither sends anything to the motors.
	**/
	public static function readAt(p:Int, k:Int):Int {
		final f = config[p] != 0 ? CONFIG : (analog[p] != 0 ? ANALOG : DIGITAL);
		final b = Pads.buttonsOf(p);
		final pressed = f == DIGITAL ? b & ~0x0006 : b;
		var r = 0;
		if (k == 0) r = idOf(f);
		else if (k == 1) r = 0x5A;
		else if (k == 2) r = ~pressed & 0xFF;
		else if (k == 3) r = (~pressed >> 8) & 0xFF;
		else if (k == 4) r = Pads.axisOf(p, 2);
		else if (k == 5) r = Pads.axisOf(p, 3);
		else if (k == 6) r = Pads.axisOf(p, 0);
		else r = Pads.axisOf(p, 1);
		return r;
	}
}
