package shim;

/**
	The machine's one CpuState, C++ half: an object at a fixed address in .bss (`recompsx_cpustate`,
	defined beside the class, core.CpuState), not on the heap. It is the hottest data there is — a
	sixth of every operand access in Crash Bandicoot: Warped's gameplay — and on the heap its lines
	fell in whatever cache sets the allocator's order gave them, there to evict and be evicted by a
	hot function's constants. At a fixed address the data placement (src/backend/dreamcast/
	dc-data-placement.txt) chooses its sets like any other hot variable's.
**/
extern class CpuStateHome {
	@:nativeFunctionCode("(&recompsx_cpustate)")
	public static function get():core.CpuState;
}
