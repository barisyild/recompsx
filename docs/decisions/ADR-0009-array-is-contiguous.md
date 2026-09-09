# ADR-0009 — Haxe `Array` is contiguous: a patch carried on vendor/reflaxe.CPP

Status: **accepted**, 2026-08-11
Changes eight lines of a vendored submodule. Does not amend ADR-0001 (reflaxe.CPP remains the
only C++ backend) or ADR-0003 (JavaScript remains the reference, and is untouched by this).

## Context

PC sampling on a Dreamcast — 113,571 samples, 128-byte granularity, resolved off-device against
the ELF — put **14% of the emulated frame inside `std::_Deque_iterator<int,int&,int*>::operator[]`**.
That is the element accessor of `std::deque`, which is how reflaxe.CPP represents a Haxe
`Array<T>`: `std::shared_ptr<std::deque<T>>`. Indexing one is a function call through a node map,
`length` is iterator subtraction with two shifts, and a fourteen-probe binary search over the
program's 10,705-entry address table therefore cost hundreds of instructions and a chain of
dependent loads.

The tables were flattened into `shim.RawBuf` first, in the tool that emits them. It worked and it
was not enough: the accessor stayed at 9%, because the callers left were the hand-written runtime
— `Spu::writeVoice`, `Spu::decodeBlock`, `Gpu::triangle`, `Timers::ticksIn`, `OverlayMgr` — and
the same measurement said a second C++ printer for *generated* code would never have touched any
of them. `Array<Int>` being a deque is not a fact about our tables. It is a fact about the whole
program.

## Decision

**`Array<T>` compiles to `std::vector<T>`, and we carry that as a patch on the vendored
compiler.**

Three of the eight lines are the representation, in the three places reflaxe.CPP decides it:
`std/cxx/_std/Array.hx`'s `@:nativeName`, `Includes.hx`'s `ArrayInclude`, and `Expressions.hx`'s
spelling for array literals. A fourth is the `@:include` meta beside the `@:nativeName` — missing
it compiled cleanly on x86-64, where libstdc++ drags `<vector>` in transitively, and failed on
sh-elf GCC 15, which does not. Two more replace the only deque-specific operations Haxe's Array
API uses: `unshift` and `shift` become `insert(begin())` and `erase(begin())`, O(n) instead of
O(1), semantically identical, and called nowhere in this project.

The last two separate the other users of deque, which are not Haxe Arrays and must not be swept
along: `DynamicToString`'s trait detects "is this a Haxe Array", so it follows the representation;
`NativeStackTrace` keeps a deque of its own for a call stack, where cheap front insertion is the
point.

## Why a fork rather than a printer of our own

Writing a second C++ emitter in `tools/recomp` was the alternative on the table, and it solves a
different problem: build time. The 15-minute transpile is the Haxe eval interpreter's tax — no
hotspot, measured — and no patch to reflaxe.CPP will change it. But that printer would emit
*generated* code, and the cost this ADR removes is in *hand-written* runtime. Eight lines against
a project, aimed by a profile at the thing the profile actually named.

## What was verified before this was believed

- `scripts/spike.sh`: clean.
- `scripts/conformance.sh`: 14 tests x 2 targets, all agreeing, including `Mem 27f9aa59` and
  `CtxPass 8a6e7e04`.
- The game on C++, `--headless-hash 3000`: **`5853aa57`**, the digest it had before.
- `sh-elf-nm` on the Dreamcast binary: **zero** `_Deque_iterator` symbols. The accessor is not
  merely uncalled, it does not exist — `std::vector::operator[]` inlines away entirely.
- `.text` 3,121,255 -> 3,106,147 bytes, on a machine with an 8 KB instruction cache.

`Array<Bool>` was the one hazard worth naming: `std::vector<bool>` is C++'s bit-packing
specialisation, its `operator[]` returns a proxy rather than a reference, and the runtime has five
of them (`Scheduler.active`, `KThreads.used`, `OverlayMgr.resident`, `Kernel.clearRCnt`,
`Kernel.autoAck`). The conformance suite is what settled it rather than an argument.

## Consequences

We own a patch on a pinned submodule and must carry it across upstream updates; it is small and
its whole surface is the word "deque". A `Array.unshift`/`shift` in future code becomes O(n) — for
this project, where the portable subset already forbids allocation after init, that is a
non-event, but it is the one behavioural difference and it is written down here.

Nothing above the compiler changed: no runtime source, no emitter, no backend, no digest.

Historical decision restored from `6819782` on `dreamcast-hardware-rendering`.
The September main reconciliation and current verification are recorded in PROGRESS.md.
