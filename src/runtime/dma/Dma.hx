package dma;

import core.Irq;
import core.Runtime;
import mem.Memory;

/**
	The DMA controller — and, for a PlayStation game, the thing that actually draws.

	Psy-Q does not write GP0 a word at a time. `DrawOTag` hands the GPU an *ordering table*: a
	backwards-linked chain in RAM where each node carries a word count and the packets that follow
	it, and channel 2 walks it. So a runtime with a working GPU port and no DMA sees a game submit
	its display list into nothing and render an empty screen while looking perfectly healthy —
	which is exactly what this one did, twenty-nine GP0 words in eight minutes of play.

	Transfers complete instantly. Nothing in the emulated machine can observe the difference: the
	channel is busy for no emulated time, and a game that polls CHCR bit 24 sees it already clear.
	Register map from psx-spx "DMA Channels" as recorded in docs/specs/runtime.md §7.9.
**/
class Dma {
	static inline var BASE = 0x1F801080;

	// Per-channel registers, 0x10 apart: MADR, BCR, CHCR.
	static inline var MADR = 0x0;
	static inline var BCR = 0x4;
	static inline var CHCR = 0x8;

	static inline var CH_GPU = 2;
	static inline var CH_CDROM = 3;
	static inline var CH_SPU = 4;
	static inline var CH_OTC = 6;

	// CHCR bits.
	static inline var CHCR_BUSY = 0x01000000;
	static inline var CHCR_TRIGGER = 0x10000000;

	static var madr:Array<Int>;
	static var bcr:Array<Int>;
	static var chcr:Array<Int>;

	/** DPCR — per-channel enable nibbles. Reset value from psx-spx. */
	static var dpcr = 0x07654321;

	/** DICR — interrupt enables and flags. */
	static var dicr = 0;

	/** Words pushed to the GPU, and lists walked. The first evidence a game is drawing. */
	public static var wordsToGpu(default, null) = 0;
	public static var listsWalked(default, null) = 0;

	public static function init():Void {
		madr = [for (_ in 0...7) 0];
		bcr = [for (_ in 0...7) 0];
		chcr = [for (_ in 0...7) 0];
		dpcr = 0x07654321;
		dicr = 0;
		wordsToGpu = 0;
		listsWalked = 0;
		wordsFromCd = 0;
		wordsToSpu = 0;
		tablesCleared = 0;
	}

	public static inline function contains(p:Int):Bool {
		return p >= BASE && p <= 0x1F8010FF;
	}

	public static function read(p:Int):Int {
		if (p == 0x1F8010F0) return dpcr;
		else if (p == 0x1F8010F4) return readDicr();
		else return channelRead(p);
	}

	/**
		DICR, with bit 31 computed rather than stored.

		psx-spx defines it as read-only and derived: the force bit, or the master enable together
		with any flag whose channel is enabled. Returning the raw register left it permanently
		clear, so a driver that polls this one bit to learn a transfer finished waits on a
		condition that can never become true — and the whole of DMA looks like it never completes
		while every channel has in fact already run.
	**/
	static inline function readDicr():Int {
		final force = (dicr & 0x00008000) != 0;
		final master = (dicr & 0x00800000) != 0;
		final flags = (dicr >>> 24) & 0x7F;
		final enables = (dicr >>> 16) & 0x7F;
		final raised = force || (master && (flags & enables) != 0);
		return raised ? (dicr | 0x80000000) : (dicr & 0x7FFFFFFF);
	}

	static inline function channelRead(p:Int):Int {
		final ch = (p - BASE) >> 4;
		final reg = p & 0xF;
		if (ch < 0 || ch > 6) return 0;
		else if (reg == MADR) return madr[ch];
		else if (reg == BCR) return bcr[ch];
		else if (reg == CHCR) return chcr[ch];
		else return 0;
	}

	public static function write(p:Int, v:Int):Void {
		if (p == 0x1F8010F0) dpcr = v;
		else if (p == 0x1F8010F4) writeDicr(v);
		else channelWrite(p, v);
	}

	/** DICR's flag bits are write-1-to-clear; the enables are ordinary. */
	static inline function writeDicr(v:Int):Void {
		final acked = (v >>> 24) & 0x7F;
		dicr = (v & 0x00FFFFFF) | (((dicr >>> 24) & ~acked & 0x7F) << 24);
	}

	static inline function channelWrite(p:Int, v:Int):Void {
		final ch = (p - BASE) >> 4;
		final reg = p & 0xF;
		if (ch < 0 || ch > 6) {}
		else if (reg == MADR) madr[ch] = v & 0xFFFFFF;
		else if (reg == BCR) bcr[ch] = v;
		else if (reg == CHCR) startIfArmed(ch, v);
		else {}
	}

	static function startIfArmed(ch:Int, v:Int):Void {
		chcr[ch] = v;
		if (!enabled(ch)) return;
		else {}
		if ((v & CHCR_BUSY) == 0) return;
		else {}
		run(ch);
	}

	static inline function enabled(ch:Int):Bool {
		return ((dpcr >>> (ch * 4 + 3)) & 1) != 0;
	}

	/**
		Runs a channel to completion, now.

		Sync mode lives in CHCR bits 9–10: 0 is a straight burst, 1 is a slice, 2 is a linked list.
		Only the GPU's list and block modes are carried out; the rest clear their busy bit and say
		so, because a channel that never finishes is a game that never continues.
	**/
	static function run(ch:Int):Void {
		final sync = (chcr[ch] >>> 9) & 3;
		if (ch == CH_GPU && sync == 2) walkList();
		else if (ch == CH_GPU) blockToGpu();
		else if (ch == CH_CDROM) sectorToRam();
		else if (ch == CH_SPU) ramToSpu();
		else if (ch == CH_OTC) clearOrderingTable();
		else unimplementedChannel(ch);
		finish(ch);
	}

	/**
		The ordering table: each node is a header word holding a byte count and the address of the
		next node, followed by that many packet words.

		Walked forwards from MADR through the `next` links, which run *backwards* through memory
		because a game builds its table back to front — nearest last. The terminator is any address
		with bit 23 set, which is how the BIOS's own `ClearOTagR` ends a table.
	**/
	static function walkList():Void {
		var addr = madr[CH_GPU] & 0x1FFFFC;
		var guard = 0;
		while (true) {
			final header = Memory.read32(addr);
			final count = (header >>> 24) & 0xFF;
			for (i in 0...count) {
				Memory.write32(0x1F801810, Memory.read32(addr + 4 + (i << 2)));
			}
			wordsToGpu += count;
			addr = header & 0x1FFFFC;
			// Bit 23 of the link marks the end. A table that neither ends nor repeats would
			// otherwise walk all of RAM.
			if ((header & 0x800000) != 0) break;
			else {}
			guard++;
			if (guard > 0x10000) return runaway();
			else {}
		}
		listsWalked++;
		madr[CH_GPU] = 0xFFFFFF;
	}

	static function runaway():Void {
		Runtime.reportOnce(0x6B000000, "DMA list walked 65536 nodes without ending");
	}

	/** Block mode: BCR holds a block size and a block count, and the words go straight out. */
	static function blockToGpu():Void {
		final size = bcr[CH_GPU] & 0xFFFF;
		final blocks = (bcr[CH_GPU] >>> 16) & 0xFFFF;
		final total = size * (blocks == 0 ? 1 : blocks);
		var addr = madr[CH_GPU] & 0x1FFFFC;
		// Direction bit 0: 1 is RAM to device. Reading VRAM back is not carried out yet.
		if ((chcr[CH_GPU] & 1) == 0) return notReadable();
		else {}
		for (i in 0...total) {
			Memory.write32(0x1F801810, Memory.read32(addr));
			addr += 4;
		}
		wordsToGpu += total;
		madr[CH_GPU] = addr & 0xFFFFFF;
	}

	/**
		Channel 3: the sector the CD-ROM controller is holding, into RAM.

		This is how a game actually reads a disc. libcd sets `Setloc`/`ReadN`, waits for the INT1
		that says a sector has arrived, sets the request bit so the controller loads its data FIFO,
		and then hands the copying to this channel — it never reads 1F801802 in a loop. So a
		controller that answers every command correctly and a channel that quietly does nothing
		produce a game that receives the interrupt, finds its buffer untouched, and reports a
		sector error: everything works except the one step that moves the bytes.

		Burst and slice are the same transfer here, since it completes instantly either way; the
		difference on hardware is only how the channel shares the bus. Words rather than bytes
		because BCR counts words, and the address step follows CHCR bit 1 — backwards transfers are
		legal and cost one comparison to honour.
	**/
	static function sectorToRam():Void {
		final size = bcr[CH_CDROM] & 0xFFFF;
		final blocks = (bcr[CH_CDROM] >>> 16) & 0xFFFF;
		final sync = (chcr[CH_CDROM] >>> 9) & 3;
		// Burst mode counts words in BCR's low half, and zero there means the full 0x10000.
		final total = sync == 0
			? (size == 0 ? 0x10000 : size)
			: size * (blocks == 0 ? 1 : blocks);
		final step = (chcr[CH_CDROM] & 2) != 0 ? -4 : 4;
		var addr = madr[CH_CDROM] & 0x1FFFFC;
		for (i in 0...total) {
			Memory.write32(addr, cd.Cdrom.dmaWord());
			addr += step;
		}
		wordsFromCd += total;
		// Whatever was compiled for these addresses is no longer what is there. The disc is how a
		// game replaces code, so this is where the mapping has to be told (kernel.OverlayMgr).
		kernel.OverlayMgr.noteLoad(0x80000000 | (madr[CH_CDROM] & 0x1FFFFC), total * 4,
			cd.Cdrom.currentLba());
		madr[CH_CDROM] = addr & 0xFFFFFF;
	}

	/** Words the disc has handed over. The first evidence a game is loading anything. */
	public static var wordsFromCd(default, null) = 0;

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}

	static function notReadable():Void {
		Runtime.reportOnce(0x6B000001, "DMA read from the GPU, which has no VRAM to give yet");
	}

	/**
		Channel 4: wave data from RAM into sound RAM.

		Slice mode, like the GPU's block transfers: BCR holds a block size and a block count, and
		libspu sets both. Reads from the SPU are legal on hardware and not carried out here — a
		game reading its own samples back is doing something no bring-up needs yet, and pretending
		would be worse than saying so.
	**/
	static function ramToSpu():Void {
		final size = bcr[CH_SPU] & 0xFFFF;
		final blocks = (bcr[CH_SPU] >>> 16) & 0xFFFF;
		final sync = (chcr[CH_SPU] >>> 9) & 3;
		final total = sync == 0
			? (size == 0 ? 0x10000 : size)
			: size * (blocks == 0 ? 1 : blocks);
		if ((chcr[CH_SPU] & 1) == 0) return spuNotReadable();
		else {}
		var addr = madr[CH_SPU] & 0x1FFFFC;
		for (i in 0...total) {
			spu.Spu.dmaWord(Memory.read32(addr));
			addr += 4;
		}
		wordsToSpu += total;
		madr[CH_SPU] = addr & 0xFFFFFF;
		// libspu does not poll the channel; it waits on this. `SpuIsTransferCompleted` opens the
		// SPU class with spec "completed" and blocks until it arrives, so a transfer that happens
		// perfectly and never announces itself stops the game just as dead as no transfer at all —
		// and more confusingly, because the wave data is right there in sound RAM.
		kernel.KEvents.post(kernel.KEvents.CLASS_SPU, SPEC_COMPLETED);
	}

	/** "The thing you asked for has finished" — psx-spx, BIOS event specs. */
	static inline var SPEC_COMPLETED = 0x0020;

	/** Words of wave data uploaded. */
	public static var wordsToSpu(default, null) = 0;

	static function spuNotReadable():Void {
		Runtime.reportOnce(0x6B000002, "DMA read from the SPU, which does not give samples back");
	}

	/**
		Channel 6: writes the empty ordering table a game draws into.

		The one channel that touches no device — it only writes RAM, and what it writes is a chain
		of addresses each pointing at the word below it, ending in the same bit-23 terminator that
		stops channel 2's walk. That chain *is* the ordering table: `ClearOTagR` is this transfer
		and nothing else, and every frame begins with it.

		Which makes its absence quietly total. A game clears its table, fills it with primitives,
		and hands it to channel 2 — but a table that was never built holds whatever was in that
		memory, so the walk either ends immediately or never, and either way nothing is drawn. Crash
		Bash reports it in its own words, once per frame: "empty prims".

		Runs downwards from MADR, as psx-spx describes, with the last word written — the lowest
		address — carrying the end marker.
	**/
	static function clearOrderingTable():Void {
		final count = bcr[CH_OTC] & 0xFFFF;
		final n = count == 0 ? 0x10000 : count;
		var addr = madr[CH_OTC] & 0x1FFFFC;
		for (i in 0...n) {
			// Every entry points at the one below it; the last one ends the list.
			Memory.write32(addr, i == n - 1 ? 0x00FFFFFF : ((addr - 4) & 0xFFFFFF));
			addr -= 4;
		}
		tablesCleared++;
		madr[CH_OTC] = addr & 0xFFFFFF;
	}

	/** Ordering tables built. One per frame, in a game that is drawing. */
	public static var tablesCleared(default, null) = 0;

	static function unimplementedChannel(ch:Int):Void {
		Runtime.reportOnce(0x6C000000 | ch, "DMA channel " + ch + " has no device behind it yet");
	}

	/** Clears busy and raises the channel's interrupt if the game asked for one. */
	static function finish(ch:Int):Void {
		chcr[ch] = chcr[ch] & ~(CHCR_BUSY | CHCR_TRIGGER);
		final enable = (dicr >>> 16) & 0x7F;
		if ((enable & (1 << ch)) == 0) return;
		else {}
		dicr = dicr | (1 << (24 + ch));
		if ((dicr & 0x00800000) != 0) Irq.raiseLine(Irq.DMA);
		else {}
	}
}
