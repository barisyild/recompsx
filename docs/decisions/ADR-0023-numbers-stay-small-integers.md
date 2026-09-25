# ADR-0023: On V8 the machine's integers stay small integers
Status: accepted   Date: 2026-09-25

## Context
The user saw many garbage collections in the page, most with the speed limit off, and more on
phones. The runtime allocates nothing after init by design, so the garbage had to come from the
engine. It did: almost all of it was heap-allocated numbers made from the machine's own
integers. Found with the inspector's allocation tracker (it sees JIT and builtin allocations,
which the sampling profiler does not) — under Node on the page's bundle with a host that does
what `web/index.html` does, and in a headless Brave with a throwaway profile over the DevTools
protocol, whose V8 (15.3) has Chrome's 31-bit small integers.

V8 keeps an integer unboxed only while it is a small integer (Smi): 32 bits in Node, 31 in
Chrome, Edge and Brave (pointer compression). A field or array that once holds anything else —
a double, -0, a uint32 above 2^31, even an integer that arrives boxed — becomes a double field
for good; every later read in unoptimised code, and every trip of its value through a call the
JIT did not inline, allocates. Four things did that here:

- `IntMath.mod` was JavaScript's `%`, which gives -0 for a negative dividend it divides evenly.
  DIV leaves its remainder in HI, so `CpuState.hi` became a double field.
- The SPU's sustain phase added `-by`, which is -0 when a slow exponential fall rounds to
  nothing; `envLevel` became a double array, its values reached the CPU through the voice
  registers, and from the first such read the double spread register to register until 25 of
  `CpuState`'s fields were doubles (`--trace-generalization`, frame ~2600).
- The emitter wrote SRL by zero as `x >>> 0` and SRLV without truncation: the unsigned reading, a
  number above 2^31 for a negative word. Besides boxing, `==` finds it unequal to the same bits
  held signed, so BEQ took the other branch on JavaScript than on C++ (the new `Codegen`
  fixture fails exactly so without the fix: 2147483648 where -2147483648 is expected).
- On 31-bit engines a KSEG0 address (0x80000000 and up) is not a Smi at all, so every guest
  pointer handed to a memory accessor the JIT did not inline was a heap number.

Beside those, strings: `noteOnce` messages were concatenated on every call although printed
once (SPU voice-register writes, key-ons, interrupt-mask writes, overlay checks), and the page's
sound path made two buffers per 128-frame push.

## Decision
On JavaScript, every value the runtime stores stays Smi-shaped wherever the engine can hold it
so, and the emitter hands the bus physical addresses.

- `IntMath.mod` truncates with `| 0` like `div`; runtime code does not store a negated value
  that can be zero (`a - b`, not `a + -b`); the emitter never writes `>>> 0` and truncates
  SRLV (`recomp.codegen.Emitter`, SRL/SRLV).
- Loads and stores pass `address & 0x1FFFFFFF` (`Emitter.busAddr`), which every accessor
  computes first anyway, so nothing changes but the argument's size: below 2^29, never boxed.
- A `noteOnce` whose message is built is guarded by `Runtime.alreadyReported`; the JS shim lends
  the SPU's buffer to the page, which copies into storage it owns and makes one buffer a tick.

## Alternatives
- The register file on an `Int32Array`, fields as accessors (tried on the bundle in Brave):
  generated-code allocations −8 %, but the getters boxed 23 MB of their own — worse. The
  Haxe-level form was already measured 22 % slower on Node (`CpuState`'s note).
- Accessors cut to the RAM path plus one call, so V8 inlines more of them: 16.7 k → 20 k
  objects a frame in Brave — worse; the game keeps pointers in the scratchpad too, and the
  far function boxed them.
- Nothing: Safari's JavaScriptCore never boxes numbers, but V8 is most browsers, and a phone
  pays for every scavenge.

## Consequences
Measured on the attract loop, frames 5000–5300/5600, sound on. Node (32-bit Smi): 33.5 MB of
garbage in 300 frames → 0.85 MB; boxed numbers in generated code 1.95 M → 429. Brave: objects
per emulated frame about 44 k → 21 k; scavenges per 1000 frames 103–113 → 32–39, and their share
of wall time 2.0–2.3 % → 0.8 % with the speed limit off. Digests unchanged everywhere (game
0e180c28 / ab13c60f, `--no-audio` c346c0af / 53e5c7fd, demo 329de455, all conformance tests;
`Codegen` 51a15d34 with the new shift-by-zero fixture). The C++ build is unaffected in meaning;
the extra mask folds into the accessor's own.

What remains on 31-bit engines, about 16–21 k objects a frame: guest words outside ±2^30 that
cross an accessor call V8 did not inline — `read32`'s return value and `write32`'s value
argument — and the double register fields they come from. Removing that means the emitter
writing the RAM path inline at each access, a bundle-size trade (class-wide accessor inlining
measured +34 % earlier); it is a separate decision. `scripts/check.sh` does not yet flag `>>> 0`
or a negated stored value; the `Codegen` fixture and `--trace-generalization` are how to check.
