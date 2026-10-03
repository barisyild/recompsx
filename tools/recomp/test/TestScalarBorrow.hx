import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.FunctionSummary;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarBorrow;
import recomp.codegen.ScalarEntry;
import recomp.codegen.ScalarPlan.ScalarMemory;
import sys.io.File;

@:access(TestCodegen)
@:access(TestOverlay)
class TestScalarBorrow {
	static inline var BASE = 0x80140000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 47;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function move(rd:Int, rs:Int):Int return TestCodegen.alu(0x21, rd, rs, 0);
	static function projectionWords(base:Int, kind:Int):Array<Int> {
		// MTHI keeps the whole caller outside scalar recovery, so this exercises the
		// actual direct-call adapter instead of folding caller and child together.
		var w = [move(16,31), TestCodegen.alu(0x11,0,4,0), imm(0x24,12,4,0), imm(0x24,13,4,7)];
		if (kind == 43 || kind == 46) w.resize(2);
		if (kind == 44) w.push(imm(0x2b,5,4,0));
		if (kind == 40) { w.push(imm(0x24,14,5,0)); w.push(imm(0x24,15,5,7)); }
		w.push(TestCodegen.jal(base+128)); w.push(0);
		if (kind == 36) w.push(imm(0x24,14,4,0)); // An observation before overwrite forbids omission.
		if (kind == 37 || kind == 38) {
			w = w.concat([imm(4,0,6,3),0,imm(9,8,0,41),0]);
			if (kind == 38) w.push(imm(9,8,0,42)); // Both paths overwrite, unlike case 37.
		} else w.push(imm(9,8,0,41));
		if (kind == 33 || kind == 43) w.push(imm(9,9,0,42));
		if (kind == 42) { w.push(move(4,5)); w.push(imm(0x24,3,4,0)); }
		w.push(move(31,16)); w.push(JR); w.push(0);
		while (w.length < 32) w.push(0);
		return w.concat(switch (kind) {
			case 33 | 43: [imm(0x24,8,4,0),JR,imm(0x24,9,4,0)];
			case 34: [imm(0x2b,6,4,0),imm(0x23,2,4,0),JR,imm(0x23,8,4,4)];
			case 35: [imm(4,0,6,3),0,JR,imm(0x23,8,4,4),JR,imm(0x23,2,4,0)];
			case 39: [imm(0x23,2,4,0),JR,imm(0x23,8,4,8)]; // Incomplete donor coverage.
			case 40: [imm(0x23,2,4,0),imm(0x2b,6,5,0),JR,imm(0x23,8,4,0)];
			case 41: [imm(0x23,2,4,0),JR,imm(9,8,4,4)];
			case 42: [imm(0x23,2,4,0),JR,imm(9,4,4,4)];
			case 44: [imm(0x23,8,4,0),JR,imm(0x24,2,8,0)];
			case 45: [imm(15,8,0,0x8004),JR,imm(0x23,2,8,0)];
			case 46: [imm(0x2b,6,4,0),JR,imm(0x23,8,4,0)];
			case _: [imm(0x23,2,4,0),JR,imm(0x23,8,4,4)];
		});
	}
	static function aliasWords(base:Int, kind:Int):Array<Int> {
		final lo = kind == 19 || kind == 21 ? -8 : 0;
		final hi = kind == 18 || kind == 29 ? 15 : 7;
		final w = [move(16, 31), imm(0x24, 8, 18, lo), imm(0x24, 9, 18, hi)];
		if (kind == 28 || kind == 29) {
			w.push(imm(0x24, 10, 19, -8)); w.push(imm(0x24, 11, 19, 7));
		}
		if (kind == 25) w.push(move(18, 5));
		if (kind == 26) w.push(TestCodegen.alu(0x26, 18, 18, 6));
		if (kind == 31) { w.push(TestCodegen.jal(0x8000f020)); w.push(0); }
		if (kind != 17) w.push(imm(9, 4, 18, switch(kind) { case 18 | 29: 4; case 19: -4; case 24: 16; case 27: 32767; case _: 0; }));
		if (kind == 20) w.push(TestCodegen.alu(0, 18, 0, 18) | (1 << 6));
		if (kind == 23) {
			final target = base + (w.length + 2) * 4;
			w.push(0x08000000 | ((target & 0x0fffffff) >>> 2)); w.push(0);
		}
		if (kind == 28 || kind == 29) w.push(imm(9, 5, 19, kind == 29 ? -4 : 0));
		w.push(TestCodegen.jal(base + 128));
		w.push(switch(kind) { case 17: move(4, 18); case 21: imm(9, 18, 18, 4); case 22: imm(0x24, 10, 18, 0); case _: 0; });
		w.push(move(31, 16)); w.push(JR); w.push(0);
		while (w.length < 32) w.push(0);
		return w.concat(switch(kind) {
			case 28 | 29: [imm(0x2b, 6, 4, 0), imm(0x23, 2, 5, 0), JR, imm(0x23, 3, 4, 0)];
			case 30: [imm(4, 0, 6, 3), 0, JR, imm(0x2b, 6, 4, 4), JR, imm(0x23, 2, 4, 0)];
			case _: [imm(0x24, 2, 4, 0), JR, imm(0x24, 3, 4, 4)];
		});
	}
	static function words(base:Int, kind:Int):Array<Int> {
		if (kind >= 32) return projectionWords(base,kind);
		if (kind >= 16) return aliasWords(base, kind);
		final w = [move(16, 31), imm(0x24, 8, 4, kind == 2 ? -8 : 0), imm(0x24, 9, 4, kind == 1 ? 15 : 7)];
		if (kind == 8 || kind == 13) { w.push(imm(0x24, 10, 5, 0)); w.push(imm(0x24, 11, 5, 7)); }
		if (kind == 3) w.push(move(4, 5));
		if (kind == 6) { w.push(TestCodegen.jal(0x8000f020)); w.push(0); }
		if (kind == 14) { w.push(imm(4, 0, 6, 2)); w.push(0); w.push(move(4, 5)); }
		if (kind == 15) w.push(imm(9, 7, 0, 2));
		final callAt = base + w.length * 4;
		w.push(TestCodegen.jal(base + 128));
		w.push(kind == 4 ? imm(9, 4, 4, 4) : (kind == 5 ? move(4, 5) : 0));
		if (kind == 7) { w.push(TestCodegen.jal(base + 128)); w.push(0); }
		if (kind == 15) {
			w.push(imm(9, 7, 7, -1));
			w.push(imm(7, 0, 7, Std.int((callAt - (base + w.length * 4 + 4)) / 4))); w.push(0);
		}
		w.push(move(31, 16)); w.push(JR); w.push(0);
		while (w.length < 32) w.push(0);
		final child = switch (kind) {
			case 1: [imm(0x23, 2, 4, 4), JR, 0];
			case 2: [imm(0x23, 2, 4, -4), JR, 0];
			case 7 | 15: [imm(0x23, 2, 4, 0), JR, imm(9, 4, 4, 4)];
			case 8: [imm(0x2b, 6, 4, 0), imm(0x23, 2, 5, 0), JR, imm(0x23, 3, 4, 0)];
			case 9: [imm(4, 0, 6, 3), 0, JR, imm(0x2b, 6, 4, 4), JR, imm(0x23, 2, 4, 0)];
			case 10: [JR, imm(0x23, 2, 4, 8)]; // Not covered by caller's 0..7.
			case 11: [imm(15, 8, 0, 0x8004), JR, imm(0x23, 2, 8, 0)]; // Constant address.
			case 13: [imm(0x23, 2, 4, 0), JR, imm(0x23, 3, 5, 8)]; // One uncovered span rejects all.
			case _: [imm(0x24, 2, 4, 0), JR, imm(0x24, 3, 4, 4)];
		};
		return w.concat(child);
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'BorrowOptimized' : 'BorrowReference';
		final bodies = new StringBuf(); final dispatch = new StringBuf(); final resume = new StringBuf();
		final entries = new StringBuf(); final counts = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(base, kind); final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image('borrowed spans', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'borrow$kind', Confidence.Entry);
			d.addSeed(base + 128, Discovery.defaultName(base + 128), Confidence.Entry); d.run(false);
			final caller = d.functions.get(base); final callee = d.functions.get(base + 128);
			final emitter = new Emitter(image, d, opt);
			final pool = new recomp.codegen.ScalarPool(cls + 'ProjectionValues');
			if (kind >= 32) emitter.scalarPool = pool;
			final owner = opt && kind == 32 ? cls + 'Owner32' : cls;
			emitter.staticTargetOf = a -> kind != 12 && d.functions.exists(a) ? (a == base+128 ? owner : cls) : null;
			final summary = new FunctionSummary(callee, image, _ -> null); FunctionSummary.solve([summary]);
			emitter.writesOf = a -> a == base + 128 ? summary.writes : Emitter.ALL_REGS;
			final body = emitter.emitFunction(caller); final calleeBody = emitter.emitFunction(callee);
			bodies.add(body); bodies.add(calleeBody);
			if (opt && kind == 32) File.saveContent('out/_codegen/fixtures/' + owner + '.hx',
				'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $owner {\n' + calleeBody + '}\n');
			if (opt && kind == 8) {
				final plan = emitter.scalarPlan(callee);
				File.saveContent('out/_codegen/fixtures/BorrowForward.hx', 'class BorrowForward {\n'
					+ plan.emitHelper(cls) + ScalarEntry.borrowedAdapter(plan, cls) + '}\n');
			}
			counts.add('case $kind: ${Emitter.blockOrder(caller).length};\n');
			entries.add('case $kind: switch(entry) {\n');
			for (fn in [caller, callee]) {
				resume.add('case ${fn.entry}: ${fn.name}(ctx, entry);\n');
				final blocks = Emitter.blockOrder(fn);
				for (i in 0...blocks.length) {
					dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
					if (fn == caller) entries.add('case $i: ${blocks[i]};\n');
				}
			}
			entries.add('default: -1; }\n');
			if (check) {
				final projected = opt && [32,33,34,35,38,40,41,42].indexOf(kind) >= 0;
				final fresh = opt && [39,43,44,45,46].indexOf(kind) >= 0;
				final expected = opt && (kind < 10 || kind == 14 || kind == 15 || [16, 17, 18, 19, 21, 25, 26, 28, 29, 30, 31,36,37].indexOf(kind) >= 0);
				Assert.equals(body.indexOf(callee.name + '_withSpans_from_') >= 0, projected, 'memory projection eligibility $kind');
				Assert.equals(body.indexOf(callee.name + '_projected_from_') >= 0, fresh, 'fresh projection preflight $kind');
				if (projected || fresh) {
					final start = body.indexOf('public static function ' + callee.name + (fresh ? '_projected_from_' : '_withSpans_from_'));
					final adapter = body.substr(start);
					Assert.isTrue(adapter.indexOf('ctx.t0 =') < 0, 'dead result never published');
					Assert.isTrue(adapter.indexOf('|| ctx.unwindToken != 0') >= 0, 'pre-existing unwind preserves full observable state');
					Assert.isTrue(adapter.indexOf(owner + '.' + callee.name + '(ctx)') >= 0, 'projection fallback keeps the real owner');
					Assert.equals(pool.count, 0, 'memory projections stay outside pure body pool');
					if (kind == 33 || kind == 43) Assert.isTrue(body.indexOf('():Void {') >= 0 && adapter.indexOf('ctx.t1 =') < 0, 'all dead reads use Void without result transport');
					if (kind == 42) Assert.isTrue(adapter.indexOf('ctx.a0 =') < 0, 'overwritten pointer result is not published');
					if (fresh) Assert.isTrue(adapter.indexOf('Memory.span(') >= 0, 'complete access preflight without borrowed spans');
				}
				if (kind == 11) Assert.isTrue(calleeBody.indexOf('_withSpans') < 0, 'constant addresses have no borrowed adapter');
				Assert.equals(body.indexOf(callee.name + '_withSpans(') >= 0, expected, 'borrow eligibility $kind');
				if (expected) {
					Assert.isTrue(calleeBody.indexOf('|| !(Memory.spanOk(checked0)') >= 0, 'shared borrow validity guard $kind');
					Assert.isTrue(body.indexOf('|| !(Memory.spanOk(fspan_a0)') < 0, 'caller does not repeat guard $kind');
					Assert.isTrue(calleeBody.indexOf('|| core.Cooperative.resumeEntry >= 0') >= 0, 'shared entry checkpoint guard $kind');
					Assert.isTrue(calleeBody.indexOf(callee.name + '(ctx);') >= 0, 'whole callee fallback $kind');
					if (kind == 1 || kind == 2) {
						Assert.isTrue(calleeBody.indexOf('Memory.spanOffset(checked0, ' + (kind == 1 ? 4 : -4)) > calleeBody.indexOf('|| !(Memory.spanOk(checked0)'), 'covered rebasing inside shared guarded arm');
						Assert.isTrue(body.indexOf(callee.name + '_withSpans(ctx, fspan_a0)') >= 0, 'borrowed caller passes its unshifted valid-or-none span');
					}
					if (kind >= 16 && kind < 32) Assert.isTrue(body.indexOf('_withSpans(ctx, fspan_s2') >= 0 || body.indexOf('_withSpans(ctx, (Memory.spanOk(fspan_s2)') >= 0, 'borrow donor register span $kind');
					if (kind == 21) Assert.isTrue(body.indexOf('Memory.spanStep(fspan_s2, 4') >= 0, 'donor step is live through alias');
					if (kind == 4) Assert.isTrue(body.indexOf('Memory.spanStep(fspan_a0, 4') >= 0, 'last use after delay step stays live');
					if (kind == 3 || kind == 5 || kind == 6 || kind == 7) Assert.isTrue(body.split('fspan_a0 = Memory.span(ctx.a0').length > 2, 'pointer refresh before borrowed call');
				}
				if (opt && (kind == 0 || kind == 32 || kind == 43)) {
					emitter.hooks = [callee.entry => true];
					final hooked = emitter.emitFunction(caller);
					Assert.isTrue(hooked.indexOf(callee.name + '_withSpans') < 0 && hooked.indexOf(callee.name + '_projected') < 0, 'hook prevents memory helper');
					emitter.hooks = null; emitter.relocatable = true;
					final reloc = emitter.emitFunction(caller);
					Assert.isTrue(reloc.indexOf(callee.name + '_withSpans') < 0 && reloc.indexOf(callee.name + '_projected') < 0, 'relocatable caller excluded');
				}
			}
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n' + bodies.toString()
			+ 'public static function entryCount(kind:Int):Int { return switch(kind) {\n' + counts.toString() + 'default: 0; }; }\n'
			+ 'public static function entryAddress(kind:Int, entry:Int):Int { return switch(kind) {\n' + entries.toString() + 'default: -1; }; }\n'
			+ 'public static function resume(fn:Int, entry:Int, ctx:CpuState):Void { switch(fn) {\n' + resume.toString() + 'default: } }\n'
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n' + dispatch.toString() + 'default: return false; } }\n}\n';
	}
	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/BorrowOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/BorrowReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	static function programProjections():Void {
		// Exercise Program's residency/summary callbacks, not just a standalone Emitter.
		for (kind in 32...COUNT) {
			final base = 0x80010000;
			final exe = TestOverlay.exeOf(TestOverlay.words(projectionWords(base, kind)));
			final image = Image.ofExe('program memory projection', exe);
			final d = new Discovery(image);
			d.addSeed(base, 'caller', Confidence.Entry); d.run(false);
			final u = new recomp.codegen.Universe(null, image, d, null);
			final p = new recomp.codegen.Program([u], exe);
			final body = u.emitter.emitFunction(d.functions.get(base));
			final expected = kind != 36 && kind != 37;
			Assert.equals(body.indexOf('_withSpans_from_') >= 0 || body.indexOf('_projected_from_') >= 0,
				expected, 'Program enables guarded memory projections $kind');
			p.setHooks([{addr:base + 128, scope:'exe'}]);
			final hooked = u.emitter.emitFunction(d.functions.get(base));
			Assert.isTrue(hooked.indexOf('_withSpans_from_') < 0 && hooked.indexOf('_projected_from_') < 0,
				'Program hook invalidates a cached memory projection $kind');
		}
	}
	public static function run():Void {
		Assert.group('scalar calls borrow complete live spans without losing entry observations');
		final memory = new ScalarMemory(); memory.add(4, 4, 4);
		final borrowed = ScalarBorrow.analyze(memory, [4 => {v:'span',lo:0,hi:7}]);
		Assert.isTrue(borrowed != null, 'coverage includes last byte');
		Assert.isTrue(memory.spans[0].borrowedCondition('span').indexOf(' & 3) == 0') >= 0, 'range proof does not discard alignment');
		Assert.equals(borrowed.args[0], 'span', 'caller passes unshifted span to shared adapter');
		Assert.isTrue(ScalarBorrow.analyze(memory, [4 => {v:'span',lo:0,hi:6}]) == null, 'one missing byte rejects borrowing');
		final wrapped = new ScalarMemory(); wrapped.add(4, 0x7fffffff, 1);
		Assert.isTrue(ScalarBorrow.analyze(wrapped, [4 => {v:'span',lo:-8,hi:7}]) == null, 'wrapped anchor is not coverage');
		generate(true);
		programProjections();
	}
}
