package shim;

/**
	The GPU's hot state, C++ half: one word per variable in `recompsx_gpu`, a link-time array beside
	the GTE's register file (`native/recompsx_arena.h`), for the same reason (see GteFile): on the
	SH-4 every static is an address loaded from the literal pool before the access itself, and the
	triangle path (`gpu.Gpu.polygonHw` with its inlined helpers) read some forty of them per
	primitive. An element of one array is a base the compiler keeps in a register plus a
	displacement — the first sixteen words one instruction away. Indices are constants at every use.

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class GpuFile {
	@:nativeFunctionCode("(recompsx_gpu[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_gpu[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;

	/** The polygon core (ADR-0047, gpu.Gpu.polygonHw): on the SH-4 its answer for the packet's first
	    triangle (`second` 0) or a quad's second (1) — 0 drawn, 2 drawn with a state not the one last
	    sent, 3 rejected, 1 for the C form; elsewhere 1 (gpu.Gpu's header). */
	@:nativeFunctionCode("recompsx_gpu_poly_try(({arg0}), ({arg1}), ({arg2}), ({arg3}))")
	public static function poly(ram:RawBuf, at:Int, op:Int, second:Int):Int;

	/** The state words 52-61 hold (the polygon core's), to the backend as words (bp_gpu_state_w). */
	@:nativeFunctionCode("bp_gpu_state_w(recompsx_gpu + 52)")
	public static function backendState():Void;

	/** The triangle words 36-47 hold (gpu.Gpu.triWords), to the backend as words (bp_gpu_tri_w). */
	@:nativeFunctionCode("bp_gpu_tri_w(recompsx_gpu + 36)")
	public static function backendTri():Void;

	/** After the core recorded a triangle under the backend's state and answered 2 (ADR-0051): the
	    state words 52-61 hold, which the backend takes and moves that record into
	    (`recompsx_gpu_state_after_tri` in gpu.Gpu's header: bp_gpu_state_after_tri). */
	@:nativeFunctionCode("recompsx_gpu_state_after_tri()")
	public static function backendStateAfterTri():Void;

	/** The core's check build (`-DRECOMPSX_GPU_POLY_CHECK=1`): after the C form drew a packet. */
	@:nativeFunctionCode("recompsx_gpu_poly_after(({arg0}))")
	public static function polyChecked(op:Int):Void;

}
