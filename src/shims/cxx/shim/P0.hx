package shim;

/**
	Guest accesses through the SH-4's MMU (ADR-0049, `recompsx_fastmem` on the Dreamcast): the bus
	address as a P0 address, one load or store, and the CpuState's clock named as the access's input
	so the compiler has stored it there before an access that may trap (`native/recompsx_arena.h`,
	recompsx_p0_*). The 8- and 16-bit loads come back sign-extended, as the SH-4 loads them. And the
	CpuState's next deadline read from memory, for the pump tests: an access that traps may have
	moved it, which the compiler is not told (Runtime.deadline).
**/
@:include("recompsx_arena.h", true)
extern class P0 {
	@:nativeFunctionCode("recompsx_p0_ld32((unsigned int)({arg0}), &(({arg1})->cycles))")
	public static function ld32(a:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_ld16((unsigned int)({arg0}), &(({arg1})->cycles))")
	public static function ld16(a:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_ld8((unsigned int)({arg0}), &(({arg1})->cycles))")
	public static function ld8(a:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_st32((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function st32(a:Int, v:Int, ctx:core.CpuState):Void;

	@:nativeFunctionCode("recompsx_p0_st16((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function st16(a:Int, v:Int, ctx:core.CpuState):Void;

	@:nativeFunctionCode("recompsx_p0_st8((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function st8(a:Int, v:Int, ctx:core.CpuState):Void;

	@:nativeFunctionCode("recompsx_p0_deadline(&(({arg0})->nextEvent))")
	public static function deadline(ctx:core.CpuState):Int;

	/*
		By base register and offset (Memory.read32bt and the rest): for an offset that is not
		negative, the base's bus address `base & 0x1FFFFFFF` — the compiler's to share among the
		accesses through one base value — plus the offset in the instruction's displacement or R0;
		for a negative one the bus address, as above. The same clock and deadline rules.
	*/
	@:nativeFunctionCode("recompsx_p0_ld32b((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function ld32b(base:Int, off:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_ld16b((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function ld16b(base:Int, off:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_ld8b((unsigned int)({arg0}), ({arg1}), &(({arg2})->cycles))")
	public static function ld8b(base:Int, off:Int, ctx:core.CpuState):Int;

	@:nativeFunctionCode("recompsx_p0_st32b((unsigned int)({arg0}), ({arg1}), ({arg2}), &(({arg3})->cycles))")
	public static function st32b(base:Int, off:Int, v:Int, ctx:core.CpuState):Void;

	@:nativeFunctionCode("recompsx_p0_st16b((unsigned int)({arg0}), ({arg1}), ({arg2}), &(({arg3})->cycles))")
	public static function st16b(base:Int, off:Int, v:Int, ctx:core.CpuState):Void;

	@:nativeFunctionCode("recompsx_p0_st8b((unsigned int)({arg0}), ({arg1}), ({arg2}), &(({arg3})->cycles))")
	public static function st8b(base:Int, off:Int, v:Int, ctx:core.CpuState):Void;
}
