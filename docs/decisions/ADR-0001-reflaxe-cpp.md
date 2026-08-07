# ADR-0001: Compile the runtime and generated code with reflaxe.CPP, not hxcpp
Status: accepted   Date: 2026-08-08

## Context

recompsx must run the same Haxe runtime and generated game code on desktop today and on game
consoles later (GameCube first candidate), plus on JVM-family targets. Haxe's standard C++
target, hxcpp, ships a garbage collector and its own runtime support library, both of which are
hostile to console environments (memory constraints, no dynamic allocation discipline, platform
assumptions in the runtime). We need dependency-free C++ we fully control and can hand to any
platform SDK's toolchain.

## Decision

Compile `src/runtime`, `src/shims`, `shared/`, and all generated game code with **reflaxe.CPP**
(vendored as a pinned git submodule under `vendor/`) running on a **project-local pinned Haxe
4.3.7** in `.toolchain/`, emitting GC-less C++17 that our own CMake build consumes. hxcpp is
used nowhere. The system Haxe installation is never used. JVM targets later reuse the identical
Haxe sources through `src/shims/jvm`.

## Alternatives

- **hxcpp** — rejected: GC plus hxcpp runtime is console-hostile, and it would make the
  no-allocation-after-init discipline unenforceable.
- **Emit C++ directly from our own emitter** — rejected for now: it would duplicate a compiler
  backend we get for free, and it forfeits writing the runtime in Haxe. Retained as the
  fallback if reflaxe.CPP becomes a blocker (the tool already owns codegen).
- **lix for toolchain pinning** — rejected: adds a Node dependency and a second lockfile world;
  two tarball fetches into `.toolchain/` are transparent and agent-friendly.

## Verified facts this project relies on

Sources read directly from the reflaxe.CPP repository (state as of 2025-12-09, v0.1.0,
"In Development", single maintainer). Do not re-derive these from memory; re-verify by
experiment if behavior contradicts them.

- CI tests **exactly Haxe 4.3.7** (`.github/workflows/main.yml`). Haxe 5 is untested and must
  be assumed broken for this library.
- Invocation: `-lib reflaxe.cpp -D cpp-output=<dir>`; its `extraParams.hxml` defines `-D cxx`
  and runs `cxxcompiler.CompilerInit.Start()`.
- Output layout: `<out>/include/<Module>.h` + `<out>/src/<Module>.cpp` per class, plus
  `_main_.cpp` containing a plain `int main(int, const char**)` that calls
  `Main_Fields_::main()`, plus a `_GeneratedFiles.json` manifest.
- Extern metadata that exists: `@:include(path, brackets)`, `@:addInclude`, `@:headerInclude`,
  `@:cppInclude`, `@:noInclude`, `@:topLevel`, `@:native`, `@:nativeFunctionCode`,
  `@:nativeTypeCode`, `@:valueType`, `@:uniquePtrType`.
- **`untyped __cpp__("...")` injection is enabled** (`targetCodeInjectionName` in
  `CompilerInit.hx`) — the escape hatch for any binding the metadata cannot express.
- Low-level types available: `cxx.Ptr<T>`, **`cxx.CArray<T>` (raw `T*` with unchecked `[]`)**,
  `cxx.ConstCharPtr`, `cxx.VoidPtr`, `cxx.Ref`, `cxx.num.{Int8..UInt64,SizeT}`,
  `cxx.Stdlib.{malloc,free,ccast,sizeof}`, `cxx.Syntax.*`.
- `haxe.Int64` and `haxe.io.Bytes` have **no reflaxe.CPP std override**, so `haxe.Int64` falls
  back to Haxe's pair-of-Int32 emulation (a closed "Int64 wrong type" issue confirms past bugs).
  Therefore: 64-bit math goes through our `I64` abstract over `cxx.num.Int64`, and raw memory
  goes through our `RawBytes` abstract over `cxx.CArray<UInt8>`.
- C++ exceptions are supported, and a `cxx_exceptions_disabled` define exists. Our policy is
  no exceptions anywhere in runtime or generated code regardless; emulated `longjmp` uses the
  unwind-token protocol in `docs/specs/runtime.md` §7.3.7.
- Closures lower to `std::function` — banned in hot paths.
- `@:keep` has an open "not honored" issue — reachability must come from dispatch-table
  references, never from `@:keep`.

## Consequences

- The portable-subset discipline (golden rule 1 in `AGENTS.md`) is mandatory and partly
  enforced by `scripts/check.sh`.
- The `[M0-VERIFY]` checklist in `PROGRESS.md` gates feature work: every assumption above that
  affects code shape gets a minimal experiment before we build on it. Answers are recorded in
  `PROGRESS.md`; this ADR is amended if any assumption breaks.
- **Fork-and-fix policy**: compiler bugs are patched on a project branch inside
  `vendor/reflaxe.CPP` and offered upstream as PRs. The submodule pin never floats.
- Single-maintainer upstream risk is accepted, mitigated by vendoring and by the standing
  fallback of emitting C++ directly from our own emitter.
