/**
	Cross-target arithmetic conformance.

	Every operation the recompiler emits for a MIPS instruction is exercised here with the values
	that expose the differences between targets — overflow boundaries, sign changes, shift edges.
	The program prints a digest; `scripts/test.sh` runs it on every target and requires the same
	answer. A divergence here means generated game code would diverge too, silently, in whichever
	game happened to add two large numbers.

	This exists because JavaScript and C++ genuinely disagree by default: `0x7FFFFFFF + 1` is
	2147483648 on JS and -2147483648 on C++ and on the real hardware. Haxe does not paper over it.
	The project's answer is `| 0` on every wrapping result, which JS needs and C++ folds away.

	Written in the portable subset, and deliberately without `if` inside loops — reflaxe.CPP
	deletes those (PROGRESS.md upstream defect 8).
**/
class Arith {
	static var digest = 0x811C9DC5;

	static function feed(v:Int):Void {
		var h = digest ^ (v & 0xFF);
		h = shim.IntMath.mul(h, 16777619);
		h = h ^ ((v >>> 8) & 0xFF);
		h = shim.IntMath.mul(h, 16777619);
		h = h ^ ((v >>> 16) & 0xFF);
		h = shim.IntMath.mul(h, 16777619);
		h = h ^ ((v >>> 24) & 0xFF);
		digest = shim.IntMath.mul(h, 16777619);
	}

	/** The values that break things: boundaries, signs, and the bit patterns MIPS code produces. */
	static final PROBES = [
		0, 1, -1, 2, -2, 0x7FFFFFFF, -0x80000000, 0x40000000, -0x40000000,
		0xFFFF, -0xFFFF, 0x10000, 0x00FFFFFF, 0x7FFF, -0x8000, 0x12345678, -0x12345678,
		0x80000000, 0xDEADBEEF, 0x0000FFFF, 3, -3, 7, -7, 255, 256
	];

	public static function main():Void {
		final n = PROBES.length;

		// --- addu / subu: the MIPS ALU wraps, and `| 0` is what makes JS agree ---
		var i = 0;
		while (i < n) {
			var j = 0;
			while (j < n) {
				final a = PROBES[i];
				final b = PROBES[j];
				feed((a + b) | 0);
				feed((a - b) | 0);
				feed((-a) | 0);
				feed(shim.IntMath.mul(a, b));
				j++;
			}
			i++;
		}

		// --- bitwise: always in range, but cheap to confirm ---
		i = 0;
		while (i < n) {
			var j = 0;
			while (j < n) {
				final a = PROBES[i];
				final b = PROBES[j];
				feed(a & b);
				feed(a | b);
				feed(a ^ b);
				feed(~a);
				feed(~(a | b));          // nor
				j++;
			}
			i++;
		}

		// --- shifts: variable amounts are masked to 5 bits by the hardware ---
		i = 0;
		while (i < n) {
			var s = 0;
			while (s < 32) {
				final a = PROBES[i];
				feed(a << s);
				feed(a >> s);
				feed(a >>> s);
				s++;
			}
			i++;
		}

		// --- comparisons: slt and the unsigned idiom the emitter uses for sltu ---
		i = 0;
		while (i < n) {
			var j = 0;
			while (j < n) {
				final a = PROBES[i];
				final b = PROBES[j];
				feed(a < b ? 1 : 0);
				feed((a ^ 0x80000000) < (b ^ 0x80000000) ? 1 : 0);
				j++;
			}
			i++;
		}

		// --- division and remainder, avoiding the divide-by-zero cases MIPS defines separately ---
		i = 0;
		while (i < n) {
			var j = 0;
			while (j < n) {
				final a = PROBES[i];
				final b = PROBES[j];
				final safe = b == 0 ? 1 : b;
				// MIPS defines 0x80000000 / -1 as 0x80000000; C++ makes it undefined, so the
				// recompiler special-cases it and this test stays away from it.
				final skip = (a == -0x80000000 && safe == -1);
				final divisor = skip ? 3 : safe;
				feed(shim.IntMath.div(a, divisor));
				feed(shim.IntMath.mod(a, divisor));
				j++;
			}
			i++;
		}

		// --- byte and halfword extraction, as the load instructions produce ---
		i = 0;
		while (i < n) {
			final a = PROBES[i];
			feed((a << 24) >> 24);       // lb  sign-extend
			feed(a & 0xFF);              // lbu
			feed((a << 16) >> 16);       // lh  sign-extend
			feed(a & 0xFFFF);            // lhu
			i++;
		}

		shim.Backend.log(shim.Backend.LOG_INFO, "arith digest=" + hex(digest));
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return out;
	}
}
