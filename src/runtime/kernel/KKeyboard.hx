package kernel;

import shim.Backend;

/**
	The host's keyboard, on its way to the machine's keyboard (`sio.Ps2Keyboard`, ADR-0040).

	**The keyboard types while it is in use**: while something polls a PS1 keyboard — a mod's text
	field does, every frame it is open. Where the host's keyboard also plays a pad (the browser and
	the desktop map keys onto pad 0), a letter must not be a button as well: typing `s` into a field
	would press square too. So from the first poll the backend's keyboard types (bp_key_text) and
	only its arrows still steer; each vblank, what it typed goes to the keyboard as key presses;
	and once no poll has come for a few vblanks it plays again, and whatever waited is dropped.

	A headless digest run has no keyboard, as it has no controllers: nothing ever answers there.
**/
class KKeyboard {
	/** Vblanks a poll keeps the keyboard typing for. */
	public static inline var IN_USE = 8;

	/** Characters taken from the backend in one vblank, at most. */
	static inline var PER_VBLANK = 64;

	static var typing = false;
	static var vblank = 0;
	static var usedAt = 0;

	public static function init():Void {
		if (typing) Backend.keyText(false);
		else {}
		sio.Ps2Keyboard.init();
		typing = false;
		vblank = 0;
		usedAt = 0;
	}

	/** A PS1 keyboard was polled (`sio.Ps2Keyboard.read`): the keyboard types from now on. */
	public static function used():Void {
		usedAt = vblank;
		if (!typing) {
			typing = true;
			sio.Ps2Keyboard.clear();
			Backend.keyText(true);
		} else {}
	}

	/** Whether the keyboard types (see above). */
	public static inline function isTyping():Bool return typing;

	/** Once per vblank, after the pads: what the backend typed goes to the keyboard. */
	public static function sample():Void {
		vblank = (vblank + 1) | 0;
		if (typing && ((vblank - usedAt) | 0) > IN_USE) {
			typing = false;
			sio.Ps2Keyboard.clear();
			Backend.keyText(false);
		} else if (typing && Kernel.haltAt == 0) {
			var n = 0;
			var more = true;
			while (more && n < PER_VBLANK) {
				final c = Backend.keyNext();
				if (c < 0) more = false;
				else sio.Ps2Keyboard.type(c);
				n++;
			}
		} else {}
	}
}
