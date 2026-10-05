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
	  - a DualShock answers the eight bytes the host sent in its slot's window — a command, its
	    TAP byte and six more — as a transfer of its own (ADR-0052): a read in analog mode is
	    5A73h, its buttons and its sticks, which fill the four halfwords, and libpad configures the
	    pad and drives its motors there;
	  - an empty slot is all FFFFh.

	**A long read answers the one before it.** The tap takes the host's eight bytes for each slot
	while it sends what it has, and talks to the four controllers after the transfer: what a long
	read returns is each controller's answer to what the previous long read sent it (BlueRetro's
	logic-analyser logs of an SCPH-1070: "a 0x43 config mode request sent in TX3 produces its
	response visible in the RX4 data"; ADR-0042 amended). libpad counts on it. Answered at once
	instead, its configuration of a DualShock fell out of step: it read 43h's answer as the one to
	the read before, left configuration mode early and asked 45h of a pad in normal mode, forever —
	Crash Bash then paused its Adventure hub with "CONTROLLER 1-A IS UNPLUGGED". The first long read
	answers a read made at its start. A garbage read or a slot-A read sends the controllers nothing
	this way.

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

	/** What the next long read answers, eight bytes a slot: the controllers' answers to `commands`,
	    taken when the last long read ended (`execute`). One read reports one moment. */
	static var slotBytes:Array<Int>;

	/** What the last long read sent each slot, eight bytes a slot; a read until one has. */
	static var commands:Array<Int>;

	/** Whether `slotBytes` holds answers yet. */
	static var primed = false;

	public static function init():Void {
		plugged = true;
		requested = false;
		answered = SLOT_A;
		inUse = false;
		slotBytes = [for (_ in 0...SLOT_BYTES) 0xFF];
		commands = [for (i in 0...SLOT_BYTES) (i & 7) == 0 ? 0x42 : 0x00];
		primed = false;
	}

	/** What the slot-A access starting now answers, from the one before it. */
	public static function next():Int {
		if (!requested) return SLOT_A;
		else if (answered == LONG) return GARBAGE;
		else return LONG;
	}

	/** A slot-A access has ended, having answered `kind`, with `request` as its third byte. A long
	    read's commands go to the controllers now. */
	public static function finished(kind:Int, request:Bool):Void {
		requested = request;
		answered = kind;
		if (kind == LONG) execute();
		else {}
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

	/** At a long read's address byte: the first one answers a read made now, as the tap would. */
	public static function latch():Void {
		if (!primed) execute();
		else {}
	}

	/** Byte `index` (0..31) of the long read's slot windows, as the host sends it. */
	public static inline function command(index:Int, v:Int):Void {
		commands[index] = v & 0xFF;
	}

	/**
		Each slot's commands to its controller, as a transfer of its own after the address the tap
		gives it: a DualShock answers them (`DualShock.answer`, configuration and motors included), a
		digital pad answers every one as a read, an empty slot not at all.
	**/
	static function execute():Void {
		for (slot in 0...4) {
			final at = slot << 3;
			if (Pads.isConnected(slot) && Pads.isDualShock(slot)) {
				DualShock.select(slot);
				for (k in 0...8) slotBytes[at + k] = DualShock.answer(k + 1, commands[at + k]) & 0xFF;
			} else {
				for (k in 0...8) slotBytes[at + k] = slotRead(slot, k);
			}
		}
		primed = true;
	}

	/**
		Byte `k` (0..7) of slot `slot` in a long read, for a digital pad: its ID 41h 5Ah and its
		buttons (active low), then FFh padding; FFh throughout for an empty slot.
	**/
	static function slotRead(slot:Int, k:Int):Int {
		final b = Pads.buttonsOf(slot);
		var r = 0xFF;
		if (!Pads.isConnected(slot)) r = 0xFF;
		else if (k == 0) r = 0x41;
		else if (k == 1) r = 0x5A;
		else if (k == 2) r = ~b & 0xFF;
		else if (k == 3) r = (~b >> 8) & 0xFF;
		else {}
		return r;
	}

	/** Byte `index` (0..31) of the long read's slot windows as the tap answers it: slot `index >> 3`. */
	public static inline function slotByte(index:Int):Int return slotBytes[index];
}
