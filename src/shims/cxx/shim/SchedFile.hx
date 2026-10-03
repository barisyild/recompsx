package shim;

/**
	The scheduler's state, C++ half: one word per value in `recompsx_sched`, a link-time array
	beside the GTE's, the GPU's, the SPU's and the root counters' (`native/recompsx_arena.h`). The
	deadlines were a heap buffer behind a pointer and the bookkeeping four statics, each an address
	from the literal pool and a line of its own; a stretch of the GPU's list walk, ~200 a frame,
	went through all of them twice. Here they are one base and a displacement, and the words a
	stretch touches share a line (core.Scheduler names each word).

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class SchedFile {
	@:nativeFunctionCode("(recompsx_sched[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_sched[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;
}
