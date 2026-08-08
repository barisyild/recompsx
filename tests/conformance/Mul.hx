import core.CpuState;
import core.Ops;

/**
	Multiply and divide conformance.

	`core.Ops` implements 64-bit multiplication by hand from 16-bit halves, and division with the
	edge cases the hardware defines and C++ does not. Both are the kind of code that is either
	exactly right or subtly wrong in a way no game reveals for a month, and both must produce
	identical bits on every target — the GTE and every fixed-point calculation in every PS1 game
	rest on them.

	The probe values are chosen to break things: sign boundaries, values whose product needs all
	64 bits, and the two division cases the hardware defines specially.
**/
class Mul {
	static final PROBES = [
		0, 1, -1, 2, -2, 3, -3, 7, -7,
		0x7FFFFFFF, -0x80000000, 0x40000000, -0x40000000,
		0xFFFF, 0x10000, 0x12345678, -0x12345678,
		0x80000000, 0xDEADBEEF, 0x0000FFFF, 0x00010001, 65535, 65536
	];

	public static function main():Void {
		Conf.feedName("mul");
		final ctx = new CpuState();

		// Every pairing, signed and unsigned, both halves of the result.
		var i = 0;
		while (i < PROBES.length) {
			var j = 0;
			while (j < PROBES.length) {
				final a = PROBES[i];
				final b = PROBES[j];

				Ops.mult(ctx, a, b);
				Conf.feed(ctx.lo);
				Conf.feed(ctx.hi);

				Ops.multu(ctx, a, b);
				Conf.feed(ctx.lo);
				Conf.feed(ctx.hi);

				Ops.div(ctx, a, b);
				Conf.feed(ctx.lo);
				Conf.feed(ctx.hi);

				Ops.divu(ctx, a, b);
				Conf.feed(ctx.lo);
				Conf.feed(ctx.hi);

				j++;
			}
			i++;
		}

		// The answers that are known outright, stated so a failure names itself.

		// A plain multiply, small enough to check by eye.
		Ops.mult(ctx, 7, 6);
		Conf.expect("7 * 6 low", ctx.lo, 42);
		Conf.expect("7 * 6 high", ctx.hi, 0);

		// Signs.
		Ops.mult(ctx, -7, 6);
		Conf.expect("-7 * 6 low", ctx.lo, -42);
		Conf.expect("-7 * 6 high", ctx.hi, -1);

		Ops.mult(ctx, -7, -6);
		Conf.expect("-7 * -6 low", ctx.lo, 42);
		Conf.expect("-7 * -6 high", ctx.hi, 0);

		// A product that needs the high word: 0x10000 * 0x10000 == 2^32.
		Ops.multu(ctx, 0x10000, 0x10000);
		Conf.expect("2^16 * 2^16 low", ctx.lo, 0);
		Conf.expect("2^16 * 2^16 high", ctx.hi, 1);

		// The largest unsigned product: 0xFFFFFFFF^2 == 0xFFFFFFFE00000001.
		Ops.multu(ctx, -1, -1);
		Conf.expect("0xFFFFFFFF^2 low", ctx.lo, 1);
		Conf.expect("0xFFFFFFFF^2 high", ctx.hi, -2);

		// ...and the signed reading of the same operands is (-1) * (-1) == 1.
		Ops.mult(ctx, -1, -1);
		Conf.expect("-1 * -1 low", ctx.lo, 1);
		Conf.expect("-1 * -1 high", ctx.hi, 0);

		// Division, ordinary.
		Ops.div(ctx, 42, 5);
		Conf.expect("42 / 5", ctx.lo, 8);
		Conf.expect("42 % 5", ctx.hi, 2);

		// Truncation toward zero, and a remainder taking the dividend's sign.
		Ops.div(ctx, -42, 5);
		Conf.expect("-42 / 5", ctx.lo, -8);
		Conf.expect("-42 % 5", ctx.hi, -2);

		// Division by zero: not a fault. The hardware defines these, and compiled code checks
		// for them *after* the divide, so the divide has to complete.
		Ops.div(ctx, 42, 0);
		Conf.expect("42 / 0 quotient", ctx.lo, -1);
		Conf.expect("42 / 0 remainder", ctx.hi, 42);

		Ops.div(ctx, -42, 0);
		Conf.expect("-42 / 0 quotient", ctx.lo, 1);
		Conf.expect("-42 / 0 remainder", ctx.hi, -42);

		// The one quotient that does not fit in 32 bits. Undefined in C++, defined here.
		Ops.div(ctx, -2147483648, -1);
		Conf.expect("INT_MIN / -1 quotient", ctx.lo, -2147483648);
		Conf.expect("INT_MIN / -1 remainder", ctx.hi, 0);

		// Unsigned division has to read both operands as unsigned, which on a signed type is
		// where implementations usually go wrong.
		Ops.divu(ctx, -1, 2);            // 0xFFFFFFFF / 2
		Conf.expect("0xFFFFFFFF / 2", ctx.lo, 0x7FFFFFFF);
		Conf.expect("0xFFFFFFFF % 2", ctx.hi, 1);

		Ops.divu(ctx, -2, -1);           // 0xFFFFFFFE / 0xFFFFFFFF == 0 remainder 0xFFFFFFFE
		Conf.expect("0xFFFFFFFE / 0xFFFFFFFF", ctx.lo, 0);
		Conf.expect("0xFFFFFFFE % 0xFFFFFFFF", ctx.hi, -2);

		Ops.divu(ctx, -1, -1);           // 0xFFFFFFFF / 0xFFFFFFFF == 1
		Conf.expect("0xFFFFFFFF / 0xFFFFFFFF", ctx.lo, 1);
		Conf.expect("0xFFFFFFFF % 0xFFFFFFFF", ctx.hi, 0);

		Ops.divu(ctx, 100, 0);
		Conf.expect("unsigned / 0 quotient", ctx.lo, -1);
		Conf.expect("unsigned / 0 remainder", ctx.hi, 100);

		// The unsigned comparison the emitter relies on for `sltu`.
		Conf.expect("0x80000000 is not < 1 unsigned",
			Ops.unsignedLess(0x80000000, 1) ? 1 : 0, 0);
		Conf.expect("1 is < 0x80000000 unsigned",
			Ops.unsignedLess(1, 0x80000000) ? 1 : 0, 1);

		Conf.report("mul");
	}
}
