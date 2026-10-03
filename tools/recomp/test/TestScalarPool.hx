import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Program;
import recomp.codegen.ScalarPlan;
import recomp.codegen.ScalarPool;
import recomp.codegen.Universe;

/** Sharing is keyed by the calculation, never by a guest address or an overlay identity. */
@:access(TestOverlay)
@:access(TestDiscovery)
@:access(TestCodegen)
class TestScalarPool {
	static inline var JR = 0x03e00008;
	static inline var BASE = 0x80010000;
	static inline var WINDOW = 0x80020000;
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);

	static function code(callee:Int, shift:Int, cfg:Bool):Array<Int> {
		final w = [alu(0x21, 16, 31, 0), TestCodegen.jal(callee), 0, imm(9, 8, 0, 41),
			alu(0x21, 31, 16, 0), JR, 0];
		while (w.length < 16) w.push(0);
		if (cfg) {
			for (x in [imm(12, 8, 4, 65535), imm(4, 5, 4, 4), 0, imm(9, 2, 8, shift), JR, 0, JR, imm(9, 2, 8, shift + 1)]) w.push(x);
		} else {
			w.push(alu(0x21, 8, 4, 5)); w.push(alu(0, 2, 0, 8) | (shift << 6));
			w.push(JR); w.push(0);
		}
		while (w.length < 32) w.push(0);
		return w;
	}

	static function program(opt:Bool = true, scalar:Bool = true, cfgFlow:Bool = false):Program {
		final exe = TestOverlay.exeOf(TestOverlay.words(code(BASE + 64, 1, cfgFlow)));
		final image = Image.ofExe('pool test', exe);
		final d = new Discovery(image);
		d.addSeed(BASE, Discovery.defaultName(BASE), Confidence.Entry); d.run(false);
		final universes = [new Universe(null, image, d, null)];
		for (i in 0...2) {
			final cfg = TestOverlay.overlayConfig(i == 0 ? 'a' : 'b');
			final w = code(WINDOW + 64, i + 1, cfgFlow);
			w[8] = i + 1; // Unreachable fingerprint padding; the entry code itself stays identical.
			final bytes = TestOverlay.words(w);
			final image = Image.ofExeWithOverlay('pool overlay', exe, bytes, WINDOW);
			final d = new Discovery(image, WINDOW, cfg.endAddr(), true);
			d.addSeed(WINDOW, Discovery.defaultName(WINDOW), Confidence.Entry); d.run(false);
			universes.push(new Universe(cfg, image, d, bytes));
		}
		return new Program(universes, exe, 0, opt, true, null, scalar);
	}

	static function joined(files:Map<String, String>):String {
		return [for (name => text in files) if (StringTools.startsWith(name, 'Fns_')
			|| StringTools.startsWith(name, 'Ovl_')) text].join('\n');
	}

	public static function run():Void {
		Assert.group('scalar pool: overlays, regeneration, hooks and opt-outs');
		for (cfg in [false, true]) validate(cfg);
		final d = TestDiscovery.discover([imm(0x23, 2, 4, 0), JR, 0]);
		final plan = ScalarPlan.analyze(d.functions.get(BASE), d.image);
		Assert.isTrue(plan != null && plan.memory != null, 'checked memory helper fixture');
		final pool = new ScalarPool('MustStayPure');
		Assert.rejects(() -> pool.intern(plan), 'memory helpers', 'read helpers cannot enter pure pool');
		Assert.equals(pool.count, 0, 'failed pool insertion has no side effects');
	}

	static function validate(cfg:Bool):Void {
		final p = program(true, true, cfg);
		final dir = 'out/_tooltest_scalar_pool';
		final files = TestOverlay.writeAndRead(p, dir);
		final shared = files.get('ScalarValues.hx');
		Assert.isTrue(shared != null, 'shared module emitted');
		Assert.equals(shared.split('public static function').length - 1, 2, 'base and overlay share computation, different code stays separate');
		Assert.equals(joined(files).split('ScalarValues.value_0(').length - 1, 2, 'identical calculation called from two universes');
		Assert.equals(joined(files).split('ScalarValues.value_1(').length - 1, 1, 'same guest address in another overlay has a different body');
		Assert.isTrue(joined(files).indexOf('_value_from_') < 0, 'no caller-owned copies');
		final written = p.filesWritten;
		final again = TestOverlay.writeAndRead(p, dir);
		Assert.equals(p.filesWritten, written, 'per-write statistics reset');
		for (name => text in files) Assert.equals(again.get(name), text, 'repeat write recreates complete module ' + name);
		p.setHooks([{addr: WINDOW + 64, scope: 'b'}]);
		final hooked = TestOverlay.writeAndRead(p, dir);
		Assert.equals(hooked.get('ScalarValues.hx').split('public static function').length - 1, 1, 'hooked body excluded from pool');
		Assert.isTrue(joined(hooked).indexOf('ScalarValues.value_1(') < 0, 'no stale pooled reference after hook change');
		for (disabled in [program(false, true, cfg), program(true, false, cfg)]) {
			final off = TestOverlay.writeAndRead(disabled, dir);
			Assert.isTrue(!off.exists('ScalarValues.hx'), 'opt-out removes the old shared module');
			Assert.isTrue(joined(off).indexOf('ScalarValues.') < 0, 'opt-out removes all shared calls');
		}
		if (cfg) Assert.isTrue(shared.indexOf('ScalarResult.accounting') >= 0, 'CFG pool retains the second return word');
	}
}
