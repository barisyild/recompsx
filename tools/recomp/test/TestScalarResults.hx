import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import recomp.codegen.ScalarPlan;
import recomp.mips.Instr;
import sys.io.File;

@:access(TestCodegen)
@:access(TestDiscovery)
@:access(recomp.codegen.ScalarPlan)
class TestScalarResults {
	static inline var BASE = 0x800e0000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 11;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function words(kind:Int, base:Int):Array<Int> {
		return switch (kind) {
			case 0: [alu(0x26, 2, 4, 5), alu(0x21, 8, 4, 5), JR, 0];
			case 1: [alu(0x21, 8, 4, 5), alu(0x21, 2, 8, 0), JR, alu(0x21, 3, 8, 0)];
			case 2: [alu(0x26, 9, 4, 5), imm(9, 8, 4, 5), imm(9, 2, 0, 7), alu(0x21, 1, 4, 0),
				imm(9, 4, 5, 11), alu(0x21, 5, 1, 0), JR, 0];
			case 3: [imm(9, 8, 8, 1), imm(9, 8, 8, -1), JR, alu(0x26, 2, 4, 5)];
			case 4: [imm(0x23, 2, 4, 0), imm(0x23, 8, 4, 4), imm(0x20, 9, 4, 8), JR, imm(9, 4, 4, 12)];
			case 5: [imm(7, 0, 4, 4), alu(0x26, 8, 4, 5), alu(0x21, 2, 4, 5), JR, alu(0x26, 3, 8, 4),
				alu(0x23, 2, 4, 5), JR, alu(0x26, 3, 8, 5)];
			case 6: [imm(0x24, 2, 4, 0), imm(0x24, 8, 4, 0), JR, 0];
			case 7 | 8:
				final w = [alu(0x21, 16, 31, 0), TestCodegen.jal(base + 64), 0];
				if (kind == 7) w.push(imm(9, 8, 0, 41));
				else { w.push(TestCodegen.jal(base + 128)); w.push(0); }
				w.push(alu(0x21, 31, 16, 0)); w.push(JR); w.push(0);
				while (w.length < 16) w.push(0);
				for (x in [alu(0x21, 2, 4, 5), alu(0x26, 3, 4, 5), alu(0x23, 8, 4, 5), JR, 0]) w.push(x);
				if (kind == 8) {
					while (w.length < 32) w.push(0);
					for (x in [alu(0x25, 2, 4, 5), alu(0x21, 3, 2, 0), JR, 0]) w.push(x);
				}
				w;
			case 9:
				final w = [for (r in 1...31) imm(14, r, 31, r)]; w.push(JR); w.push(0); w;
			case _: [imm(9, 29, 29, -16), alu(0x21, 8, 29, 0), imm(9, 29, 29, 16), JR, alu(0x21, 2, 8, 0)];
		};
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'ResultsOptimized' : 'ResultsReference'; final pool = new ScalarPool(cls + 'Values');
		final bodies = new StringBuf(); final dispatch = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(kind, base);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (n in 0...w.length) bytes.setInt32(n * 4, w[n]);
			final image = new Image('scalar results fixture', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'results$kind', Confidence.Entry); d.run(false);
			final emitter = new Emitter(image, d, opt); emitter.scalarPool = pool;
			emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
			final order = [for (a in d.functions.keys()) a]; order.sort((a,b) -> a - b);
			for (a in order) {
				final fn = d.functions.get(a); final body = emitter.emitFunction(fn); bodies.add(body);
				final blocks = Emitter.blockOrder(fn);
				for (n in 0...blocks.length) dispatch.add('case ${blocks[n]}: ${fn.name}(ctx, $n); return true;\n');
				final plan = emitter.scalarPlan(fn);
				if (opt && kind == 0) File.saveContent('out/_codegen/fixtures/ResultsForward.hx', 'class ResultsForward {\n' + plan.emitHelper(cls) + '}\n');
				if (opt && kind == 4) bodies.add('public static function acceptsReadAddress(ctx:CpuState):Bool {\n'
					+ plan.memory.guard('\t') + '\t\treturn true;\n\t} else { return false; }\n}\n');
				if (check) {
					Assert.equals(plan != null, opt, 'multi-result eligibility $kind');
					if (plan != null) {
						Assert.isTrue(plan.emitHelper().indexOf('ctx') < 0, 'multi-result helper has scalar parameters');
						if (a == base) {
							final arity = [2, 3, 6, 1, 4, 3, 2, 4, 4, 30, 2][kind];
							final transport = [2, 1, 1, 1, 3, 3, 1, 2, 2, 30, 1][kind];
							Assert.equals(plan.outputs.length, arity, 'all observable outputs retained $kind');
							Assert.equals(plan.results.length, transport, 'only unique computed outputs need return words $kind');
						}
					}
					if (a == base) Assert.equals(body.indexOf(pool.className + '.value_') >= 0, opt && kind == 7, 'two live outputs project a third dead output');
				}
			}
		}
		if (opt) File.saveContent('out/_codegen/fixtures/' + pool.className + '.hx', pool.source());
		final readReg = new StringBuf();
		for (r in 1...32) readReg.add('case $r: ctx.${Instr.regName(r)};\n');
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
			+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n'
			+ bodies.toString() + 'public static function reg(ctx:CpuState, r:Int):Int { return switch(r) {\n' + readReg.toString() + 'default: 0;\n}; }\n'
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool {\nswitch(addr) {\n'
			+ dispatch.toString() + 'default: return false;\n}\n}\n}\n';
	}
	static function generate(check:Bool):Void {
		if (!sys.FileSystem.exists('out/_codegen/fixtures')) sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/ResultsOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/ResultsReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('scalar results: unique return values and exact boundary reconstruction'); generate(true);
		final pool = new ScalarPool('TupleShape');
		for (w in [words(0, 0x80010000), [alu(0x26, 3, 4, 5), alu(0x21, 9, 4, 5), JR, 0],
			[alu(0x26, 2, 4, 5), alu(0x21, 8, 4, 5), alu(0x21, 3, 2, 0), JR, 0]]) {
			final d = TestDiscovery.discover(w); pool.intern(ScalarPlan.analyze(d.functions.get(0x80010000), d.image));
		}
		Assert.equals(pool.count, 1, 'logical results share despite changed registers, aliases and fixed costs');
		final d = TestDiscovery.discover([alu(0x26, 2, 4, 5), alu(0x23, 8, 4, 5), JR, 0]);
		pool.intern(ScalarPlan.analyze(d.functions.get(0x80010000), d.image));
		Assert.equals(pool.count, 2, 'different secondary computation cannot alias the same primary return');
		pool.intern(ScalarPlan.analyze(d.functions.get(0x80010000), d.image, 1 << 2));
		Assert.equals(pool.count, 3, 'projected tuple arity participates in sharing');
	}
}
