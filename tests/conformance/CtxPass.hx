import core.CpuState;

/**
	That a `CpuState` handed to a function is the caller's own, not a copy of it.

	Every recompiled function takes `ctx` and writes to it — that is what a register file *is* —
	and the whole program is one such call chain. So the question this asks is not a fine point of
	semantics; it is whether generated code works at all. On JavaScript a class instance is always
	a reference and the answer cannot be wrong. On reflaxe.CPP it depends on the memory-management
	type the class carries, and the wrong choice compiles cleanly, passes every existing test, and
	silently discards every register write across a call boundary.

	It is easy to get there by accident: `@:valueType` removes the `std::shared_ptr` that otherwise
	wraps every `ctx` argument — which looks like exactly the optimisation one wants — and replaces
	it with pass-by-value, which is both a forty-field copy per call and a correctness bug. This
	test is what tells the two apart.
**/
class CtxPass {
	public static function main():Void {
		Conf.feedName("CtxPass");

		final ctx = new CpuState();
		ctx.v0 = 0;
		ctx.sp = 0x80100000;
		ctx.cycles = 0;

		// A callee's write must be visible to the caller.
		writeRegisters(ctx);
		Conf.expect("a callee's write to v0 reaches the caller", ctx.v0, 0x1234);
		Conf.expect("and to sp", ctx.sp, 0x80200000);
		Conf.expect("and to cycles", ctx.cycles, 99);

		// Through two frames, which is what a call chain is.
		outer(ctx);
		Conf.expect("two frames deep still writes through", ctx.v1, 0x5678);

		// The same object seen through a second binding is the same object.
		final alias = ctx;
		alias.t0 = 0x4321;
		Conf.expect("an alias is not a copy", ctx.t0, 0x4321);

		// Stored in a field and mutated there — the shape `Irq.saved` uses.
		held = ctx;
		held.a0 = 0x0BAD;
		Conf.expect("a field holding it is not a copy", ctx.a0, 0x0BAD);

		// A loop of writes through a call, which is the hot path in miniature.
		var i = 0;
		while (i < 64) {
			bump(ctx);
			i++;
		}
		Conf.expect("sixty-four accumulated writes all landed", ctx.cycles, 99 + 64);

		Conf.feed(ctx.v0);
		Conf.feed(ctx.v1);
		Conf.feed(ctx.sp);
		Conf.feed(ctx.t0);
		Conf.feed(ctx.a0);
		Conf.feed(ctx.cycles);

		Conf.report("CtxPass");
	}

	static var held:CpuState;

	static function writeRegisters(c:CpuState):Void {
		c.v0 = 0x1234;
		c.sp = 0x80200000;
		c.cycles = 99;
	}

	static function outer(c:CpuState):Void {
		inner(c);
	}

	static function inner(c:CpuState):Void {
		c.v1 = 0x5678;
	}

	static function bump(c:CpuState):Void {
		c.cycles = (c.cycles + 1) | 0;
	}
}
