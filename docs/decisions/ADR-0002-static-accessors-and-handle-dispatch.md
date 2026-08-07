# ADR-0002: Static accessors and integer-handle dispatch
Status: accepted   Date: 2026-08-08

## Context

Two design questions were left open by the master plan because they depended on how reflaxe.CPP
actually lowers Haxe, not on what we would prefer:

1. How do generated MIPS functions reach emulated memory? The plan assumed an instance API
   (`mem.read32(a)`) backed by an abstract over raw bytes, with `inline` making it free.
2. How does the address→function table work? The plan assumed an array of function references,
   with an integer-handle scheme as a documented fallback.

The M0.3 spikes (`tests/spike/verify`) answered both, and the answers were not the assumed ones.
Both findings are recorded with evidence in `PROGRESS.md` [M0-VERIFY] #12 and #18.

**Inlined instance methods do not compile when called twice in a scope.** Haxe's inliner
introduces a receiver temporary, and reflaxe.CPP emits its name verbatim — `T& _this = …;` for
classes, `T* this1 = …;` for abstracts — without uniquifying it. Two inlined instance-method
calls in one function body produce `error: redefinition of '_this'`. Generated code performs
several memory accesses per MIPS function, so an instance API is not merely slower, it does not
build. Static methods have no receiver, emit no temporary, and inline perfectly:
`Mem.set32(0x1000, v)` becomes four direct `Mem::ram[4096] = …;` stores.

**Function values are heap-allocated and type-erased, and arrays of them do not compile.**
`Array<(Int)->Int>` lowers to `std::deque<std::shared_ptr<std::function<int(int)>>>`. The array
literal fails to compile outright (`arithmetic on a pointer to the function type`), and even if
it built, a shared_ptr'd `std::function` per entry is unacceptable for a table with one entry per
reachable address on a 32 MB console.

## Decision

**Memory and other hot runtime state are exposed as `static` methods over `static` fields.** The
codegen contract is `Memory.read32(a)`, not `mem.read32(a)`; generated functions take `ctx` only.
`RawMem` is a class of static buffers and static inline accessors, not an abstract. There is
exactly one emulated machine, so a singleton is also the honest model.

**The function table stores packed integer handles and dispatches through generated `switch`
statements.** Each shard emits `static function dispatch(localIdx:Int, ctx:CpuState):Void`
switching over its own functions; the address→handle table holds `(shardId << 20) | localIdx` in
raw memory; a generated top-level switch routes a handle to its shard. No function value exists
anywhere in the program.

## Alternatives

- **Fork reflaxe.CPP to uniquify inline temporaries.** The proper fix, and worth upstreaming
  eventually, but it would make our build depend on a patch before any recompilation exists.
  Deferred, not rejected — it is item 1 of the fork-and-fix backlog in `PROGRESS.md`.
- **Drop `inline` and rely on the C++ compiler.** Memory accessors and generated code land in
  different translation units, so this needs LTO or unity builds to inline at all. Rejected as
  the default: it trades a guaranteed property for a build-configuration-dependent one.
- **Wrap every generated statement in braces** so each `_this` gets its own C++ scope. Works
  only for generated code, not for the hand-written runtime, and makes the output unreadable.

## Consequences

- Runtime subsystems that would naturally be objects (Memory, Gpu, Spu, Cdrom) are static
  classes. Acceptable — there is one PS1 — but it means no second instance for A/B comparison in
  the same process. If a divergence-bisecting interpreter ever needs two states, it compares
  across processes or serialized snapshots instead.
- Dispatch through a switch is a bounds-checked jump table in practice, which is competitive with
  an indirect call and far better than a `std::function` invocation. The generated top-level
  switch grows with the shard count, not the function count, so it stays small.
- The handle table is plain `Int` data in a `CArray`, so it participates in the same
  determinism-hashing and savestate machinery as everything else.
- Both decisions become moot if the upstream inline bug is fixed and function pointers start
  lowering cleanly. Revisit only if a measurement says the switch dispatch is a bottleneck.
