import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ValueRegion;
import sys.io.File;

@:access(TestCodegen)
class TestValueRegions {
	static inline var BASE = 0x80100000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 13;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function words(kind:Int, base:Int):Array<Int> {
		return switch(kind) {
			case 0: [imm(9, 8, 4, 7), alu(0x26, 8, 8, 5), alu(0x21, 2, 8, 5),
				imm(0x2b, 2, 6, 0), imm(9, 8, 8, 3), imm(9, 8, 8, -3), JR, 0];
			case 1: [alu(0x21, 8, 4, 0), alu(0x21, 4, 5, 0), alu(0x21, 5, 8, 0),
				alu(0x21, 2, 4, 5), imm(0x2b, 2, 6, 0), JR, 0];
			case 2: [alu(0x26, 2, 4, 5), alu(0x26, 3, 4, 5), alu(0x21, 8, 2, 3),
				imm(9, 2, 0, 17), imm(0x2b, 3, 6, 0), JR, 0];
			case 3: [alu(0x21, 16, 31, 0), imm(9, 3, 0, 5), imm(9, 8, 4, 1), imm(9, 8, 8, 2),
				TestCodegen.jal(0x8000f100), 0, imm(9, 4, 4, 1), imm(9, 4, 4, 2),
				TestCodegen.jal(0x8000f104), 0, alu(0x21, 31, 16, 0), JR, 0];
			case 4: [imm(9, 8, 4, 1), imm(9, 8, 8, 2), imm(0x24, 0, 7, 0),
				imm(9, 8, 8, 1), imm(9, 8, 8, 2), imm(0x24, 2, 7, 0), JR, 0];
			case 5: [imm(9, 8, 4, 1), imm(9, 8, 8, 2), 0x40096000,
				alu(0x26, 2, 8, 9), alu(0x26, 2, 2, 5), JR, 0];
			case 6: [imm(9, 8, 4, 1), imm(9, 8, 8, 2), alu(0x1a, 0, 8, 5), alu(0x12, 2, 0, 0),
				imm(9, 2, 2, 1), imm(9, 2, 2, 2), JR, 0];
			case 7:
				final w = [alu(0x26, 10, 4, 5), alu(0x26, 10, 10, 5)];
				for (part in 0...3) {
					w.push(part == 1 ? imm(9, 8, 8, 4) : alu(0x21, 8, 6, 0)); w.push(imm(9, 8, 8, 4));
					// Enough real reads to select the emitter's function-span optimization.
					for (n in 0...6) w.push(imm(0x23, n > 0 ? 0 : part == 0 ? 2 : part == 1 ? 3 : 9, 8, 0));
				}
				w.push(JR); w.push(0); w;
			case 8: [imm(9, 4, 4, 1), imm(9, 4, 4, -1), imm(4, 5, 4, 4), imm(9, 4, 4, 7),
				imm(9, 2, 0, 1), JR, 0, imm(9, 2, 0, 2), JR, 0];
			case 9: [imm(9, 8, 4, 1), imm(9, 8, 8, 2), imm(8, 2, 4, 1),
				imm(12, 9, 5, 255), imm(8, 9, 9, 7), JR, 0];
			case 10: [imm(9, 8, 4, 1), imm(9, 8, 8, 2), alu(0x21, 31, 5, 0),
				imm(9, 2, 8, 1), imm(9, 2, 2, 2), JR, 0];
			case 11:
				final w = [for (_ in 0...40) imm(9, 2, 2, 1)];
				w.push(imm(0x2b, 2, 6, 0)); w.push(JR); w.push(0); w;
			case _:
				[alu(0x21, 16, 31, 0), TestCodegen.jal(0x8000f108), 0,
					imm(9, 2, 2, 1), imm(9, 2, 2, 2), imm(9, 7, 7, -1), imm(7, 0, 7, -6), 0,
					alu(0x21, 31, 16, 0), JR, 0];
		};
	}
	static function source(opt:Bool, enabled:Bool, check:Bool):String {
		final cls = !opt ? 'ValuesReference' : enabled ? 'ValuesOptimized' : 'ValuesBaseline';
		final bodies = new StringBuf(); final dispatch = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(kind, base);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (n in 0...w.length) bytes.setInt32(n * 4, w[n]);
			final image = new Image('value region fixture', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'values$kind', Confidence.Entry); d.run(false);
			final emitter = new Emitter(image, d, opt, true, false, enabled);
			final fn = d.functions.get(base); final body = emitter.emitFunction(fn); bodies.add(body);
			final blocks = Emitter.blockOrder(fn);
			for (n in 0...blocks.length) dispatch.add('case ${blocks[n]}: ${fn.name}(ctx, $n); return true;\n');
			if (check && opt && !enabled) Assert.isTrue(body.indexOf('vr_') < 0, 'value SSA opt-out $kind');
			if (check && opt && enabled && kind != 8) Assert.isTrue(body.indexOf('vr_') >= 0, 'value SSA region emitted $kind');
			if (check && opt && kind == 7) {
				Assert.isTrue(body.indexOf('fspan_t0 = Memory.span(') >= 0, 'fixture refreshes a function span');
				Assert.isTrue(body.indexOf('Memory.spanStep(fspan_t0') >= 0, 'fixture steps a function span');
			}
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
			+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE = $BASE;\npublic static inline var COUNT = $COUNT;\n'
			+ bodies.toString() + 'public static function dispatch(addr:Int, ctx:CpuState):Bool {\nswitch(addr) {\n'
			+ dispatch.toString() + 'default: return false;\n}\n}\n}\n';
	}
	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/ValuesOptimized.hx', source(true, true, check));
		File.saveContent('out/_codegen/fixtures/ValuesBaseline.hx', source(true, false, check));
		File.saveContent('out/_codegen/fixtures/ValuesReference.hx', source(false, false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('value SSA: observation boundaries and exact reconstruction'); generate(true);
		final prefix = [imm(9, 8, 4, 1), imm(9, 8, 8, 2)];
		for (barrier in [imm(0x23, 0, 6, 0), imm(0x24, 0, 6, 0), imm(0x2b, 8, 6, 0),
			alu(0x18, 0, 4, 5), alu(0x10, 8, 0, 0), 0x40086000, 0x40886000, 0x4a180001,
			0x0000000c, 0x0000000d, -1, imm(8, 0, 4, 1), TestCodegen.jal(0x8000f100), JR,
			alu(0x21, 31, 4, 0)]) {
			final body = [for (n in 0...5) new recomp.ir.FunctionIR.InstructionIR(
				recomp.mips.Decoder.decode(0x80010000 + n * 4, n < 2 ? prefix[n] : n == 2 ? barrier : prefix[n - 3]))];
			Assert.equals(ValueRegion.analyze(body, 0, body.length).end, 2, 'no speculation across an architectural observation');
		}
	}
}
