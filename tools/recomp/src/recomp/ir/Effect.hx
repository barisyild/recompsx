package recomp.ir;

/** Flags for observable instruction effects; CONTROL and CALL also constrain later passes. */
enum abstract Effect(Int) from Int to Int {
	var NONE = 0;
	var READ_MEMORY = 1;
	var WRITE_MEMORY = 2;
	var READ_HILO = 4;
	var WRITE_HILO = 8;
	var READ_COP = 16;
	var WRITE_COP = 32;
	var CALL = 64;
	var TRAP = 128;
	var CONTROL = 256;
	var UNKNOWN = 512;

	public inline function has(effect:Effect):Bool return (this & effect) != 0;
}
