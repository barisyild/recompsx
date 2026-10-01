package mem;

import shim.RawBuf;
import shim.RawMem;

/**
	The emulated address space.

	Every load and store recompiled game code performs arrives here. The design constraints are
	unusually sharp: it must be fast enough that a 33 MHz machine's memory traffic is not the
	bottleneck, identical to the byte on every target, and static — because reflaxe.CPP cannot
	inline an instance method twice in one scope (ADR-0002), and generated code does several
	accesses per function.

	The fast path is one AND and one branch. `p & 0xFF800000` is zero exactly for the 8 MB window
	that holds main RAM and its three mirrors, which is where essentially all traffic goes; the
	scratchpad, the hardware registers and the BIOS window are handled off the hot path.

	Address folding comes first and is free: KUSEG, KSEG0 and KSEG1 are three views of the same
	memory differing only in cacheability, which this emulator does not model, so masking the top
	three bits collapses them. Games rely on that — display lists are commonly built through
	KSEG1 so that writes are visible to the GPU without a cache flush.

	RAM, the scratchpad, and the interrupt controller's two registers exist. The rest of the
	hardware page reads 0, swallows writes, and reports itself once — which makes the log a list
	of the subsystems still to build, in the order the game asks for them.
**/
/* The arena declarations must reach every translation unit that inlines a memory
 * access, and reflaxe does not carry an extern's include along an inlining chain —
 * but every generated shard includes this header, so it is the right place to say it
 * once. Ignored by targets that have no C++ headers. */
@:headerCode("#include \"recompsx_arena.h\"")
class Memory {
	public static inline var RAM_SIZE = 0x200000;      // 2 MB
	public static inline var RAM_MASK = 0x1FFFFF;
	public static inline var SCRATCH_SIZE = 0x400;     // 1 KB of fast memory in the CPU
	public static inline var SCRATCH_BASE = 0x1F800000;

	// Keep RAM/non-RAM tag bits, remove only the two RAM-mirror bits.
	// A decoded value is a RAM byte offset ONLY after the RAM_SIZE check.
	// Keep p (not r) for every non-RAM path.
	public static inline var RAM_DECODE_MASK = 0x1F9FFFFF;
	public static inline var SCRATCH_MATCH_MASK = 0x1FFFFC00;

	/** The hardware register page. 0x1F801000..0x1F803FFF, 12 KB of I/O plus expansion 2. */
	static inline var IO_BASE = 0x1F801000;
	static inline var IO_SIZE = 0x3000;

	/** Emulated RAM and scratchpad, as `shim.Arena` accessors rather than fields. A field would
	    be a pointer, and a pointer costs two dependent loads per access on the C++ targets and
	    cannot be held in a register across stores — the measurement and the rest of the reasoning
	    are in `src/shims/cxx/native/recompsx_arena.h`. On JavaScript these inline to the same
	    typed arrays they always were. */
	public static inline function ram():RawBuf return shim.Arena.ram();
	public static inline function scratch():RawBuf return shim.Arena.scratch();

	/** Reads and writes outside anything mapped, counted so a report can mention them. */
	public static var unmappedAccesses:Int = 0;

	public static function init():Void {
		// Zero-filled, deliberately: emulated state must never start from host memory, or the
		// first run differs from the second and every determinism guarantee is void.
		machine = NONE;
		for (i in 0...RAM_SIZE) RawMem.set8(ram(), i, 0);
		for (i in 0...SCRATCH_SIZE) RawMem.set8(scratch(), i, 0);
		resetMemControl();
		RomFont.init();
	}

	/** Strips the segment. The three cached/uncached views collapse to one physical address. */
	public static inline function phys(a:Int):Int return a & 0x1FFFFFFF;

	/** True for the 8 MB window holding RAM and its mirrors — the hot path's test. */
	static inline function isRam(p:Int):Bool return (p & 0xFF800000) == 0;

	/**
		RAM or scratchpad: memory whose reads have no effect and whose contents change only when
		the machine's own code writes them. What a skipped idle loop requires of every address it
		reads and of its counter slot — checked at run time, because a polled address is a
		register's value, not a constant. Everything else, the ports above all, is not plain: a
		timer's count moves without any code running, and a FIFO's read is a side effect.
	**/
	public static function isPlainMemory(a:Int):Bool {
		final p = phys(a);
		return (p & RAM_DECODE_MASK) < RAM_SIZE || (p & SCRATCH_MATCH_MASK) == SCRATCH_BASE;
	}

	/**
		Whether an idle loop's dry turn (the recompiler's idle-loop prologue) may read `a`: plain
		memory, or a device register that only an event or a store can change and that reading
		does not change — the controller port's status (JOY_STAT) and the interrupt controller's
		status and mask. Between two pumps nothing runs but the loop, which stores to neither, so
		such a register reads the same on every turn the prologue skips, as memory does: libpad
		waits for each controller byte polling JOY_STAT, a few hundred turns a frame.
	**/
	public static function isIdleReadable(a:Int):Bool {
		final w = phys(a) & ~3;
		return isPlainMemory(a) || w == 0x1F801044 || w == 0x1F801070 || w == 0x1F801074;
	}

	// ---- reads ---------------------------------------------------------------------------------

	/*
		The accessors are `Access`, which C++ inlines at the call site: RAM and the scratchpad
		there, the ports out of line in the `slow` functions below. These forward to it and cost
		nothing on either target: Haxe inlines the one-liners, so a call site names `Access`.

		The 16/32-bit paths go through MemA — the aligned accessors — not RawMem. Everything
		arriving here is aligned by architecture: MIPS traps a misaligned lw/lh on real hardware,
		and the kernel HLE's own structures are word-aligned by construction. Byte-offset walkers
		(Iso9660 records) never come through Memory and keep RawMem's tolerant byte composition.
	*/
	public static inline function read8u(a:Int):Int return Access.read8u(a);

	public static inline function read8s(a:Int):Int return (Access.read8u(a) << 24) >> 24;

	public static inline function read16u(a:Int):Int return Access.read16u(a);

	public static inline function read16s(a:Int):Int return (Access.read16u(a) << 16) >> 16;

	public static inline function read32(a:Int):Int return Access.read32(a);

	// ---- writes --------------------------------------------------------------------------------

	public static inline function write8(a:Int, v:Int):Void Access.write8(a, v);

	public static inline function write16(a:Int, v:Int):Void Access.write16(a, v);

	public static inline function write32(a:Int, v:Int):Void Access.write32(a, v);

	// ---- with the cycle count in a local (Access, the timed forms) --------------------------------

	public static inline function read8ut(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read8ut(a, ctx, cyc);

	public static inline function read8st(a:Int, ctx:core.CpuState, cyc:Int):Int
		return (Access.read8ut(a, ctx, cyc) << 24) >> 24;

	public static inline function read16ut(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read16ut(a, ctx, cyc);

	public static inline function read16st(a:Int, ctx:core.CpuState, cyc:Int):Int
		return (Access.read16ut(a, ctx, cyc) << 16) >> 16;

	public static inline function read32t(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read32t(a, ctx, cyc);

	public static inline function write8t(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write8t(a, v, ctx, cyc);

	public static inline function write16t(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write16t(a, v, ctx, cyc);

	public static inline function write32t(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write32t(a, v, ctx, cyc);

	// ---- out of line: where a span's check failed ---------------------------------------------------

	/*
		The same accesses as a call, for the path a span takes when its check failed (the emitter's
		spanLoad and spanStore): rare — a base pointing at the ports, or a run that crosses the end
		of a region — so it goes out of line, where inlining the whole decode again beside the
		span's own path doubled every such access's code (Crash 3's image grew 1 MB with function
		spans).
	*/

	@:specifier("__attribute__((noinline))")
	public static function read8uf(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read8ut(a, ctx, cyc);

	@:specifier("__attribute__((noinline))")
	public static function read8sf(a:Int, ctx:core.CpuState, cyc:Int):Int
		return (Access.read8ut(a, ctx, cyc) << 24) >> 24;

	@:specifier("__attribute__((noinline))")
	public static function read16uf(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read16ut(a, ctx, cyc);

	@:specifier("__attribute__((noinline))")
	public static function read16sf(a:Int, ctx:core.CpuState, cyc:Int):Int
		return (Access.read16ut(a, ctx, cyc) << 16) >> 16;

	@:specifier("__attribute__((noinline))")
	public static function read32f(a:Int, ctx:core.CpuState, cyc:Int):Int return Access.read32t(a, ctx, cyc);

	@:specifier("__attribute__((noinline))")
	public static function write8f(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write8t(a, v, ctx, cyc);

	@:specifier("__attribute__((noinline))")
	public static function write16f(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write16t(a, v, ctx, cyc);

	@:specifier("__attribute__((noinline))")
	public static function write32f(a:Int, v:Int, ctx:core.CpuState, cyc:Int):Void Access.write32t(a, v, ctx, cyc);

	// ---- spans: a run of accesses through one base -----------------------------------------------

	/** Where the scratchpad starts in the arena RAM shares with it (RECOMPSX_SCRATCH_OFFSET). */
	public static inline var SCRATCH_OFFSET = 0x2000A0;

	/**
		The span of `a` when every byte from `a + lo` to `a + hi` is plain memory — all of it in
		RAM, in one 2 MB mirror, or all of it in the scratchpad — or none (`spanOk` false).

		For a run of guest loads and stores through one base register with no write to it between
		them (the recompiler's spans): checked once here, each access is then the span and its own
		offset into the arena (spanRead*, spanWrite*) instead of the full decode (Access). The
		same bytes either way, since a span is only taken where every access in it would have
		taken Access's fast path; where there is none the run goes through Access, access by
		access, in order, as before — a mirror crossed, a register page, anything else. What a
		span is, is the shim's (`shim.Span`): the arena's address on C++, its index elsewhere.
	**/
	public static inline function span(a:Int, lo:Int, hi:Int):shim.Span {
		// One compare for the RAM case: the mask leaves `r` below RAM_SIZE for RAM and its
		// mirrors and at 8 MB or more for anything else, so with offsets from a 16-bit immediate
		// `r + hi < RAM_SIZE` already says `r < RAM_SIZE` — and with `lo` not negative, as it
		// nearly always is, the compiler drops `r + lo >= 0`. It was a range test and a branch
		// more at every take, a dozen thousand a frame.
		final r = a & RAM_DECODE_MASK;
		var at = shim.Arena.spanNone();
		if (r + hi < RAM_SIZE && r + lo >= 0) at = shim.Arena.spanAt(r);
		else if ((a & SCRATCH_MATCH_MASK) == SCRATCH_BASE) {
			final s = a & (SCRATCH_SIZE - 1);
			if (s + lo >= 0 && s + hi < SCRATCH_SIZE) at = shim.Arena.spanAt(SCRATCH_OFFSET + s);
			else {}
		} else {}
		return at;
	}

	/** No span: what a run that must decode access by access holds. */
	public static inline function spanNone():shim.Span return shim.Arena.spanNone();

	/** Whether `s` is a span, rather than none. */
	public static inline function spanOk(s:shim.Span):Bool return shim.Arena.spanOk(s);

	/**
		A span after its base register was stepped by `imm` (`addiu r, r, imm`): the index moved
		the same way while every byte from `+ lo` to `+ hi` stays in the region it was in — RAM's
		mirror, or the scratchpad — else -1, and the accesses decode one by one as they would
		without a span. Exactly `span(new value, lo, hi)` wherever it is not -1: inside one
		region, an address and its arena index move together.

		How a pointer walked through memory keeps its span (the recompiler's function spans): a
		vertex decoder reading a stream through `$gp`, four bytes a step, took the full decode at
		every read, the RAM test failing before the scratchpad's.
	**/
	public static inline function spanStep(s:shim.Span, imm:Int, lo:Int, hi:Int):shim.Span {
		final i = shim.Arena.spanIndex(s);
		final j = i + imm;
		return i < RAM_SIZE
			? ((j + lo >= 0 && j + hi < RAM_SIZE) ? shim.Arena.spanAt(j) : shim.Arena.spanNone())
			: ((j + lo >= SCRATCH_OFFSET && j + hi < SCRATCH_OFFSET + SCRATCH_SIZE) ? shim.Arena.spanAt(j) : shim.Arena.spanNone());
	}

	// An access through a span: the span, and the access's offset from the span's base register.
	public static inline function spanRead8u(s:shim.Span, k:Int):Int return shim.Arena.spanRead8(s, k);

	public static inline function spanRead8s(s:shim.Span, k:Int):Int return (shim.Arena.spanRead8(s, k) << 24) >> 24;

	public static inline function spanRead16u(s:shim.Span, k:Int):Int return shim.Arena.spanRead16(s, k);

	public static inline function spanRead16s(s:shim.Span, k:Int):Int return (shim.Arena.spanRead16(s, k) << 16) >> 16;

	public static inline function spanRead32(s:shim.Span, k:Int):Int return shim.Arena.spanRead32(s, k);

	public static inline function spanWrite8(s:shim.Span, k:Int, v:Int):Void shim.Arena.spanWrite8(s, k, v);

	public static inline function spanWrite16(s:shim.Span, k:Int, v:Int):Void shim.Arena.spanWrite16(s, k, v);

	public static inline function spanWrite32(s:shim.Span, k:Int, v:Int):Void shim.Arena.spanWrite32(s, k, v);

	// ---- unaligned access ------------------------------------------------------------------------

	/**
		`lwl`/`lwr` and `swl`/`swr`: the MIPS answer to unaligned access.

		A compiler emits them in pairs to move a word at an arbitrary address, each handling the
		part of the word that lies in one aligned word. The merge patterns below are the
		little-endian ones; they are stated as expressions rather than loops because they are
		exactly the four cases, and a table lookup would be slower and no clearer.
	**/
	public static function lwl(a:Int, current:Int):Int {
		final w = read32(a & ~3);
		return switch (a & 3) {
			case 0: (current & 0x00FFFFFF) | (w << 24);
			case 1: (current & 0x0000FFFF) | (w << 16);
			case 2: (current & 0x000000FF) | (w << 8);
			case _: w;
		}
	}

	public static function lwr(a:Int, current:Int):Int {
		final w = read32(a & ~3);
		return switch (a & 3) {
			case 0: w;
			case 1: (current & 0xFF000000) | (w >>> 8);
			case 2: (current & 0xFFFF0000) | (w >>> 16);
			case _: (current & 0xFFFFFF00) | (w >>> 24);
		}
	}

	/**
		An `lwr`/`lwl` pair that loads one unaligned word — `lwr rt, k(rs)` and `lwl rt, k+3(rs)`,
		either first (`lwrFirst`), at `aR` and `aL` — as the recompiler fuses it (PatternMatcher):
		in RAM, the one or two aligned words the pair reads, joined, with no switch on the
		alignment and no call; anywhere else the two run as they are, in their order. Each half
		of the pair writes the byte lanes the other leaves, so in RAM `current` is not read.
	**/
	public static inline function lwu(aR:Int, aL:Int, current:Int, lwrFirst:Bool, ctx:core.CpuState, cyc:Int):Int {
		final rR = phys(aR) & RAM_DECODE_MASK;
		final rL = phys(aL) & RAM_DECODE_MASK;
		if (shim.MemA.likely(rR + 3 == rL && rL < RAM_SIZE)) {
			final sh = (rR & 3) << 3;
			final lo = shim.MemA.get32(ram(), rR & ~3);
			return sh == 0 ? lo : ((lo >>> sh) | (shim.MemA.get32(ram(), rL & ~3) << (32 - sh)));
		} else return lwuSlow(aR, aL, current, lwrFirst, ctx, cyc);
	}

	static function lwuSlow(aR:Int, aL:Int, current:Int, lwrFirst:Bool, ctx:core.CpuState, cyc:Int):Int {
		ctx.cycles = cyc;
		return lwrFirst ? lwl(aL, lwr(aR, current)) : lwr(aR, lwl(aL, current));
	}

	public static function swl(a:Int, v:Int):Void {
		final aligned = a & ~3;
		final w = read32(aligned);
		write32(aligned, switch (a & 3) {
			case 0: (w & 0xFFFFFF00) | (v >>> 24);
			case 1: (w & 0xFFFF0000) | (v >>> 16);
			case 2: (w & 0xFF000000) | (v >>> 8);
			case _: v;
		});
	}

	public static function swr(a:Int, v:Int):Void {
		final aligned = a & ~3;
		final w = read32(aligned);
		write32(aligned, switch (a & 3) {
			case 0: v;
			case 1: (w & 0x000000FF) | (v << 8);
			case 2: (w & 0x0000FFFF) | (v << 16);
			case _: (w & 0x00FFFFFF) | (v << 24);
		});
	}

	// ---- everything that is not RAM ----------------------------------------------------------

	static inline function isScratch(p:Int):Bool
		return p >= SCRATCH_BASE && p < SCRATCH_BASE + SCRATCH_SIZE;

	static inline function isIo(p:Int):Bool
		return p >= IO_BASE && p < IO_BASE + IO_SIZE;

	// ---- the ROM window ---------------------------------------------------------------------------
	//
	// 0x1FC00000 is where a real machine's BIOS sits. There is none here and there never will be
	// (golden rule 4) — the kernel is emulated at the call level, so nothing needs to execute from
	// this region. But a game still *reads* it, and until now every such read returned zero
	// because the window was not served at all: not stubbed, not reported, simply absent from the
	// map.
	//
	// One byte of it decides a great deal. Games identify which console they are running on by
	// reading the region letter at the end of the ROM's version string — 'A' for America, 'E' for
	// Europe, 'I' for Japan — and a zero there matches none of them, so the check falls through to
	// its first case. Crash Bash NTSC-U was drawing its "console may have been modified" screen in
	// *Japanese*: the glyph codes it asked the font ROM for decode to 強制終了しました。本体が…,
	// which is the Japanese text of the same message. A disc that says SCEA in a console that says
	// nothing is a mismatch, and the game is right to complain.
	//
	// So the window answers with what this machine is, which is a thing we are entitled to say
	// about ourselves — the same statement `Cdrom.getId` already makes when it reports the disc
	// region. Nothing here is copied from any ROM: it is a short identification written for this
	// emulator, in the layout games look for.

	static inline var ROM_BASE = 0x1FC00000;
	static inline var ROM_SIZE = 0x80000;

	/** Where the region letter lives, at the tail of the version string. */
	static inline var ROM_REGION_BYTE = 0x1FC7FF52;

	/**
		Which console this claims to be: 'A' America, 'E' Europe, 'I' Japan.

		Set from the game's configured region — a recompiled program is one machine running one
		game, so the console's region is the game's. America is the default because a value is
		needed before anything sets one, and a wrong-but-consistent answer is easier to trace than
		a zero that means "no console at all".
	**/
	public static var romRegion = 0x41;   // 'A'

	/** Where the ASCII glyph table begins — the game-measured `0xBFC7F8DE`, physically. */
	static inline var ROM_FONT_BASE = 0x1FC7F8DE;

	static function romRead8(p:Int):Int {
		if (p == ROM_REGION_BYTE) return romRegion & 0xFF;
		else if (p >= ROM_FONT_BASE && p < ROM_FONT_BASE + RomFont.COUNT * RomFont.BYTES_PER_GLYPH)
			return RomFont.byteAt(p - ROM_FONT_BASE);
		else return 0;
	}

	static inline function isRom(p:Int):Bool
		return p >= ROM_BASE && p < ROM_BASE + ROM_SIZE;

	/**
		The hardware registers.

		Only the interrupt controller so far. Everything else in the page still reads 0 and
		swallows writes, and says so once — which is the list of subsystems left to build, in the
		order the game asks for them.

		Registers are 32-bit and the narrow accesses fold onto them: a halfword read of I_STAT is
		the low half, which games do use.
	**/
	static function ioRead32(p:Int):Int {
		if (p == 0x1F801070) return core.Irq.readStat();
		else if (p == 0x1F801074) return core.Irq.readMask();
		else if (p == 0x1F801810) return gpu.Gpu.readData();
		else if (p == 0x1F801814) return gpu.Gpu.readStatus(cycleHint());
		else if (isMemControl(p)) return memControl[(p - MEMCTRL_BASE) >> 2];
		else if (p == RAM_SIZE_REG) return ramSizeReg;
		else return ioUnknownRead(p);
	}

	// ---- the memory-control registers ---------------------------------------------------------
	//
	// Nine words at 1F801000h that say where the expansion regions live and how many cycles the
	// bus should wait for each device, plus RAM_SIZE at 1F801060h and the cache-control word up at
	// FFFE0130h. Every game's startup writes some of them — usually copying the same values the
	// BIOS already put there, because Sony's own library does it unconditionally.
	//
	// Stored and handed back, and nothing more. Bus timing is not modelled: this emulator charges
	// a fixed cost per instruction and pacing is cosmetic (golden rule 3), so a game that widens
	// the CD-ROM's access window changes a number it can read back and nothing else. That is the
	// honest implementation rather than a stub — the values a game writes here it also *reads*,
	// and a register that returns zero to a game that just wrote 0x200931E1 is a lie that shows up
	// somewhere far away.
	//
	// The reset values are the BIOS's, from psx-spx "Memory Control": what a game finds if it
	// looks before it writes.

	static inline var MEMCTRL_BASE = 0x1F801000;
	static inline var MEMCTRL_COUNT = 9;
	static inline var RAM_SIZE_REG = 0x1F801060;

	/** FFFE0130h, outside the I/O page entirely — the only register in its own address space. */
	static inline var CACHE_CONTROL_REG = 0x1FFE0130;

	static var memControl:Array<Int>;
	static var ramSizeReg = 0;
	static var cacheControl = 0;

	static inline function isMemControl(p:Int):Bool
		return p >= MEMCTRL_BASE && p < MEMCTRL_BASE + MEMCTRL_COUNT * 4;

	static function resetMemControl():Void {
		memControl = [
			0x1F000000,   // 1000 expansion 1 base
			0x1F802000,   // 1004 expansion 2 base
			0x0013243F,   // 1008 expansion 1 delay/size
			0x00003022,   // 100C expansion 3 delay/size
			0x0013243F,   // 1010 BIOS ROM delay/size
			0x200931E1,   // 1014 SPU delay/size
			0x00020843,   // 1018 CD-ROM delay/size
			0x00070777,   // 101C expansion 2 delay/size
			0x00031125    // 1020 common delay
		];
		ramSizeReg = 0x00000B88;
		cacheControl = 0;
	}

	/**
		The machine, for registers whose value depends on the clock.

		GPUSTAT's beam-parity bit is the reason: it has to be computed from the line the beam is
		on, and a memory read has no `ctx` parameter to ask. This used to be two ints —
		`cycleHint`/`raHint` — that every pump site copied out of `ctx`, which put two stores on
		the hottest path in the program for the benefit of the rarest: profiled on the game's own
		scheduler loop, the copies were pure overhead at 2,570 sites and the values were consulted
		only when an access actually reached a device. Holding the one `CpuState` instead costs
		those sites nothing and is *fresher*: `machine.cycles` at the moment of the access, not at
		the entry of the block — the same value today, because generated code accumulates cycles
		at block end, but no longer a copy that can lag.

		One static, set once at boot. There is exactly one live machine; HLE thread switches copy
		registers into it rather than replacing it, which is what makes a single binding correct.
	**/
	// Stand-alone device fixtures may run without a CPU; boot binds the live machine. Until then
	// it is `NONE`, a CpuState nothing runs on, whose clock reads 0 — not `null` in a `Null<>`:
	// on C++ that was a `std::optional` of the pointer, a flag tested and a value loaded on every
	// clocked register read, where this is one load (docs/perf/dreamcast-ledger.md, E-040).
	static final NONE:core.CpuState = new core.CpuState();
	public static var machine:core.CpuState = NONE;

	/** The current cycle count, read straight off the machine. */
	public static inline function cycleHint():Int return machine.cycles;

	/** The running function's return address, for diagnostics that need to name a caller. */
	public static inline function raHint():Int return machine.ra;

	static function ioWrite32(p:Int, v:Int):Void {
		if (p == 0x1F801070) inline core.Irq.writeStat(v);
		else if (p == 0x1F801074) core.Irq.writeMask(v);
		else if (p == 0x1F801810) inline gpu.Gpu.writeGp0(v);
		else if (p == 0x1F801814) gpu.Gpu.writeGp1(v);
		else if (isMemControl(p)) memControl[(p - MEMCTRL_BASE) >> 2] = v;
		else if (p == RAM_SIZE_REG) ramSizeReg = v;
		else ioUnknownWrite(p, v);
	}

	/**
		The unknown-register reports, guarded before the message exists.

		`reportOnce(key, "..." + hexAddr(p))` builds its string on every call and only then finds
		the key already reported. Harmless for a call that happens once; fatal for a register a
		game polls in a tight loop — a profile showed the machine spending a quarter of its time
		in string concatenation, limping a thousand times slower than it emulated, which read as a
		hang. The guard makes the already-reported path one map lookup and nothing else.
	**/
	static function ioUnknownRead(p:Int):Int {
		final key = 0x10000000 | (p & 0xFFFF);
		if (!core.Runtime.alreadyReported(key)) {
			core.Runtime.reportOnce(key, "read from I/O register " + hexAddr(p));
		} else {}
		return 0;
	}

	static function ioUnknownWrite(p:Int, v:Int):Void {
		final key = 0x11000000 | (p & 0xFFFF);
		if (!core.Runtime.alreadyReported(key)) {
			core.Runtime.reportOnce(key, "write to I/O register " + hexAddr(p));
		} else {}
	}

	static function hexAddr(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}

	@:specifier("__attribute__((noinline))")
	public static function slowRead8(p:Int):Int {
		if (isScratch(p)) return RawMem.get8(scratch(), p - SCRATCH_BASE);
		// The CD-ROM's four registers are genuinely byte-wide and index-banked; folding them onto
		// a 32-bit word would read three neighbours that mean something else entirely.
		else if (isCdrom(p)) return inline cd.Cdrom.readPolled(p, raHint());
		else if (isSio(p)) return inline sio.Sio0.read8(p);
		else if (isIo(p)) return ((inline ioRead32(p & ~3)) >>> ((p & 3) << 3)) & 0xFF;
		else if (isRom(p)) return inline romRead8(p);
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) return mod.ModRam.read8(p);   // mods' memory (ADR-0033)
		#end
		else return unmapped8();
	}

	static function cdWordWrite(p:Int, v:Int):Void {
		cd.Cdrom.write8(p, v & 0xFF, cycleHint());
		cd.Cdrom.write8(p + 1, (v >>> 8) & 0xFF, cycleHint());
		cd.Cdrom.write8(p + 2, (v >>> 16) & 0xFF, cycleHint());
		cd.Cdrom.write8(p + 3, (v >>> 24) & 0xFF, cycleHint());
	}

	/**
		A halfword write to the CD page: the low byte, then the high one.

		Its absence was a seven-second stall at every boot. The CD registers are byte-wide, so the
		byte and word paths both existed and this one did not — a `sh` to 1F801802 fell through to
		the generic I/O fallback, which read a register that does not exist, merged into it, and
		wrote the result nowhere. libcd enables the drive's interrupts with exactly that store, so
		the enable never happened, the first answer was latched behind a closed gate, and the
		library recovered the only way it could: by timing out and polling.

		The shape of the bug is worth remembering because it is the second of its kind this month
		(the SPU's main volume was a 32-bit store into halfword-only code). A device is not
		"reachable" until every access width reaches it, and a missing width does not fail — it
		silently goes somewhere else.
	**/
	static function cdHalfWrite(p:Int, v:Int):Void {
		cd.Cdrom.write8(p, v & 0xFF, cycleHint());
		cd.Cdrom.write8(p + 1, (v >>> 8) & 0xFF, cycleHint());
	}

	/** A word read of the CD page: four byte registers, little-endian, each with its own effect. */
	static function cdWord(p:Int):Int {
		return cd.Cdrom.read8(p)
			| (cd.Cdrom.read8(p + 1) << 8)
			| (cd.Cdrom.read8(p + 2) << 16)
			| (cd.Cdrom.read8(p + 3) << 24);
	}

	static inline function isCdrom(p:Int):Bool
		return p >= 0x1F801800 && p <= 0x1F801803;

	/** The root counters: 1F801100..1F80112F. */
	static inline function isTimer(p:Int):Bool
		return p >= 0x1F801100 && p <= 0x1F80112F;

	/** SIO0 and SIO1: 1F801040..1F80105F. Byte- and halfword-accessed, so they bypass the
		32-bit folding the ordinary I/O page uses. */
	static inline function isSio(p:Int):Bool
		return p >= 0x1F801040 && p <= 0x1F80105F;

	static function unmapped8():Int {
		unmappedAccesses++;
		return 0;
	}

	@:specifier("__attribute__((noinline))")
	public static function slowRead16(p:Int):Int {
		if (isScratch(p)) return RawMem.get16(scratch(), p - SCRATCH_BASE);
		else if (isCdrom(p)) return (inline cd.Cdrom.read8(p)) | ((inline cd.Cdrom.read8(p + 1)) << 8);
		else if (isSio(p)) return inline sio.Sio0.read16(p);
		else if (isTimer(p)) return (inline timers.Timers.read(p, cycleHint())) & 0xFFFF;
		else if (spu.Spu.contains(p)) return inline spu.Spu.read16(p);
		else if (isIo(p)) return ((inline ioRead32(p & ~3)) >>> ((p & 2) << 3)) & 0xFFFF;
		else if (isRom(p)) return (inline romRead8(p)) | ((inline romRead8(p + 1)) << 8);
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) return mod.ModRam.read16(p);
		#end
		else return unmapped8();
	}

	/**
		The I/O reads are inlined here, at the call site, and nowhere else — and the same in
		`slowRead8`, `slowRead16` and the three `slowWrite`s, where `ioWrite32` in turn inlines
		`Gpu.writeGp0`, so a GP0 word reaches the GPU's dispatcher from `write32` in one call.

		A game polls a timer through `read32`, and the profile showed the chain as five frames:
		`read32 → slowRead32 → Timers.read → value → fold`. Inlining the accessors class-wide
		copies their bodies into fourteen thousand generated sites and measured slower both times
		it was tried (PROGRESS 2026-09-25); `inline` on these calls copies each body once, into
		this one function, and grows the bundle by five kilobytes. Haxe can only do it for a body
		whose every `return` is final, which is why `romRead8` is one if/else chain.
	**/
	@:specifier("__attribute__((noinline))")
	public static function slowRead32(p:Int):Int {
		if (isScratch(p)) return RawMem.get32(scratch(), p - SCRATCH_BASE);
		else if (isSio(p)) return inline sio.Sio0.read32(p);
		else if (isTimer(p)) return inline timers.Timers.read(p, cycleHint());
		// The CD's four registers were reachable by byte and halfword but not by word, so a
		// 32-bit read of the status register fell through to the unknown-I/O path and answered
		// zero — a drive that reports nothing, to a driver that reads it that way.
		else if (isCdrom(p)) return inline cdWord(p);
		else if (dma.Dma.contains(p)) return inline dma.Dma.read(p);
		else if (spu.Spu.contains(p)) return inline spuWord(p);
		else if (isIo(p)) return inline ioRead32(p);
		else if (p == CACHE_CONTROL_REG) return cacheControl;
		else if (isRom(p)) return (inline romRead8(p)) | ((inline romRead8(p + 1)) << 8)
			| ((inline romRead8(p + 2)) << 16) | ((inline romRead8(p + 3)) << 24);
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) return mod.ModRam.read32(p);
		#end
		else return unmapped8();
	}

	/**
		The SPU is a bank of 16-bit registers, and libspu writes pairs of them at once.

		Volume comes in twos — left beside right, in that order and adjacent — so a library sets
		both with a single word store, and the main volume is the pair that matters most: with it
		unwritten every voice is multiplied by zero. That is what an SPU reachable only by halfword
		produced. Twenty-four voices playing, four hundred thousand samples of correctly decoded
		ADPCM, and silence.
	**/
	static function spuWord(p:Int):Int {
		return spu.Spu.read16(p) | (spu.Spu.read16(p + 2) << 16);
	}

	static function spuWordWrite(p:Int, v:Int):Void {
		spu.Spu.write16(p, v & 0xFFFF);
		spu.Spu.write16(p + 2, (v >>> 16) & 0xFFFF);
	}

	@:specifier("__attribute__((noinline))")
	public static function slowWrite8(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set8(scratch(), p - SCRATCH_BASE, v);
		else if (isCdrom(p)) inline cd.Cdrom.write8(p, v, cycleHint());
		else if (isSio(p)) inline sio.Sio0.write8(p, v);
		else if (isIo(p)) inline ioWriteNarrow(p, v & 0xFF, 0xFF);
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) mod.ModRam.write8(p, v);
		#end
		else unmappedAccesses++;
	}

	/**
		A narrow write to a 32-bit register.

		Read-modify-write rather than a plain store, because the surrounding bits belong to the
		register and a game writing one byte of I_MASK means to leave the rest alone.
	**/
	static function ioWriteNarrow(p:Int, v:Int, valueMask:Int):Void {
		final reg = p & ~3;
		final shift = (p & 3) << 3;
		final old = inline ioRead32(reg);
		inline ioWrite32(reg, (old & ~(valueMask << shift)) | ((v & valueMask) << shift));
	}

	@:specifier("__attribute__((noinline))")
	public static function slowWrite16(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set16(scratch(), p - SCRATCH_BASE, v);
		else if (isSio(p)) inline sio.Sio0.write16(p, v);
		else if (isTimer(p)) inline timers.Timers.write(p, v & 0xFFFF, cycleHint());
		else if (isCdrom(p)) inline cdHalfWrite(p, v & 0xFFFF);
		else if (spu.Spu.contains(p)) inline spu.Spu.write16(p, v & 0xFFFF);
		else if (isIo(p)) inline ioWriteNarrow(p, v & 0xFFFF, 0xFFFF);
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) mod.ModRam.write16(p, v);
		#end
		else unmappedAccesses++;
	}

	@:specifier("__attribute__((noinline))")
	public static function slowWrite32(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set32(scratch(), p - SCRATCH_BASE, v);
		else if (isTimer(p)) inline timers.Timers.write(p, v & 0xFFFF, cycleHint());
		else if (isCdrom(p)) inline cdWordWrite(p, v);
		else if (dma.Dma.contains(p)) inline dma.Dma.write(p, v);
		else if (spu.Spu.contains(p)) inline spuWordWrite(p, v);
		else if (isIo(p)) inline ioWrite32(p, v);
		// The cache-control word. Nothing here has a cache, so this is storage — but it is the
		// register a game uses to enable the scratchpad, and one that read back zero after being
		// written would be a machine no game has ever run on.
		else if (p == CACHE_CONTROL_REG) cacheControl = v;
		#if recompsx_mods
		else if (mod.ModRam.contains(p)) mod.ModRam.write32(p, v);
		#end
		else unmappedAccesses++;
	}

	/** Bulk copy within RAM, for DMA and the kernel's memcpy. */
	public static function copyRam(dst:Int, src:Int, bytes:Int):Void {
		var d = phys(dst) & RAM_MASK;
		var s = phys(src) & RAM_MASK;
		var n = bytes;
		while (n > 0) {
			RawMem.set8(ram(), d, RawMem.get8(ram(), s));
			d++;
			s++;
			n--;
		}
	}

	/** Loads an image into RAM — a program, or an overlay arriving from the disc. */
	public static function loadInto(addr:Int, src:RawBuf, srcOffset:Int, bytes:Int):Void {
		var d = phys(addr) & RAM_MASK;
		var i = 0;
		while (i < bytes) {
			RawMem.set8(ram(), d + i, RawMem.get8(src, srcOffset + i));
			i++;
		}
	}
}
