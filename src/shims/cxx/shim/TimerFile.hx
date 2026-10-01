package shim;

/**
	The root counters' state, C++ half: one word per value in `recompsx_timers`, a link-time array
	beside the GTE's, the GPU's and the SPU's register files (`native/recompsx_arena.h`). As
	`Array<Int>`s each of the nine per-counter tables was a shared pointer to a vector — three
	dependent loads for an element — on the path of every counter read, which a game polling a
	timeout reads hundreds of times a frame (timers.Timers.TimerArray names each table's offset).

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class TimerFile {
	@:nativeFunctionCode("(recompsx_timers[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_timers[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;
}
