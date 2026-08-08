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
	}

	public static inline function contains(p:Int):Bool {
		return p >= BASE && p <= 0x1F8010FF;
	}

	public static function read(p:Int):Int {
		if (p == 0x1F8010F0) return dpcr;
		else if (p == 0x1F8010F4) return dicr;
		else return channelRead(p);
	}

	static function channelRead(p:Int):Int {
		final ch = (p - BASE) >> 4;
		if (ch < 0 || ch > 6) return 0;
		else {}
		final reg = p & 0xF;
		if (reg == MADR) return madr[ch];
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
	static function writeDicr(v:Int):Void {
		final acked = (v >>> 24) & 0x7F;
		dicr = (v & 0x00FFFFFF) | (((dicr >>> 24) & ~acked & 0x7F) << 24);
	}

	static function channelWrite(p:Int, v:Int):Void {
		final ch = (p - BASE) >> 4;
		if (ch < 0 || ch > 6) return;
		else {}
		final reg = p & 0xF;
		if (reg == MADR) madr[ch] = v & 0xFFFFFF;
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

	static function notReadable():Void {
		Runtime.reportOnce(0x6B000001, "DMA read from the GPU, which has no VRAM to give yet");
	}

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
