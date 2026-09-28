package sio;

/**
	The Multitap (SCPH-1070): four controllers and four memory cards on one port (psx-spx,
	"Controller and Memory Card Multitap Adaptor"). It is plugged into port 1, with the host's pads
	0-3 in slots A-D (ADR-0042).

	A game reads it as it reads a pad: address 01h, then 42h. It answers for slot A, so a game that
	knows nothing of the tap sees an ordinary controller. The byte a game sends third, while the tap
	answers 5Ah, is its request, and 01h asks that the *next* read be the long one:

	  - ID 5A80h, then four halfwords per slot, A to D;
	  - a digital pad in a slot is its ID 5A41h and its buttons, padded with FFFFh;
	  - an empty slot is all FFFFh.

	Asked again during a long read, the read after it is garbage: four bytes (Hi-Z, 80h, 5Ah, slot
	A's ID low byte) and nothing more. Then comes the long one again. So a game that always asks
	gets long and garbage by turns, and one that asks every other read gets slot A and long by
	turns (psx-spx's table; `next` implements it). With slot A empty the tap does not acknowledge
	the address, and no request can be sent at all. So with all four slots empty (a headless run)
	the tap answers exactly as an empty port does.

	Addresses 02h-04h read slots B-D directly, each answering as a pad on its own port would. Cards
	answer at 81h-84h. Slot A's is the machine's one card (`MemoryCard`); B-D hold none.

	**Pad 1 is in one place at a time.** A two-player game that knows no tap looks for its second
	player in port 2, so pad 1 is there as well as in slot B. Once a game uses the tap for more than
	slot A (a long read, or slot B-D addressed), pad 1 is in slot B only (`inUse`, and
	`Pads.padOnPort`). From then on no game sees one controller twice. It stays so until the machine
	is reset: a game that has found the tap goes on using it.
**/
class Multitap {
	/** What a slot-A access answers with (psx-spx: "returns Slot A data", "Slot A-D", "garbage"). */
	public static inline var SLOT_A = 0;
	public static inline var LONG = 1;
	public static inline var GARBAGE = 2;

	/** Bytes a long read answers after its ID: four slots of four halfwords. */
	public static inline var SLOT_BYTES = 32;

	/** Whether the tap is in port 1; without it, port 1 holds pad 0 and port 2 pad 1 directly. */
	public static var plugged = true;

	/** The last slot-A access's request (its third byte was 01h), and what that access answered. */
	static var requested = false;
	static var answered = SLOT_A;

	/** The game has used the tap for more than slot A; pad 1 has left port 2 for slot B. */
	public static var inUse(default, null) = false;

	/** Each slot's pad as of the long read's address byte: one read reports one moment. */
	static var slotPresent:Array<Int>;
	static var slotButtons:Array<Int>;

	public static function init():Void {
		plugged = true;
		requested = false;
		answered = SLOT_A;
		inUse = false;
		slotPresent = [0, 0, 0, 0];
		slotButtons = [0, 0, 0, 0];
	}

	/** What the slot-A access starting now answers, from the one before it. */
	public static function next():Int {
		if (!requested) return SLOT_A;
		else if (answered == LONG) return GARBAGE;
		else return LONG;
	}

	/** A slot-A access has ended, having answered `kind`, with `request` as its third byte. */
	public static function finished(kind:Int, request:Bool):Void {
		requested = request;
		answered = kind;
	}

	/** Slot A was empty: the access ended at its address, before any request could be sent. */
	public static function aborted():Void {
		requested = false;
		answered = SLOT_A;
	}

	/** The game reads the tap beyond slot A. */
	public static function used():Void {
		inUse = true;
	}

	/** At a long read's address byte: every slot's pad, as it is now. */
	public static function latch():Void {
		for (s in 0...4) {
			slotPresent[s] = Pads.isConnected(s) ? 1 : 0;
			slotButtons[s] = Pads.buttonsOf(s);
		}
	}

	/**
		Byte `index` (0..31) of the long read's slot block: slot `index >> 3`, a digital pad's ID
		41h 5Ah and its buttons (active low), then FFh padding. An empty slot answers FFh
		throughout.
	**/
	public static function slotByte(index:Int):Int {
		final slot = index >> 3;
		final k = index & 7;
		if (slotPresent[slot] == 0) return 0xFF;
		else if (k == 0) return 0x41;
		else if (k == 1) return 0x5A;
		else if (k == 2) return ~slotButtons[slot] & 0xFF;
		else if (k == 3) return (~slotButtons[slot] >> 8) & 0xFF;
		else return 0xFF;
	}
}
