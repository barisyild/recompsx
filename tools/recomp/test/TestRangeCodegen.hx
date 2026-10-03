import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarPool;
import sys.io.File;

@:access(TestCodegen)
class TestRangeCodegen {
	static inline var BASE = 0x800a0000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 15;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function words(kind:Int, base:Int):Array<Int> {
		return switch (kind) {
			case 0: [imm(12, 2, 4, 65535), imm(8, 2, 2, 32767), JR, 0];
			case 1: [alu(3, 2, 0, 4) | (16 << 6), alu(0x22, 2, 0, 2), JR, 0];
			case 2: [imm(12, 2, 4, 255), alu(0, 2, 0, 2) | (16 << 6), imm(8, 2, 2, -32768), JR, 0];
			case 3: [imm(12, 2, 4, 32767), alu(0x20, 2, 2, 2), JR, imm(8, 2, 2, -32768)];
			case 4: [imm(13, 2, 0, 65535), alu(0x27, 2, 2, 0), imm(8, 2, 2, -32768), JR, 0];
			case 5: [imm(15, 2, 0, 0x8000), alu(0x25, 2, 2, 4), alu(2, 2, 0, 2) | (1 << 6), JR, imm(8, 2, 2, -32768)];
			case 6: [imm(8, 2, 4, 1), JR, 0];
			case 7: [alu(0x22, 2, 0, 4), JR, 0];
			case 8: [imm(0x24, 2, 4, 0), 0, imm(8, 2, 2, 7), JR, 0];
			case 9: [imm(0x24, 2, 4, 0), 0, imm(12, 2, 2, 255), JR, imm(8, 2, 2, 7)];
			case 10: [imm(15, 2, 0, 0x7fff), imm(13, 2, 2, 65535), imm(9, 2, 2, 1), imm(8, 2, 2, -1), JR, 0];
			case 11: [imm(12, 2, 4, 255), imm(4, 0, 0, 1), 0, imm(8, 2, 2, 1), JR, 0];
			case 12 | 13:
				final w = [alu(0x21, 16, 31, 0), TestCodegen.jal(base + 64), 0,
					imm(9, 8, 0, 41), alu(0x21, 31, 16, 0), JR, 0];
				while (w.length < 16) w.push(0);
				w.push(imm(12, 8, 4, 65535)); w.push(imm(8, 2, kind == 12 ? 8 : 4, 7));
				w.push(JR); w.push(0); w;
			case _: [alu(0x22, 2, 4, 4), JR, 0];
		};
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'RangeOptimized' : 'RangeReference';
		final pool = new ScalarPool(cls + 'Values');
		final bodies = new StringBuf(); final dispatch = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(kind, base);
			final bytes = haxe.io.Bytes.alloc(w.length * 4);
			for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
			final image = new Image('range fixture', base, bytes); final d = new Discovery(image);
			d.addSeed(base, 'range$kind', Confidence.Entry); d.run(false);
			final emitter = new Emitter(image, d, opt); emitter.scalarPool = pool;
			emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
			final order = [for (a in d.functions.keys()) a]; order.sort((a,b) -> a - b);
			for (addr in order) {
				final fn = d.functions.get(addr); final body = emitter.emitFunction(fn); bodies.add(body);
				final blocks = Emitter.blockOrder(fn);
				for (i in 0...blocks.length) dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
				if (check && addr == base) {
					Assert.equals(body.indexOf('_value(') >= 0, opt && (kind < 6 || kind == 9 || kind == 12 || kind == 14), 'range helper eligibility $kind');
					Assert.equals(body.indexOf(pool.className + '.value_') >= 0, opt && kind == 12, 'range projection eligibility $kind');
					if (opt && kind == 14) Assert.isTrue(body.indexOf('range14_value():Int') >= 0, 'x-x has no input parameters');
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
		File.saveContent('out/_codegen/fixtures/RangeOptimized.hx', source(true, check));
		File.saveContent('out/_codegen/fixtures/RangeReference.hx', source(false, check));
	}
	public static function main():Void generate(false);
	public static function run():Void {
		Assert.group('ranges: emitted scalar arithmetic and conservative fallback'); generate(true);
	}
}
