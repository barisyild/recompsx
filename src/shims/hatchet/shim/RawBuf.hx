package shim;

/**
	The raw byte buffer type, named once so the runtime never mentions a target-specific one.

	Hatchet half: a bare `uint8_t*` (`cpp.RawPointer<cpp.UInt8>`). Every access goes through
	`RawMem`/`MemA`, whose bodies live in `native/recompsx_hatchet.h`.
**/
typedef RawBuf = cpp.RawPointer<cpp.UInt8>;
