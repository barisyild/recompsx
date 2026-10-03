import recomp.analysis.RegisterRanges;
import recomp.analysis.RegisterRanges.WordRange;
import recomp.ir.Effect;
import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Decoder;

@:access(TestCodegen)
@:access(TestDiscovery)
class TestRegisterRanges {
	static inline var BASE = 0x80010000;
	static inline var JR = 0x03e00008;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function effects(words:Array<Int>, offset:Int):Effect {
		final d = TestDiscovery.discover(words);
		final ir = new FunctionIR(d.functions.get(BASE), d.image);
		for (b in ir.blocks) for (x in b.instructions) if (x.decoded.addr == BASE + offset) return x.effects;
		throw 'missing range-test instruction';
	}
	static function probe(r:WordRange):Array<Int> {
		final p = [r.lo, r.hi];
		for (n in [0x80000001, -65536, -32768, -257, -128, -1, 0, 1, 127, 255, 32767, 65535, 0x7ffffffe])
			if (r.contains(n)) p.push(n);
		return p;
	}
	static function contained(r:WordRange, n:Int, op:String):Void {
		Assert.isTrue(r.contains(n), op + ' result outside [' + r.lo + ', ' + r.hi + ']: ' + n);
	}
	public static function run():Void {
		Assert.group('ranges: word bounds contain edge and interior arithmetic results');
		final ranges = [WordRange.ANY, WordRange.ZERO, WordRange.BOOL,
			new WordRange(-128, 127), new WordRange(0, 255), new WordRange(-32768, 32767),
			new WordRange(0, 65535), new WordRange(0x80000000, -1), new WordRange(1, 0x7fffffff),
			new WordRange(0x80000000, 0x8000000f), new WordRange(0x7ffffff0, 0x7fffffff),
			new WordRange(-257, -128), WordRange.constant(0x80000000), WordRange.constant(0x7fffffff),
			WordRange.constant(-1), WordRange.constant(0x12345678)];
		for (a in ranges) {
			for (x in probe(a)) {
				contained(a.not(), ~x, 'not');
				for (n in 0...32) {
					contained(a.shl(n), x << n, 'shl');
					contained(a.sar(n), x >> n, 'sar');
					contained(a.shr(n), (x >>> n) | 0, 'shr');
				}
			}
			for (b in ranges) for (x in probe(a)) for (y in probe(b)) {
				final sum = (x + y) | 0; final difference = (x - y) | 0;
				contained(a.add(b), sum, 'add'); contained(a.sub(b), difference, 'sub');
				contained(a.and(b), x & y, 'and'); contained(a.or(b), x | y, 'or');
				contained(a.xor(b), x ^ y, 'xor');
				if (a.canAdd(b)) Assert.isTrue(((x ^ sum) & (y ^ sum)) >= 0, 'proved addition cannot overflow');
				if (a.canSub(b)) Assert.isTrue(((x ^ y) & (x ^ difference)) >= 0, 'proved subtraction cannot overflow');
			}
		}
		Assert.group('ranges: proofs, observable barriers and independently addressable entries');
		final mask = imm(12, 2, 4, 65535);
		final add = imm(8, 2, 2, 7);
		Assert.isTrue(!effects([mask, add, JR, 0], 4).has(Effect.TRAP), 'masked sum cannot overflow');
		Assert.isTrue(!effects([alu(0x22, 2, 4, 4), JR, 0], 0).has(Effect.TRAP), 'same-register subtraction is zero');
		Assert.isTrue(effects([alu(0x22, 2, 0, 4), JR, 0], 0).has(Effect.TRAP), 'negating unknown MIN can overflow');
		Assert.isTrue(effects([imm(15, 2, 0, 0x7fff), imm(13, 2, 2, 65535), add, JR, 0], 8).has(Effect.TRAP), 'constant overflow stays a trap');
		Assert.isTrue(!effects([mask, TestCodegen.jal(0x8000f000), add, JR, 0], 8).has(Effect.TRAP), 'call slot runs before callee');
		Assert.isTrue(effects([mask, TestCodegen.jal(0x8000f000), 0, add, JR, 0], 12).has(Effect.TRAP), 'callee continuation starts unknown');
		Assert.isTrue(effects([mask, imm(4, 0, 5, 1), 0, add, JR, 0], 12).has(Effect.TRAP), 'interior entry cannot inherit predecessor bounds');
		for (barrier in [imm(0x24, 2, 4, 0), imm(0x2b, 5, 4, 0), 0x0000000c, 0x4a180001])
			Assert.isTrue(effects([mask, barrier, 0, add, JR, 0], 12).has(Effect.TRAP), 'runtime effect clears facts');
		Assert.isTrue(effects([imm(0x24, 2, 4, 0), add, JR, 0], 4).has(Effect.TRAP), 'load delay cannot imply a new bounded operand');
		Assert.isTrue(effects([mask, alu(9, 2, 8, 0), add, JR, 0], 8).has(Effect.TRAP), 'link overwrites its destination with an unknown relocatable PC');
		final state = new RegisterRanges();
		state.visit(new InstructionIR(Decoder.decode(BASE, imm(9, 0, 0, 123))));
		Assert.equals(state.get(0).lo, 0, 'zero register remains zero');
		Assert.equals(state.get(0).hi, 0, 'zero register bounds remain singleton');
	}
}
