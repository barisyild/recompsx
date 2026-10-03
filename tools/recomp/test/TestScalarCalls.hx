import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.FunctionSummary;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import sys.io.File;

/** Caller-specific scalar signatures, assembled independently of any game or ABI. */
@:access(TestCodegen)
@:access(TestDiscovery)
class TestScalarCalls {
	static inline var BASE = 0x80080000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 21;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function jal(a:Int):Int return TestCodegen.jal(a);
	static function j(a:Int):Int return 0x08000000 | ((a & 0x0fffffff) >>> 2);

	static function words(base:Int, kind:Int):Array<Int> {
		final w = [alu(0x21, 16, 31, 0), jal(base + 128), kind == 13 ? imm(9, 5, 5, 3) : 0];
		final kill = imm(9, 8, 0, 41);
		if (kind == 17) {
			w.insert(1, alu(0x21, 6, 4, 0)); w.insert(2, alu(0x21, 7, 5, 0));
		}
		switch (kind) {
			case 1: // Both forward arms overwrite; the slot belongs to the branch.
				w.push(imm(4, 0, 4, 4)); w.push(0); w.push(kill);
				w.push(j(base + 36)); w.push(0); w.push(imm(9, 8, 0, 42));
			case 2: w.push(alu(0x21, 3, 8, 0));
			case 3: w.push(imm(4, 0, 4, 2)); w.push(0); w.push(kill);
			case 4: w.push(imm(0x24, 0, 6, 0)); w.push(kill);
			case 5: w.push(jal(0x8000f010)); w.push(0); w.push(kill);
			case 6: w.push(imm(9, 8, 8, 1));
			case 7: // A loop safe point observes t0 before its later overwrite.
				w.push(imm(9, 7, 7, -1)); w.push(imm(7, 0, 7, -2)); w.push(0); w.push(kill);
			case 8: w.push(imm(8, 9, 4, 7)); w.push(kill);
			case 11: w[1] = j(base + 128);
			case 12: // Kill in the return slot, after the return target has been latched.
			case 15 | 16: // The branch reads before the slot overwrites t0.
				w.push(imm(4, 0, kind == 15 ? 8 : 4, 2)); w.push(kill); w.push(imm(9, 3, 0, 11));
			case 17: w.push(alu(0x21, 2, 3, 0)); w.push(kill);
			case _: w.push(kill);
		}
		w.push(alu(0x21, 31, 16, 0)); w.push(JR); w.push(kind == 12 ? kill : 0);
		while (w.length < 32) w.push(0);
		if (kind == 9) w.push(imm(0x24, 0, 6, 0));
		if (kind == 10) w.push(imm(0x2b, 5, 6, 0));
		if (kind == 17) w.push(imm(9, 8, 6, 1)); // Dead SSA definition; extra cycle must still be charged.
		w.push(kind == 14 ? imm(9, 8, 6, 7) : alu(0x21, 8, kind == 17 ? 6 : 4, kind == 17 ? 7 : 5));
		w.push(switch (kind) {
			case 14: alu(0x21, 2, 4, 5);
			case 19: alu(0x23, 2, 4, 5);
			case 20: alu(0x23, 2, 5, 4);
			case _: alu(0, kind == 17 ? 3 : 2, 0, 8) | ((kind == 18 ? 2 : 1) << 6);
		});
		w.push(JR); w.push(0);
		return w;
	}

	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? "ScalarCallsOptimized" : "ScalarCallsReference";
		final bodies = new StringBuf(); final dispatch = new StringBuf();
		final pool = new ScalarPool(cls + 'Values');
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12);
			final w = words(base, kind);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image("scalar calls", base, bytes);
			final d = new Discovery(image);
			d.addSeed(base, 'caller$kind', Confidence.Entry);
			d.addSeed(base + 128, Discovery.defaultName(base + 128), Confidence.Entry);
			d.run(false);
			final emitter = new Emitter(image, d, opt);
			emitter.scalarPool = pool;
			emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
			final caller = d.functions.get(base);
			final summary = new FunctionSummary(caller, image, a -> d.raJumpOf(base, a));
			final callee = new FunctionSummary(d.functions.get(base + 128), image, _ -> null);
			for (c in summary.calls) if (c.target == base + 128) c.callee = callee;
			FunctionSummary.solve([summary, callee]);
			final body = emitter.emitFunction(caller);
			bodies.add(body);
			bodies.add(emitter.emitFunction(d.functions.get(base + 128)));
			for (f in [caller, d.functions.get(base + 128)]) {
				final blocks = Emitter.blockOrder(f);
				for (i in 0...blocks.length)
					dispatch.add('case ${blocks[i]}: ${f.name}(ctx, $i); return true;\n');
			}
			if (check) {
				final eligible = [0, 1, 12, 13, 14, 16, 17, 18, 19, 20].indexOf(kind) >= 0;
				Assert.equals(body.indexOf(pool.className + '.value_') >= 0, opt && eligible, 'projection eligibility $kind');
				if (eligible) {
					Assert.equals(summary.calls[0].requiredOutputs(), 1 << (kind == 17 ? 3 : 2), 'only result live at call $kind');
					if (opt) {
						Assert.isTrue(body.indexOf('|| ctx.unwindToken != 0') >= 0, 'unwind guard $kind');
						Assert.isTrue(body.indexOf('_value_from_') < 0, 'no per-site helper body $kind');
						if (kind == 14) Assert.isTrue(body.indexOf('ctx.a2') < 0, 'dead result removes its input');
						if (kind == 17) Assert.isTrue(body.indexOf('ctx.v1 = ' + pool.className + '.value_0(ctx.a2, ctx.a3)') >= 0,
							'same calculation shares code with different input/output GPRs and accounting');
					}
				} else if (kind != 11) {
					Assert.isTrue((summary.calls[0].requiredOutputs() & (1 << 8)) != 0 || kind == 9 || kind == 10,
						'observable scratch output retained $kind');
				}
			}
		}
		if (check) {
			Assert.equals(pool.count, opt ? 5 : 0, 'only distinct pure computations get a helper');
			Assert.isTrue(pool.source().indexOf('ctx') < 0, 'shared helper has no CpuState');
		}
		if (opt) File.saveContent('out/_codegen/fixtures/' + pool.className + '.hx', pool.source());
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
			+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n'
			+ bodies.toString() + '\npublic static function dispatch(addr:Int, ctx:CpuState):Bool {\nswitch(addr) {\n'
			+ dispatch.toString() + 'default: return false;\n}\n}\n}\n';
	}

	static function generate(check:Bool):Void {
		if (!sys.FileSystem.exists('out/_codegen/fixtures')) sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/ScalarCallsOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/ScalarCallsReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('scalar calls: boundary liveness and emitted specializations');
		generate(true);
	}
}
