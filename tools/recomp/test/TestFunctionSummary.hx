import recomp.analysis.FunctionSummary;
import recomp.ir.Effect;

@:access(TestDiscovery)
@:access(TestCodegen)
@:access(TestOverlay)
@:access(recomp.codegen.Program)
class TestFunctionSummary {
	static inline var BASE = 0x80010000;
	static inline var JR = 0x03e00008;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function jal(a:Int):Int return TestCodegen.jal(a);

	static function summaries(words:Array<Int>):Array<FunctionSummary> {
		final d = TestDiscovery.discover(words);
		final all = [for (fn in d.functions) new FunctionSummary(fn, d.image, a -> d.raJumpOf(fn.entry, a))];
		all.sort((a, b) -> a.entry - b.entry);
		for (f in all) for (c in f.calls) for (g in all) if (c.target == g.entry) c.callee = g;
		FunctionSummary.solve(all);
		return all;
	}

	public static function run():Void {
		Assert.group('summaries: inputs, effects, delay slots and recursive fixed point');
		final leaf = summaries([imm(9, 2, 4, 3), JR, imm(9, 3, 2, 1)])[0];
		Assert.equals(leaf.inputs, (1 << 4) | (1 << 31), 'read before write, including return target');
		Assert.equals(leaf.writes, (1 << 2) | (1 << 3), 'explicit results');
		Assert.equals(leaf.preserved(), FunctionSummary.ALL & ~12, 'never-written registers');
		Assert.equals((leaf.effects:Int), (Effect.CONTROL:Int), 'pure leaf');
		final trap = summaries([imm(8, 2, 4, 3), JR, 0])[0];
		Assert.isTrue(trap.effects.has(Effect.TRAP), 'ADDI overflow stays an effect projection refuses');
		// Generated code wraps ADD/ADDI/SUB and raises no overflow exception: no handler runs.
		Assert.equals(trap.inputs, (1 << 4) | (1 << 31), 'unraised overflow reads only its operands');
		Assert.equals(trap.writes, 1 << 2, 'unraised overflow writes only its result');
		final syscall = summaries([0x0000000c, JR, 0])[0];
		Assert.equals(syscall.inputs, FunctionSummary.ALL, 'a syscall enters the kernel, which may read anything');
		Assert.equals(syscall.writes, FunctionSummary.ALL, 'and write anything');
		final memory = summaries([imm(0x24, 0, 4, 0), imm(0x2b, 5, 6, 0), JR, 0])[0];
		Assert.isTrue(memory.effects.has(Effect.READ_MEMORY) && memory.effects.has(Effect.WRITE_MEMORY),
			'zero-target reads still have effects');
		final call = summaries([jal(BASE + 16), imm(9, 4, 0, 7), JR, 0, imm(9, 2, 4, 3), JR, 0]);
		Assert.equals(call[0].inputs, 0, 'link and slot define callee inputs before call');
		Assert.equals(call[0].writes, (1 << 31) | (1 << 4) | (1 << 2), 'transitive writes');
		final unknown = summaries([jal(0x800000a0), 0, JR, 0])[0];
		Assert.equals(unknown.writes, FunctionSummary.ALL, 'unknown call writes everything');
		Assert.isTrue(unknown.effects.has(Effect.UNKNOWN), 'unknown call is not pure');
		final linkedReturn = summaries([0x03e0f809, 0, JR, 0])[0];
		Assert.equals(linkedReturn.writes, 1 << 31, 'linking return through ra only writes the link');
		Assert.equals(linkedReturn.calls.length, 0, 'linking return agrees with Discovery and Emitter');
		final indirect = summaries([0x0100f809, 0, JR, 0])[0];
		Assert.equals(indirect.writes, FunctionSummary.ALL, 'unresolved jalr call writes everything');
		final copiedRa = summaries([TestCodegen.alu(0x21, 8, 31, 0), 0x01000008, 0])[0];
		Assert.equals(copiedRa.writes, 1 << 8, 'a proved copy of the return address is not an unknown call');
		final nonlocal = summaries([imm(0x23, 31, 4, 0), JR, 0])[0];
		Assert.isTrue(nonlocal.effects.has(Effect.NONLOCAL_RETURN), 'checked return may unwind frames');
		Assert.equals(nonlocal.writes, 1 << 31, 'checked return does not execute an unknown target in the caller');
		Assert.equals(nonlocal.calls.length, 0, 'nonlocal return is not a call edge');
		final conditional = summaries([imm(1, 16, 4, 3), 0, JR, 0, imm(9, 2, 5, 3), JR, 0]);
		Assert.isTrue(conditional[0].calls[0].conditional, 'linked conditional call is explicit');
		Assert.isTrue((conditional[0].writes & (1 << 2)) != 0, 'conditional callee may write result');
		final join = summaries([imm(4, 0, 5, 3), 0, imm(9, 4, 0, 7), 0,
			jal(BASE + 32), 0, JR, 0, imm(9, 2, 4, 3), JR, 0]);
		Assert.isTrue((join[0].inputs & (1 << 4)) != 0, 'definition on only one predecessor is not definite');
		final recursive = summaries([jal(BASE + 24), 0, imm(9, 2, 4, 3), JR, 0, 0,
			jal(BASE), 0, imm(9, 3, 5, 2), JR, 0]);
		for (f in recursive) {
			Assert.equals(f.inputs, (1 << 4) | (1 << 5), 'mutual recursion propagates inputs');
			Assert.equals(f.writes, (1 << 31) | 12, 'mutual recursion propagates writes');
		}
		recursive.reverse(); FunctionSummary.solve(recursive);
		Assert.equals(recursive[0].writes, recursive[1].writes, 'fixed point independent of traversal order');

		Assert.group('summaries: overlay residency and hook invalidation');
		final p = TestOverlay.build(['one', 'two'], [1, 2]);
		final base = p.universes[0]; final overlay = p.universes[1];
		Assert.equals(p.summaryFor(base, TestOverlay.WINDOW), null, 'unknown resident overlay');
		Assert.equals(p.summaryFor(base, TestOverlay.BASE_IN_WINDOW), null, 'overlaid executable bytes');
		Assert.equals(p.summaryFor(overlay, TestOverlay.WINDOW + 0x40).writes, 1 << 2, 'same overlay callee');
		Assert.equals(p.summaryFor(overlay, BASE + 0x100).writes, 1 << 2, 'resident executable callee');
		Assert.equals(p.summaryFor(base, BASE).writes, FunctionSummary.ALL, 'unknown overlay effects propagate');
		p.setHooks([{addr: BASE + 0x100, scope: 'exe'}]);
		Assert.equals(p.summaryFor(overlay, BASE + 0x100).writes, FunctionSummary.ALL, 'hook invalidates cached summary');
		Assert.isTrue(p.summaryFor(overlay, BASE + 0x100).effects.has(Effect.UNKNOWN), 'hook effects unknown');
	}
}
