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
class Memory {
	public static inline var RAM_SIZE = 0x200000;      // 2 MB
	public static inline var RAM_MASK = 0x1FFFFF;
	public static inline var SCRATCH_SIZE = 0x400;     // 1 KB of fast memory in the CPU
	static inline var SCRATCH_BASE = 0x1F800000;

	/** The hardware register page. 0x1F801000..0x1F803FFF, 12 KB of I/O plus expansion 2. */
	static inline var IO_BASE = 0x1F801000;
	static inline var IO_SIZE = 0x3000;

	public static var ram:RawBuf;
	public static var scratch:RawBuf;

	/** Reads and writes outside anything mapped, counted so a report can mention them. */
	public static var unmappedAccesses:Int = 0;

	public static function init():Void {
		// Zero-filled, deliberately: emulated state must never start from host memory, or the
		// first run differs from the second and every determinism guarantee is void.
		ram = RawMem.alloc(RAM_SIZE);
		scratch = RawMem.alloc(SCRATCH_SIZE);
		resetMemControl();
		RomFont.init();
	}

	/** Strips the segment. The three cached/uncached views collapse to one physical address. */
	public static inline function phys(a:Int):Int return a & 0x1FFFFFFF;

	/** True for the 8 MB window holding RAM and its mirrors — the hot path's test. */
	static inline function isRam(p:Int):Bool return (p & 0xFF800000) == 0;

	// ---- reads ---------------------------------------------------------------------------------

	public static inline function read8u(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get8(ram, p & RAM_MASK) : slowRead8(p);
	}

	public static inline function read8s(a:Int):Int {
		return (read8u(a) << 24) >> 24;
	}

	public static inline function read16u(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get16(ram, p & RAM_MASK) : slowRead16(p);
	}

	public static inline function read16s(a:Int):Int {
		return (read16u(a) << 16) >> 16;
	}

	public static inline function read32(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get32(ram, p & RAM_MASK) : slowRead32(p);
	}

	// ---- writes --------------------------------------------------------------------------------

	public static inline function write8(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set8(ram, p & RAM_MASK, v);
		else slowWrite8(p, v);
	}

	public static inline function write16(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set16(ram, p & RAM_MASK, v);
		else slowWrite16(p, v);
	}

	public static inline function write32(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set32(ram, p & RAM_MASK, v);
		else slowWrite32(p, v);
	}

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
		else {}
		if (p >= ROM_FONT_BASE && p < ROM_FONT_BASE + RomFont.COUNT * RomFont.BYTES_PER_GLYPH)
			return RomFont.byteAt(p - ROM_FONT_BASE);
		else {}
		return 0;
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
		else if (p == 0x1F801814) return gpu.Gpu.readStatus(cycleHint);
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
		The current cycle count, for registers whose value depends on the clock.

		GPUSTAT's beam-parity bit is the reason: it has to be computed from the line the beam is on,
		and a memory read has no `ctx` to ask. The pump keeps this in step, which is enough because
		nothing between two pump points can observe the beam moving anyway.
	**/
	public static var cycleHint:Int = 0;

	/** The interrupted function's return address, for diagnostics that need to name a caller. */
	public static var raHint:Int = 0;

	static function ioWrite32(p:Int, v:Int):Void {
		if (p == 0x1F801070) core.Irq.writeStat(v);
		else if (p == 0x1F801074) core.Irq.writeMask(v);
		else if (p == 0x1F801810) gpu.Gpu.writeGp0(v);
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

	static function slowRead8(p:Int):Int {
		if (isScratch(p)) return RawMem.get8(scratch, p - SCRATCH_BASE);
		// The CD-ROM's four registers are genuinely byte-wide and index-banked; folding them onto
		// a 32-bit word would read three neighbours that mean something else entirely.
		else if (isCdrom(p)) return cd.Cdrom.readPolled(p, raHint);
		else if (isSio(p)) return sio.Sio0.read8(p);
		else if (isIo(p)) return (ioRead32(p & ~3) >>> ((p & 3) << 3)) & 0xFF;
		else if (isRom(p)) return romRead8(p);
		else return unmapped8();
	}

	static function cdWordWrite(p:Int, v:Int):Void {
		cd.Cdrom.write8(p, v & 0xFF, cycleHint);
		cd.Cdrom.write8(p + 1, (v >>> 8) & 0xFF, cycleHint);
		cd.Cdrom.write8(p + 2, (v >>> 16) & 0xFF, cycleHint);
		cd.Cdrom.write8(p + 3, (v >>> 24) & 0xFF, cycleHint);
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
		cd.Cdrom.write8(p, v & 0xFF, cycleHint);
		cd.Cdrom.write8(p + 1, (v >>> 8) & 0xFF, cycleHint);
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

	static function slowRead16(p:Int):Int {
		if (isScratch(p)) return RawMem.get16(scratch, p - SCRATCH_BASE);
		else if (isCdrom(p)) return cd.Cdrom.read8(p) | (cd.Cdrom.read8(p + 1) << 8);
		else if (isSio(p)) return sio.Sio0.read16(p);
		else if (isTimer(p)) return timers.Timers.read(p, cycleHint) & 0xFFFF;
		else if (spu.Spu.contains(p)) return spu.Spu.read16(p);
		else if (isIo(p)) return (ioRead32(p & ~3) >>> ((p & 2) << 3)) & 0xFFFF;
		else if (isRom(p)) return romRead8(p) | (romRead8(p + 1) << 8);
		else return unmapped8();
	}

	static function slowRead32(p:Int):Int {
		if (isScratch(p)) return RawMem.get32(scratch, p - SCRATCH_BASE);
		else if (isSio(p)) return sio.Sio0.read32(p);
		else if (isTimer(p)) return timers.Timers.read(p, cycleHint);
		// The CD's four registers were reachable by byte and halfword but not by word, so a
		// 32-bit read of the status register fell through to the unknown-I/O path and answered
		// zero — a drive that reports nothing, to a driver that reads it that way.
		else if (isCdrom(p)) return cdWord(p);
		else if (dma.Dma.contains(p)) return dma.Dma.read(p);
		else if (spu.Spu.contains(p)) return spuWord(p);
		else if (isIo(p)) return ioRead32(p);
		else if (p == CACHE_CONTROL_REG) return cacheControl;
		else if (isRom(p)) return romRead8(p) | (romRead8(p + 1) << 8)
			| (romRead8(p + 2) << 16) | (romRead8(p + 3) << 24);
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

	static function slowWrite8(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set8(scratch, p - SCRATCH_BASE, v);
		else if (isCdrom(p)) cd.Cdrom.write8(p, v, cycleHint);
		else if (isSio(p)) sio.Sio0.write8(p, v);
		else if (isIo(p)) ioWriteNarrow(p, v & 0xFF, 0xFF);
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
		final old = ioRead32(reg);
		ioWrite32(reg, (old & ~(valueMask << shift)) | ((v & valueMask) << shift));
	}

	static function slowWrite16(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set16(scratch, p - SCRATCH_BASE, v);
		else if (isSio(p)) sio.Sio0.write16(p, v);
		else if (isTimer(p)) timers.Timers.write(p, v & 0xFFFF, cycleHint);
		else if (isCdrom(p)) cdHalfWrite(p, v & 0xFFFF);
		else if (spu.Spu.contains(p)) spu.Spu.write16(p, v & 0xFFFF);
		else if (isIo(p)) ioWriteNarrow(p, v & 0xFFFF, 0xFFFF);
		else unmappedAccesses++;
	}

	static function slowWrite32(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set32(scratch, p - SCRATCH_BASE, v);
		else if (isTimer(p)) timers.Timers.write(p, v & 0xFFFF, cycleHint);
		else if (isCdrom(p)) cdWordWrite(p, v);
		else if (dma.Dma.contains(p)) dma.Dma.write(p, v);
		else if (spu.Spu.contains(p)) spuWordWrite(p, v);
		else if (isIo(p)) ioWrite32(p, v);
		// The cache-control word. Nothing here has a cache, so this is storage — but it is the
		// register a game uses to enable the scratchpad, and one that read back zero after being
		// written would be a machine no game has ever run on.
		else if (p == CACHE_CONTROL_REG) cacheControl = v;
		else unmappedAccesses++;
	}

	/** Bulk copy within RAM, for DMA and the kernel's memcpy. */
	public static function copyRam(dst:Int, src:Int, bytes:Int):Void {
		var d = phys(dst) & RAM_MASK;
		var s = phys(src) & RAM_MASK;
		var n = bytes;
		while (n > 0) {
			RawMem.set8(ram, d, RawMem.get8(ram, s));
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
			RawMem.set8(ram, d + i, RawMem.get8(src, srcOffset + i));
			i++;
		}
	}
}
