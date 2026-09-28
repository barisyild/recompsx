# ADR-0033: Mods — per-game Haxe that extends a recompiled game, through hooks the generator emits
Status: accepted   Date: 2026-09-28
Realises the "modding hook" docs/specs/tool.md reserved for `nativeReplacements`, which was
specified but never implemented.

## Context

A static recompilation is a program we build, so a game can be given what it never had — a menu
entry, a mode, a fix — the way a port would be, not the way a cheat device patches a running
console. The first request: an ONLINE line under BATTLE MODE in Crash Bash's Select Game Type
menu, on the JavaScript target, without editing the transpiled code. The user asked for it to be
a permanent, general facility for every game, not a one-game patch.

What is available without new machinery is not enough. Data patches reach the game (`mem.Memory`
writes), but code patches do not: the instructions in RAM are not what runs. The runtime's
dynamic dispatch (`Runtime.bindDispatch`) sees only calls by address; Crash Bash makes 4,643
direct static calls against 658 through `FnTable.run`, and a mod needs to reach the functions
the game calls directly. Golden rule 5 forbids editing generated code, and a build without mods
must stay the program every digest was measured on.

## Decision

A mod is a directory `games/<SERIAL>/mods/<id>/`: a `mod.json` naming the guest functions it
hooks (by address, optionally scoped to an overlay or "exe", since overlays share windows), the
class whose `install` registers it, and optionally its guest-memory heap; and Haxe sources in
package `<id>`, held to the runtime's portable subset and determinism rules.

`recompsx gen --mods <ids | all>` emits one line at the entry of each hooked function — after the
entry pump, before a leaf's register locals, and only for a real call (`entry == 0`, and in a
cooperative build not a resume past the entry's own checkpoint):
`if (entry == 0 && mod.ModHost.enter(ctx, addr)) return;`. It refuses a hook no function begins
at, copies the mods' sources beside the generated program, and writes `ModList`, which declares
the hooked addresses and the heap and calls each mod's `install`. Nothing else in the output
changes; without `--mods` the output is byte-identical to the generator's before this ADR.

The runtime's `mod.ModHost` is the whole interface: `hook(addr, fn)` (true from `fn` answers the
call), `callOriginal` (the hooked function runs as the guest called it, without yielding),
`call` (any guest function), `onFrame` (every vblank, from `Kernel.onFrame`), `onBoot` (the
executable loaded, before its first instruction), a bump allocator with `cstring` and `copy`,
guest memory and pad reads, console settings (`setting`/`setSetting`, ADR-0034), the
keyboard's text (`textEntry`/`typed`, ADR-0036) and the mouse (`mouseOver`, `mouseClicks`...,
ADR-0038). Handlers are static functions held as function
values, the pattern `Runtime.bindDispatch` already relies on on both targets. The launcher
installs mods and the kernel calls the frame hook only under `-D recompsx_mods`;
`scripts/build-web.sh <SERIAL> --mods <ids>` builds the browser bundle with them.

Mods get memory of their own past the machine's 2 MB: `mod.ModRam`, at physical 1F000000h —
expansion region 1, the parallel port, where a retail console has nothing — reached by guest
code as 9F000000h like any other pointer. The memory map decodes it in its slow path, after RAM,
the scratchpad and the I/O page, so the only accesses that pay for the test are ones that would
have read nothing; its first 100h bytes stay zero, as the "Licensed by Sony" probe at 1F000084h
expects of an empty port. The heap is there, `memory` bytes of it (64 KB by default). DMA
addresses RAM only, so a manifest may put the heap in guest RAM instead (`heap` {addr, size})
for data a game must DMA.

## Alternatives

- **Wrap the runtime's dispatcher only.** No generator change, but it sees only calls by
  address — most of a game's calls are direct.
- **A check at every function entry.** One table lookup in the hottest code there is, in every
  build, for the few functions a mod names.
- **Patch the guest's instructions and re-run analysis.** Mods would be MIPS, the tool would
  recompile them, and every mod would be a new program to validate; Haxe is the language this
  project already verifies on both targets.
- **Separate "before" and "after" hooks.** An exit hook needs every return path of the emitted
  function, including tail jumps, returns elsewhere (ADR-0027) and cooperative suspension;
  `callOriginal` inside the entry hook gives before-and-after with one emitted line.
- **Virtual `Mod` classes.** Inheritance and interfaces are not verified on reflaxe.CPP (golden
  rule 6); function values are.
- **`nativeReplacements` as tool.md described it (the function registered in FnTable instead of
  generated code).** Replaces only calls by address, and only wholesale; the entry hook covers
  replacement (return true) and every other case.

## Consequences

- A build with mods is a different program by design: its digests are its own, and a mod's
  input handling runs only where there is input (headless runs have no pads).
- Hooks name addresses, so a mod is tied to one pressing — which `exeSha256` in game.json
  already enforces for the whole config. Scoped hooks (`"in": "<overlay>"`) are needed wherever a
  window is shared, and relocatable code (ADR-0025) takes no hooks until it has an address to
  name.
- `callOriginal` runs the function to completion: a hook around a function that waits for a
  vblank would stall a cooperative (browser) build's slice. Hook what returns.
- Mod memory answers where an empty parallel port answered zero, but only in a mods build and
  only its first 100h bytes are kept zero; a game that probes the port deeper than the BIOS's
  own check would see mod data. A heap placed in guest RAM (`heap`) is a claim the tool cannot
  check.
- The first cut put the heap in kernel RAM (8000E000h); memory past 2 MB replaced it the same day,
  on the user's suggestion: nothing a game writes can reach it.
- Verified on both targets: conformance `ModHooks` (hooks that pass, answer and wrap; bypass;
  frame and boot handlers; heap and `ModRam`) digests identically on JS and reflaxe.CPP. Not yet
  built: a whole game in C++ with `-D recompsx_mods`.
