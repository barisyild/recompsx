import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import sys.io.File;

@:access(TestCodegen)
class TestScalarEffects {
	static inline var BASE = 0x80100000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 32;
	static function imm(op:Int, rt:Int, rs:Int, k:Int):Int return TestCodegen.imm(op, rt, rs, k);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function words(kind:Int):Array<Int> return switch(kind) {
		case 0: [imm(0x2b, 6, 4, 0), JR, 0]; // Void store-only helper.
		case 1: [imm(0x23, 2, 4, 0), imm(0x2b, 6, 4, 0), JR, 0]; // Return the OLD load.
		case 2: [imm(0x2b, 6, 4, 0), imm(0x23, 2, 5, 0), JR, 0];
		case 3: [imm(0x23, 2, 4, 0), imm(0x2b, 6, 5, 0), imm(0x23, 3, 4, 0), JR, 0];
		case 4: [imm(0x28, 6, 4, 0), imm(0x29, 7, 4, 2), imm(0x23, 2, 5, 0), JR, imm(0x2b, 2, 4, 4)];
		case 5: [imm(0x23, 2, 4, 0), imm(0x23, 3, 5, 0), imm(0x2b, 3, 4, 0), JR, imm(0x2b, 2, 5, 0)];
		case 6: [imm(0x23, 2, 4, 0), imm(9, 2, 2, 1), imm(0x2b, 2, 4, 0), imm(0x23, 3, 5, 0), JR, 0];
		case 7: [imm(0x2b, 0, 4, 0), JR, imm(0x2b, 0, 5, 0)];
		case 8: [imm(0x23, 2, 4, 0), imm(9, 2, 2, 1), imm(0x2b, 2, 4, 0), imm(0x24, 0, 5, 0), JR, imm(0x24, 3, 5, 0)];
		case 9: [imm(0x23, 2, 4, 0), imm(9, 2, 2, 1), imm(0x2b, 2, 4, 0), JR, imm(0x2b, 6, 5, 0)];
		case 10: [imm(9, 4, 4, 4), imm(0x2b, 4, 5, 0), imm(0x23, 2, 4, 0), JR, imm(9, 4, 4, 4)];
		case 11: [imm(9, 29, 29, -16), imm(0x2b, 6, 29, 4), imm(0x23, 2, 29, 4), JR, imm(9, 29, 29, 16)];
		case 12: [imm(0x28, 6, 4, 1), imm(0x2b, 7, 4, 4), JR, imm(0x23, 2, 5, 4)];
		case 13: [imm(0x2b, 6, 4, 0), JR, imm(0x23, 2, 4, 0)];
		case 14: [imm(0x2b, 6, 4, 0), imm(0x20, 2, 4, 3), JR, imm(0x24, 3, 4, 3)];
		case 15: [imm(0x2b, 6, 4, 0), imm(0x21, 2, 4, 2), JR, imm(0x25, 3, 4, 2)];
		case 16: [imm(0x29, 6, 4, 0), imm(0x21, 2, 4, 0), JR, imm(0x25, 3, 4, 0)];
		case 17: [imm(0x28, 6, 4, 0), imm(0x20, 2, 4, 0), JR, imm(0x24, 3, 4, 0)];
		case 18: [imm(0x23, 2, 4, 0), imm(0x23, 3, 4, 0), JR, imm(0x2b, 6, 4, 4)];
		case 19: [imm(0x23, 2, 4, 0), imm(0x2b, 6, 4, 4), JR, imm(0x23, 3, 4, 0)];
		case 20: [imm(0x23, 2, 4, 0), imm(0x28, 6, 4, 1), JR, imm(0x23, 3, 4, 0)];
		case 21: [imm(0x2b, 6, 4, 0), imm(0x29, 7, 4, 2), JR, imm(0x23, 2, 4, 0)];
		case 22: [imm(0x23, 2, 4, 0), imm(0x29, 6, 4, 2), JR, imm(0x25, 3, 4, 2)];
		case 23: [imm(0x23, 2, 4, 0), imm(0x2b, 6, 5, 0), JR, imm(0x23, 3, 4, 0)];
		case 24: [imm(0x23, 2, 4, 0), imm(0x20, 3, 4, 1), imm(0x25, 8, 4, 2), JR, imm(0x2b, 6, 4, 8)];
		case 25: [imm(0x2b, 6, 4, 0), imm(0x23, 2, 4, 0), alu(0x26, 2, 2, 7), JR, imm(0x23, 3, 4, 0)];
		case 26: [imm(0x2b, 5, 4, 0), imm(0x23, 8, 4, 0), JR, imm(0x23, 2, 8, 0)];
		case 27: [imm(0x23, 2, 4, 0), imm(0x20, 3, 4, 3), imm(0x28, 6, 4, 3), JR, imm(0x20, 8, 4, 2)];
		case 28: [imm(0x23, 2, 4, 0), imm(0x20, 3, 4, 0), imm(0x28, 6, 4, 3), JR, imm(0x24, 8, 4, 0)];
		case 29: [imm(0x2b, 6, 4, 0), imm(0x25, 2, 4, 2), imm(0x29, 7, 4, 0), JR, imm(0x25, 3, 4, 2)];
		case 30: [imm(0x2b, 6, 4, 0), imm(0x24, 2, 5, 0), JR, imm(0x24, 3, 5, 0)];
		case _: [imm(15, 8, 0, 0x20), alu(0x21, 8, 4, 8), imm(0x23, 2, 4, 0), imm(0x2b, 6, 8, 0), JR, imm(0x23, 3, 4, 0)];
	};
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'EffectsOptimized' : 'EffectsReference';
		final out = new StringBuf(); final dispatch = new StringBuf();
		out.add('import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n');
		for (kind in 0...COUNT) {
			final w = words(kind); final base = BASE + (kind << 12); final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (n in 0...w.length) bytes.setInt32(n * 4, w[n]);
			final image = new Image('ordered scalar effects', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'effect$kind', Confidence.Entry); d.run(false);
			final fn = d.functions.get(base); final emitter = new Emitter(image, d, opt);
			out.add(emitter.emitFunction(fn)); dispatch.add('case $base: effect$kind(ctx); return true;\n');
			final plan = emitter.scalarPlan(fn);
			if (opt && kind == 0) File.saveContent('out/_codegen/fixtures/EffectsForward.hx', 'class EffectsForward {\n' + plan.emitHelper(cls) + '}\n');
			if (opt && kind == 5) out.add('public static function accepts(ctx:CpuState):Bool {\n' + plan.memory.guard('\t')
				+ '\t\treturn true;\n\t} else { return false; }\n}\n');
			if (check) {
				Assert.equals(plan != null, opt, 'ordered memory signature $kind');
				if (plan != null) {
					final helper = plan.emitHelper(); Assert.isTrue(helper.indexOf('ctx') < 0, 'effect helper has no CpuState');
					Assert.isTrue(helper.indexOf('spanWrite') >= 0, 'store cannot disappear with unused GPR results');
					Assert.isTrue(plan.memory.writes, 'memory effects are explicit');
					final loads = [0, 1, 1, 2, 1, 2, 2, 0, 2, 1, 1, 0, 1, 0, 0, 0, 0, 0, 1, 1, 2, 1, 1, 2, 1, 0, 1, 2, 1, 0, 1, 2];
					Assert.equals(helper.split('Memory.spanRead').length - 1, loads[kind], 'proved memory reuse and alias invalidation $kind');
					final stores = [for (word in w) if (word >>> 26 == 0x28 || word >>> 26 == 0x29 || word >>> 26 == 0x2b) word];
					Assert.equals(helper.split('Memory.spanWrite').length - 1, stores.length, 'all observable stores retained $kind');
					if (kind == 0 || kind == 7) Assert.isTrue(helper.indexOf('):Void') >= 0, 'no dummy scalar return for setter');
					if (kind == 2 || kind == 5) Assert.equals(plan.memory.spans.length, 2, 'independent checked memory parameters');
					final pool = new ScalarPool('EffectsMustNotPool');
					Assert.rejects(() -> pool.intern(plan), 'memory helpers', 'effectful helpers excluded from pure pool');
				}
			}
		}
		out.add('public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n');
		out.add('public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n' + dispatch.toString() + 'default: return false; } }\n}\n');
		return out.toString();
	}
	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/EffectsOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/EffectsReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('scalar effects: ordered aliases, checked spans and void signatures'); generate(true);
		for (n in [6, 7]) {
			final w = [for (r in 4...4 + n) imm(0x2b, 0, r, 0)]; w.push(JR); w.push(0);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image('span parameter budget', BASE, bytes); final d = new Discovery(image);
			d.addSeed(BASE, 'manySpans', Confidence.Entry); d.run(false);
			final plan = recomp.codegen.ScalarPlan.analyze(d.functions.get(BASE), image);
			Assert.equals(plan != null, n == 6, 'spans count toward the actual parameter budget');
		}
		final memory = new recomp.codegen.ScalarPlan.ScalarMemory();
		Assert.isTrue(memory.add(0, 0x80040000, 4) != null, 'first constant range');
		Assert.isTrue(memory.add(0, 0x80050000, 4) != null, 'distant constant range');
		Assert.equals(memory.spans.length, 2, 'distant addresses do not exceed span arithmetic bounds');
		Assert.isTrue(memory.possible(), 'both constant spans are plain RAM');
		Assert.isTrue(memory.add(0, 0x1f801074, 4) != null, 'record device access before deciding');
		Assert.isTrue(!memory.possible(), 'one known I/O span rejects the whole helper');
		// An immutable load can be preflighted. A prior possibly aliased write after a
		// known overwrite must still reject stale read provenance in this linear leaf.
		for (w in [[imm(0x23, 8, 4, 0), JR, imm(0x23, 2, 8, 0)],
			[imm(0x2b, 5, 4, 0), imm(0x2b, 6, 5, 0), imm(0x23, 8, 4, 0), JR, imm(0x23, 2, 8, 0)]]) {
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image('unknown pointer after memory effect', BASE, bytes); final d = new Discovery(image);
			d.addSeed(BASE, 'unknownPointer', Confidence.Entry); d.run(false);
			Assert.equals(recomp.codegen.ScalarPlan.analyze(d.functions.get(BASE), image) != null, w.length == 3,
				'loaded pointer requires an unchanged memory version');
		}
	}
}
