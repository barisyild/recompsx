package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;
import shim.Backend;
import shim.RawBuf;
import shim.RawMem;

/**
	File descriptors, and the devices behind them.

	The PlayStation kernel presents everything as files: the TTY, the CD-ROM, and the memory cards
	all open by name and are read and written through the same six calls. Most of what a game does
	with them is print debug text — `write(1, ...)` is where a Psy-Q `printf` ends up once a game
	has linked its own rather than the kernel's, so this is often the only place a game says
	anything about itself.

	The device set here is honest about what exists: the TTY, `cdrom:` — a mounted image, or a
	directory of files extracted from one — and the memory cards, `bu00:` and `bu10:`, whose files
	`KBu` keeps. Anything else fails to open, and says which name it was: a failed open is
	something games handle, a silent wrong answer is not.

	Function numbers from psx-spx "BIOS Function Summary": the same calls appear on both vectors,
	A0(00h..05h) and B0(32h..37h), which is why both route here.
**/
class KFiles {
	static inline var MAX_FD = 16;

	// Device kinds a descriptor can name.
	static inline var DEV_NONE = 0;
	static inline var DEV_TTY = 1;
	static inline var DEV_CD = 2;
	static inline var DEV_BU = 3;

	static var kind:Array<Int>;

	/** Per-descriptor backend slot and read position, for the ones that are real files. */
	static var slot:Array<Int>;
	static var pos:Array<Int>;

	/** For descriptors inside an image: the file's first sector and its length. */
	static var lba:Array<Int>;
	static var size:Array<Int>;

	/**
		Where `cdrom:` reads from.

		Two shapes of disc exist in practice and this is the simpler one: a directory of files
		already extracted from the image. It needs no ISO9660 and no sector arithmetic, and it is
		what someone reverse-engineering a game usually has to hand — which makes it the fastest
		route from "the kernel works" to "the game has its data". A real BIN/CUE goes through
		`shared/psxdisc` and lands on the same device from underneath.
	**/
	static var discDir = "";

	/** Backend slot reserved for a mounted disc image, or -1 when `cdrom:` is a directory. */
	static inline var IMAGE_SLOT = 7;
	static var imageMounted = false;

	public static function mountDirectory(path:String):Void {
		discDir = path;
		imageMounted = false;
		Runtime.noteOnce(0x59100000, "cdrom: is a directory of extracted files at " + path);
	}

	/**
		Mounts a disc image, or says it is not one.

		Tried before the directory because it is the stricter test: an image either has a volume
		descriptor where one of the known sector layouts would put it, or it does not. A path that
		fails this is offered to `mountDirectory`, so a caller can hand over either shape without
		having to know which it has.
	**/
	public static function mountImage(path:String):Bool {
		if (Backend.fileOpen(IMAGE_SLOT, path) != 0) return false;
		else {}
		if (!cd.Iso9660.mount(IMAGE_SLOT)) return notAnImage();
		else {}
		imageMounted = true;
		discDir = "";
		return true;
	}

	static function notAnImage():Bool {
		Backend.fileClose(IMAGE_SLOT);
		return false;
	}

	public static function discAvailable():Bool {
		return imageMounted || discDir != "";
	}

	/** Bytes written to the TTY. A game that says nothing is a different problem from one that fails. */
	public static var ttyBytes(default, null) = 0;

	public static function init():Void {
		kind = [for (_ in 0...MAX_FD) DEV_NONE];
		slot = [for (_ in 0...MAX_FD) -1];
		pos = [for (_ in 0...MAX_FD) 0];
		lba = [for (_ in 0...MAX_FD) 0];
		size = [for (_ in 0...MAX_FD) 0];
		// Allocated here rather than on first read: RawBuf is a value type on C++ and cannot be
		// null, so there is nothing to test for. Nothing allocates after boot in any case.
		staging = RawMem.alloc(STAGING);
		// The BIOS hands these out already open, as any C runtime expects.
		kind[0] = DEV_TTY;   // stdin, which never has anything to give
		kind[1] = DEV_TTY;   // stdout
		kind[2] = DEV_TTY;   // stderr
		searchFd = -1;
		ttyBytes = 0;
	}

	/** Dispatch for the file range of either vector. False if `fn` is not one of ours. */
	public static function callA0(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x00) ctx.v0 = open(ctx, ctx.a0, ctx.a1);
		else if (fn == 0x01) ctx.v0 = lseek(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x02) ctx.v0 = read(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x03) ctx.v0 = write(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x04) ctx.v0 = close(ctx, ctx.a0);
		else if (fn == 0x07) ctx.v0 = isatty(ctx.a0);
		else if (fn == 0x09) ctx.v0 = putc(ctx.a0, ctx.a1);
		else return false;
		return true;
	}

	public static function callB0(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x32) ctx.v0 = open(ctx, ctx.a0, ctx.a1);
		else if (fn == 0x33) ctx.v0 = lseek(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x34) ctx.v0 = read(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x35) ctx.v0 = write(ctx, ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x36) ctx.v0 = close(ctx, ctx.a0);
		else if (fn == 0x39) ctx.v0 = isatty(ctx.a0);
		else if (fn >= 0x41 && fn <= 0x46) return cardCall(ctx, fn);
		else return false;
		return true;
	}

	/**
		B(41h) format, B(42h) firstfile, B(43h) nextfile, B(44h) rename, B(45h) erase and B(46h)
		undelete, when they name a card; false for any other device, which the kernel reports.
	**/
	static function cardCall(ctx:CpuState, fn:Int):Bool {
		var ours = true;
		if (fn == 0x43) {
			if (searchFd >= 0 && Memory.read32(KDevices.fcb(searchFd) + KDevices.FCB_DEVICE) == KDevices.dcb(KDevices.BU))
				ctx.v0 = KDevices.nextFile(ctx, KDevices.fcb(searchFd), ctx.a0);
			else ours = false;
		} else if (!parseDevice(ctx.a0) || parsedDevice != "bu") ours = false;
		else if (fn == 0x41) ctx.v0 = KBu.format(ctx, parsedId);
		else if (fn == 0x42) ctx.v0 = firstFile(ctx);
		else if (fn == 0x44) ctx.v0 = renameOnCard(ctx);
		else if (fn == 0x45) ctx.v0 = freeFcb() ? KBu.erase(ctx, parsedId, parsedFile) : tooManyOpen();
		else {
			Runtime.reportOnce(0xB0046, "B0(46h) undelete — not in the BIOS's behaviour we follow; says 0");
			ctx.v0 = 0;
		}
		return ours;
	}

	/**
		B(42h) firstfile on a card, as OpenBIOS `firstFile` (fileio/filesystem.c, MIT): the search
		FCB is the first free one, found once and kept — and not marked as taken, the BIOS's slip —
		and the device's firstfile slot is called with it (`KDevices`).
	**/
	static function firstFile(ctx:CpuState):Int {
		if (searchFd < 0) {
			for (fd in 0...MAX_FD) {
				if (searchFd < 0 && kind[fd] == DEV_NONE && Memory.read32(KDevices.fcb(fd)) == 0) searchFd = fd;
				else {}
			}
		} else {}
		var result = 0;
		if (searchFd < 0) Kernel.lastError = 0x18;
		else {
			final f = KDevices.fcb(searchFd);
			Memory.write32(f + KDevices.FCB_DEVICE_ID, parsedId);
			Memory.write32(f + KDevices.FCB_DEVICE, KDevices.dcb(KDevices.BU));
			result = KDevices.firstFile(ctx, KDevices.BU, f, parsedFile, ctx.a1);
		}
		return result;
	}

	/** The FCB firstfile and nextfile search with, OpenBIOS `g_firstFile`; -1 before the first. */
	static var searchFd = -1;

	static function renameOnCard(ctx:CpuState):Int {
		final id = parsedId;
		final from = parsedFile;
		var result = 0;
		if (!parseDevice(ctx.a1) || parsedDevice != "bu") {
			Kernel.lastError = 0x13;
			result = 0;
		} else result = KBu.rename(ctx, id, from, parsedId, parsedFile);
		return result;
	}

	/** Whether an FCB is free for erase's temporary use: with all sixteen open, it fails. */
	static function freeFcb():Bool {
		var free = false;
		for (fd in 3...MAX_FD) free = free || kind[fd] == DEV_NONE;
		return free;
	}

	static function tooManyOpen():Int {
		Kernel.lastError = 0x18;
		return 0;
	}

	/** B(55h) _get_error(fd): a card file's own error; for the others, the last one. */
	public static function errorOf(fd:Int):Int {
		var e = -1;
		if (valid(fd)) e = kind[fd] == DEV_BU ? KBu.errorOf(fd) : Kernel.lastError;
		else {}
		return e;
	}

	// ---- device names ------------------------------------------------------------------------------

	/**
		OpenBIOS `splitFilepathAndFindDevice` (fileio/misc.c, MIT): leading spaces skipped, the
		device's name up to the colon, and the digits at its end read as a port — decimal digits
		at hex place values, so "bu10" is 10h. False when there is no colon.
	**/
	static function parseDevice(p:Int):Bool {
		var at = p;
		while (Memory.read8u(at) == 0x20) at++;
		var name = "";
		var id = 0;
		var digits = false;
		var c = Memory.read8u(at);
		var n = 0;
		while (c != 0x3A && c != 0 && n < 32) {
			final digit = c >= 0x30 && c <= 0x39;
			if (digit || digits) {
				digits = true;
				id = ((id << 4) + (digit ? c - 0x30 : 0)) | 0;
			} else name += String.fromCharCode(c);
			at++;
			n++;
			c = Memory.read8u(at);
		}
		parsedDevice = name;
		parsedId = id;
		parsedFile = (at + 1) | 0;
		return c == 0x3A;
	}

	static var parsedDevice = "";
	static var parsedId = 0;
	static var parsedFile = 0;

	// ---- the calls -----------------------------------------------------------------------------

	/**
		Only `tty:` opens. Everything else fails, and says which name it was.

		A failing open is a normal thing for a game to meet and handle. Returning a descriptor that
		then reads zeroes would be worse: the game would believe it had its data.
	**/
	static function open(ctx:CpuState, nameAddr:Int, mode:Int):Int {
		if (isTty(nameAddr)) return allocate(DEV_TTY);
		else if (parseDevice(nameAddr) && parsedDevice == "bu") return openOnCard(ctx, mode);
		else if (imageMounted) return openInImage(nameOf(nameAddr));
		else if (discDir != "") return openOnDisc(nameOf(nameAddr));
		else return unknownDevice(nameAddr);
	}

	/** A file on a card: `KBu` opens it, or the descriptor goes back and the error is the game's. */
	static function openOnCard(ctx:CpuState, mode:Int):Int {
		final fd = allocate(DEV_BU);
		if (fd < 0) {
			Kernel.lastError = 0x18;
			return -1;
		} else {}
		if (!KBu.open(ctx, fd, parsedId, parsedFile, mode)) {
			release(fd);
			Kernel.lastError = KBu.errorOf(fd);
			return -1;
		} else {}
		return fd;
	}

	/**
		Opens a file the game named the way the kernel expects: `cdrom:\\DIR\\NAME.EXT;1`.

		The mangling is all convention. The device prefix goes, backslashes become the host's
		separator, and the `;1` version suffix that ISO9660 puts on every file is dropped — games
		write it because the format demands it, not because they mean anything by it.
	**/
	static function openOnDisc(name:String):Int {
		final fd = allocate(DEV_CD);
		if (fd < 0) return -1;
		else {}
		final s = freeBackendSlot();
		if (s < 0) return closeAndFail(fd);
		else {}
		if (Backend.fileOpen(s, discDir + "/" + hostPath(name)) != 0) return notOnDisc(fd, name);
		else {}
		slot[fd] = s;
		pos[fd] = 0;
		return fd;
	}

	/**
		Opens a file inside a mounted image.

		The descriptor holds the file's starting sector rather than a backend slot: reads go
		through `Iso9660`, which knows how to skip whatever the sector layout wraps the user bytes
		in. A raw 2352-byte image is not contiguous, so this cannot be a plain byte offset.
	**/
	static function openInImage(name:String):Int {
		final path = isoPath(name);
		if (!cd.Iso9660.find(path)) return reportMissing(path);
		else {}
		final fd = allocate(DEV_CD);
		if (fd < 0) return -1;
		else {}
		slot[fd] = -1;
		lba[fd] = cd.Iso9660.foundLba;
		size[fd] = cd.Iso9660.foundSize;
		pos[fd] = 0;
		return fd;
	}

	static function reportMissing(path:String):Int {
		Runtime.reportOnce(0x59400000 + path.length, "not in the image: " + path);
		return -1;
	}

	/** Strips the device prefix, leaving the path the volume descriptor would recognise. */
	static function isoPath(name:String):String {
		final colon = name.indexOf(":");
		return colon >= 0 ? name.substr(colon + 1) : name;
	}

	static function notOnDisc(fd:Int, name:String):Int {
		release(fd);
		Runtime.reportOnce(0x59200000 + name.length, "not on the disc: " + name);
		return -1;
	}

	static function closeAndFail(fd:Int):Int {
		release(fd);
		Runtime.reportOnce(0x59300000, "no backend file slot left for a disc read");
		return -1;
	}

	/** Backend slot 0 is the executable image; the rest are the game's to use. */
	static function freeBackendSlot():Int {
		for (s in 1...8) {
			if (!slotTaken(s)) return s;
			else {}
		}
		return -1;
	}

	static function slotTaken(s:Int):Bool {
		for (fd in 0...MAX_FD) {
			if (kind[fd] == DEV_CD && slot[fd] == s) return true;
			else {}
		}
		return false;
	}

	static function hostPath(name:String):String {
		var out = "";
		var i = 0;
		// Skip the device prefix, which runs to the colon.
		final colon = name.indexOf(":");
		if (colon >= 0) i = colon + 1;
		else {}
		while (i < name.length) {
			final c = name.charAt(i);
			if (c == ";") break;
			else {}
			out += c == "\\" ? "/" : c;
			i++;
		}
		// A leading separator would make it an absolute host path, which it is not.
		return out.charAt(0) == "/" ? out.substr(1) : out;
	}

	static function unknownDevice(nameAddr:Int):Int {
		Runtime.reportOnce(0x59000000 | (nameAddr & 0xFFFF),
			"open of a device that does not exist yet: " + nameOf(nameAddr));
		return -1;
	}

	/**
		The first descriptor free both here and in its FCB in RAM (`KDevices`): a game may take an
		FCB itself — libcard marks firstfile's as used, which the BIOS forgets to — and the BIOS
		looks at the FCB's flags, not at anything of ours.
	**/
	static function allocate(dev:Int):Int {
		for (fd in 3...MAX_FD) {
			if (kind[fd] == DEV_NONE && Memory.read32(KDevices.fcb(fd)) == 0) return take(fd, dev);
			else {}
		}
		Runtime.reportOnce(0x59FFFFFF, "all " + MAX_FD + " file descriptors are in use");
		return -1;
	}

	static function take(fd:Int, dev:Int):Int {
		kind[fd] = dev;
		Memory.write32(KDevices.fcb(fd) + KDevices.FCB_FLAGS, 1);
		Memory.write32(KDevices.fcb(fd) + KDevices.FCB_DEVICE,
			KDevices.dcb(dev == DEV_TTY ? KDevices.TTY : (dev == DEV_CD ? KDevices.CDROM : KDevices.BU)));
		return fd;
	}

	static function release(fd:Int):Void {
		kind[fd] = DEV_NONE;
		Memory.write32(KDevices.fcb(fd) + KDevices.FCB_FLAGS, 0);
	}

	static function close(ctx:CpuState, fd:Int):Int {
		if (!valid(fd)) return -1;
		else if (kind[fd] == DEV_BU) return closeOnCard(ctx, fd);
		else {}
		if (kind[fd] == DEV_CD && slot[fd] >= 0) releaseSlot(fd);
		else {}
		// The three the BIOS opened stay open, exactly as a C runtime's do.
		if (fd >= 3) release(fd);
		else {}
		return 0;
	}

	/** psxclose: the descriptor is freed either way, and fd is the answer when the device agreed. */
	static function closeOnCard(ctx:CpuState, fd:Int):Int {
		final ok = KBu.close(ctx, fd);
		release(fd);
		if (!ok) Kernel.lastError = KBu.errorOf(fd);
		else {}
		return ok ? fd : -1;
	}

	static function write(ctx:CpuState, fd:Int, src:Int, len:Int):Int {
		if (!valid(fd)) return -1;
		else if (kind[fd] == DEV_TTY) return writeTty(src, len);
		else if (kind[fd] == DEV_BU) return onCard(KBu.write(ctx, fd, src, len), fd);
		else return -1;
	}

	/** A card transfer's answer, with the descriptor's error made the last one when it failed. */
	static function onCard(result:Int, fd:Int):Int {
		if (result < 0) Kernel.lastError = KBu.errorOf(fd);
		else {}
		return result;
	}

	static function writeTty(src:Int, len:Int):Int {
		var i = 0;
		while (i < len) {
			KLib.putchar(Memory.read8u(src + i));
			i++;
		}
		ttyBytes += len;
		return len;
	}

	static function releaseSlot(fd:Int):Void {
		Backend.fileClose(slot[fd]);
		slot[fd] = -1;
	}

	/**
		Reads into emulated memory.

		Through a staging buffer and then the memory map, byte at a time, rather than straight into
		RAM: the destination is an emulated address and may not be RAM at all. Slow, and it does not
		matter — a game loads a few megabytes once per level, not per frame.
	**/
	static function read(ctx:CpuState, fd:Int, dst:Int, len:Int):Int {
		if (!valid(fd)) return -1;
		else if (kind[fd] == DEV_BU) return onCard(KBu.read(ctx, fd, dst, len), fd);
		else if (kind[fd] != DEV_CD) return 0;         // the TTY has nothing to give
		else return readDisc(fd, dst, len);
	}

	static var staging:RawBuf;
	static inline var STAGING = 0x8000;

	static function readDisc(fd:Int, dst:Int, len:Int):Int {
		if (slot[fd] < 0) return readFromImage(fd, dst, len);
		else {}
		var done = 0;
		while (done < len) {
			final want = (len - done) > STAGING ? STAGING : (len - done);
			final got = Backend.fileRead(slot[fd], pos[fd], staging, want);
			if (got <= 0) break;
            else {}
			for (i in 0...got) Memory.write8(dst + done + i, RawMem.get8(staging, i));
			pos[fd] += got;
			done += got;
			if (got < want) break;
			else {}
		}
		OverlayMgr.noteLoad(dst, done);
		return done;
	}

	/** Whence: 0 from the start, 1 from here, 2 from the end — the usual three. */
	static function readFromImage(fd:Int, dst:Int, len:Int):Int {
		var want = len;
		if (pos[fd] + want > size[fd]) want = size[fd] - pos[fd];
		else {}
		if (want <= 0) return 0;
		else {}
		var done = 0;
		while (done < want) {
			final chunk = (want - done) > STAGING ? STAGING : (want - done);
			final got = cd.Iso9660.readAt(lba[fd], pos[fd], staging, 0, chunk);
			if (got <= 0) break;
			else {}
			for (i in 0...got) Memory.write8(dst + done + i, RawMem.get8(staging, i));
			pos[fd] += got;
			done += got;
		}
		// A game may load code with the kernel's own file API rather than driving the CD itself,
		// so this path has to say so too (kernel.OverlayMgr).
		OverlayMgr.noteLoad(dst, done);
		return done;
	}

	static function lseek(fd:Int, offset:Int, whence:Int):Int {
		if (!valid(fd)) return -1;
		else if (kind[fd] == DEV_BU) return KBu.lseek(fd, offset, whence);
		else if (kind[fd] != DEV_CD) return notSeekable();
		else return seekDisc(fd, offset, whence);
	}

	static function seekDisc(fd:Int, offset:Int, whence:Int):Int {
		if (whence == 0) pos[fd] = offset;
		else if (whence == 1) pos[fd] = (pos[fd] + offset) | 0;
		else pos[fd] = ((slot[fd] >= 0 ? Backend.fileSize(slot[fd]) : size[fd]) + offset) | 0;
		if (pos[fd] < 0) pos[fd] = 0;
		else {}
		return pos[fd];
	}

	static function notSeekable():Int {
		Runtime.reportOnce(0x59000001, "lseek on a device that cannot seek");
		return -1;
	}

	static function isatty(fd:Int):Int {
		return valid(fd) && kind[fd] == DEV_TTY ? 1 : 0;
	}

	static function putc(ch:Int, fd:Int):Int {
		if (!valid(fd)) return -1;
		else {}
		KLib.putchar(ch);
		ttyBytes++;
		return ch & 0xFF;
	}

	// ---- plumbing -------------------------------------------------------------------------------

	static inline function valid(fd:Int):Bool {
		return fd >= 0 && fd < MAX_FD && kind[fd] != DEV_NONE;
	}

	/** True for a name beginning "tty", which is how the kernel's console is opened. */
	static function isTty(p:Int):Bool {
		return Memory.read8u(p) == 0x74 && Memory.read8u(p + 1) == 0x74
			&& Memory.read8u(p + 2) == 0x79;
	}

	/** The name, for a diagnostic. Bounded, because a bad pointer would otherwise walk all of RAM. */
	static function nameOf(p:Int):String {
		var out = "";
		var i = 0;
		while (i < 64) {
			final c = Memory.read8u(p + i);
			if (c == 0) break;
			else {}
			out += String.fromCharCode(c >= 0x20 && c < 0x7F ? c : 0x3F);
			i++;
		}
		return out;
	}
}
