import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import sys.io.File;

@:access(TestCodegen)
class TestScalarMemoryCfg {
	static inline var BASE = 0x80120000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 22;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function jump(a:Int):Int return 0x08000000 | ((a & 0x0fffffff) >>> 2);
	static function diamond(base:Int, prefix:Array<Int>, slot:Int, fall:Array<Int>, taken:Array<Int>, tail:Array<Int>, rs:Int = 6, end:Bool = true):Array<Int> {
		final join = base + (prefix.length + 2 + fall.length + 2 + taken.length) * 4;
		final w = prefix.concat([imm(4, 0, rs, fall.length + 3), slot]).concat(fall).concat([jump(join), 0]).concat(taken).concat(tail);
		return end ? w.concat([JR, 0]) : w;
	}
	static function words(kind:Int, b:Int):Array<Int> return switch(kind) {
		case 0: diamond(b, [], 0, [imm(0x2b, 7, 4, 0)], [], []);
		case 1: diamond(b, [], 0, [imm(0x23, 2, 4, 0)], [imm(9, 2, 0, 17)], []);
		case 2: diamond(b, [], 0, [imm(0x2b, 7, 4, 0)], [imm(0x2b, 6, 4, 0)], []);
		case 3: diamond(b, [], 0, [imm(0x2b, 7, 4, 0)], [imm(0x2b, 6, 5, 0)], [imm(0x23, 2, 4, 0)]);
		case 4: diamond(b, [imm(0x23, 8, 4, 0)], 0, [imm(0x2b, 7, 4, 0)], [imm(0x2b, 6, 5, 0)], [imm(0x23, 2, 4, 0)], 8);
		case 5: diamond(b, [imm(0x23, 8, 4, 0)], imm(0x2b, 7, 4, 0), [imm(0x2b, 6, 5, 0)], [imm(0x2b, 7, 5, 0)], [imm(0x23, 2, 4, 0)], 8);
		case 6: diamond(b, [], imm(9, 6, 0, 0), [imm(0x2b, 7, 4, 0)], [imm(0x2b, 6, 4, 0)], []);
		case 7: diamond(b, [], 0, [imm(0x28, 7, 4, 1)], [imm(0x29, 7, 5, 2)], [imm(0x23, 2, 4, 0)]);
		case 8: diamond(b, [], 0, [imm(0x2b, 7, 4, 0), imm(0x23, 2, 4, 0)], [imm(0x2b, 6, 4, 4), imm(0x23, 2, 4, 0)], []);
		case 9: diamond(b, [], 0, [imm(0x2b, 7, 4, 0)], [], [imm(0x23, 2, 4, 0)]);
		case 10: diamond(b, [imm(0x23, 2, 4, 0)], 0, [imm(0x2b, 7, 4, 0)], [], [imm(0x23, 3, 4, 0)]);
		case 11: diamond(b, [], 0, [imm(9, 8, 4, 4)], [imm(9, 8, 4, 4)], [imm(0x2b, 7, 8, 0)]);
		case 12: diamond(b, [], 0, [imm(9, 8, 4, 4)], [imm(9, 8, 5, 4)], [imm(0x2b, 7, 8, 0)]);
		case 13: [imm(4, 0, 6, 4), imm(0x2b, 7, 4, 0), imm(0x23, 2, 5, 0), JR, imm(0x28, 6, 4, 0), imm(0x23, 2, 4, 0), JR, imm(0x29, 7, 5, 0)];
		case 14: diamond(b, [], 0, [imm(0x24, 2, 5, 0)], [imm(9, 2, 0, 7)], [imm(0x2b, 7, 4, 0)]);
		case 15: diamond(b, [], 0, [imm(0x24, 0, 5, 0)], [], [imm(0x2b, 7, 4, 0)]);
		case 16:
			final first = diamond(b, [], 0, [imm(0x2b, 7, 4, 0)], [imm(0x2b, 6, 4, 0)], [imm(0x23, 2, 4, 0)], 6, false);
			first.concat(diamond(b + first.length * 4, [], 0, [imm(0x2b, 6, 5, 0)], [imm(0x2b, 7, 5, 0)], [imm(0x23, 3, 4, 0)], 2));
		case 17: [imm(4, 0, 6, 1), imm(0x2b, 7, 4, 0), JR, imm(0x23, 2, 4, 0)];
		case 18: [jump(b + 8), imm(0x2b, 7, 4, 0), JR, imm(0x23, 2, 4, 0)];
		case 19: diamond(b, [imm(15, 8, 0, 0x1f80), imm(13, 8, 8, 0x1074)], 0, [imm(0x23, 2, 8, 0)], [imm(9, 2, 0, 0)], []);
		case 20: [imm(4, 0, 6, 11), 0, imm(4, 0, 7, 4), imm(0x2b, 6, 4, 0), imm(0x2b, 7, 5, 0), jump(b + 32), 0,
			imm(0x2b, 0, 5, 0), imm(0x23, 2, 4, 0), JR, imm(0x2b, 2, 4, 4), 0, JR, imm(9, 2, 0, 7)];
		case _:
			final first = diamond(b, [imm(0x23, 8, 4, 0)], 0, [imm(0x2b, 0, 4, 0)], [imm(0x2b, 7, 4, 0)], [imm(0x23, 8, 4, 0)], 8, false);
			first.concat(diamond(b + first.length * 4, [], 0, [imm(0x2b, 7, 5, 0)], [imm(0x2b, 0, 5, 0)], [imm(0x23, 2, 4, 0)], 8));
	};
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'MemoryCfgOptimized' : 'MemoryCfgReference';
		final bodies = new StringBuf(); final dispatch = new StringBuf(); final resume = new StringBuf();
		final entries = new StringBuf(); final counts = new StringBuf();
		for (kind in 0...COUNT) {
			final b = BASE + (kind << 12); final w = words(kind, b); final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image('scalar memory CFG', b, bytes); final d = new Discovery(image);
			d.addSeed(b, 'memoryCfg$kind', Confidence.Entry); d.run(false);
			final fn = d.functions.get(b); final emitter = new Emitter(image, d, opt); final body = emitter.emitFunction(fn);
			bodies.add(body); resume.add('case $b: memoryCfg$kind(ctx, entry);\n');
			final blocks = Emitter.blockOrder(fn); counts.add('case $kind: ${blocks.length};\n');
			entries.add('case $kind: switch(entry) {\n');
			for (i in 0...blocks.length) {
				entries.add('case $i: ${blocks[i]};\n');
				dispatch.add('case ${blocks[i]}: memoryCfg$kind(ctx, $i); return true;\n');
			}
			entries.add('default: -1; }\n');
			if (check) {
				final plan = emitter.scalarPlan(fn);
				Assert.equals(plan != null, opt && kind != 12 && kind != 19, 'memory CFG eligibility $kind');
				if (plan != null) {
					final helper = plan.emitHelper();
					Assert.isTrue(plan.accounting != null && plan.memory != null, 'both entry and span guards required');
					Assert.isTrue(body.indexOf('if (entry == 0)') < body.indexOf('final memory0Address'), 'interior entry bypasses preflight');
					Assert.isTrue(helper.indexOf('ctx') < 0 && helper.indexOf('CpuState') < 0, 'memory CFG uses scalar signature');
					// Path-dependent accounting is returned, even by a Void helper; a constant word
					// (every path costs the same) is charged by the caller and never stored.
					if (plan.pathAccounting()) Assert.isTrue(helper.indexOf('ScalarResult.accounting') >= 0, 'path accounting also returned by Void helper');
					else Assert.isTrue(helper.indexOf('ScalarResult.accounting') < 0 && body.indexOf('ScalarResult.accounting') < 0,
						'constant accounting is charged at the call site');
					if (kind == 0 || kind == 2) Assert.isTrue(helper.indexOf('):Void') >= 0, 'conditional setter has no dummy result');
					if (kind == 0) Assert.isTrue(helper.indexOf('if (') >= 0, 'untaken store stays conditional');
					if (kind == 1) Assert.isTrue(helper.indexOf('? Memory.spanRead') >= 0, 'untaken load stays conditional');
					if (kind == 8 || kind == 9) Assert.isTrue(helper.indexOf('Memory.spanRead32') >= 0, 'no memory facts forwarded from another arm');
					Assert.rejects(() -> new ScalarPool('NoMemoryCfgPool').intern(plan), 'memory helpers', 'memory CFG cannot be pooled as pure');
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
		File.saveContent('out/_codegen/fixtures/MemoryCfgOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/MemoryCfgReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void { Assert.group('scalar memory CFG: conditional effects and entry boundaries'); generate(true); }
}
