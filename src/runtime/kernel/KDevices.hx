package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;

/**
	The kernel's file and device control blocks, in RAM where games look for them.

	psx-spx "BIOS Memory Map": the table of tables at 100h points, at 140h, to sixteen 2Ch-byte
	FCBs — one per descriptor — and, at 150h, to the device table, 50h bytes a device: its name,
	its flags and block size, a description, and seventeen function pointers (psx-spx "BIOS
	Control Blocks"; OpenBIOS `struct Device` and `struct File`, psxlibc/device.h and stdio.h,
	MIT). Here those are the kernel's tty, cdrom and bu, and every function pointer is a stub in
	the BIOS window, one per device and function, which `Runtime` hands back to this class when a
	game jumps to it.

	Games do more than read these. Psy-Q's libcard finds the "bu" device, puts a function of its own
	in its firstfile slot, calls firstfile — which the BIOS runs through that slot — and from there
	calls the original through the pointer it saved, having marked the search FCB as taken, which
	the BIOS forgets to do. So firstfile and nextfile go through the device table here too: a slot
	still holding its stub runs the kernel's own code at once, and a slot a game changed runs the
	game's function, with the FCB it expects. The other slots are laid out for a game to read and
	are not yet called through: no game has been seen replacing one (ADR-0037).
**/
class KDevices {
	static inline var FCB_TABLE = 0x0000E000;
	public static inline var FCB_SIZE = 0x2C;
	static inline var FCB_COUNT = 16;
	static inline var DCB_TABLE = 0x0000E300;
	static inline var DCB_SIZE = 0x50;
	static inline var DCB_COUNT = 10;
	static inline var STRINGS = 0x0000E700;

	// Devices, in table order.
	public static inline var TTY = 0;
	public static inline var CDROM = 1;
	public static inline var BU = 2;

	// FCB fields (OpenBIOS `struct File`).
	public static inline var FCB_FLAGS = 0x00;
	public static inline var FCB_DEVICE_ID = 0x04;
	public static inline var FCB_ERRNO = 0x18;
	public static inline var FCB_DEVICE = 0x1C;
	public static inline var FCB_FD = 0x28;

	// DCB slots (OpenBIOS `struct Device`): the function pointers start at 10h.
	static inline var SLOT_FIRST = 0x10;
	public static inline var FIRSTFILE = 0x34;
	public static inline var NEXTFILE = 0x38;

	/** Stubs in the BIOS window, after the A0/B0/C0 ones (`KTables`): one per device and slot. */
	static inline var STUB_BASE = 0x1FC02800;
	static inline var STUB_STRIDE = 8;

	public static function init():Void {
		for (i in 0...(FCB_COUNT * FCB_SIZE)) Memory.write8(FCB_TABLE + i, 0);
		for (i in 0...(DCB_COUNT * DCB_SIZE)) Memory.write8(DCB_TABLE + i, 0);
		for (fd in 0...FCB_COUNT) Memory.write32(fcb(fd) + FCB_FD, fd);
		// The three the kernel opens on the console, as `KFiles` has them.
		for (fd in 0...3) {
			Memory.write32(fcb(fd) + FCB_FLAGS, fd == 0 ? 1 : 2);
			Memory.write32(fcb(fd) + FCB_DEVICE, dcb(TTY));
		}
		Memory.write32(0x140, 0x80000000 | FCB_TABLE);
		Memory.write32(0x144, FCB_COUNT * FCB_SIZE);
		Memory.write32(0x150, 0x80000000 | DCB_TABLE);
		Memory.write32(0x154, DCB_COUNT * DCB_SIZE);
		var at = STRINGS;
		at = device(TTY, at, "tty", "CONSOLE", 0x03, 0x01);
		at = device(CDROM, at, "cdrom", "CD-ROM", 0x14, 0x800);
		device(BU, at, "bu", "MEMORY CARD", 0x14, 0x80);
	}

	/** A device's DCB: name and description strings placed at `at`; the address after them. */
	static function device(index:Int, at:Int, name:String, desc:String, flags:Int, block:Int):Int {
		final d = DCB_TABLE + index * DCB_SIZE;
		var p = at;
		Memory.write32(d + 0x00, 0x80000000 | p);
		p = string(p, name);
		Memory.write32(d + 0x04, flags);
		Memory.write32(d + 0x08, block);
		Memory.write32(d + 0x0C, 0x80000000 | p);
		p = string(p, desc);
		var slot = SLOT_FIRST;
		while (slot < DCB_SIZE) {
			Memory.write32(d + slot, stubFor(index, slot));
			slot += 4;
		}
		return (p + 3) & ~3;
	}

	static function string(at:Int, s:String):Int {
		for (i in 0...s.length) {
			final c = s.charCodeAt(i);
			Memory.write8(at + i, c == null ? 0 : c);
		}
		Memory.write8(at + s.length, 0);
		return at + s.length + 1;
	}

	/** The address of descriptor `fd`'s FCB, as the game sees it. */
	public static inline function fcb(fd:Int):Int return 0x80000000 | (FCB_TABLE + fd * FCB_SIZE);

	/** A device's DCB, as the game sees it. */
	public static inline function dcb(index:Int):Int return 0x80000000 | (DCB_TABLE + index * DCB_SIZE);

	public static inline function stubFor(index:Int, slot:Int):Int
		return STUB_BASE + ((index * 0x20 + (slot >> 2)) * STUB_STRIDE);

	/** The device and slot a BIOS-window address is the stub of, as index * 100h + slot; or -1. */
	public static function callAt(addr:Int):Int {
		final off = (addr & 0x1FFFFFFF) - STUB_BASE;
		var found = -1;
		if (off >= 0 && off < 3 * 0x20 * STUB_STRIDE && (off & (STUB_STRIDE - 1)) == 0) {
			final n = off >> 3;
			found = ((n >> 5) << 8) | ((n & 0x1F) << 2);
		} else {}
		return found;
	}

	/**
		A device function reached through its stub — a game calling the one it saved before putting
		its own in the slot. The arguments are the BIOS's: the FCB first. False for one the kernel
		does not call through the table, which `Runtime` then reports.
	**/
	public static function callStub(ctx:CpuState, target:Int):Bool {
		final index = target >> 8;
		final slot = target & 0xFF;
		var handled = true;
		if (index == BU && slot == FIRSTFILE) ctx.v0 = buFirstFile(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (index == BU && slot == NEXTFILE) ctx.v0 = buNextFile(ctx, ctx.a0, ctx.a1);
		else handled = false;
		return handled;
	}

	/**
		OpenBIOS `firstFile` and `nextFile` (fileio/filesystem.c, MIT): the device's slot, called
		with the search FCB — the kernel's own function if the slot still holds its stub, else
		whatever the game put there.
	**/
	public static function firstFile(ctx:CpuState, index:Int, fcbAt:Int, nameAt:Int, entryAt:Int):Int {
		final f = Memory.read32(dcb(index) + FIRSTFILE);
		var result = 0;
		if (f == stubFor(index, FIRSTFILE)) result = buFirstFile(ctx, fcbAt, nameAt, entryAt);
		else result = callGame(ctx, f, fcbAt, nameAt, entryAt);
		return result;
	}

	public static function nextFile(ctx:CpuState, fcbAt:Int, entryAt:Int):Int {
		final d = Memory.read32(fcbAt + FCB_DEVICE);
		final f = Memory.read32(d + NEXTFILE);
		var result = 0;
		if (d == dcb(BU) && f == stubFor(BU, NEXTFILE)) result = buNextFile(ctx, fcbAt, entryAt);
		else result = callGame(ctx, f, fcbAt, entryAt, 0);
		return result;
	}

	static function buFirstFile(ctx:CpuState, fcbAt:Int, nameAt:Int, entryAt:Int):Int {
		final result = KBu.firstFile(ctx, Memory.read32(fcbAt + FCB_DEVICE_ID), nameAt, entryAt);
		Memory.write32(fcbAt + FCB_ERRNO, KBu.lastScratchError());
		return result;
	}

	static function buNextFile(ctx:CpuState, fcbAt:Int, entryAt:Int):Int {
		final result = KBu.nextFile(ctx, entryAt);
		Memory.write32(fcbAt + FCB_ERRNO, KBu.lastScratchError());
		return result;
	}

	/** A game's function in a device slot, called as the BIOS calls it; its v0. */
	static function callGame(ctx:CpuState, f:Int, a:Int, b:Int, c:Int):Int {
		final ra = ctx.ra;
		final pc = ctx.pc;
		ctx.a0 = a;
		ctx.a1 = b;
		ctx.a2 = c;
		ctx.pc = f;
		Runtime.call(ctx, f);
		ctx.ra = ra;
		ctx.pc = pc;
		return ctx.v0;
	}
}
