# Spec — Recompiler tool (`tools/recomp`)

Normative specification for the build-time tool. Source: master plan §6 + Appendix A.
Changes to behavior described here must be reflected in this file and, if architectural, in an
ADR under `docs/decisions/`.

The tool runs on unconstrained Haxe (`--interp` default; optional JVM jar for speed — same
source, golden tests run on both). Only its *output* and the shared `shared/psxdisc/` package
obey the portable subset. **Global invariant: the tool is fully deterministic** — identical
inputs (image + config + tool version) produce byte-identical output; all iteration is
address-ordered; CI asserts regen-idempotence (run `gen` twice, byte-compare trees).

## Package layout

```
tools/recomp/src/recomp/
  Main.hx  cli/Cli.hx
  loader/   PsxExe.hx  CueSheet.hx  DiscImage.hx  Iso9660.hx
  mips/     Op.hx  Instr.hx  Decoder.hx  Disasm.hx
  analysis/ Discovery.hx  Cfg.hx  JumpTables.hx  Symbols.hx  Model.hx  Coverage.hx
  codegen/  Emitter.hx  Shards.hx  FnTableGen.hx
  config/   GameConfig.hx
  synth/    Synth.hx            (M1.5 scale spike)
shared/psxdisc/                 (portable subset; shared with runtime CD subsystem)
  SectorSource.hx  DiscModel.hx  IsoFs.hx  Msf.hx
```

## 1. Input loaders

**PS-EXE** (`loader/PsxExe.hx`) — 2048-byte header, LE u32 fields (per psx-spx CDROM File
Formats): 0x000 magic `"PS-X EXE"` (hard error if absent); 0x010 `initialPc`; 0x014
`initialGp`; 0x018 `loadAddr`; 0x01C `fileSize` (payload bytes; warn if not N*0x800 — homebrew
violates); 0x028/0x02C `memfillAddr/Size` (BSS zerofill); 0x030/0x034 `spBase/spOffset`
(usually 0x801FFFF0; 0 = keep caller stack); 0x04C region marker ASCII; payload at 0x800 →
`loadAddr`. Validation: `fileSize <= len-0x800` else hard error (truncated dump). Address
folding helper used everywhere: `Vaddr.phys(a) = a & 0x1FFFFFFF`; RAM = phys < 0x200000, masked
`& 0x1FFFFF`. Scratchpad is never executable — discovery ignores it. Homebrew path: `game.json`
may specify a bare `exeFile` (via local.json) instead of a disc — the PSn00bSDK fixture path.

**CUE/BIN** (`loader/CueSheet.hx`, `DiscImage.hx`) — CUE subset: `FILE ... BINARY`,
`TRACK nn <MODE1/2352|MODE2/2352|MODE1/2048|MODE2/2336|AUDIO>`, `INDEX`, `PREGAP/POSTGAP`;
`REM/FLAGS/...` skipped; multi-FILE sheets supported (logical LBA accumulates across files).
LBA convention: **logical LBA** (ISO9660 PVD at LBA 16; disc MSF 00:02:00 = LBA 0). Sector
layouts: Mode1/2352 (user 2048 @ +16), Mode2 Form1 (2048 @ +24), Mode2 Form2 (2324 @ +24;
decided per sector from subheader submode bit 5), AUDIO (2352 PCM). **EDC/ECC ignored by
default** (redump-clean assumption); `--check-edc` verifies and warns, never errors.

**Shared disc model** (`shared/psxdisc/` — portable subset; the runtime's CD subsystem reuses it):

```haxe
interface SectorSource {   // tool impl = sys.io; runtime impl = backend bp_file_*
  function readRaw2352(lba:Int, out:ByteBuf, outPos:Int):Bool;
  function totalSectors():Int;
}
enum TrackMode { Audio; Mode1Raw; Mode2Raw; Mode1Cooked2048; Mode2Cooked2336; }
class Track { num; mode; startLba; lengthSectors; fileIndex; fileByteOffset; }
class DiscModel { tracks:Array<Track>; totalSectors; function trackForLba(lba:Int):Int; }
class DiscReader {  // cooked view: locates user-data offset per track mode/subheader
  function readUser2048(lba, out, outPos):Bool;   // error on Form2 sector
  function readForm2_2324(lba, out, outPos):Bool;
  function subheader(lba:Int):Int;  // packed file/channel/submode/codinginfo; -1 if none
}
```

`ByteBuf` = thin abstract: `haxe.io.Bytes` on tool targets, `RawMem` on runtime targets
(single `#if` seam) — keeps `haxe.io.Bytes` out of the runtime.

**ISO9660** (`shared/psxdisc/IsoFs.hx`) — PVD @ LBA 16 (`"CD001"`); directory extents walked
recursively (path table ignored, no Joliet); `;1` version suffix stripped on match.
`IsoEntry {path, lba, size, isDir}`; `mount/list/find/readFile`. Boot flow: parse `SYSTEM.CNF`
(`BOOT = cdrom:\PATH;1`), fall back to `PSX.EXE`; config `exePath` overrides.

`SYSTEM.CNF` is parsed for more than the boot path: `TCB = n` and `EVENT = n` size the kernel's
thread and event tables, and `STACK = <hex>` overrides the initial SP. The runtime's kernel HLE
consumes these (see `docs/specs/runtime.md` §1), so the loader must surface them, defaulting to
TCB 4 / EVENT 16 when the file is absent.

### 1.1 Input modes

A dump reaches the tool in one of four shapes, selected by which key `local.json` provides:

| `local.json` key | Shape | analyze / gen | Runtime CD emulation |
|---|---|---|---|
| `cue` | BIN/CUE (single or multi-track) | full | full — the preferred form |
| `iso` | single-track raw image | full | full (no CDDA tracks) |
| `filesDir` | a directory of files extracted from the disc, with `SYSTEM.CNF` at its root | full | via a synthesized image (see below) |
| `exeFile` | a bare PS-EXE, no disc | full (no overlays from disc) | none needed — the homebrew/fixture path |

**`filesDir`** is a first-class input because extracted-file dumps are common and are what most
existing RE workflows produce. The tool builds an in-memory `DiscModel` over the directory:
`IsoFs` is served from the real filesystem, and LBAs are assigned deterministically (directory
order, Mode2/Form1, 2048-byte user data) so `analyze`, `gen` and overlay extraction all work
unchanged.

The caveat is LBA fidelity: a game that stores raw sector numbers captured from the original
pressing will not find its data at our synthesized LBAs. Games that resolve everything through
the ISO9660 directory (kernel file API, `CdSearchFile`) are unaffected. Therefore:

- `analyze` / `gen` accept `filesDir` unconditionally — recompilation never depends on LBAs.
- For running, `recompsx mkiso` writes a real Mode2/2352 BIN+CUE from a `filesDir`, and the
  resulting image is what the runtime mounts. If a game turns out to depend on original LBAs,
  the fix is to run against a real dump (or an image rebuilt with the original layout), and the
  symptom will be visible as CD read failures in the trace — not as silent corruption.

## 2. Analysis passes

Analysis operates per **universe**: base EXE mapped into a 2MB RAM image, or (per overlay) base
+ overlay bytes patched at its `loadAddr`. Jump-table data reads come from the owning universe's
view. Output = `analysis.json` + coverage report under `out/<game>/analysis/`.

**Function discovery** — worklist, seeds in priority order: (1) `initialPc`, overlay
`entryHints[]`, `functionHints[].isFunction`, imported function symbols; (2) closure over `jal`
targets + `j` tail-call targets discovered during CFG build; (3) gap sweep: unclassified
word-aligned text regions scanned for prologue heuristics (`addiu sp,sp,-N` in first 2 instrs,
or `sw ra,N(sp)` in first 6, preceded by padding) → low-confidence seeds (flagged; still
recompiled — jalr may reach them). Function extent = `[entry, max reachable block end]`; ends at
`jr ra`+slot, unconditional jump with no internal successor, or call to config-marked
`noReturn`. **Overlap/multi-entry policy**: entries inside another function's extent → both
kept, shared blocks duplicated into each (always correct; avoids fragile function splitting —
same policy as N64Recomp). Entries must be 4-aligned (hard error otherwise); zero-word/nop
padding classified `padding`.

**CFG** — leader algorithm; delay slots belong to their branch's block. Edge kinds: Fall,
BrTaken, BrNotTaken, Switch(caseIdx), Return, CallCont. Edge cases: branch/jump **in** a delay
slot → hard error with both pcs + 8-instr context (never compiler-emitted; signals misclassified
data). Delay slot that is itself a branch target: legal — slot becomes a block leader for the
incoming edge AND is still duplicated into its branch's paths (no codegen special case).
Conditional branch out of extent → conditional tail call.

**Jump-table recognition** — dataflow matcher for the Psy-Q/GCC idiom
(`sltiu $v0,$idx,N; beqz →default; sll $v0,$idx,2; lui/addu/lw table; jr $v0` + gp-relative
variant): backward-slice from `jr rX` to the defining `lw`; constant-resolve the base via
lui/addiu/addu folding (gp-relative folds with `initialGp`); bound N from the dominating
`sltiu`; read N words from the universe view; validate every entry (4-aligned, inside classified
text) else reject. On success: mark `[base, base+4N)` as data-in-text, attach Switch edges.
`jumpTableHints[]` force `{jrAddr, tableBase, count}` when hand-written asm defeats the matcher.

**Call analysis** — `jal T`: static if T in same universe (or overlay→base), **dynamic
(`Runtime.call`) if T inside any configured overlay VA window**, kernel vectors (0xA0/B0/C0, low
RAM < 0x10000), or unclassified. `jalr`: recorded in the indirect-call inventory (drives coverage
report). `j` to another function's entry = tail call.

**Symbol import** — `syms.txt` (committed; `0xADDR name [func|obj]`), GNU ld `.map` subset,
SN/Psy-Q `.MAP` subset. Symbols feed naming + seeds only, never semantics.

**Coverage report** — per universe: classified byte % (code/data/padding/unknown), function
count by confidence tier, unresolved-jalr list (function + site pc), unresolved-jr list, gap list
with first-words dump, suspicious patterns (INVALID density >5% in a claimed function; prologue
with no callers; overlaps). Warnings don't fail `analyze`; hard errors do.

**Serialized model** — `analysis.json` (schemaVersion, toolVersion, per-universe functions with
blocks/succ/jumpTables/calls, dataRegions, stats). `gen` reuses it when input hashes match, else
re-analyzes in-process.

## 3. Codegen — structure

(Complete instruction→Haxe emission tables and the worked example: **Appendix A** below.)

- **CpuState**: 31 named Int fields (`at..ra` by ABI name — `$zero` has NO field: reads emit
  literal 0, writes dropped, loads to r0 still perform the read for I/O side effects),
  `hi, lo, pc` (virtual: written only before `Runtime.call`/`Kernel.*`/traps), `cycles`,
  `nextEvent` (wrap-safe subtraction compares).
- **Sanctioned runtime API surface** (generated code touches nothing else):
  `Memory.read8s/8u/16s/16u/32`, `Memory.write8/16/32`, `Memory.lwl/lwr` (return merged value) /
  `Memory.swl/swr` (RMW); `Runtime.call/pump/mfc0/mtc0/rfe`; `Kernel.syscall/brk`;
  `Ops.mult/multu/div/divu` (hi:lo writers — single tested impl of MIPS edge cases:
  `div rs,0 → hi=rs, lo=(rs>=0?-1:1)`; `div 0x80000000,-1 → hi=0, lo=0x80000000` (C++ UB —
  special-cased); `divu rs,0 → hi=rs, lo=0xFFFFFFFF`);
  `Gte.execute/getData/setData/getCtrl/setCtrl`.
- **Body template**: single-linear-chain CFGs emit a flat body (common leaf case — readability
  + compile-time win); everything else emits `while(true) switch(bb)` with dense block indices
  in address order, original VA as comment per case.
- **Cycles & pump**: flat 1 cycle/instruction, `ctx.cycles += N` immediately before every
  control transfer; `if (ctx.cycles - ctx.nextEvent >= 0) Runtime.pump(ctx);` at exactly
  (a) function entry, (b) after the increment on every back-edge (target VA ≤ source block
  start, incl. switch edges). Straight-line code carries no pump. The pump contract guarantees
  forward progress (idle `b .` loops become pump-driven time advancement).
- **Sharding**: functions sorted by (universe, entry VA), greedily packed ≤150 funcs and ≤10k
  lines per file; stable split points; overlay boundaries force separate shard sets under
  `out/<game>/hx/ovl_<id>/`. Names: class `Fns_<seq>_<startVA>`, function `f_<VA8hex>` always
  (symbols only in comments — stable diffs).
- **FnTable** (generated): stores **packed Int handles**, never function values. Each shard emits
  `static function dispatch(localIdx:Int, ctx:CpuState):Void` — a `switch` over its own
  functions — and the address→handle table holds `(shardId << 20) | localIdx` in raw memory. A
  top-level generated `switch` routes a handle to the owning shard's `dispatch`.

  This is not a stylistic choice. Verified 2026-08-08 (PROGRESS.md [M0-VERIFY] #18): reflaxe.CPP
  lowers `Array<(CpuState)->Void>` to `std::deque<std::shared_ptr<std::function<void(CpuState)>>>`
  — a heap allocation and a type-erased indirect call per entry — and the array literal does not
  even compile. Storing function values is therefore impossible as well as undesirable.

  Handle-table layout: v1 flat table over 2MB at 4-byte granularity (512K entries × 4 bytes =
  2 MB of `Int`s, in a `CArray` like everything else); the console default (`-D fntable=binary`)
  is a sorted VA array + binary search behind the same API, costing ~8 bytes per discovered
  function. Registration is loop-friendly per-shard code, never one giant literal.

  Reachability is safe without `@:keep` (which upstream does not honor): functions referenced
  only from a shard's `dispatch` switch survive `-dce full` — verified in the same spike.
- Also generated: `GameInfo.hx` (initial pc/gp/sp, load ranges, memfill, exe payload reference),
  `Overlays.hx` (per overlay: id, VA range, source sectors/file extent, FNV-1a content hash,
  entries) — consumed by runtime CD-tracking activation + hash-fallback.
- **Overlay call policy**: static direct calls only within same universe or overlay→base;
  anything targeting a configured overlay window goes through `Runtime.call` (activation state
  decides which module answers).
- **Deliberate non-fidelity** (documented): add/addi/sub never trap on overflow; load delay off
  by default (per-function `loadDelayAccurate` opt-in: emitter pre-captures old rt into a temp
  for the single successor instruction); hi/lo latency invisible; i-cache invisible (stale-cache
  self-patching games out of scope v1); misaligned access raises no AdEL/AdES.

## 4. Per-game config schema

`games/<game>/game.json` (committed, schemaVersion 1): `id`, `title`, `region`, `exePath`
(in-image), `exeSha256` (filled by `--accept-hashes`; mismatch = hard error naming expected
redump), `overlays[] {id, name, source {kind: file|sectors|memdump, ...}, loadAddr, length,
entryHints[]}`, `functionHints[] {addr, name, isFunction, noReturn, loadDelayAccurate}`,
`jumpTableHints[] {jrAddr, tableBase, count}`, `nativeReplacements[] {addr, haxeFn}` (escape
hatch + modding hook — registered in FnTable instead of generated code; original still analyzed
for coverage), `setjmpFns[]/longjmpFns[]` (→ `Runtime.setjmp/longjmp` per the unwind design),
`symsFile`, `mapFile`. Addresses are decimal u32 in JSON (no hex in JSON); the tool prints hex
everywhere. `memdump` source covers compressed overlays: the user captures the post-decompression
RAM region once (external emulator dump), commits it under `games/<game>/dumps/`; runtime
activation uses hash-fallback only for these.

`games/<game>/local.json` (gitignored, machine-local) supplies exactly one of `cue`, `iso`,
`filesDir` or `exeFile` as an absolute path — see §1.1. A committed `local.json.example`
documents the shape for each game.

## 5. CLI

```
recompsx <extract|analyze|gen|dis|mkiso|synth> games/<game>/game.json [flags]
  extract: mount image, verify hashes, unpack exe + overlays to out/<game>/analysis/extracted/
  analyze: analysis passes → analysis.json + coverage report
  gen:     analyze (or reuse fresh analysis.json) + emit out/<game>/hx/**
  dis:     --at 0x80010000 --count 64 [--ovl <id>]
  mkiso:   build a Mode2/2352 BIN+CUE from a filesDir input (§1.1)
  synth:   M1.5 scale generator
flags: --out <dir> · --dump-cfg <addr|all> (Graphviz) · --check-edc · --accept-hashes · -v/-vv/-q
exit codes: 0 ok · 1 crash · 2 usage · 3 loader error · 4 analysis hard error · 5 codegen error
            · 6 hash mismatch
```

## 6. Tool testing

Zero-dependency test runner (plain asserts, exit code).

1. **Golden disasm fixtures** (`ADDR RAWWORD | expected text`; every opcode ≥2×, edge
   immediates, GTE field combos).
2. **Analysis unit tests** on hand-encoded synthetic functions via in-test word-builder helpers:
   jump tables (both variants + one that must stay unresolved), tail calls, multi-entry overlap,
   delay-slot-as-branch-target, branch-in-delay-slot (asserts hard error), gap-sweep heuristic,
   bltzal linking, syms/map parsing.
3. **Codegen snapshot tests** (input asm → expected .hx; `-D bless` rewrites expected/, reviewed
   via git diff; the Appendix A worked example is a fixture — spec and fixture must never drift).
4. **Loader tests**: in-memory synthetic ISO9660 + Mode2 Form1/Form2 mix + 2-track CUE with
   audio; truncated PS-EXE; non-0x800-multiple homebrew.
5. **End-to-end**: committed self-built PSn00bSDK `hello.exe` fixture (+README recording SDK
   commit + build command) → analyze finds main + ≥20 functions, 0 hard errors; gen output
   **typechecks** via `haxe --no-output` against the real runtime classpath (full reflaxe.CPP
   compile belongs to M1.5, not the per-commit loop).
6. **Regen-idempotence** byte-compare.

## 7. Scale spike (M1.5 gate)

`recompsx synth --funcs 20000 --avg-instrs 100 --seed 1` generates *real encoded MIPS* (valid
arith, branches, cross-calls, ~10% with 8-way jump tables) into a fake EXE → standard analyze+gen
(no shortcuts) → ~2M instructions across ~140 shards → reflaxe.CPP → clang -O2. Record in
PROGRESS.md: gen time, Haxe time, clang time, peak RSS, binary size. Thresholds (fail = act
before M2): Haxe→C++ ≤5 min; clang ≤15 min; RSS ≤8 GB. Mitigation ladder: shards→50 funcs;
confirm one TU per class for `-j` parallelism; ccache; `-O1` dev profile.

## 8. Failure-mode policy

| Condition | Phase | Behavior |
|---|---|---|
| INVALID instruction reachable as code | analyze | Hard error: pc, raw word, universe, function, ±8-instr disasm, hint ("if data → jumpTableHint; if bad seed → remove functionHint") |
| Branch/jump in delay slot | analyze | Hard error, both pcs + context |
| Unresolved jalr | — | Fine by design — coverage report + runtime FnTable dispatch |
| Unresolved jr (no table) | analyze/run | Warning; dynamic dispatch; runtime miss traps with target VA + caller pc + active overlays — exactly the data needed to write a hint |
| Call into unanalyzed region | run | Runtime trap, same diagnostic bundle (ctx.pc current at every dynamic boundary) |
| Image/exe hash mismatch | extract | Hard error naming expected redump hash |
| Overlay content hash mismatch at runtime | run | Hash-identification across all known overlays; unknown → trap listing nearest candidates |
| SMC beyond overlays | — | Out of scope v1; escapes = nativeReplacements + memdump overlays; debug builds may checksum code ranges on pump and log first divergence pc |
| Function falls off extent | analyze | Warning + trailing `Runtime.trap(...)` emitted — silent fallthrough impossible |

---

# Appendix A — MIPS→Haxe emission spec (normative)

## A.1 Decode tables (`mips/Decoder.hx`)

`Op` enum (closed; one constructor per operation): SLL SRL SRA SLLV SRLV SRAV · JR JALR SYSCALL
BREAK · MFHI MTHI MFLO MTLO MULT MULTU DIV DIVU · ADD ADDU SUB SUBU AND OR XOR NOR SLT SLTU ·
BLTZ BGEZ BLTZAL BGEZAL J JAL BEQ BNE BLEZ BGTZ · ADDI ADDIU SLTI SLTIU ANDI ORI XORI LUI ·
LB LH LWL LW LBU LHU LWR SB SH SWL SW SWR · MFC0 MTC0 RFE · MFC2 CFC2 MTC2 CTC2 LWC2 SWC2
COP2CMD · INVALID.

`Instr` record: `addr, raw, op, rs, rt, rd, shamt, immS` (sign-extended), `immU`
(zero-extended), `target` (absolute VA for j/jal/branches), `code` (20-bit syscall/break field
or 25-bit COP2 imm).

- Primary (31..26): `00 SPECIAL, 01 REGIMM, 02 J, 03 JAL, 04 BEQ, 05 BNE, 06 BLEZ, 07 BGTZ,
  08 ADDI, 09 ADDIU, 0A SLTI, 0B SLTIU, 0C ANDI, 0D ORI, 0E XORI, 0F LUI, 10 COP0, 12 COP2,
  20 LB, 21 LH, 22 LWL, 23 LW, 24 LBU, 25 LHU, 26 LWR, 28 SB, 29 SH, 2A SWL, 2B SW, 2E SWR,
  32 LWC2, 3A SWC2`; all else INVALID (incl. COP1/COP3).
- SPECIAL funct: `00 SLL, 02 SRL, 03 SRA, 04 SLLV, 06 SRLV, 07 SRAV, 08 JR, 09 JALR, 0C SYSCALL,
  0D BREAK, 10 MFHI, 11 MTHI, 12 MFLO, 13 MTLO, 18 MULT, 19 MULTU, 1A DIV, 1B DIVU, 20 ADD,
  21 ADDU, 22 SUB, 23 SUBU, 24 AND, 25 OR, 26 XOR, 27 NOR, 2A SLT, 2B SLTU`.
- REGIMM rt: `00 BLTZ, 01 BGEZ, 10 BLTZAL, 11 BGEZAL`; non-canonical rt → INVALID (hardware
  aliases exist; no compiler emits them — treat as misclassified-data signal).
- COP0 rs: `00 MFC0, 04 MTC0`; rs bit4 + funct `10` = RFE; TLB ops + BC0x → INVALID (no TLB).
- COP2 rs (bit25 clear): `00 MFC2, 02 CFC2, 04 MTC2, 06 CTC2`; BC2x → INVALID (GTE condition
  line unwired). Bit25 set → COP2CMD, `code` = imm25 (bit19 sf, 18..17 MVMVA matrix, 16..15
  vector, 14..13 translation, bit10 lm, 5..0 real command — passed through whole; the runtime
  GTE decodes the fields).
- `j/jal target = (addr & 0xF0000000) | (imm26 << 2)`; branch `target = addr + 4 + (immS << 2)`.

Formatter: GNU-style, ABI reg names, hex immediates, symbol substitution on targets; `nop` for
`sll zero,zero,0`; all analyzer diagnostics embed ±8 instructions of context.

## A.2 Emission cheat sheet

Metavariables: `RS/RT/RD` = `ctx.<abiName>` (r0 reads = literal 0; pure writes to r0 emit
nothing; loads to r0 still perform the read — I/O side effects — result dropped); `S16/U16/SA`
folded literals; `A` = `RS + S16`; `RET` = site VA + 8. Haxe Int is 32-bit signed; `>>>`
logical; variable shifts masked `& 31`. `[M0-VERIFY]` wrapping semantics of reflaxe.CPP int
arithmetic — if it emits plain C++ `int`, force `-fwrapv` in CMake and record it in ADR-0001.

| Group | Instr | Emitted Haxe |
|---|---|---|
| ALU-imm | addi/addiu | `RT = RS + S16;` (non-trapping by policy) |
| | slti | `RT = RS < S16 ? 1 : 0;` |
| | sltiu | `RT = (RS ^ 0x80000000) < K ? 1 : 0;` — `K = S16 ^ 0x80000000` folded (imm sign-extends then compares unsigned) |
| | andi/ori/xori | `RT = RS & U16;` / `\|` / `^` |
| | lui | `RT = <IMM16<<16 folded literal>;` |
| ALU-reg | add/addu | `RD = RS + RT;` |
| | sub/subu | `RD = RS - RT;` |
| | and/or/xor | `RD = RS & RT;` etc. |
| | nor | `RD = ~(RS \| RT);` |
| | slt | `RD = RS < RT ? 1 : 0;` |
| | sltu | `RD = (RS ^ 0x80000000) < (RT ^ 0x80000000) ? 1 : 0;` (sign-bit XOR idiom — inlines; clang recognizes it as an unsigned compare) |
| Shift | sll | `RD = RT << SA;` (`sll zero,zero,0` → nothing) |
| | srl/sra | `RD = RT >>> SA;` / `RD = RT >> SA;` |
| | sllv/srlv/srav | `RD = RT << (RS & 31);` / `>>>` / `>>` |
| Mul/Div | mult/multu | `Ops.mult(ctx, RS, RT);` / `Ops.multu(...)` — hi:lo via I64; 16×16 decomposition fallback if Int64 proves shaky |
| | div/divu | `Ops.div(ctx, RS, RT);` — edge table in §3 |
| | mfhi/mflo | `RD = ctx.hi;` / `RD = ctx.lo;` |
| | mthi/mtlo | `ctx.hi = RS;` / `ctx.lo = RS;` |
| Load | lb/lbu/lh/lhu/lw | `RT = Memory.read8s(A);` etc. |
| | lwl/lwr | `RT = Memory.lwl(A, RT);` / `RT = Memory.lwr(A, RT);` |
| Store | sb/sh/sw | `Memory.write8(A, RT);` etc. |
| | swl/swr | `Memory.swl(A, RT);` / `Memory.swr(A, RT);` |
| Branch | beq/bne | cond `RS == RT` / `RS != RT` — always latched into `var cN` BEFORE the delay slot |
| | blez/bgtz/bltz/bgez | `RS <= 0` / `RS > 0` / `RS < 0` / `RS >= 0` |
| | bltzal/bgezal | cond computed from RS **before** link; then `ctx.ra = RET;` **unconditionally** (hardware links even when not taken; `rs == ra` compares the pre-link value — both properties fall out of this ordering) |
| Jump | j (intra-fn) | `<slot>; ctx.cycles += n; bb = <idx>; continue;` |
| | j (tail call) | `<slot>; ctx.cycles += n; <call as jal>; return;` |
| | jal (static) | `ctx.ra = RET; <slot>; Fns_XX.f_<target>(ctx);` (ra always written — cheap, preserves fidelity) |
| | jal (dynamic) | `ctx.ra = RET; <slot>; ctx.pc = T; Runtime.call(ctx, T);` |
| | jalr rd,rs | `var tK = RS; ctx.<rd> = RET; <slot>; ctx.pc = tK; Runtime.call(ctx, tK);` (target latched before link — handles `jalr ra, ra`) |
| | jr ra | `<slot>; return;` (computed-ra tricks out of scope v1; escape = nativeReplacements) |
| | jr rX (table) | `var tK = RX; <slot>; ctx.cycles += n; switch (tK) { case 0x...: bb = i; continue; ... default: ctx.pc = tK; Runtime.call(ctx, tK); return; }` |
| | jr rX (unrecovered) | `var tK = RX; <slot>; ctx.pc = tK; Runtime.call(ctx, tK); return;` |
| System | syscall/break | `ctx.pc = ADDR; Kernel.syscall(ctx, CODE20);` then continue in-line (no delay slot; Psy-Q div-zero break guards return) |
| COP0 | mfc0/mtc0 | `RT = Runtime.mfc0(ctx, N);` / `Runtime.mtc0(ctx, N, RT);` |
| | rfe | `Runtime.rfe(ctx);` |
| COP2 | mfc2/mtc2 | `RT = Gte.getData(ctx, N);` / `Gte.setData(ctx, N, RT);` |
| | cfc2/ctc2 | `RT = Gte.getCtrl(ctx, N);` / `Gte.setCtrl(ctx, N, RT);` |
| | lwc2/swc2 | `Gte.setData(ctx, N, Memory.read32(A));` / `Memory.write32(A, Gte.getData(ctx, N));` |
| | cop2 imm25 | `Gte.execute(ctx, IMM25);` |

## A.3 lwl/lwr/swl/swr exact merges

Little-endian PSX; `w` = aligned word at `a & ~3`, `cur` = current rt value, `v` = store value.

| a&3 | lwl result | lwr result | swl writes | swr writes |
|---|---|---|---|---|
| 0 | `(cur & 0x00FFFFFF) \| (w << 24)` | `w` | `(w & 0xFFFFFF00) \| (v >>> 24)` | `v` |
| 1 | `(cur & 0x0000FFFF) \| (w << 16)` | `(cur & 0xFF000000) \| (w >>> 8)` | `(w & 0xFFFF0000) \| (v >>> 16)` | `(w & 0x000000FF) \| (v << 8)` |
| 2 | `(cur & 0x000000FF) \| (w << 8)` | `(cur & 0xFFFF0000) \| (w >>> 16)` | `(w & 0xFF000000) \| (v >>> 8)` | `(w & 0x0000FFFF) \| (v << 16)` |
| 3 | `w` | `(cur & 0xFFFFFF00) \| (w >>> 24)` | `v` | `(w & 0x00FFFFFF) \| (v << 24)` |

## A.4 Worked example (this exact pair is a codegen snapshot fixture)

Input (idiomatic Psy-Q shape — prologue, loop back-edge, call, epilogue in the `jr` delay slot):

```
80010000: 27bdffe8  addiu sp, sp, -0x18        ; B0
80010004: afbf0014  sw    ra, 0x14(sp)
80010008: 00001021  addu  v0, zero, zero
8001000c: 00004021  addu  t0, zero, zero
80010010: 0104082a  slt   at, t0, a0           ; B1 (loop head)
80010014: 14200007  bne   at, zero, 0x80010034
80010018: 00000000   nop                       ;   delay slot
8001001c: 00402021  addu  a0, v0, zero         ; B2 (exit path)
80010020: 0c004010  jal   0x80010040
80010024: 00000000   nop                       ;   delay slot
80010028: 8fbf0014  lw    ra, 0x14(sp)
8001002c: 03e00008  jr    ra
80010030: 27bd0018   addiu sp, sp, 0x18        ;   delay slot (epilogue)
80010034: 00481021  addu  v0, v0, t0           ; B3 (loop body)
80010038: 1000fff5  beq   zero, zero, 0x80010010
8001003c: 25080001   addiu t0, t0, 1           ;   delay slot
```

Exact generated output:

```haxe
/** f_80010000 (sym: sum_n) — base, 0x80010000..0x8001003f */
public static function f_80010000(ctx:CpuState):Void {
  if (ctx.cycles - ctx.nextEvent >= 0) Runtime.pump(ctx);
  var bb = 0;
  while (true) switch (bb) {
    case 0: // 0x80010000
      ctx.sp = ctx.sp + -24;
      Memory.write32(ctx.sp + 20, ctx.ra);
      ctx.v0 = 0;
      ctx.t0 = 0;
      ctx.cycles += 4;
      bb = 1; continue;
    case 1: // 0x80010010
      ctx.at = ctx.t0 < ctx.a0 ? 1 : 0;
      var c0 = ctx.at != 0;      // condition latched BEFORE delay slot
      // delay: nop
      ctx.cycles += 3;
      bb = c0 ? 3 : 2; continue;
    case 2: // 0x8001001c
      ctx.a0 = ctx.v0;
      ctx.ra = 0x80010028;       // link written before delay slot
      // delay: nop
      ctx.cycles += 3;
      Fns_00_80010000.f_80010040(ctx);
      ctx.ra = Memory.read32(ctx.sp + 20);
      // jr ra — delay: addiu sp, sp, 0x18
      ctx.sp = ctx.sp + 24;
      ctx.cycles += 3;
      return;
    case 3: // 0x80010034
      ctx.v0 = ctx.v0 + ctx.t0;
      // b 0x80010010 — delay: addiu t0, t0, 1
      ctx.t0 = ctx.t0 + 1;
      ctx.cycles += 3;
      if (ctx.cycles - ctx.nextEvent >= 0) Runtime.pump(ctx);  // back-edge pump
      bb = 1; continue;
    default: return; // unreachable; keeps switch total
  }
}
```

Rules demonstrated: condition temp before the delay slot; jal link → slot → call ordering;
delay-slot instruction inlined into the `jr ra` return path; cycle increments immediately before
every control transfer, each covering exactly the instructions since the previous increment.
