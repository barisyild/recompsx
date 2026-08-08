package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;
import shim.Backend;
import shim.IntMath;

/**
	The C library the BIOS provides, on the A0 vector.

	Every one of these operates on *emulated* memory, byte by byte through the memory map, because
	the pointers a game passes are its own addresses and the results have to be visible to it. None
	of them may touch host memory, and none may allocate.

	Function numbers are from psx-spx "BIOS Function Summary". The semantics are ordinary C, with
	two traps worth stating out loud: `bcopy` takes source first and destination second, the
	opposite of `memcpy`, and `memmove` has to survive overlap in both directions.

	Games often link Psy-Q's own copies of these instead, in which case the recompiler translated
	them and none of this is reached. It is reached when a game called the kernel's, which some do
	precisely because it saves space.
**/
class KLib {
	/** Dispatch for the library range of the A0 table. Returns false if `fn` is not one of ours. */
	public static function call(ctx:CpuState, fn:Int):Bool {
		// Grouped by kind rather than run as one 40-arm chain: each group is a short jump for the
		// compiler and a readable unit for a person.
		if (fn >= 0x15 && fn <= 0x26) return strings(ctx, fn);
		else if (fn >= 0x27 && fn <= 0x2E) return blocks(ctx, fn);
		else return misc(ctx, fn);
	}

	// ---- strings ------------------------------------------------------------------------------

	static function strings(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x15) ctx.v0 = strcat(ctx.a0, ctx.a1);
		else if (fn == 0x16) ctx.v0 = strncat(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x17) ctx.v0 = strcmp(ctx.a0, ctx.a1);
		else if (fn == 0x18) ctx.v0 = strncmp(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x19) ctx.v0 = strcpy(ctx.a0, ctx.a1);
		else if (fn == 0x1A) ctx.v0 = strncpy(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x1B) ctx.v0 = strlen(ctx.a0);
		else if (fn == 0x1C || fn == 0x1E) ctx.v0 = strchr(ctx.a0, ctx.a1);
		else if (fn == 0x1D || fn == 0x1F) ctx.v0 = strrchr(ctx.a0, ctx.a1);
		else if (fn == 0x24) ctx.v0 = strstr(ctx.a0, ctx.a1);
		else if (fn == 0x25) ctx.v0 = toupper(ctx.a0);
		else if (fn == 0x26) ctx.v0 = tolower(ctx.a0);
		else return false;
		return true;
	}

	public static function strlen(s:Int):Int {
		var n = 0;
		while (Memory.read8u(s + n) != 0) n++;
		return n;
	}

	static function strcpy(dst:Int, src:Int):Int {
		var i = 0;
		while (true) {
			final c = Memory.read8u(src + i);
			Memory.write8(dst + i, c);
			if (c == 0) break;
			else {}
			i++;
		}
		return dst;
	}

	static function strncpy(dst:Int, src:Int, n:Int):Int {
		var i = 0;
		// C's strncpy pads with zeroes to the full length and does not terminate if it ran out.
		while (i < n) {
			final c = Memory.read8u(src + i);
			Memory.write8(dst + i, c);
			if (c == 0) break;
			else {}
			i++;
		}
		while (i < n) {
			Memory.write8(dst + i, 0);
			i++;
		}
		return dst;
	}

	static function strcat(dst:Int, src:Int):Int {
		strcpy(dst + strlen(dst), src);
		return dst;
	}

	static function strncat(dst:Int, src:Int, n:Int):Int {
		final end = dst + strlen(dst);
		var i = 0;
		while (i < n) {
			final c = Memory.read8u(src + i);
			if (c == 0) break;
			else {}
			Memory.write8(end + i, c);
			i++;
		}
		Memory.write8(end + i, 0);
		return dst;
	}

	static function strcmp(a:Int, b:Int):Int {
		var i = 0;
		while (true) {
			final x = Memory.read8u(a + i);
			final y = Memory.read8u(b + i);
			if (x != y) return x - y;
			else {}
			if (x == 0) return 0;
			else {}
			i++;
		}
	}

	static function strncmp(a:Int, b:Int, n:Int):Int {
		var i = 0;
		while (i < n) {
			final x = Memory.read8u(a + i);
			final y = Memory.read8u(b + i);
			if (x != y) return x - y;
			else {}
			if (x == 0) return 0;
			else {}
			i++;
		}
		return 0;
	}

	static function strchr(s:Int, c:Int):Int {
		final want = c & 0xFF;
		var i = 0;
		while (true) {
			final x = Memory.read8u(s + i);
			if (x == want) return s + i;
			else {}
			if (x == 0) return 0;
			else {}
			i++;
		}
	}

	static function strrchr(s:Int, c:Int):Int {
		final want = c & 0xFF;
		var found = 0;
		var i = 0;
		while (true) {
			final x = Memory.read8u(s + i);
			if (x == want) found = s + i;
			else {}
			if (x == 0) return found;
			else {}
			i++;
		}
	}

	static function strstr(hay:Int, needle:Int):Int {
		final n = strlen(needle);
		if (n == 0) return hay;
		else {}
		var i = 0;
		while (Memory.read8u(hay + i) != 0) {
			if (strncmp(hay + i, needle, n) == 0) return hay + i;
			else {}
			i++;
		}
		return 0;
	}

	static function toupper(c:Int):Int {
		return (c >= 0x61 && c <= 0x7A) ? c - 0x20 : c;
	}

	static function tolower(c:Int):Int {
		return (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;
	}

	// ---- blocks of memory -----------------------------------------------------------------------

	static function blocks(ctx:CpuState, fn:Int):Bool {
		// bcopy takes (src, dst); memcpy takes (dst, src). Getting this backwards corrupts memory
		// in a way that looks like a game bug, so it is worth the explicit note.
		if (fn == 0x27) ctx.v0 = memmove(ctx.a1, ctx.a0, ctx.a2);
		else if (fn == 0x28) ctx.v0 = memset(ctx.a0, 0, ctx.a1);
		else if (fn == 0x29) ctx.v0 = memcmp(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x2A) ctx.v0 = memcpy(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x2B) ctx.v0 = memset(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x2C) ctx.v0 = memmove(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x2D) ctx.v0 = memcmp(ctx.a0, ctx.a1, ctx.a2);
		else if (fn == 0x2E) ctx.v0 = memchr(ctx.a0, ctx.a1, ctx.a2);
		else return false;
		return true;
	}

	static function memcpy(dst:Int, src:Int, n:Int):Int {
		var i = 0;
		while (i < n) {
			Memory.write8(dst + i, Memory.read8u(src + i));
			i++;
		}
		return dst;
	}

	/** Overlap-safe: copy backwards when the destination is inside the source. */
	static function memmove(dst:Int, src:Int, n:Int):Int {
		if (dst > src && dst < src + n) return copyBackwards(dst, src, n);
		else return memcpy(dst, src, n);
	}

	static function copyBackwards(dst:Int, src:Int, n:Int):Int {
		var i = n - 1;
		while (i >= 0) {
			Memory.write8(dst + i, Memory.read8u(src + i));
			i--;
		}
		return dst;
	}

	static function memset(dst:Int, v:Int, n:Int):Int {
		final b = v & 0xFF;
		var i = 0;
		while (i < n) {
			Memory.write8(dst + i, b);
			i++;
		}
		return dst;
	}

	static function memcmp(a:Int, b:Int, n:Int):Int {
		var i = 0;
		while (i < n) {
			final x = Memory.read8u(a + i);
			final y = Memory.read8u(b + i);
			if (x != y) return x - y;
			else {}
			i++;
		}
		return 0;
	}

	static function memchr(s:Int, c:Int, n:Int):Int {
		final want = c & 0xFF;
		var i = 0;
		while (i < n) {
			if (Memory.read8u(s + i) == want) return s + i;
			else {}
			i++;
		}
		return 0;
	}

	// ---- everything else -------------------------------------------------------------------------

	static function misc(ctx:CpuState, fn:Int):Bool {
		if (fn == 0x0E || fn == 0x0F) ctx.v0 = ctx.a0 < 0 ? (-ctx.a0) | 0 : ctx.a0;
		else if (fn == 0x10 || fn == 0x11) ctx.v0 = atoi(ctx.a0);
		else if (fn == 0x2F) ctx.v0 = rand();
		else if (fn == 0x30) srand(ctx.a0);
		else if (fn == 0x33) ctx.v0 = KHeap.malloc(ctx.a0);
		else if (fn == 0x34) KHeap.free(ctx.a0);
		else if (fn == 0x37) ctx.v0 = calloc(ctx.a0, ctx.a1);
		else if (fn == 0x38) ctx.v0 = KHeap.realloc(ctx.a0, ctx.a1);
		else if (fn == 0x3C) putchar(ctx.a0);
		else if (fn == 0x3E) ctx.v0 = puts(ctx.a0);
		else if (fn == 0x3F) ctx.v0 = printf(ctx);
		else return false;
		return true;
	}

	static function calloc(nx:Int, ny:Int):Int {
		final bytes = IntMath.mul(nx, ny);
		final p = KHeap.malloc(bytes);
		if (p != 0) memset(p, 0, bytes);
		else {}
		return p;
	}

	static function atoi(s:Int):Int {
		var i = 0;
		while (isSpace(Memory.read8u(s + i))) i++;
		var sign = 1;
		final c = Memory.read8u(s + i);
		if (c == 0x2D) { sign = -1; i++; }
		else if (c == 0x2B) i++;
		else {}
		var n = 0;
		while (true) {
			final d = Memory.read8u(s + i);
			if (d < 0x30 || d > 0x39) break;
			else {}
			n = (IntMath.mul(n, 10) + (d - 0x30)) | 0;
			i++;
		}
		return IntMath.mul(n, sign);
	}

	static inline function isSpace(c:Int):Bool {
		return c == 0x20 || (c >= 0x09 && c <= 0x0D);
	}

	// ---- the kernel's random number generator ------------------------------------------------

	/**
		The BIOS LCG.

		Seeded deterministically at boot and never from host entropy: a recompiled game has to
		produce the same sequence on every run and every platform, or the frame digests that gate
		this project mean nothing. A game wanting variety seeds it from a frame counter, which is
		emulated state and therefore still deterministic.
	**/
	static var seed = 0;

	public static function init():Void {
		seed = 0;
		digits = [for (_ in 0...32) 0];
		line = "";
	}

	static function rand():Int {
		seed = (IntMath.mul(seed, 0x41C64E6D) + 0x3039) | 0;
		return (seed >>> 16) & 0x7FFF;
	}

	static function srand(s:Int):Void {
		seed = s;
	}

	// ---- TTY -------------------------------------------------------------------------------------

	/**
		Characters the game prints, buffered until a newline.

		Games print debug text through the kernel and it is often the only thing they say about
		what they are doing. Buffering to whole lines keeps it readable next to the runtime's own
		log rather than one character per line.
	**/
	static var line = "";

	static function putchar(c:Int):Void {
		final ch = c & 0xFF;
		if (ch == 0x0A) flushLine();
		else if (ch >= 0x20 && ch < 0x7F) line += String.fromCharCode(ch);
		else {}
	}

	static function flushLine():Void {
		Backend.log(Backend.LOG_INFO, "tty: " + line);
		line = "";
	}

	static function puts(s:Int):Int {
		var i = 0;
		while (true) {
			final c = Memory.read8u(s + i);
			if (c == 0) break;
			else {}
			putchar(c);
			i++;
		}
		putchar(0x0A);
		return 0;
	}

	/**
		`printf`, integer only.

		No `%f`: this runtime has no floating point at all (golden rule 1), and a PS1 game that
		printed one would be printing from its own library rather than the kernel's anyway.

		Arguments after the format come in a1..a3 and then the stack, which is the MIPS o32
		convention — the first four words of the argument list live in registers but the *stack*
		slots for them still exist, so argument five is at sp+16.
	**/
	static function printf(ctx:CpuState):Int {
		final fmt = ctx.a0;
		var argIndex = 0;
		var i = 0;
		var written = 0;
		while (true) {
			final c = Memory.read8u(fmt + i);
			if (c == 0) break;
			else {}
			i++;
			if (c != 0x25) { putchar(c); written++; continue; }
			else {}

			// A conversion. Width and zero-padding are honoured; precision is not, because
			// nothing in the integer set needs it.
			var pad = 0;
			var zero = false;
			var spec = Memory.read8u(fmt + i);
			if (spec == 0x30) { zero = true; i++; spec = Memory.read8u(fmt + i); }
			else {}
			while (spec >= 0x30 && spec <= 0x39) {
				pad = (IntMath.mul(pad, 10) + (spec - 0x30)) | 0;
				i++;
				spec = Memory.read8u(fmt + i);
			}
			// Length modifiers: everything is 32-bit here, so they only need skipping.
			while (spec == 0x6C || spec == 0x68) { i++; spec = Memory.read8u(fmt + i); }
			i++;
			written += emitConversion(ctx, spec, argIndex, pad, zero);
			if (spec != 0x25) argIndex++;
			else {}
		}
		return written;
	}

	static function emitConversion(ctx:CpuState, spec:Int, argIndex:Int, pad:Int, zero:Bool):Int {
		if (spec == 0x25) { putchar(0x25); return 1; }
		else {}
		final v = argOf(ctx, argIndex);
		if (spec == 0x63) { putchar(v); return 1; }
		else if (spec == 0x73) return writeString(v, pad);
		else if (spec == 0x64 || spec == 0x69) return writeSigned(v, pad, zero);
		else if (spec == 0x75) return writeUnsigned(v, pad, zero);
		else if (spec == 0x78) return writeBase(v, 16, false, pad, zero);
		else if (spec == 0x58) return writeBase(v, 16, true, pad, zero);
		else if (spec == 0x6F) return writeBase(v, 8, false, pad, zero);
		else if (spec == 0x70) return writePointer(v);
		else return unknownSpec(spec);
	}

	static function unknownSpec(spec:Int):Int {
		Runtime.reportOnce(0x57000000 | spec, "printf conversion " + spec);
		return 0;
	}

	/** o32: the first four words are in a0..a3, and argument five onwards is at sp+16. */
	static function argOf(ctx:CpuState, index:Int):Int {
		if (index == 0) return ctx.a1;
		else if (index == 1) return ctx.a2;
		else if (index == 2) return ctx.a3;
		else return Memory.read32(ctx.sp + 16 + ((index - 3) << 2));
	}

	/**
		Digits, built as character codes in a fixed buffer rather than as a String.

		Not style: `String.charCodeAt` does not compile under reflaxe.CPP — the generator indexes
		the string, gets a `char`, and then emits a method call on it. Numbers here are formatted
		with no String anywhere, which is also what the portable subset asks for (strings are
		cold-path only) and means printf allocates nothing.

		Ten digits is the most a 32-bit value needs in base 10; 32 covers base 2 if it is ever
		wanted, and costs nothing.
	**/
	// Filled in `init`, not here. A static initialised with an array comprehension makes reflaxe
	// emit a statement block at namespace scope, which is not valid C++ — and every other table in
	// this runtime is built at init anyway, because nothing may allocate after boot.
	static var digits:Array<Int>;

	static function writeSigned(v:Int, pad:Int, zero:Bool):Int {
		if (v == 0) return writeDigits(0, 1, false, pad, zero);
		else if (v == -2147483648) return writeMinInt(pad, zero);   // its own negation does not fit
		else if (v < 0) return writeDigits((-v) | 0, 10, true, pad, zero);
		else return writeDigits(v, 10, false, pad, zero);
	}

	static function writeMinInt(pad:Int, zero:Bool):Int {
		// The one value that cannot be negated: split the last digit off and print the rest.
		final n = fill(214748364, 10, false);
		digits[n] = 0x38;
		return flush(n + 1, true, pad, zero);
	}

	static function writeUnsigned(v:Int, pad:Int, zero:Bool):Int {
		if (v >= 0) return writeDigits(v, 10, false, pad, zero);
		else return writeBigUnsigned(v, pad, zero);
	}

	/**
		Decimal for a value the game means as unsigned.

		Above 2^31 the Int is negative and a plain divide is wrong. Halving first keeps it
		positive: floor(u/10) is floor((u/2)/5), off by at most one, and the remainder says which.
	**/
	static function writeBigUnsigned(v:Int, pad:Int, zero:Bool):Int {
		var q = IntMath.div(v >>> 1, 5);
		var r = (v - IntMath.mul(q, 10)) | 0;
		if (r >= 10) { q = (q + 1) | 0; r -= 10; }
		else {}
		final n = fill(q, 10, false);
		digits[n] = 0x30 + r;
		return flush(n + 1, false, pad, zero);
	}

	static function writeBase(v:Int, base:Int, upper:Bool, pad:Int, zero:Bool):Int {
		if (v == 0) return writeDigits(0, base, false, pad, zero);
		else {}
		// Unsigned: shift rather than divide, so the sign bit is just another digit.
		final shift = base == 16 ? 4 : 3;
		final mask = base - 1;
		var n = 0;
		var x = v;
		while (x != 0 && n < 32) {
			digits[n] = digitCode(x & mask, upper);
			x = x >>> shift;
			n++;
		}
		reverse(n);
		return flush(n, false, pad, zero);
	}

	static function writePointer(v:Int):Int {
		putchar(0x30);
		putchar(0x78);
		return 2 + writeBase(v, 16, false, 8, true);
	}

	static function writeDigits(v:Int, base:Int, negative:Bool, pad:Int, zero:Bool):Int {
		final n = fill(v, base, false);
		return flush(n, negative, pad, zero);
	}

	/** Fills `digits` most-significant first and returns how many. */
	static function fill(v:Int, base:Int, upper:Bool):Int {
		if (v == 0) { digits[0] = 0x30; return 1; }
		else {}
		var n = 0;
		var x = v;
		while (x != 0 && n < 32) {
			digits[n] = digitCode(IntMath.mod(x, base), upper);
			x = IntMath.div(x, base);
			n++;
		}
		reverse(n);
		return n;
	}

	static function reverse(n:Int):Void {
		var i = 0;
		var j = n - 1;
		while (i < j) {
			final t = digits[i];
			digits[i] = digits[j];
			digits[j] = t;
			i++;
			j--;
		}
	}

	static inline function digitCode(d:Int, upper:Bool):Int {
		return d < 10 ? 0x30 + d : (upper ? 0x41 : 0x61) + (d - 10);
	}

	/** Pads to width and emits. A zero-padded negative keeps its sign in front of the zeroes. */
	static function flush(n:Int, negative:Bool, pad:Int, zero:Bool):Int {
		final width = n + (negative ? 1 : 0);
		var written = 0;
		if (negative && zero) { putchar(0x2D); written++; }
		else {}
		while (written + (width - (negative && zero ? 1 : 0)) < pad) {
			putchar(zero ? 0x30 : 0x20);
			written++;
		}
		if (negative && !zero) { putchar(0x2D); written++; }
		else {}
		for (i in 0...n) putchar(digits[i]);
		return written + n;
	}

	/** A string argument, read out of emulated memory and bounded in case the pointer is bad. */
	static function writeString(p:Int, pad:Int):Int {
		if (p == 0) return writeLiteralNull(pad);
		else {}
		var n = 0;
		while (n < 1024 && Memory.read8u(p + n) != 0) n++;
		var written = 0;
		while (written + n < pad) { putchar(0x20); written++; }
		for (i in 0...n) putchar(Memory.read8u(p + i));
		return written + n;
	}

	static function writeLiteralNull(pad:Int):Int {
		var written = 0;
		while (written + 6 < pad) { putchar(0x20); written++; }
		putchar(0x28); putchar(0x6E); putchar(0x75); putchar(0x6C); putchar(0x6C); putchar(0x29);
		return written + 6;
	}
}
