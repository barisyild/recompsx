import core.CpuState;
import core.Irq;
import core.Runtime;
import kernel.KPads;
import mem.Memory;
import sio.Pads;

/**
	The BIOS controller driver under HLE (kernel.KPads): InitPAD's buffers as the vblank handler
	leaves them, and PAD_init/PAD_dr's packed answer — the formats psx-spx "BIOS Joypad Functions"
	and OpenBIOS's sio0 driver define, which a libetc game reads byte for byte.
**/
class PadBios {
	static inline var BUF1 = 0x80100000;
	static inline var BUF2 = 0x80100040;
	static inline var DEST = 0x80100080;
	static inline var VBLANK = 1 << 0;

	public static function main():Void {
		final ctx = new CpuState();
		Runtime.boot(ctx);
		// Pad 1: Cross and Left held; pad 2 empty.
		Pads.set(0, true, 0x4000 | 0x0080);
		Pads.set(1, false, 0);

		// Garbage first, so the zero-fill is visible.
		for (i in 0...0x22) {
			Memory.write8(BUF1 + i, 0xAA);
			Memory.write8(BUF2 + i, 0xAA);
		}
		Conf.expect("InitPAD returns 1", KPads.initPad(BUF1, 0x22, BUF2, 0x22), 1);
		Conf.expect("InitPAD zero-fills buffer 1", Memory.read8u(BUF1 + 0x21), 0);
		Conf.expect("and buffer 2", Memory.read8u(BUF2 + 0x10), 0);

		// Not started: a vblank changes nothing.
		KPads.onInterrupt(VBLANK);
		Conf.expect("before StartPAD, no read", Memory.read8u(BUF2), 0);

		KPads.startPad();
		Conf.expect("StartPAD unmasks vblank", Irq.readMask() & VBLANK, VBLANK);
		KPads.onInterrupt(0);
		Conf.expect("no vblank, no read", Memory.read8u(BUF2), 0);
		KPads.onInterrupt(VBLANK);
		Conf.expect("pad 1 status: read", Memory.read8u(BUF1), 0x00);
		Conf.expect("pad 1 ID: digital", Memory.read8u(BUF1 + 1), 0x41);
		Conf.expect("pad 1 low byte: Left pressed", Memory.read8u(BUF1 + 2), 0x7F);
		Conf.expect("pad 1 high byte: Cross pressed", Memory.read8u(BUF1 + 3), 0xBF);
		Conf.expect("pad 2 status: no answer", Memory.read8u(BUF2), 0xFF);
		Conf.expect("pad 2 keeps its old ID byte", Memory.read8u(BUF2 + 1), 0x00);
		for (i in 0...6) {
			Conf.feed(Memory.read8u(BUF1 + i));
			Conf.feed(Memory.read8u(BUF2 + i));
		}

		// Unplugging pad 1 leaves its old data behind a status of FFh.
		Pads.set(0, false, 0);
		KPads.onInterrupt(VBLANK);
		Conf.expect("an unplugged pad reads FFh", Memory.read8u(BUF1), 0xFF);
		Conf.expect("its last buttons stay", Memory.read8u(BUF1 + 2), 0x7F);
		KPads.stopPad();
		Pads.set(0, true, 0);
		KPads.onInterrupt(VBLANK);
		Conf.expect("after StopPAD, no read", Memory.read8u(BUF1), 0xFF);

		// PAD_init: only its two types, then PAD_dr's packed, byte-swapped halfwords at the target.
		Conf.expect("PAD_init refuses another type", KPads.padInit(0x10000001, DEST), 0);
		Conf.expect("PAD_init takes 20000001h", KPads.padInit(0x20000001, DEST), 2);
		Pads.set(0, true, 0x0008);      // Start
		Pads.set(1, true, 0x8000);      // Square
		KPads.onInterrupt(VBLANK);
		final both = Memory.read32(DEST);
		Conf.feed(both);
		Conf.expect("pad 1: bytes swapped, Start pressed", both & 0xFFFF, 0xF7FF);
		Conf.expect("pad 2: Square pressed", (both >>> 16) & 0xFFFF, 0xFF7F);
		Pads.set(1, false, 0);
		KPads.onInterrupt(VBLANK);
		Conf.expect("PAD_dr: a missing pad reads FFFFh", (KPads.padDr() >>> 16) & 0xFFFF, 0xFFFF);

		Conf.report("PadBios");
	}
}
