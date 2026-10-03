package dma;

import core.Irq;
import core.Runtime;
import core.Scheduler;
import gpu.Gpu;
import mem.Memory;
import shim.Backend;
import shim.MemA;

/**
	The DMA controller — and, for a PlayStation game, the thing that actually draws.

	Psy-Q does not write GP0 a word at a time. `DrawOTag` hands the GPU an *ordering table*: a
	backwards-linked chain in RAM where each node carries a word count and the packets that follow
	it, and channel 2 walks it. So a runtime with a working GPU port and no DMA sees a game submit
	its display list into nothing and render an empty screen while looking perfectly healthy —
	which is exactly what this one did, twenty-nine GP0 words in eight minutes of play.

	Transfers complete instantly — except channel 2's ordering table, which the channel walks a node
	at a time while the CPU runs on, reading each node from RAM when it gets there. Games write
	packets into a table they have already handed over, and on hardware those are drawn if the walk
	has not passed them yet: Crash Bash's pause menu puts its text in that way, and a walk done at
	the moment the transfer starts drew the boxes and lost the text (as it did in PCSX-ReARMed
	until "slow linked list walking", which lists this game). The walk costs a cycle a word and a
	cycle a node, the channel's own rate, plus the time the GPU would take to draw what each node
	carries (`Gpu.takeWork`): the channel feeds a 16-word FIFO, so on hardware it goes at the speed
	the GPU draws — at a cycle a word alone, Crash Bash's last menu line was still written after
	the walk had passed it. Every other transfer is busy for no emulated time, and a game that
	polls CHCR bit 24 sees it already clear.
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
		listAt = -1;
		listClock = 0;
		listLinks = 0;
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
		// Clearing the start bit stops a list the channel is still walking.
		if (ch == CH_GPU && listAt >= 0 && (v & CHCR_BUSY) == 0) stopList();
		else {}
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
		if (ch == CH_GPU && sync == 2) startList();
		else {
			if (ch == CH_GPU) toGpu();
			else if (ch == CH_CDROM) sectorToRam();
			else if (ch == CH_SPU) ramToSpu();
			else if (ch == CH_OTC) clearOrderingTable();
			else unimplementedChannel(ch);
			finish(ch);
		}
	}

	/**
		Channel 2, bracketed for a backend that shows where a frame goes (the Dreamcast's overlay):
		walking the list, decoding each primitive and handing it to the backend is the drawing
		that happens inside the emulated frame. 99.9 % of Crash Bash's GP0 words arrive through the
		list, so the direct port writes are left unbracketed rather than marked once a word.
	**/
	static function toGpu():Void {
		Backend.profileMark(Backend.PROFILE_GPU, 1);
		blockToGpu();
		Backend.profileMark(Backend.PROFILE_GPU, 0);
	}

	/**
		The ordering table: each node is a header word holding a word count and the address of the
		next node, followed by that many packet words.

		Walked forwards from MADR through the `next` links, which run *backwards* through memory
		because a game builds its table back to front — nearest last. The terminator is any address
		with bit 23 set, which is how the BIOS's own `ClearOTagR` ends a table.

		A stretch of `LIST_STEP` cycles at a time (see the class comment): the first when CHCR
		starts the channel, the rest on `Scheduler.DMA_STEP`, each due when the one before it would
		have finished — the channel's own clock, so a pump that comes late catches up rather than
		stretching the walk. Most of an ordering table is empty nodes, which only link on: 71 % of
		the 4.1 M nodes Crash Bash walks in vblanks 18800-20300; they cost their header's cycle and
		nothing else. A table that neither ends nor repeats is given up on after 65536 links, the
		nodes up to there drawn, as before.
	**/
	static inline var LIST_STEP = 256;

	/** The node the walk goes on from, or -1 when no list is being walked. */
	static var listAt = -1;
	/** When the walk's next stretch is due: its own clock, advanced by what each one cost. */
	static var listClock = 0;
	static var listLinks = 0;

	/** A list is being walked: the frame the GPU is drawing is not finished. Only presentation
	    reads it (Scanout's PRESENT_DRAWING); nothing that runs the machine does. */
	public static inline function listWalking():Bool return listAt >= 0;

	static function startList():Void {
		listAt = madr[CH_GPU] & 0x1FFFFC;
		listLinks = 0;
		listClock = Memory.cycleHint();
		// What the GPU was given before, through its port, is not this walk's to wait for.
		Gpu.takeWork();
		stepList();
	}

	/** Scheduler.DMA_STEP: the next stretch of the list. */
	public static function onEvent(ctx:core.CpuState):Void {
		if (listAt >= 0) stepList();
		else {}
	}

	/** Out of line on C++ for the reason `Gpu.polygonHw` gives: inlined into the register write
	    that starts it, the walk shared one starved frame with everything else in `slowWrite32`. */
	@:specifier("__attribute__((noinline))")
	static function stepList():Void {
		Backend.profileMark(Backend.PROFILE_GPU, 1);
		final ram = Memory.ram();
		var addr = listAt;
		var spent = 0;
		var state = LIST_GOING;
		// The counters in locals for the step, stored back once at its end: a node is a handful of
		// instructions, and two statics read and written for each were a fair part of them.
		var links = listLinks;
		var words = wordsToGpu;
		while (state == LIST_GOING && spent < LIST_STEP) {
			final header = MemA.get32(ram, addr);
			// The next node's line on its way while this node's words are drawn: a list is a chain
			// through RAM in no order the cache can guess, and each header was a miss.
			MemA.prefetch(ram, header & 0x1FFFFC);
			final count = (header >>> 24) & 0xFF;
			// Straight from RAM into GP0, not through the CPU's memory map: the channel only ever
			// addresses RAM, wrapping at 2 MB exactly as `Memory.read32`'s decode does for these
			// addresses, and GP0 is all 0x1F801810 is. Going through `write32` cost each word a
			// read, a write, a region search and three calls — half of all the time spent in this
			// channel, measured on the hardware-drawing path. The GPU takes the node whole.
			if (count != 0) {
				Gpu.writeGp0Words(ram, addr + 4, count);
				words = (words + count) | 0;
			} else {}
			// The channel's own cycle a word, and however long the GPU takes to draw what it was
			// handed, since its FIFO holds sixteen words and the channel waits on it.
			spent += count + 1 + Gpu.takeWork();
			// Bit 23 of the link marks the end.
			if ((header & 0x800000) != 0) state = LIST_ENDED;
			else {
				links++;
				if (links > 0x10000) state = LIST_RUNAWAY;
				else {
					addr = header & 0x1FFFFC;
					// An ordering table's untouched entries follow one another by the hundred: each
					// is a link and the channel's cycle, no words, and no GPU work — this node took
					// what there was, and nothing has drawn since. The loop above for one costs its
					// counters kept in memory around the GPU's calls; here they stay in registers.
					// Exactly as that loop would walk them: while one is empty (no count, no end
					// bit), the step has cycles left and the link count is short of a runaway.
					var next = MemA.get32(ram, addr);
					while ((next & 0xFF800000) == 0 && spent < LIST_STEP && links < 0x10000) {
						spent++;
						links++;
						addr = next & 0x1FFFFC;
						next = MemA.get32(ram, addr);
					}
				}
			}
		}
		listLinks = links;
		wordsToGpu = words;
		Backend.profileMark(Backend.PROFILE_GPU, 0);
		listClock = (listClock + spent) | 0;
		if (state == LIST_GOING) {
			listAt = addr;
			Scheduler.scheduleAt(Scheduler.DMA_STEP, listClock);
		} else endList(state == LIST_ENDED);
	}

	static inline var LIST_GOING = 0;
	static inline var LIST_ENDED = 1;
	static inline var LIST_RUNAWAY = 2;

	static function endList(ended:Bool):Void {
		listAt = -1;
		if (ended) {
			listsWalked++;
			madr[CH_GPU] = 0xFFFFFF;
		} else runaway();
		finish(CH_GPU);
	}

	/** The game took the start bit back: the walk stops where it is, and nothing more is sent. */
	static function stopList():Void {
		listAt = -1;
		Scheduler.cancelSlot(Scheduler.DMA_STEP);
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
		// Direction bit 0: 1 is RAM to device, 0 the other way.
		if ((chcr[CH_GPU] & 1) == 0) return blockFromGpu(total);
		else {}
		final ram = Memory.ram();
		var i = 0;
		while (i < total) {
			// An upload's words go to VRAM a row at a time (Gpu.uploadRun); the rest, commands.
			final used = Gpu.uploading() ? Gpu.uploadRun(ram, addr, total - i) : 0;
			if (used > 0) {
				addr += used << 2;
				i += used;
			} else {
				inline Gpu.writeGp0(MemA.get32(ram, addr & 0x1FFFFC));   // as stepList
				addr += 4;
				i++;
			}
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
		// Forwards and inside RAM, which is every read a game makes: the sector in one copy
		// (Cdrom.dmaCopy stores what that many dmaWord calls would). Otherwise word by word.
		if (step == 4 && addr + (total << 2) <= 0x200000) {
			cd.Cdrom.dmaCopy(Memory.ram(), addr, total);
			addr += total << 2;
		} else {
			for (i in 0...total) {
				Memory.write32(addr, cd.Cdrom.dmaWord());
				addr += step;
			}
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

	/**
		Channel 2 the other way: GPUREAD into RAM, which is how a game takes VRAM back after
		GP0(C0h) — libgpu's StoreImage. Each word is what a read of the port gives, the rectangle's
		pixels while it lasts and the latch after, and the address steps as CHCR bit 1 says.
	**/
	static function blockFromGpu(total:Int):Void {
		final step = (chcr[CH_GPU] & 2) != 0 ? -4 : 4;
		final ram = Memory.ram();
		var addr = madr[CH_GPU] & 0x1FFFFC;
		for (i in 0...total) {
			MemA.set32(ram, addr & 0x1FFFFC, Gpu.readData());
			addr += step;
		}
		madr[CH_GPU] = addr & 0xFFFFFF;
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
		// Inside RAM, the block in runs (Spu.dmaCopy, wrapping at the end of sound RAM as
		// pushHalfword does); a block reaching past RAM's end, word by word.
		if (addr + (total << 2) <= 0x200000) {
			spu.Spu.dmaCopy(Memory.ram(), addr, total);
			addr += total << 2;
		} else {
			for (i in 0...total) {
				spu.Spu.dmaWord(Memory.read32(addr));
				addr += 4;
			}
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
		// A table that stays inside RAM is stored directly — what Memory.write32 would do there,
		// without asking which region each word is in. One running below RAM's first word goes
		// through the memory map, as it always did.
		// Every entry but the last points at the word below it, which inside RAM is its own address
		// less four as it stands: one store and one subtract a word, and the last one after the
		// loop rather than a test for it in every turn (Crash Bash clears thousands a frame).
		final last = addr - ((n - 1) << 2);
		if (last >= 0) {
			final ram = Memory.ram();
			while (addr > last) {
				MemA.set32(ram, addr, addr - 4);
				addr -= 4;
			}
			MemA.set32(ram, last, 0x00FFFFFF);
			addr = last - 4;
		} else {
			for (i in 0...n) {
				// Every entry points at the one below it; the last one ends the list.
				Memory.write32(addr, i == n - 1 ? 0x00FFFFFF : ((addr - 4) & 0xFFFFFF));
				addr -= 4;
			}
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
