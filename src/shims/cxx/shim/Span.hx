package shim;

/**
	A span (mem.Memory.span): where in the arena a run of guest accesses through one base starts.

	On C++ the arena's own address there, so that an access through the span is that address
	plus its offset: on the SH-4 one `mov.l @(disp,Rn)` per access. As an index into the arena
	the compiler saw `&recompsx_mem + (span + offset)`, made the array's address plus the offset a
	constant of its own for every offset, and paid an add and a move to address each access
	through it — three instructions where one does. Null is no span (Arena.spanNone); the
	JavaScript and JVM twins are the index itself, -1 for none.
**/
typedef Span = cxx.CArray<cxx.num.UInt8>;
