# ADR-0006: Overlays are disc extents with fixed windows, resolved by fingerprint
Status: accepted   Date: 2026-08-09

## Context

Most commercial PlayStation games are larger than the two megabytes of RAM they run in, and they
close the gap by loading code from the disc into fixed regions as they go. The recompiler compiled
only the boot executable, so the first time Crash Bash called into code it had loaded from
`CRASHBSH.DAT`, dispatch had nothing to run and the call silently did nothing.

An earlier ad-hoc attempt (reverted in `b1dbec5`) proved the mechanics but got identity wrong: it
patched a single captured RAM image over the executable at build time. A game loads *several*
overlays into the *same* memory over its life, so one capture describes one moment and is data for
every other. Addresses that were code when it was taken are artwork later, and the reverse.

This decision covers what an overlay *is*, how a build knows about one, how the runtime decides
which is present, and what all of that costs on the targets that matter.

## Decision

**An overlay is a disc extent placed at a fixed address.** PlayStation overlays are linked at
their final virtual address — nothing relocates them at load time — so the pair *(these bytes,
this window)* identifies one completely. A stanza in `games/<id>/game.json` says where the bytes
are on the disc, where they go, and which addresses to seed. Nothing about a running machine is
needed to write one, and nothing captured from one is committed.

**Each overlay is analysed as its own universe**: the executable with that overlay's bytes laid
over its window. Overlay passes are scoped to the window, so the base is analysed once, and
*lenient* inside it: code and artwork are adjacent there with no linker map, so a seed is validated
before it is believed and a function that traces into impossible code is dropped with a reason.
Inside the executable the same discovery remains a hard error, because there it means the analysis
is wrong.

**Calls are direct wherever residency is not in question**, which is three cases:

| From | To | Emitted as |
|---|---|---|
| anywhere | the executable, outside every window | direct call |
| the executable, or another overlay | inside a window | dispatch by address |
| an overlay | its own window | direct call |

The third line is the one worth stating: an overlay calling itself is safe because the caller
running at all proves the callee is resident — they arrived together. So indirection is paid only
where the hardware paid it, and overlay code is no slower than base code.

**Residency is decided at run time by three signals.** A load into a window over the bytes an
overlay is *recognised by* evicts it. `FlushCache` rescans every window and identifies what is in
it by FNV-1a over its first words, compared against a fingerprint the tool computed — and because
a real machine cannot see newly written code until the cache is flushed, every game that loads
code passes through there, whatever its loader did. A dispatch that misses inside a window rescans
once before reporting. The tool refuses to emit two overlays whose fingerprints collide.

**Overlays nest rather than exclude.** Several resident windows may cover one address; the
smallest wins. A game loads a large region and then swaps a smaller piece of it, and the large one
is still correct everywhere the small one is not. Crash Bash does exactly this: a 32 KB `stage`
overlay lands in the middle of the 378 KB `boot` window, and both are genuinely present.

**Residency is attested by the fingerprint region only, and eviction watches only that region.**
"Resident" is a statement about the first `hashWords` words of a window; nothing checks the rest,
*because* overlays nest — whole-window eviction would unseat the large overlay every time the
small one loads. The accepted cost: a load into the tail of a resident window leaves rows there
that dispatch code whose bytes are gone. In practice the swapped piece is itself an overlay with
its own stanza, whose (smaller, resident) window shadows exactly those rows. A game that streams
plain data over live code with no stanza would be mis-dispatched there — none has been met, and
the miss diagnostics name the window if one ever is.

**While a resident overlay covers an address, only its table may answer.** No fallthrough to the
executable's table: the executable's bytes at a shadowed address are gone, so a "helpful" base
answer would run code the game overwrote. An address the resident overlay has no row for is a
miss that says which entry hint to add. When *nothing* is resident, the executable's table serves
its own in-window functions — before any load, its bytes are what is there.

**Everything is statically linked, on every target.** All overlay code compiles into the one
binary and only tables decide what runs.

## Alternatives

- **Haxe macros generating the dispatch layer.** Rejected. Everything a `@:build` macro could
  synthesize, `tools/recomp` emits directly with strictly more knowledge — it sees the whole game,
  the config and the disc, where a macro sees only Haxe source. Direct emission keeps generated
  output deterministic and diffable (golden rule 5), and a macro layer would stack our
  metaprogramming on top of reflaxe.CPP, itself a macro pipeline with eight defects found in one
  month. The flexibility macros usually buy — closures, reflection, `Dynamic` — is banned anyway.
- **Identity from a captured RAM image.** What the reverted attempt did. One capture cannot
  describe memory that is reused.
- **Committing captures under `games/<id>/dumps/`,** as master plan §6.4 proposed. Rejected and
  hereby corrected: overlay bytes are game code, and golden rule 4 keeps that out of the
  repository. The `memdump` source kind remains, for compressed overlays whose stored bytes are
  not the bytes that run, but the file is gitignored and local.
- **Interpreting overlay code, or compiling it at run time.** Both give up the property the whole
  project rests on — that a game becomes ordinary compiled code.
- **A flat address table covering base and overlays together.** Cannot express two programs at one
  address, which is the entire problem.
- **Matching loads by disc key (LBA) to decide identity.** Implemented only as *provenance* for
  diagnostics, not as identity. The fingerprint answers the question completely on its own, and a
  second, weaker answer would be a second thing to be wrong.

## Consequences

- A game's config is written by running it: a dispatch miss reports the span the disc was read
  into, the sector it came from, and the numbers to paste. Crash Bash's two overlays were found
  that way, in two rounds.
- Overlay code costs nothing extra to call from itself or from the base's perspective, but a
  window's addresses cannot be resolved at build time, so cross-overlay calls stay dispatches.
- Build time grows with the number of overlays, though only by what each window contains: the
  base is analysed once.
- Shard indices are program-wide and a handle carries eleven bits of them, so a program is capped
  at 2047 shards. The tool errors rather than truncating.
- A window whose contents no overlay matches resolves to nothing, and the miss says so with the
  window named. That is the honest failure and the input to the next config round.
- **Console escape hatch, unbuilt but preserved.** Dispatch never takes a function's address, only
  a `(shard, slot)` integer, so a platform that cannot hold every overlay's compiled code at once
  can load shard groups natively behind the same interface. Nothing depends on that today; the
  point is that nothing forecloses it.
- Cross-universe duplicate bodies are emitted once and forwarded to, which matters where every
  overlay is linked into one binary.
