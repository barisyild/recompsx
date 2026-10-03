import recomp.analysis.CallAliases;
import recomp.ir.FunctionIR.BlockIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Decoder;

@:access(TestCodegen)
class TestCallAliases {
	static inline var BASE = 0x80010000;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function instruction(word:Int):InstructionIR return new InstructionIR(Decoder.decode(BASE, word));
	static function move(rd:Int, rs:Int):Int return alu(0x21, rd, rs, 0);
	/** Execute concrete words independently of the symbolic roots/offset representation.
	    Every reported equality must hold, including after overwritten sources and wraparound. */
	static function checkConcrete(words:Array<Int>, seed:Int):Void {
		final edge = [0, 1, -1, 0x80000000, 0x7fffffff, 0x80000001, 0x12345678, -65536];
		final regs = [for (r in 0...32) edge[(r + seed) % edge.length]]; regs[0] = 0;
		final facts = new CallAliases();
		var valid = true;
		for (word in words) {
			final x = instruction(word); final d = x.decoded; final a = regs[d.rs]; final b = regs[d.rt];
			var dest = d.rd;
			final value = switch (d.op) {
				case ADDU: (a + b) | 0;
				case SUBU: (a - b) | 0;
				case ADDIU: dest = d.rt; (a + d.immS) | 0;
				case LUI: dest = d.rt; d.immU << 16;
				case OR: a | b;
				case XOR: a ^ b;
				case AND: a & b;
				case NOR: ~(a | b);
				case ORI: dest = d.rt; a | d.immU;
				case XORI: dest = d.rt; a ^ d.immU;
				case ANDI: dest = d.rt; a & d.immU;
				case SLL: b << d.shamt;
				case SRL: (b >>> d.shamt) | 0;
				case SRA: b >> d.shamt;
				case _: throw 'unexpected concrete alias test instruction';
			};
			if (dest != 0) regs[dest] = value;
			facts.visit(x);
			for (r in 0...32) for (donor in 0...32) {
				final offset = facts.difference(r, donor);
				if (offset != null && ((regs[donor] + offset) | 0) != regs[r]) valid = false;
			}
		}
		Assert.isTrue(valid, 'every affine equality holds for concrete edge input $seed');
	}
	public static function run():Void {
		Assert.group('call aliases: immutable versions, wrapped arithmetic and observation boundaries');
		final words = [imm(9, 4, 18, 32767), imm(9, 5, 4, 32767), alu(0x23, 6, 5, 18),
			alu(0, 7, 0, 6) | (16 << 6), alu(0x21, 8, 4, 7), alu(0x25, 9, 8, 0),
			alu(0x26, 10, 9, 9), imm(13, 11, 10, 0xffff), imm(14, 11, 11, 0x1234),
			imm(12, 12, 11, 0xff00), alu(0x24, 13, 12, 11), imm(15, 14, 0, 0x8000),
			alu(3, 15, 0, 14) | (31 << 6), alu(2, 16, 0, 14) | (31 << 6),
			alu(0x23, 17, 18, 14), imm(9, 0, 17, 7), move(4, 18),
			alu(0x26, 18, 18, 19), move(5, 18), imm(9, 18, 18, -4),
			alu(0x27, 18, 18, 19), move(6, 18), imm(13, 7, 6, 0),
			imm(14, 8, 7, 0), alu(0, 9, 0, 8), alu(0x24, 10, 9, 9)];
		for (seed in 0...8) checkConcrete(words, seed);
		final facts = new CallAliases();
		facts.visit(instruction(move(4, 18)));
		facts.visit(instruction(imm(9, 18, 18, 4)));
		Assert.equals(facts.difference(4, 18), -4, 'copy retains its original value after donor step');
		facts.visit(instruction(alu(0x26, 18, 18, 19)));
		Assert.isTrue(facts.difference(4, 18) == null, 'non-affine overwrite breaks the old alias');
		facts.visit(instruction(move(5, 18)));
		Assert.equals(facts.difference(5, 18), 0, 'new unknown result can still be copied exactly');
		for (barrier in [imm(0x24, 8, 19, 0), imm(0x2b, 8, 19, 0), 0x0000000c,
			0x4a180001, alu(0x12, 8, 0, 0), alu(0x18, 0, 8, 9),
			imm(8, 8, 8, 1), TestCodegen.jal(0x8000f020), 0xffffffff]) {
			facts.visit(instruction(move(4, 18)));
			facts.visit(instruction(barrier));
			Assert.isTrue(facts.difference(4, 18) == null, 'observation discards unrelated aliases');
		}
		final block = new BlockIR(0, BASE);
		block.body.push(instruction(move(18, 31)));
		block.transfer = instruction(TestCodegen.jal(0x8000f020));
		block.delaySlot = instruction(move(4, 31));
		final call = CallAliases.beforeCall(block);
		Assert.isTrue(call.difference(18, 31) == null, 'link write invalidates pre-call ra copies');
		Assert.equals(call.difference(4, 31), 0, 'delay slot observes the new link value');
		final entry = new BlockIR(1, BASE + 16); entry.transfer = block.transfer;
		Assert.isTrue(CallAliases.beforeCall(entry).difference(4, 18) == null, 'public block entry has no predecessor aliases');
	}
}
