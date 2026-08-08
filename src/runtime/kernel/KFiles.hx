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

	The device set here is honest about what exists. The TTY is real. `cdrom:` and `bu00:` report
	and fail, because the disc and card layers are not built, and a failed open is something games
	handle — a silent wrong answer is not.

	Function numbers from psx-spx "BIOS Function Summary": the same calls appear on both vectors,
	A0(00h..05h) and B0(32h..37h), which is why both route here.
**/
class KFiles {
	static inline var MAX_FD = 16;

	// Device kinds a descriptor can name.
	static inline var DEV_NONE = 0;
	static inline var DEV_TTY = 1;
	static inline var DEV_CD = 2;

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
		ttyBytes = 0;
	}

	/** Dispatch for the file range of either vector. False if `fn` is not one of ours. */
	public static function callA0(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x00) ctx.v0 = open(ctx.a0, ctx.a1);
		else if (fn == 0x01) ctx.v0 = lseek(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x02) ctx.v0 = read(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x03) ctx.v0 = write(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x04) ctx.v0 = close(ctx.a0);
		else if (fn == 0x07) ctx.v0 = isatty(ctx.a0);
		else if (fn == 0x09) ctx.v0 = putc(ctx.a0, ctx.a1);
		else return false;
		return true;
	}

	public static function callB0(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x32) ctx.v0 = open(ctx.a0, ctx.a1);
		else if (fn == 0x33) ctx.v0 = lseek(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x34) ctx.v0 = read(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x35) ctx.v0 = write(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x36) ctx.v0 = close(ctx.a0);
		else if (fn == 0x39) ctx.v0 = isatty(ctx.a0);
		else return false;
		return true;
	}

	// ---- the calls -----------------------------------------------------------------------------

	/**
		Only `tty:` opens. Everything else fails, and says which name it was.

		A failing open is a normal thing for a game to meet and handle. Returning a descriptor that
		then reads zeroes would be worse: the game would believe it had its data.
	**/
	static function open(nameAddr:Int, mode:Int):Int {
		if (isTty(nameAddr)) return allocate(DEV_TTY);
		else if (imageMounted) return openInImage(nameOf(nameAddr));
		else if (discDir != "") return openOnDisc(nameOf(nameAddr));
		else return unknownDevice(nameAddr);
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
		kind[fd] = DEV_NONE;
		Runtime.reportOnce(0x59200000 + name.length, "not on the disc: " + name);
		return -1;
	}

	static function closeAndFail(fd:Int):Int {
		kind[fd] = DEV_NONE;
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

	static function allocate(dev:Int):Int {
		for (fd in 3...MAX_FD) {
			if (kind[fd] == DEV_NONE) return take(fd, dev);
			else {}
		}
		Runtime.reportOnce(0x59FFFFFF, "all " + MAX_FD + " file descriptors are in use");
		return -1;
	}

	static function take(fd:Int, dev:Int):Int {
		kind[fd] = dev;
		return fd;
	}

	static function close(fd:Int):Int {
		if (!valid(fd)) return -1;
		else {}
		if (kind[fd] == DEV_CD && slot[fd] >= 0) releaseSlot(fd);
		else {}
		// The three the BIOS opened stay open, exactly as a C runtime's do.
		if (fd >= 3) kind[fd] = DEV_NONE;
		else {}
		return 0;
	}

	static function write(fd:Int, src:Int, len:Int):Int {
		if (!valid(fd)) return -1;
		else if (kind[fd] == DEV_TTY) return writeTty(src, len);
		else return -1;
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
	static function read(fd:Int, dst:Int, len:Int):Int {
		if (!valid(fd)) return -1;
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
		return done;
	}

	static function lseek(fd:Int, offset:Int, whence:Int):Int {
		if (!valid(fd)) return -1;
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
