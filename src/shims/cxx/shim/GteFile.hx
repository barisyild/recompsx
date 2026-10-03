package shim;

/**
	The GTE's register file, C++ half: one word per register in `recompsx_gte`, a link-time array
	beside emulated RAM (`native/recompsx_arena.h`).

	Named static fields were one global each, and on the SH-4 a global is an address loaded from
	the literal pool before the load or store itself — RTPS read some thirty of them. An element
	of one array is its base, which the compiler keeps in a register for the whole command, plus
	a displacement: the first sixteen words are one instruction away, the rest two. Indices are
	constants at every use, and the array is its own object, so the compiler can keep an element
	in a machine register as freely as it kept a field.

	`dot3` is a matrix row times a vector, three signed halfwords of the file by three
	(`recompsx_gte_dot3`, which `gte.Gte`'s header carries, the only class that calls it): on the
	SH-4 its multiply-accumulate unit reads them itself.

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class GteFile {
	@:nativeFunctionCode("(recompsx_gte[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_gte[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;

	/** The low 32 bits of the sum of halfword m times halfword v, m+1 times v+1 and m+2 times
	    v+2, each signed; halfword h is word h >> 1's low half for an even h, its high half else. */
	@:nativeFunctionCode("recompsx_gte_dot3(({arg0}), ({arg1}))")
	public static function dot3(m:Int, v:Int):Int;

	/** RTPS/RTPT's vertex at halfword `vh` in the SH-4's core (ADR-0046, `recompsx_gte_rtp` in
	    gte.Gte's header): 0 when it wrote every output, 1 when it declined and the C form runs. On
	    any other machine 1, which the compiler folds away. */
	@:nativeFunctionCode("recompsx_gte_rtp(({arg0}), ({arg1}) ? 1 : 0, ({arg2}) ? 1 : 0)")
	public static function rtp(vh:Int, lm:Bool, last:Bool):Int;

	/** After the C form of a vertex: with RECOMPSX_GTE_RTP_CHECK the core's answer, worked on a copy
	    of the file, compared with it word by word; otherwise nothing. */
	@:nativeFunctionCode("recompsx_gte_rtp_after()")
	public static function rtpChecked():Void;
}
