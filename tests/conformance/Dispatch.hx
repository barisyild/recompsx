import core.CpuState;
import kernel.OverlayMgr;

/** Synthetic executable/overlay tables from TestOverlay, compiled by today's generator. */
@:access(kernel.OverlayMgr)
class Dispatch {
	static inline var BASE = 0x80010000;
	static inline var WINDOW = 0x80020000;

	public static function main():Void {
		core.Runtime.boot(new CpuState());
		FnTable.init();
		Overlays.init();
		Conf.feedName("Dispatch");
		// A missing address must never match an uninitialized cache tag.
		Conf.expect("minus one on a cold cache", FnTable.lookup(-1), -1);
		Conf.expect("zero on a cold cache", FnTable.lookup(0), -1);
		final entry = FnTable.lookup(BASE);
		Conf.expect("first row is callable", entry, 0);
		Conf.expect("interior resume is not an entry", FnTable.isEntry(BASE + 8) ? 1 : 0, 0);
		Conf.expect("interior resume exists", FnTable.lookup(BASE + 8) >= 0 ? 1 : 0, 1);
		// These addresses collide in the direct-mapped cache, including a cached miss.
		for (i in 0...64) {
			Conf.expect("collision miss", FnTable.lookup(BASE + 0x1000), -1);
			Conf.expect("collision restores row zero", FnTable.lookup(BASE), entry);
			Conf.expect("repeated hit", FnTable.lookup(BASE), entry);
			Conf.expect("bad overlay id", Overlays.lookup(-1, WINDOW), -1);
			Conf.expect("past final overlay", Overlays.lookup(2, WINDOW), -1);
			Conf.expect("overlay-only address is absent from exe", FnTable.lookup(WINDOW + 0x40), -1);
			final a = Overlays.lookup(0, WINDOW + 0x40);
			final b = Overlays.lookup(1, WINDOW + 0x40);
			Conf.expect("both overlays have their own row", a >= 0 && b >= 0 && a != b ? 1 : 0, 1);
			Conf.expect("revisiting overlay keeps its row", Overlays.lookup(0, WINDOW + 0x40), a);
			Conf.expect("same-address different overlay", Overlays.lookup(1, WINDOW + 0x40), b);
		}
		// Dispatch must honor resident-window shadowing, even when the overlay has no row.
		final ctx = new CpuState();
		ctx.nextEvent = 0x7fffffff;
		ctx.v0 = 99;
		Conf.expect("base code before overlay load", FnTable.call(WINDOW + 0x60, ctx) ? 1 : 0, 1);
		Conf.expect("base callee writes through", ctx.v0, 0);
		OverlayMgr.define(0, WINDOW, WINDOW + 0x80, OverlayMgr.hashOf(WINDOW, 64), 16);
		OverlayMgr.rescan();
		Conf.expect("resident miss shadows base", FnTable.call(WINDOW + 0x60, ctx) ? 1 : 0, 0);
		ctx.v0 = 42;
		Conf.expect("overlay code dispatches", FnTable.call(WINDOW + 0x40, ctx) ? 1 : 0, 1);
		Conf.expect("overlay callee writes through", ctx.v0, 0);
		FnTable.init();
		Overlays.init();
		Conf.expect("repeated init preserves cache answers", FnTable.lookup(BASE), entry);
		Conf.report("Dispatch");
	}
}
