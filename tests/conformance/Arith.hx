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
	// No `inline` wrapper around Conf.feed. An inlined function materialises its parameter as a
	// local with a fixed name in the caller's scope, so two calls in one scope collide —
	// `redefinition of 'v'`. Same root cause as the `_this` collision; see upstream defect 1.

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
				Conf.feed((a + b) | 0);
				Conf.feed((a - b) | 0);
				Conf.feed((-a) | 0);
				Conf.feed(shim.IntMath.mul(a, b));
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
				Conf.feed(a & b);
				Conf.feed(a | b);
				Conf.feed(a ^ b);
				Conf.feed(~a);
				Conf.feed(~(a | b));          // nor
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
				Conf.feed(a << s);
				Conf.feed(a >> s);
				Conf.feed(a >>> s);
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
				Conf.feed(a < b ? 1 : 0);
				Conf.feed((a ^ 0x80000000) < (b ^ 0x80000000) ? 1 : 0);
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
				Conf.feed(shim.IntMath.div(a, divisor));
				Conf.feed(shim.IntMath.mod(a, divisor));
				j++;
			}
			i++;
		}

		// --- byte and halfword extraction, as the load instructions produce ---
		i = 0;
		while (i < n) {
			final a = PROBES[i];
			Conf.feed((a << 24) >> 24);       // lb  sign-extend
			Conf.feed(a & 0xFF);              // lbu
			Conf.feed((a << 16) >> 16);       // lh  sign-extend
			Conf.feed(a & 0xFFFF);            // lhu
			i++;
		}

		// A few answers are known outright, so state them rather than only hashing them.
		Conf.expect("0x7FFFFFFF + 1 wraps", (0x7FFFFFFF + 1) | 0, -2147483648);
		Conf.expect("-0x80000000 - 1 wraps", (-0x80000000 - 1) | 0, 2147483647);
		Conf.expect("imul keeps low 32 bits", shim.IntMath.mul(0x10001, 0x10001), 0x20001);
		Conf.expect("div truncates toward zero", shim.IntMath.div(-7, 2), -3);
		Conf.expect("mod takes the dividend's sign", shim.IntMath.mod(-7, 2), -1);
		Conf.expect("logical shift right", -1 >>> 28, 15);
		Conf.expect("arithmetic shift right", -1 >> 28, -1);
		Conf.expect("unsigned compare idiom",
			((0x80000000 ^ 0x80000000) < (1 ^ 0x80000000)) ? 1 : 0, 0);

		Conf.report("arith");
	}
}
