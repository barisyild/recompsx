package core;

/**
	Relocatable code's one piece of shared state (ADR-0025).

	A relocatable function is compiled once and runs wherever the game put its bytes, so the only
	thing it needs at run time is where that is. The dispatcher (`RelocTable.call`, generated)
	stores the entry address here immediately before the call, and the function's first statement
	copies it into a local — before anything it does can run another relocatable function and
	overwrite it. A suspended one gets it back from its cooperative frame (`Cooperative`).
**/
class Reloc {
	/** The entry address of the relocatable function being entered. */
	public static var base = 0;

	/** Entries into relocatable code. Deterministic, like every counter the heartbeat prints. */
	public static var calls = 0;

	public static function reset():Void {
		base = 0;
		calls = 0;
	}
}
