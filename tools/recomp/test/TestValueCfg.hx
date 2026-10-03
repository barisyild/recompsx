import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import sys.io.File;

/** Reuse the general CFG corpus, then add observation boundaries around pure choices. */
@:access(TestRegions)
class TestValueCfg {
	static function choice():Void {
		TestRegions.add(2, 4, 7); TestRegions.add(3, 5, 11);
		TestRegions.branch(4, 5, 'taken', TestRegions.imm(9, 4, 4, 3));
		TestRegions.add(2, 2, 13); TestRegions.jump('join', TestRegions.imm(9, 3, 3, 17));
		TestRegions.mark('taken'); TestRegions.add(2, 2, 19); TestRegions.add(3, 3, 23);
		TestRegions.mark('join');
	}
	static function fixtures():Void {
		TestRegions.fixtures();
		TestRegions.begin('publishedCall');
		choice(); TestRegions.words.push(0x0c003c40); TestRegions.words.push(0); // 8000f100
		TestRegions.add(2, 2, 1); TestRegions.add(2, 2, 2); TestRegions.ret(); TestRegions.finish();
		TestRegions.begin('publishedStore');
		choice(); TestRegions.words.push(TestRegions.imm(0x2b, 2, 6, 0)); TestRegions.ret(); TestRegions.finish();
		TestRegions.begin('publishedLoop');
		TestRegions.mark('head'); TestRegions.words.push(0x0c003c40); TestRegions.words.push(0);
		choice(); TestRegions.add(7, 7, -1); TestRegions.branch(7, 0, 'head', 0, 7);
		TestRegions.ret(); TestRegions.finish();
		TestRegions.begin('returns');
		TestRegions.add(2, 4, 1); TestRegions.add(3, 5, 2);
		TestRegions.branch(4, 5, 'other', TestRegions.imm(9, 4, 4, 1));
		TestRegions.add(2, 2, 3); TestRegions.ret(TestRegions.imm(9, 3, 3, 4));
		TestRegions.mark('other'); TestRegions.add(2, 2, 5); TestRegions.ret(TestRegions.imm(9, 3, 3, 6)); TestRegions.finish();
		TestRegions.begin('spanRefresh');
		TestRegions.add(8, 6, 0);
		TestRegions.branch(4, 5, 'taken', TestRegions.imm(9, 8, 8, 4));
		TestRegions.add(8, 8, 4); TestRegions.jump('join');
		TestRegions.mark('taken'); TestRegions.add(8, 8, 8);
		TestRegions.mark('join');
		for (n in 0...12) TestRegions.words.push(TestRegions.imm(0x23, n == 0 ? 2 : 0, 8, 0));
		TestRegions.ret(); TestRegions.finish();
	}
	public static function generate(check:Bool):Void {
		fixtures(); sys.FileSystem.createDirectory('out/_codegen/fixtures');
		for (mode in 0...3) {
			final cls = mode == 0 ? 'ValueCfgReference' : mode == 1 ? 'ValueCfgBaseline' : 'ValueCfgOptimized';
			final out = new StringBuf(); final counts = []; var selected = 0;
			out.add('import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n');
			for (kind in 0...TestRegions.programs.length) {
				final words = TestRegions.programs[kind]; final base = TestRegions.BASE + (kind << 12);
				final bytes = Bytes.alloc(words.length * 4);
				for (n in 0...words.length) bytes.setInt32(n * 4, words[n]);
				final image = new Image('value CFG fixture', base, bytes); final d = new Discovery(image);
				d.addSeed(base, TestRegions.names[kind], Confidence.Entry); d.run(false);
				final fn = d.functions.get(base);
				// Disable complete leaf helpers to exercise the scoped lowering itself.
				final body = new Emitter(image, d, mode != 0, true, false, true, mode == 2).emitFunction(fn);
				counts.push(Emitter.blockOrder(fn).length); out.add(body);
				if (body.indexOf('// Value CFG:') >= 0) selected++;
				if (check && mode != 2) Assert.isTrue(body.indexOf('// Value CFG:') < 0, 'CFG opt-out');
				if (check && mode == 2 && [0, 18, 19, 20, 21, 22].indexOf(kind) >= 0)
					Assert.isTrue(body.indexOf('// Value CFG:') >= 0, 'promoted fixture ${TestRegions.names[kind]}');
				if (check && mode == 2 && kind == 22) Assert.isTrue(body.indexOf('fspan_t0') >= 0, 'span refresh exercised');
			}
			if (check && mode == 2) Assert.isTrue(selected >= 5, 'nontrivial CFG coverage');
			out.add('public static inline var BASE = ${TestRegions.BASE};\npublic static inline var COUNT = ${counts.length};\n');
			out.add('public static function entries(kind:Int):Int return switch(kind) {\n');
			for (n in 0...counts.length) out.add('case $n: ${counts[n]};\n');
			out.add('case _: 0; };\npublic static function run(kind:Int, ctx:CpuState, entry:Int):Void { switch(kind) {\n');
			for (n in 0...counts.length) out.add('case $n: ${TestRegions.names[n]}(ctx, entry);\n');
			out.add('case _: } }\npublic static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n');
			for (n in 0...counts.length) out.add('case ${TestRegions.BASE + (n << 12)}: ${TestRegions.names[n]}(ctx); return true;\n');
			out.add('case _: return false; } }\n}\n'); File.saveContent('out/_codegen/fixtures/$cls.hx', out.toString());
		}
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('value CFG: joins, public entries and observation-boundary exits'); generate(true);
		final plain = TestRegions.programs[0];
		for (barrier in [TestRegions.imm(0x24, 0, 6, 0), TestRegions.imm(0x2b, 2, 6, 0),
			0x00850018, 0x00001012, 0x40086000, 0x40886000, 0x4a180001,
			0x0000000c, 0x0000000d, -1, TestRegions.imm(8, 2, 4, 1), TestRegions.imm(9, 31, 4, 1)]) {
			for (slot in [false, true]) {
				final bytes = Bytes.alloc(plain.length * 4);
				for (n in 0...plain.length) bytes.setInt32(n * 4, plain[n]);
				final image = new Image('CFG barrier', TestRegions.BASE, bytes); final d = new Discovery(image);
				d.addSeed(TestRegions.BASE, 'barrier', Confidence.Entry); d.run(false);
				final ir = new recomp.ir.FunctionIR(d.functions.get(TestRegions.BASE), image);
				// Inject after discovery: malformed opcodes are already rejected by that layer.
				final index = slot ? 3 : 0;
				final instruction = new recomp.ir.FunctionIR.InstructionIR(
					recomp.mips.Decoder.decode(TestRegions.BASE + index * 4, barrier));
				ir.blocks[0].instructions[index] = instruction;
				if (slot) ir.blocks[0].delaySlot = instruction; else ir.blocks[0].body[0] = instruction;
				final plan = new recomp.codegen.RegionPlan(ir);
				for (root in plan.roots) if (root.members.indexOf(0) >= 0)
					Assert.isTrue(recomp.codegen.ValueCfg.analyze(ir, root) == null, 'no CFG scope across effect or ra write');
			}
		}
	}
}
