import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;

/**
	GTE operations and LWL/LWR in recovered scalar bodies (ADR-0044): what ScalarGraph admits, the
	order a helper keeps, and the `ScalarCop` conformance fixture that runs the recovered helpers
	against the original blocks on every target.
**/
@:access(TestCodegen)
class TestScalarCop {
	static inline var FBASE = 0x80160000;
	/** Kinds 0..11 at FBASE + 0x100 k (see `code`); 12 and 13 are rejection checks only. */
	public static inline var KINDS = 12;
	static inline var JR = 0x03e00008;
	static inline var RTPS = 0x0180001;
	static inline var NCLIP = 0x1400006;
	static inline var AVSZ3 = 0x158002D;
	static inline var SQR = 0x0A00428;

	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function move(rd:Int, rs:Int):Int return TestCodegen.alu(0x21, rd, rs, 0);
	static function cop2(field:Int, rt:Int, rd:Int):Int return (0x12 << 26) | (field << 21) | (rt << 16) | (rd << 11);
	static function mfc2(rt:Int, rd:Int):Int return cop2(0x00, rt, rd);
	static function cfc2(rt:Int, rd:Int):Int return cop2(0x02, rt, rd);
	static function mtc2(rt:Int, rd:Int):Int return cop2(0x04, rt, rd);
	static function ctc2(rt:Int, rd:Int):Int return cop2(0x06, rt, rd);
	static function command(code:Int):Int return (0x12 << 26) | 0x02000000 | code;
	static function lwc2(rt:Int, base:Int, n:Int):Int return imm(0x32, rt, base, n);
	static function swc2(rt:Int, base:Int, n:Int):Int return imm(0x3A, rt, base, n);
	static function lwl(rt:Int, base:Int, n:Int):Int return imm(0x22, rt, base, n);
	static function lwr(rt:Int, base:Int, n:Int):Int return imm(0x26, rt, base, n);

	public static function addressOf(kind:Int):Int return FBASE + (kind << 8);
	static function name(kind:Int):String return Discovery.defaultName(addressOf(kind));

	/** v0 2, v1 3, a0 4 .. a3 7, t0 8 .. t3 11, s0 16, ra 31. */
	static function code(kind:Int):Array<Int> {
		return switch (kind) {
			// A leaf: vertex in, RTPS, results and FLAG out, one read in the delay slot.
			case 0: [mtc2(4, 0), mtc2(5, 1), command(RTPS), mfc2(2, 14), mfc2(3, 19), cfc2(8, 31), mfc2(9, 8), JR, mfc2(10, 24)];
			// LWC2/SWC2 through a0, RTPS between, and a word read back from SWC2's store.
			case 1: [lwc2(0, 4, 0), lwc2(1, 4, 4), command(RTPS), swc2(14, 4, 8), swc2(19, 4, 12), imm(0x23, 2, 4, 8),
				imm(0x21, 3, 4, 14), JR, mfc2(8, 24)];
			// The quick commands inline (NCLIP, AVSZ3) and SQR in the delay slot.
			case 2: [mtc2(4, 12), mtc2(5, 13), mtc2(6, 14), command(NCLIP), mfc2(2, 24), mtc2(7, 17), mtc2(4, 18),
				mtc2(5, 19), command(AVSZ3), mfc2(3, 7), mtc2(6, 9), JR, command(SQR)];
			// A CFG: the delay slot's write always, a write, TRX and SQR only when a0 != 0.
			case 3: [imm(0x04, 0, 4, 4), mtc2(5, 9), mtc2(6, 10), ctc2(7, 5), command(SQR), mfc2(2, 25), cfc2(3, 5), JR, mfc2(8, 9)];
			// The SXY FIFO pushed through its mirror, LZCS/LZCR, IRGB/ORGB, a read into $zero.
			case 4: [mtc2(4, 15), mtc2(5, 15), mfc2(2, 12), mfc2(3, 15), mtc2(6, 30), mfc2(8, 31), mtc2(7, 28), mfc2(9, 29),
				mfc2(10, 11), JR, mfc2(0, 15)];
			// LWL/LWR: a pair, lone halves merging with incoming values, one in the delay slot.
			case 5: [lwr(2, 4, 0), lwl(2, 4, 3), lwl(3, 4, 4), lwr(8, 4, 5), lwl(9, 4, 2), JR, lwr(9, 4, 7)];
			// Crash 3's stream reader's shape: the LWL only on one arm, the LWR in the slot.
			case 6: [imm(0x09, 4, 4, 3), imm(0x0C, 9, 5, 2), imm(0x04, 0, 9, 2), lwr(2, 4, -3), lwl(2, 4, 0), JR, 0];
			// Unaligned reads after overlapping stores, and a store between two of them.
			case 7: [imm(0x2B, 5, 4, 0), imm(0x28, 6, 4, 2), lwr(2, 4, 1), lwl(2, 4, 4), imm(0x29, 7, 4, 4), lwl(3, 4, 5),
				JR, lwr(3, 4, 2)];
			// A GTE child call: IR1 written in the call's slot, read after the call.
			case 8: [move(16, 31), TestCodegen.jal(addressOf(0)), mtc2(6, 9), mfc2(3, 9), move(31, 16), JR, mfc2(11, 25)];
			// A caller kept whole (mthi) whose call needs only some of kind 0's results: a projection.
			case 9: [move(16, 31), TestCodegen.alu(0x11, 0, 4, 0), TestCodegen.jal(addressOf(0)), 0, imm(9, 3, 0, 41),
				imm(9, 8, 0, 42), move(31, 16), JR, 0];
			// One result, read before a command that changes it: the read must stay in its place.
			case 10: [mtc2(4, 12), mtc2(5, 13), mtc2(6, 14), command(NCLIP), mfc2(2, 24), JR, command(AVSZ3)];
			// `bgez $zero` is always taken: the other arm's load and store are never preflighted.
			// (An interior entry runs that arm: a0 is a word-aligned pointer there, as kind 1's.)
			case 11: [imm(0x01, 1, 0, 3), mtc2(4, 0), imm(0x23, 2, 4, 0), imm(0x2B, 2, 4, 4), JR, mfc2(3, 0)];
			// An unknown command word: execute() needs the CPU state, so no helper.
			case 12: [mtc2(4, 0), command(0x0000002), JR, mfc2(2, 14)];
			// Coprocessor 0 stays out.
			case _: [imm(0x10, 2, 0, 0) | (12 << 11), JR, 0];
		}
	}

	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'CopOptimized' : 'CopReference';
		final w = [for (_ in 0...0x400) 0];
		for (kind in 0...14) {
			final c = code(kind);
			for (i in 0...c.length) w[(kind << 6) + i] = c[i];
		}
		final bytes = Bytes.alloc(w.length * 4);
		for (i in 0...w.length) bytes.setInt32(i * 4, w[i]);
		final image = new Image('scalar cop', FBASE, bytes);
		final d = new Discovery(image);
		// Default names: a call site names its callee by address (Discovery.defaultName).
		for (kind in 0...14) d.addSeed(addressOf(kind), name(kind), Confidence.Entry);
		d.run(false);
		final emitter = new Emitter(image, d, opt);
		final pool = new recomp.codegen.ScalarPool(cls + 'Values');
		emitter.scalarPool = pool;
		emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
		final summaries = [for (a in d.functions.keys()) a => new recomp.analysis.FunctionSummary(d.functions.get(a), image, _ -> null)];
		recomp.analysis.FunctionSummary.solve([for (s in summaries) s]);
		emitter.writesOf = a -> summaries.exists(a) ? summaries.get(a).writes : Emitter.ALL_REGS;
		final bodies = new StringBuf(), dispatch = new StringBuf(), resume = new StringBuf();
		final entries = new StringBuf(), counts = new StringBuf();
		final order = [for (a in d.functions.keys()) a];
		order.sort((x, y) -> x < y ? -1 : (x > y ? 1 : 0));
		final texts:Map<Int, String> = [];
		for (a in order) {
			final fn = d.functions.get(a);
			final kind = (a - FBASE) >> 8;
			if (kind >= KINDS) {
				texts.set(kind, emitter.emitFunction(fn));
				continue;
			}
			final text = emitter.emitFunction(fn);
			texts.set(kind, text);
			bodies.add(text);
			resume.add('case ${fn.entry}: ${fn.name}(ctx, entry);\n');
			final blocks = Emitter.blockOrder(fn);
			for (i in 0...blocks.length) dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
			counts.add('case $kind: ${blocks.length};\n');
			entries.add('case $kind: switch(entry) {\n' + [for (i in 0...blocks.length) 'case $i: ${blocks[i]};\n'].join('')
				+ 'default: -1; }\n');
		}
		if (check && opt) {
			for (kind in [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11])
				Assert.isTrue(texts.get(kind).indexOf('public static function ${name(kind)}_value(') >= 0, 'fixture: kind $kind is recovered');
			for (kind in [12, 13])
				Assert.isTrue(texts.get(kind).indexOf('_value(') < 0, 'fixture: kind $kind keeps its original body');
			final leaf = texts.get(0);
			final first = leaf.indexOf('gte.Gte.writeData(0,'), rtps = leaf.indexOf('gte.GteQuick.rtps(12, false)'),
				read = leaf.indexOf('gte.Gte.readData(14)'), last = leaf.indexOf('gte.Gte.readData(24)');
			Assert.isTrue(first >= 0 && first < rtps && rtps < read && read < last, 'fixture: the helper keeps the GTE order');
			Assert.isTrue(leaf.indexOf('return gte.Gte.') < 0, 'fixture: no GTE read is moved to the return');
			final cfg = texts.get(3);
			Assert.isTrue(~/if \(value\d+\) \{ gte\.Gte\.writeData\(10, /.match(cfg), 'fixture: a write on one arm is predicated');
			Assert.isTrue(~/if \(value\d+\) \{ gte\.Gte\.cmdSqr\(0\); \} else \{\}/.match(cfg), 'fixture: a command on one arm is predicated');
			Assert.isTrue(cfg.indexOf('gte.Gte.writeData(9, ') >= 0 && !~/if \(value\d+\) \{ gte\.Gte\.writeData\(9, /.match(cfg),
				'fixture: the delay slot\'s write is unconditional');
			Assert.isTrue(texts.get(2).indexOf('gte.GteQuick.nclip()') >= 0 && texts.get(2).indexOf('gte.GteQuick.avsz3()') >= 0,
				'fixture: the quick commands are inline');
			Assert.isTrue(texts.get(5).indexOf('Memory.spanLwr(') >= 0 && texts.get(5).indexOf('Memory.spanLwl(') >= 0,
				'fixture: LWL/LWR through the span');
			Assert.isTrue(texts.get(1).indexOf('gte.Gte.writeData(0, ') >= 0 && texts.get(1).indexOf('Memory.spanWrite32(') >= 0,
				'fixture: LWC2/SWC2 through the span');
			Assert.isTrue(texts.get(9).indexOf('public static function ${name(0)}_value_from_') >= 0, 'fixture: the GTE projection is its caller\'s');
			Assert.equals(pool.count, 0, 'fixture: no GTE helper enters the pure pool');
			final pruned = texts.get(11), at = pruned.indexOf('public static function ${name(11)}_value(');
			final entry = pruned.substr(0, pruned.indexOf('var cyc = ctx.cycles;'));
			Assert.isTrue(at >= 0 && pruned.substring(at, pruned.indexOf('\n\t}\n', at)).indexOf('Memory.') < 0
				&& entry.indexOf('Memory.span(') < 0, 'fixture: an arm no path reaches is not preflighted');
			Assert.isTrue(~/final (value\d+) = gte\.Gte\.readData\(24\);\n\t\tgte\.GteQuick\.avsz3\(\);\n\t\treturn \1;/.match(texts.get(10)),
				'fixture: a lone result read before a command is materialized before it');
			Assert.isTrue(texts.get(8).indexOf('$cls.${name(0)}_value(') >= 0, 'fixture: the caller\'s helper calls the child\'s');
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var KINDS = $KINDS;\n' + bodies.toString()
			+ 'public static function entryCount(kind:Int):Int { return switch(kind) {\n' + counts.toString() + 'default: 0; }; }\n'
			+ 'public static function entryAddress(kind:Int, entry:Int):Int { return switch(kind) {\n' + entries.toString() + 'default: -1; }; }\n'
			+ 'public static function resume(fn:Int, entry:Int, ctx:CpuState):Void { switch(fn) {\n' + resume.toString() + 'default: } }\n'
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n' + dispatch.toString() + 'default: return false; } }\n}\n';
	}

	/** Value regions never take a GTE operation or an unaligned load: they have no ordered effects. */
	static function regions():Void {
		Assert.group('scalar GTE: admitted only where effects are ordered');
		for (word in [mtc2(4, 0), mfc2(2, 14), command(RTPS), lwl(2, 4, 3), lwr(2, 4, 0), lwc2(0, 4, 0), swc2(14, 4, 8)]) {
			final graph = new recomp.codegen.ScalarGraph(true);
			final regs = graph.initial.copy();
			final x = new recomp.ir.FunctionIR.InstructionIR(recomp.mips.Decoder.decode(FBASE, word));
			Assert.isTrue(!graph.lift(x, regs, false), 'value region rejects ${recomp.mips.Disasm.text(x.decoded)}');
			final helper = new recomp.codegen.ScalarGraph();
			final hregs = helper.initial.copy();
			Assert.isTrue(helper.lift(x, hregs, true), 'helper admits ${recomp.mips.Disasm.text(x.decoded)}');
		}
		Assert.equals(Emitter.scalarGteCommand(0x0000002), null, 'an unknown command has no helper form');
		Assert.equals(Emitter.scalarGteCommand(RTPS), 'gte.GteQuick.rtps(12, false)', 'RTPS is inline in a helper (E-088)');
		Assert.equals(Emitter.scalarGteCommand(NCLIP), 'gte.GteQuick.nclip()', 'NCLIP is inline');
	}

	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		sys.io.File.saveContent('out/_codegen/fixtures/CopOptimized.hx', source(true, check));
		sys.io.File.saveContent('out/_codegen/fixtures/CopReference.hx', source(false, check));
	}

	public static function main():Void generate(false);

	public static function run():Void {
		regions();
		Assert.group('scalar GTE and LWL/LWR: the ScalarCop fixture');
		generate(true);
	}
}
