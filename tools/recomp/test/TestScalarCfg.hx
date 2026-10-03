import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import recomp.codegen.ScalarPlan;
import sys.io.File;

@:access(TestCodegen)
@:access(TestDiscovery)
class TestScalarCfg {
	static inline var BASE = 0x800c0000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 19;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function jump(a:Int):Int return 0x08000000 | ((a & 0x0fffffff) >>> 2);
	static function leaf(kind:Int):Array<Int> {
		final branch = switch (kind) {
			case 0: imm(4, 5, 4, 4);
			case 1: imm(5, 5, 4, 4);
			case 2: imm(6, 0, 4, 4);
			case 3: imm(7, 0, 4, 4);
			case 4: imm(1, 0, 4, 4);
			case _: imm(1, 1, 4, 4);
		};
		return [branch, imm(9, 2, 0, 11), imm(9, 2, 4, 7), JR, 0, JR, imm(9, 2, 5, -3)];
	}
	static function words(kind:Int, base:Int):Array<Int> {
		if (kind < 6) return leaf(kind);
		return switch (kind) {
			case 6: [imm(7, 0, 4, 4), imm(9, 2, 0, 11), imm(9, 2, 4, 7), jump(base + 28), 0,
				imm(9, 2, 5, -3), 0, JR, imm(14, 2, 2, 255)];
			case 7: [imm(4, 5, 2, 4), imm(9, 2, 4, 1), imm(9, 2, 2, 7), JR, 0, JR, imm(9, 2, 2, -3)];
			case 8: [imm(4, 5, 4, 4), 0, imm(9, 2, 0, 7), JR, 0, JR, imm(9, 2, 0, 7)];
			case 9 | 10:
				final w = [alu(0x21, 16, 31, 0), TestCodegen.jal(base + 64), 0,
					kind == 9 ? imm(9, 8, 0, 41) : alu(0x21, 3, 8, 0), alu(0x21, 31, 16, 0), JR, 0];
				while (w.length < 16) w.push(0);
				w.concat([imm(12, 8, 4, 65535), imm(4, 5, 4, 4), 0, imm(9, 2, 8, 7), JR, 0, JR, imm(9, 2, 8, -3)]);
			case 11: [imm(4, 5, 4, 4), 0, imm(9, 2, 4, 7), JR, 0, JR, imm(0x24, 2, 6, 0)];
			case 12: [imm(4, 5, 4, 4), 0, imm(8, 2, 4, 7), JR, 0, JR, imm(9, 2, 5, -3)];
			case 13: [jump(base + 16), 0, JR, 0, imm(9, 2, 4, 7), jump(base + 8), 0];
			case 15: [imm(4, 5, 4, 1), imm(9, 2, 0, 7), JR, 0];
			case 16: [imm(4, 5, 4, 4), imm(9, 2, 0, 11), imm(9, 2, 4, 7), jump(base + 28), 0,
				imm(9, 2, 5, -3), 0, imm(7, 0, 2, 4), imm(14, 2, 2, 255), imm(9, 2, 2, 5), JR, 0, JR, imm(9, 2, 2, -5)];
			case 17: [imm(4, 5, 4, 3), 0, JR, imm(9, 2, 0, 7), JR, imm(9, 2, 0, 7)];
			case 18: [imm(4, 5, 4, 7), 0, imm(4, 5, 4, 3), 0, JR, imm(9, 2, 0, 9), JR, imm(9, 2, 0, 99), JR, imm(9, 2, 0, 7)];
			case _:
				final w = [alu(0x21, 16, 31, 0), TestCodegen.jal(base + 64), 0,
					alu(0x21, 17, 2, 0), imm(14, 4, 4, 1), TestCodegen.jal(base + 64), 0,
					alu(0x21, 31, 16, 0), JR, 0];
				while (w.length < 16) w.push(0);
				w.concat(leaf(0));
		};
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'CfgOptimized' : 'CfgReference'; final pool = new ScalarPool(cls + 'Values');
		final bodies = new StringBuf(); final dispatch = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(kind, base);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (n in 0...w.length) bytes.setInt32(n * 4, w[n]);
			final image = new Image('scalar cfg fixture', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'cfg$kind', Confidence.Entry); d.run(false);
			final emitter = new Emitter(image, d, opt); emitter.scalarPool = pool;
			emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
			final order = [for (a in d.functions.keys()) a]; order.sort((a,b) -> a - b);
			for (a in order) {
				final fn = d.functions.get(a); final body = emitter.emitFunction(fn); bodies.add(body);
				final blocks = Emitter.blockOrder(fn);
				for (n in 0...blocks.length) dispatch.add('case ${blocks[n]}: ${fn.name}(ctx, $n); return true;\n');
				if (check) {
					final plan = emitter.scalarPlan(fn);
					Assert.equals(plan != null, opt && ((a == base && (kind <= 11 || kind >= 14)) || (a != base && (kind == 9 || kind == 10 || kind == 14))), 'CFG helper eligibility $kind/$a');
					if (plan != null) {
						Assert.isTrue(plan.accounting != null, 'CFG cost returned separately');
						Assert.isTrue(body.indexOf('if (entry == 0' + (plan.horizon == 0 ? ')' : ' &&')) >= 0, 'CFG interior entry retains fallback');
						Assert.isTrue(plan.emitHelper().indexOf('ctx') < 0, 'CFG helper uses scalar values only');
						Assert.equals(plan.memory != null, kind == 11, 'memory requires complete preflight');
						if (kind == 17) {
							Assert.equals(plan.inputs.length, 0, 'result and timing independent of branch operands');
							Assert.isTrue(plan.emitHelper().indexOf('?') < 0, 'constant path cost needs no predicate');
						}
						if (kind == 18) Assert.isTrue(plan.emitHelper().indexOf('99') < 0, 'entry-zero unreachable phi value eliminated');
					}
					if (a == base) Assert.equals(body.indexOf(pool.className + '.value_') >= 0, opt && kind == 9, 'CFG projected outputs $kind');
				}
			}
		}
		if (opt) File.saveContent('out/_codegen/fixtures/' + pool.className + '.hx', pool.source());
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
			+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n'
			+ bodies.toString() + 'public static function dispatch(addr:Int, ctx:CpuState):Bool {\nswitch(addr) {\n'
			+ dispatch.toString() + 'default: return false;\n}\n}\n}\n';
	}
	static function generate(check:Bool):Void {
		if (!sys.FileSystem.exists('out/_codegen/fixtures')) sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/CfgOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/CfgReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('scalar CFG: phi values, branch costs, interior entries and effect rejection'); generate(true);
		final first = leaf(0); final extra = leaf(0);
		extra[0] = imm(4, 5, 4, 5); extra.insert(3, 0); // Same results; one extra fall-through instruction.
		final pool = new ScalarPool('CostsMatter');
		for (w in [first, extra]) {
			final d = TestDiscovery.discover(w);
			final plan = ScalarPlan.analyze(d.functions.get(0x80010000), d.image);
			Assert.isTrue(plan != null, 'CFG cost-pool fixture');
			pool.intern(plan);
		}
		Assert.equals(pool.count, 2, 'CFG helpers with different path costs cannot share a body');
	}
}
