package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;

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

	static var kind:Array<Int>;

	/** Bytes written to the TTY. A game that says nothing is a different problem from one that fails. */
	public static var ttyBytes(default, null) = 0;

	public static function init():Void {
		kind = [for (_ in 0...MAX_FD) DEV_NONE];
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
		else return unknownDevice(nameAddr);
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

	/** Reading the TTY yields nothing: there is no keyboard, and a game asking gets end-of-file. */
	static function read(fd:Int, dst:Int, len:Int):Int {
		if (!valid(fd)) return -1;
		else return 0;
	}

	static function lseek(fd:Int, offset:Int, whence:Int):Int {
		if (!valid(fd)) return -1;
		else return notSeekable();
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
