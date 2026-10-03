import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Program;
import recomp.codegen.ProjectionShare;
import recomp.codegen.Universe;

/**
	Memory projections shared within one emitted class (ProjectionShare, ADR-0044), through the
	whole Program: shard assembly, overlay body forwarding, hooks and the opt-out. Execution of
	shared pairs on both targets is the `ScalarShare` conformance group.
**/
@:access(TestCodegen)
@:access(TestOverlay)
class TestProjectionShare {
	static inline var BASE = 0x80010000;
	static inline var M = 0x80011000;      // lw v0,0(a0); jr ra; lw t0,4(a0)
	static inline var N = 0x80011100;      // the same code at another address
	static inline var WINDOW = 0x80020000;
	static inline var JR = 0x03e00008;
	static final NAME = ~/\bf_[0-9a-f]{8}_(?:projected|withSpans|value)_from_[0-9A-F]{8}_[0-9A-F]{8}\b/g;
	static final DEF = ~/public static function (f_[0-9a-f]{8}_(?:projected|withSpans|value)_from_[0-9A-F]{8}_[0-9A-F]{8})\(/g;

	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function move(rd:Int, rs:Int):Int return TestCodegen.alu(0x21, rd, rs, 0);

	/** A caller kept out of whole-function recovery (`mthi`) that calls `callee` once. `borrow`
	    loads through a0 first, giving it a span the callee can borrow; `deadV0` overwrites v0
	    and keeps t0, where the others overwrite t0 and keep v0. */
	static function caller(callee:Int, borrow:Bool = false, deadV0:Bool = false):Array<Int> {
		final w = [move(16, 31), TestCodegen.alu(0x11, 0, 4, 0)];
		if (borrow) { w.push(imm(0x24, 12, 4, 0)); w.push(imm(0x24, 13, 4, 7)); }
		w.push(TestCodegen.jal(callee)); w.push(0);
		w.push(deadV0 ? imm(9, 2, 0, 41) : imm(9, 8, 0, 41));
		w.push(move(31, 16)); w.push(JR); w.push(0);
		return w;
	}
	static final CALLEE = [imm(0x23, 2, 4, 0), JR, imm(0x23, 8, 4, 4)];

	static function place(image:Array<Int>, at:Int, code:Array<Int>):Void {
		for (i in 0...code.length) image[((at - BASE) >> 2) + i] = code[i];
	}

	static function universe(exeWords:Array<Int>, seeds:Array<Int>):{exe:recomp.loader.PsxExe, u:Universe} {
		final exe = TestOverlay.exeOf(TestOverlay.words(exeWords));
		final image = Image.ofExe('projection sharing', exe);
		final d = new Discovery(image);
		for (s in seeds) d.addSeed(s, Discovery.defaultName(s), Confidence.Entry);
		d.run(false);
		return {exe: exe, u: new Universe(null, image, d, null)};
	}

	static function count(text:String, re:EReg):Int {
		var n = 0;
		re.map(text, m -> { n++; return m.matched(0); });
		return n;
	}

	/** Every projection a file calls is defined in that file, once, and every one it defines is called. */
	static function wellFormed(files:Map<String, String>, what:String):Void {
		for (name => text in files) {
			if (!StringTools.endsWith(name, '.hx')) continue;
			final defs:Map<String, Int> = [];
			DEF.map(text, m -> { final k = m.matched(1); defs.set(k, (defs.exists(k) ? defs.get(k) : 0) + 1); return m.matched(0); });
			final refs:Map<String, Int> = [];
			NAME.map(text, m -> { final k = m.matched(0); refs.set(k, (refs.exists(k) ? refs.get(k) : 0) + 1); return k; });
			var ok = true;
			for (k => c in defs) if (c != 1 || refs.get(k) <= 1) ok = false;
			for (k in refs.keys()) if (!defs.exists(k)) ok = false;
			Assert.isTrue(ok, '$what: $name defines exactly the projections it calls');
		}
	}

	static function names(text:String, kind:String, callee:Int):Array<String> {
		final re = new EReg('public static function (f_${StringTools.hex(callee, 8).toLowerCase()}_${kind}_from_[0-9A-F]{8}_[0-9A-F]{8})\\(', 'g');
		final out = [];
		re.map(text, m -> { out.push(m.matched(1)); return m.matched(0); });
		return out;
	}

	static function sameClass():Void {
		Assert.group('projection sharing: equal pairs in one class, distinct ones kept');
		final w = [for (_ in 0...0x480) 0];
		place(w, BASE, [JR, 0]);
		final callers = [BASE + 0x100, BASE + 0x200, BASE + 0x300, BASE + 0x400, BASE + 0x500, BASE + 0x600];
		place(w, callers[0], caller(M));                 // A: fresh preflight, t0 dead
		place(w, callers[1], caller(M));                 // B: equal to A
		place(w, callers[2], caller(M, true));           // C: borrows a0's span
		place(w, callers[3], caller(M, true));           // D: equal to C
		place(w, callers[4], caller(M, false, true));    // E: v0 dead instead
		place(w, callers[5], caller(N));                 // F: equal code, other callee
		place(w, M, CALLEE); place(w, N, CALLEE);
		final built = universe(w, [BASE].concat(callers).concat([M, N]));
		final p = new Program([built.u], built.exe);
		final files = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share');
		final text = files.get('Fns_00_80010000.hx');
		Assert.isTrue(text != null, 'one shard holds every caller');
		final fresh = names(text, 'projected', M), borrowed = names(text, 'withSpans', M), other = names(text, 'projected', N);
		Assert.equals(fresh.length, 2, 'A and B share one fresh pair; E keeps its own');
		Assert.equals(borrowed.length, 1, 'C and D share one borrowed pair, kept apart from the fresh one');
		Assert.equals(other.length, 1, 'equal code at another callee is not shared');
		Assert.equals(p.projectionsShared, 2, 'two call sites renamed');
		final a = 'f_80011000_projected_from_80010100_80010108';
		Assert.isTrue(fresh.indexOf(a) >= 0, 'the first site in emission order keeps its names');
		Assert.equals(count(text, new EReg('\\b$a\\(ctx\\);', 'g')), 2, 'A and B both call the first pair');
		Assert.isTrue(text.indexOf('f_80011000_projected_from_80010200_80010208') < 0, "B's own copy is not emitted");
		final e = fresh.filter(n -> n != a)[0];
		final eHelper = StringTools.replace(e, '_projected_', '_value_'), aHelper = StringTools.replace(a, '_projected_', '_value_');
		Assert.isTrue(text.indexOf('ctx.t0 =', text.indexOf('function $e(')) >= 0
			&& text.indexOf('function $eHelper(') >= 0 && text.indexOf('function $aHelper(') >= 0,
			'the pair with a different dead result keeps its own helper and publication');
		Assert.isTrue(text.indexOf('Fns_00_80010000.f_80011100(ctx)') >= 0, "F's pair falls back to its own callee");
		wellFormed(files, 'shared program');

		final again = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share');
		Assert.isTrue(again.get('Fns_00_80010000.hx') == text, 'sharing is deterministic across writes');

		p.shareProjections = false;
		final off = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share').get('Fns_00_80010000.hx');
		Assert.equals(names(off, 'projected', M).length + names(off, 'withSpans', M).length, 5, 'opt-out: every site keeps its pair');
		Assert.equals(p.projectionsShared, 0, 'opt-out shares nothing');
		Assert.isTrue(off.indexOf('f_80011000_projected_from_80010200_80010208(ctx);') >= 0, 'opt-out: B calls its own pair');
		p.shareProjections = true;

		p.setHooks([{addr: M, scope: 'exe'}]);
		final hooked = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share');
		final h = hooked.get('Fns_00_80010000.hx');
		Assert.equals(names(h, 'projected', M).length + names(h, 'withSpans', M).length, 0, 'a hooked callee has no projections to share');
		Assert.equals(names(h, 'projected', N).length, 1, 'other callees keep theirs');
		wellFormed(hooked, 'hooked program');
	}

	static function shardBoundary():Void {
		Assert.group('projection sharing: never across a class');
		final w = [for (_ in 0...0x480) 0];
		place(w, BASE, caller(M));
		final fillers = [for (i in 0...120) BASE + 0x100 + i * 8];
		for (f in fillers) place(w, f, [JR, 0]);
		place(w, BASE + 0x800, caller(M));
		place(w, M, CALLEE);
		final built = universe(w, [BASE].concat(fillers).concat([BASE + 0x800, M]));
		final p = new Program([built.u], built.exe);
		final files = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share2');
		var classes = 0;
		for (name => text in files) if (StringTools.startsWith(name, 'Fns_') && names(text, 'projected', M).length == 1) classes++;
		Assert.equals(classes, 2, 'two shards each define the pair their own caller uses');
		Assert.equals(p.projectionsShared, 0, 'equal pairs in different classes stay apart');
		wellFormed(files, 'two-shard program');
	}

	static function overlays():Void {
		Assert.group('projection sharing: with overlay body forwarding');
		final w = [for (_ in 0...0x480) 0];
		place(w, BASE, [JR, 0]); place(w, M, CALLEE);
		final exe = TestOverlay.exeOf(TestOverlay.words(w));
		final baseImage = Image.ofExe('projection sharing', exe);
		final d = new Discovery(baseImage); d.addSeed(BASE, 'entry', Confidence.Entry); d.addSeed(M, Discovery.defaultName(M), Confidence.Entry);
		d.run(false);
		final universes = [new Universe(null, baseImage, d, null)];
		for (id in ['a', 'b']) {
			final cfg = TestOverlay.overlayConfig(id);
			final ow = [for (_ in 0...32) 0];
			ow[0] = imm(9, 2, 0, id == 'a' ? 1 : 2); ow[1] = JR; ow[2] = 0;   // the fingerprint differs
			final c = caller(M);
			for (i in 0...c.length) { ow[8 + i] = c[i]; ow[16 + i] = c[i]; }
			final bytes = TestOverlay.words(ow);
			final image = Image.ofExeWithOverlay('projection sharing:$id', exe, bytes, cfg.loadAddr);
			final od = new Discovery(image, cfg.loadAddr, cfg.endAddr(), true);
			for (at in [WINDOW, WINDOW + 0x20, WINDOW + 0x40]) od.addSeed(at, Discovery.defaultName(at), Confidence.Entry);
			od.run();
			universes.push(new Universe(cfg, image, od, bytes));
		}
		final p = new Program(universes, exe);
		final files = TestOverlay.writeAndRead(p, 'out/_tooltest_projection_share3');
		var a:String = null, b:String = null;
		for (name => text in files) {
			if (StringTools.startsWith(name, 'Ovl_a_')) a = text;
			if (StringTools.startsWith(name, 'Ovl_b_')) b = text;
		}
		Assert.isTrue(a != null && b != null, 'both overlays were written');
		Assert.equals(names(a, 'projected', M).length, 1, "the first overlay's two callers share one pair");
		Assert.equals(names(b, 'projected', M).length, 0, 'the second forwards its equal bodies instead');
		Assert.isTrue(b.indexOf('Identical to `') >= 0, 'the forwarded bodies name their owner');
		Assert.equals(p.projectionsShared, 1, 'one site renamed in the owning class');
		wellFormed(files, 'overlay program');
	}

	static function unit():Void {
		Assert.group('projection sharing: exact keys');
		function pair(site:String, constant:Int, adapter:Bool = true):ProjectionText {
			final helper = 'f_80011000_value_from_$site', projected = 'f_80011000_projected_from_$site';
			return {helper: helper, adapter: projected,
				text: '\tpublic static function $helper(a0:Int):Int {\n\t\treturn (a0 + $constant) | 0;\n\t}\n'
					+ (adapter ? '\tpublic static function $projected(ctx:core.Ctx):Void {\n\t\tctx.v0 = $helper(ctx.a0);\n\t}\n' : '')};
		}
		final one = pair('80010100_80010108', 4), two = pair('80010200_80010208', 4), three = pair('80010300_80010308', 5);
		final share = new ProjectionShare();
		final first = share.apply('\t\tf_80011000_projected_from_80010100_80010108(ctx);\n' + one.text, [one]);
		Assert.equals(first, '\t\tf_80011000_projected_from_80010100_80010108(ctx);\n' + one.text, 'a first pair is kept as is');
		final second = share.apply('\t\tf_80011000_projected_from_80010200_80010208(ctx);\n' + two.text + three.text, [two, three]);
		Assert.equals(second, '\t\tf_80011000_projected_from_80010100_80010108(ctx);\n' + three.text,
			'an equal pair is renamed and dropped; one constant apart is kept');
		Assert.equals(share.shared, 1, 'one site shared');
		final lone = pair('80010400_80010408', 4, false);
		Assert.equals(share.apply('x\n' + lone.text, [lone]), 'x\n' + lone.text, 'a pair without its adapter is never shared');
		var threw = false;
		try share.apply('not the tail', [two]) catch (e:Dynamic) threw = true;
		Assert.isTrue(threw, 'attachments that are not the text tail are an error, never guessed');
		Assert.isTrue(ProjectionShare.keyOf(one) == ProjectionShare.keyOf(two), 'names are the only normalized part');
		Assert.isTrue(ProjectionShare.keyOf(one) != ProjectionShare.keyOf(three), 'constants are part of the key');
	}

	// ---- the ScalarShare conformance fixture ---------------------------------------------------

	static inline var FBASE = 0x80150000;
	static inline var FM = FBASE + 0x400;
	static inline var FN = FBASE + 0x500;
	/** Callers A..G at FBASE + 0x40k: A and B equal (fresh), C and D equal (borrowed spans),
	    E with a different dead result, F calling an equal callee at another address, and G
	    calling M twice in one function. */
	public static inline var KINDS = 7;

	static function fixtureCaller(kind:Int):Array<Int> {
		return switch (kind) {
			case 0 | 1: caller(FM);
			case 2 | 3: caller(FM, true);
			case 4: caller(FM, false, true);
			case 5: caller(FN);
			case _: [move(16, 31), TestCodegen.alu(0x11, 0, 4, 0), TestCodegen.jal(FM), 0, imm(9, 8, 0, 41),
				TestCodegen.jal(FM), 0, imm(9, 8, 0, 42), move(31, 16), JR, 0];
		}
	}

	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'ShareOptimized' : 'ShareReference';
		final w = [for (_ in 0...0x180) 0];
		for (kind in 0...KINDS) {
			final c = fixtureCaller(kind);
			for (i in 0...c.length) w[(kind << 4) + i] = c[i];
		}
		for (i in 0...CALLEE.length) { w[((FM - FBASE) >> 2) + i] = CALLEE[i]; w[((FN - FBASE) >> 2) + i] = CALLEE[i]; }
		final bytes = Bytes.alloc(w.length * 4);
		for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
		final image = new Image('projection share', FBASE, bytes);
		final d = new Discovery(image);
		for (kind in 0...KINDS) d.addSeed(FBASE + (kind << 6), 'share$kind', Confidence.Entry);
		for (a in [FM, FN]) d.addSeed(a, Discovery.defaultName(a), Confidence.Entry);
		d.run(false);
		final emitter = new recomp.codegen.Emitter(image, d, opt);
		final pool = new recomp.codegen.ScalarPool(cls + 'Values');
		emitter.scalarPool = pool;
		emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
		final summaries = [for (a in [FM, FN]) a => new recomp.analysis.FunctionSummary(d.functions.get(a), image, _ -> null)];
		recomp.analysis.FunctionSummary.solve([for (s in summaries) s]);
		emitter.writesOf = a -> summaries.exists(a) ? summaries.get(a).writes : recomp.codegen.Emitter.ALL_REGS;
		final share = new ProjectionShare();
		final bodies = new StringBuf(), dispatch = new StringBuf(), resume = new StringBuf();
		final entries = new StringBuf(), counts = new StringBuf();
		final order = [for (a in d.functions.keys()) a];
		order.sort((x, y) -> x < y ? -1 : (x > y ? 1 : 0));
		for (a in order) {
			final fn = d.functions.get(a);
			bodies.add(share.apply(emitter.emitFunction(fn), emitter.lastProjections));
			resume.add('case ${fn.entry}: ${fn.name}(ctx, entry);\n');
			final blocks = recomp.codegen.Emitter.blockOrder(fn);
			for (i in 0...blocks.length) dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
			if (a < FM) {
				final kind = (a - FBASE) >> 6;
				counts.add('case $kind: ${blocks.length};\n');
				entries.add('case $kind: switch(entry) {\n' + [for (i in 0...blocks.length) 'case $i: ${blocks[i]};\n'].join('')
					+ 'default: -1; }\n');
			}
		}
		final text = bodies.toString();
		if (check) {
			if (opt) {
				Assert.equals(share.shared, 4, 'fixture: B, D and both of G\'s sites share an earlier pair');
				Assert.equals(count(text, ~/public static function f_8015[0-9a-f]{4}_(?:projected|withSpans)_from_/g), 4, 'fixture: four distinct pairs remain');
				Assert.equals(pool.count, 0, 'fixture: memory projections stay outside the pure pool');
				wellFormed(['fixture.hx' => text], 'fixture');
			} else Assert.equals(share.shared, 0, 'reference fixture has no projections');
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var KINDS = $KINDS;\n' + text
			+ 'public static function entryCount(kind:Int):Int { return switch(kind) {\n' + counts.toString() + 'default: 0; }; }\n'
			+ 'public static function entryAddress(kind:Int, entry:Int):Int { return switch(kind) {\n' + entries.toString() + 'default: -1; }; }\n'
			+ 'public static function resume(fn:Int, entry:Int, ctx:CpuState):Void { switch(fn) {\n' + resume.toString() + 'default: } }\n'
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n' + dispatch.toString() + 'default: return false; } }\n}\n';
	}

	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		sys.io.File.saveContent('out/_codegen/fixtures/ShareOptimized.hx', source(true, check));
		sys.io.File.saveContent('out/_codegen/fixtures/ShareReference.hx', source(false, check));
	}

	public static function main():Void generate(false);

	public static function run():Void {
		unit();
		sameClass();
		shardBoundary();
		overlays();
		Assert.group('projection sharing: the ScalarShare fixture');
		generate(true);
	}
}
