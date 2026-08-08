package shim;

/**
	The raw byte buffer type, named once so the runtime never mentions a target-specific one.

	`src/shims/cxx` maps it to a bare C pointer; `src/shims/js` maps it to a typed array. Runtime
	code says `shim.RawBuf` and stays honest on both.
**/
typedef RawBuf = cxx.CArray<cxx.num.UInt8>;
