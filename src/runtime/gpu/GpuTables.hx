package gpu;

import shim.RawBuf;
import shim.RawMem;

/**
	Two of the GPU's tables in arrays of their own on C++: the opcode counts (`Gpu.opCount`, one
	word an opcode, counted at every command a list walk sends) and the parameter counts the walk
	takes a packet whole by (`Gpu.wholeWords`). From `RawMem.alloc` they lay wherever malloc put
	them, out of the data placement's reach, and on the Dreamcast the list walk's increment of
	`opCount` missed nearly every time on what else was hot there (docs/perf/dreamcast-ledger.md,
	E-150): as `recompsx_gpu_ops` and `recompsx_gpu_whole` they are sections the placement colours
	(src/backend/dreamcast/dc-data-placement.txt). Every other target allocates them as before.
	Each is handed out zero-filled, as `RawMem.alloc` hands out its buffers.
**/
#if cxx
@:cppFileCode("extern \"C\" {
unsigned char recompsx_gpu_ops[256 * 4] __attribute__((aligned(32)));
unsigned char recompsx_gpu_whole[0x60 * 4] __attribute__((aligned(32)));
}")
#end
class GpuTables {
	public static inline var OPS_BYTES = 256 << 2;
	public static inline var WHOLE_BYTES = 0x60 << 2;

	/** `Gpu.opCount`'s storage, zero-filled. */
	public static function ops():RawBuf {
		#if cxx
		final b = TableStore.ops();
		clear(b, OPS_BYTES);
		return b;
		#else
		return RawMem.alloc(OPS_BYTES);
		#end
	}

	/** `Gpu.wholeWords`'s storage, zero-filled. */
	public static function whole():RawBuf {
		#if cxx
		final b = TableStore.whole();
		clear(b, WHOLE_BYTES);
		return b;
		#else
		return RawMem.alloc(WHOLE_BYTES);
		#end
	}

	static function clear(b:RawBuf, size:Int):Void {
		var i = 0;
		while (i < size) {
			RawMem.set8(b, i, 0);
			i++;
		}
	}
}

#if cxx
/** The two arrays GpuTables' C++ file defines. */
private extern class TableStore {
	@:nativeFunctionCode("(recompsx_gpu_ops)")
	public static function ops():RawBuf;

	@:nativeFunctionCode("(recompsx_gpu_whole)")
	public static function whole():RawBuf;
}
#end
