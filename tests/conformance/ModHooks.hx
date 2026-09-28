import core.CpuState;
import mod.ModHost;

/**
	The mod host (ADR-0033) on every target: hooks that pass, answer, or wrap a guest function; the
	bypass that lets `callOriginal` run the original once without re-entering the hook; frame and
	boot handlers; and the heap a mod builds its guest-visible data in.

	No generated program is needed. The dispatcher bound here stands in for `FnTable`, and each
	"guest function" begins with exactly the line `gen --mods` emits at a hooked entry — so the path
	from `ModHost.call` through `Runtime.call`, the dispatcher and back into `enter` is the one a
	real build takes. The handlers are static functions held as function values, which is the
	shape this test exists to prove on reflaxe.CPP.
**/
class ModHooks {
	static inline var PLAIN = 0x80030000;     // hooked by nothing
	static inline var PASSED = 0x80030100;    // a hook that looks and lets the original run
	static inline var ANSWERED = 0x80030200;  // a hook that answers the call itself
	static inline var WRAPPED = 0x80030300;   // before, the original, after
	static inline var TWICE = 0x80030400;     // two hooks: the first to answer wins

	static var originals = 0;
	static var seen = 0;
	static var frames = 0;
	static var boots = 0;

	public static function main():Void {
		Conf.feedName("ModHooks");
		final ctx = new CpuState();
		core.Runtime.boot(ctx);
		ctx.nextEvent = 0x7fffffff;
		core.Runtime.bindDispatch(dispatch);

		ModHost.heap(0x8000E000, 64);
		for (a in [PASSED, ANSWERED, WRAPPED, TWICE]) ModHost.declare(a);
		ModHost.hook(PASSED, look);
		ModHost.hook(ANSWERED, answer);
		ModHost.hook(WRAPPED, wrap);
		ModHost.hook(TWICE, decline);
		ModHost.hook(TWICE, answer);
		ModHost.hook(TWICE, look);
		ModHost.onFrame(frame);
		ModHost.onBoot(boot);
		Conf.expect("installing makes the host active", ModHost.active ? 1 : 0, 1);

		for (round in 0...4) {
			final arg = round * 1000 + 17;
			Conf.feed(run(ctx, PLAIN, arg));
			Conf.feed(run(ctx, PASSED, arg));
			Conf.feed(run(ctx, ANSWERED, arg));
			Conf.feed(run(ctx, WRAPPED, arg));
			Conf.feed(run(ctx, TWICE, arg));
			Conf.feed(originals);
			Conf.feed(seen);
		}
		Conf.expect("an unhooked function runs", run(ctx, PLAIN, 21), 42);
		Conf.expect("a hook that declines leaves the original", run(ctx, PASSED, 21), 42);
		Conf.expect("an answered call skips the original", run(ctx, ANSWERED, 21), 7);
		Conf.expect("a wrapped call runs the original once, between", run(ctx, WRAPPED, 21), (22 * 2 + 100) | 0);
		Conf.expect("the first hook to answer wins", run(ctx, TWICE, 21), 7);
		originals = 0;
		run(ctx, WRAPPED, 1);
		Conf.expect("callOriginal does not re-enter its hook", originals, 1);
		Conf.expect("ra survives a guest call from a mod", ctx.ra, 0x12345678);

		// Frame and boot handlers, and the heap boot resets.
		for (i in 0...5) ModHost.frame(ctx);
		Conf.expect("frame handlers run every frame", frames, 5);
		final first = ModHost.cstring("ONLINE");
		Conf.expect("the heap starts at its base", first, 0x8000E000);
		Conf.expect("a string is its bytes", ModHost.read8u(first) | (ModHost.read8u(first + 5) << 8), 0x4F | (0x45 << 8));
		Conf.expect("and a terminator", ModHost.read8u(first + 6), 0);
		final second = ModHost.alloc(5);
		Conf.expect("allocations are word-aligned", second, 0x8000E008);
		final copied = ModHost.copy(first, 8);
		Conf.expect("a copy reads what it copied", ModHost.read32(copied), ModHost.read32(first));
		Conf.expect("the heap refuses what does not fit", ModHost.alloc(64), 0);
		ModHost.boot(ctx);
		Conf.expect("boot handlers run", boots, 1);
		Conf.expect("boot starts the heap again", ModHost.alloc(4), 0x8000E000);
		Conf.feed(ModHost.read32(0x8000E000));
		Conf.feed(ModHost.read32(0x8000E004));

		// Mod memory past 2 MB, as the memory map's slow path reaches it in a mods build.
		final at = mod.ModRam.BASE + mod.ModRam.RESERVED;
		mod.ModRam.allocate(0x200);
		Conf.expect("mod memory starts empty", mod.ModRam.read32(at), 0);
		mod.ModRam.write32(at, 0x9F001234);
		mod.ModRam.write16(at + 4, 0xBEEF);
		mod.ModRam.write8(at + 6, 0x5A);
		Conf.expect("a word", mod.ModRam.read32(at), 0x9F001234);
		Conf.expect("a halfword", mod.ModRam.read16(at + 4), 0xBEEF);
		Conf.expect("a byte", mod.ModRam.read8(at + 6), 0x5A);
		Conf.expect("its first byte is its base", mod.ModRam.contains(mod.ModRam.BASE) ? 1 : 0, 1);
		Conf.expect("its last", mod.ModRam.contains(mod.ModRam.BASE + 0x1FF) ? 1 : 0, 1);
		Conf.expect("and nothing past it", mod.ModRam.contains(mod.ModRam.BASE + 0x200) ? 1 : 0, 0);
		Conf.expect("nor RAM", mod.ModRam.contains(0x000E000) ? 1 : 0, 0);
		Conf.feed(mod.ModRam.read32(at + 4));
		Conf.report("ModHooks");
	}

	/** A guest call as generated code makes one: `ra` set, the program's loop, the result in v0. */
	static function run(ctx:CpuState, addr:Int, arg:Int):Int {
		ctx.a0 = arg;
		ctx.v0 = 0;
		ctx.ra = 0x12345678;
		core.Runtime.call(ctx, addr);
		return ctx.v0;
	}

	/** The program's table, as `FnTable.call` would be: every address here is one function. */
	static function dispatch(addr:Int, ctx:CpuState):Bool {
		var found = true;
		if (addr == PLAIN) plain(ctx);
		else if (addr == PASSED || addr == ANSWERED || addr == WRAPPED || addr == TWICE) hooked(ctx, addr);
		else found = false;
		return found;
	}

	static function plain(ctx:CpuState):Void {
		ctx.v0 = (ctx.a0 * 2) | 0;
	}

	/** A hooked function: the emitted entry line, then the body. */
	static function hooked(ctx:CpuState, addr:Int):Void {
		if (ModHost.enter(ctx, addr)) return;
		originals++;
		ctx.v0 = (ctx.a0 * 2) | 0;
		// A callee clobbers `ra` as any guest function may; the mod host restores it.
		ctx.ra = 0;
	}

	static function look(ctx:CpuState, addr:Int):Bool {
		seen++;
		return false;
	}

	static function decline(ctx:CpuState, addr:Int):Bool {
		return false;
	}

	static function answer(ctx:CpuState, addr:Int):Bool {
		ctx.v0 = 7;
		return true;
	}

	static function wrap(ctx:CpuState, addr:Int):Bool {
		ctx.a0 = (ctx.a0 + 1) | 0;
		ModHost.callOriginal(ctx, addr);
		ctx.v0 = (ctx.v0 + 100) | 0;
		return true;
	}

	static function frame(ctx:CpuState):Void {
		frames++;
	}

	static function boot(ctx:CpuState):Void {
		boots++;
	}
}
