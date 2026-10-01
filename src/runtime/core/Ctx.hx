package core;

/**
	The CpuState as a recompiled function holds it: `ctx`, which on C++ is
	`core::CpuState* __restrict` and everywhere else the CpuState itself.

	Generated code reads and writes the machine's registers in the CpuState (ADR-0029) and the
	guest's memory in `recompsx_mem` (the arena, E-012). As a plain pointer parameter `ctx` could
	point anywhere, into the arena too, so GCC reloaded every register field after every guest
	store; restrict tells it that within the function nothing but `ctx` reaches the CpuState.
	Measured under the cache model: Crash 3's generated code 0.09 ms a frame faster
	(docs/perf/dreamcast-ledger.md, E-041).

	It is true of generated code as written: the CpuState is reached through `ctx` and what is
	derived from it, and `ctx` goes to a call in every function (the entry pump at least), so GCC
	counts it as escaped and every call as one that may change it — including a runtime path that
	reaches the machine through `Memory.machine` or `Scheduler.owner`. What restrict takes away is
	only the plain loads and stores, and no guest access, GTE or GPU register file reaches the
	CpuState.

	`@:valueType`, because the spelling is already a pointer: without it reflaxe.CPP wraps the
	abstract in a `std::shared_ptr`. `@:forward`, so `ctx.a0` is the field. `from`/`to` CpuState,
	so it goes to and comes from every runtime function unchanged. Verified by a spike (golden
	rule 6): the signature, the field accesses, the conversions both ways, and a function pointer
	`void (*)(core::CpuState*, int)` to such a function — restrict on a parameter is not part of
	the function's type.
**/
@:nativeTypeCode("core::CpuState* __restrict")
@:valueType
@:forward
abstract Ctx(CpuState) from CpuState to CpuState {}
