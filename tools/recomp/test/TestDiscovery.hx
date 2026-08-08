import haxe.io.Bytes;
import recomp.analysis.AnalysisError;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.analysis.Kind;

/**
	Function discovery, on programs small enough to reason about completely.

	Real executables are the acceptance test; these are the regression test. Each case is a
	handful of hand-assembled instructions where the right answer is obvious, which is what makes
	a failure informative — when discovery breaks on Crash Bash the report says "fewer functions
	than yesterday", and only a case like these says which rule broke.
**/
class TestDiscovery {
	static inline var BASE = 0x80010000;

	/** Assembles words into an image at BASE. */
	static function img(words:Array<Int>):Image {
		final b = Bytes.alloc(words.length * 4);
		for (i in 0...words.length) b.setInt32(i * 4, words[i]);
		return new Image("test", BASE, b);
	}

	static function discover(words:Array<Int>, ?sweep = false):Discovery {
		final d = new Discovery(img(words));
		d.addSeed(BASE, "entry", Confidence.Entry);
		d.run(sweep);
		return d;
	}

	// A few encodings, named so the tests read as programs rather than hex.
	static inline var NOP        = 0x00000000;
	static inline var JR_RA      = 0x03E00008;   // jr $ra
	static inline var ADDIU_SP_M16 = 0x27BDFFF0; // addiu $sp, $sp, -16
	static inline var ADDIU_SP_P16 = 0x27BD0010; // addiu $sp, $sp, 16
	static inline var SW_RA_8    = 0xAFBF0008;   // sw $ra, 8($sp)
	static inline var LW_RA_8    = 0x8FBF0008;   // lw $ra, 8($sp)
	static inline var ADDU_V0_ZZ = 0x00001021;   // addu $v0, $zero, $zero
	static inline var JR_T0      = 0x01000008;   // jr $t0
	static inline var JALR_T0    = 0x0100F809;   // jalr $ra, $t0

	/** jal to an absolute target, from an address in the 0x8xxxxxxx region. */
	static function jal(target:Int):Int return (0x03 << 26) | ((target & 0x0FFFFFFF) >> 2);
	static function j(target:Int):Int return (0x02 << 26) | ((target & 0x0FFFFFFF) >> 2);
	/** beq $zero, $zero, offset — an unconditional-looking branch. */
	static function beqz(offsetInstrs:Int):Int return (0x04 << 26) | (offsetInstrs & 0xFFFF);
	/** bne $v0, $zero, offset */
	static function bnez(offsetInstrs:Int):Int return (0x05 << 26) | (2 << 21) | (offsetInstrs & 0xFFFF);

	public static function run():Void {
		Assert.group("discovery: a single leaf function");
		{
			final d = discover([ADDU_V0_ZZ, JR_RA, NOP]);
			Assert.equals(Lambda.count(d.functions), 1, "one function");
			final fn = d.functions.get(BASE);
			Assert.equals(fn.entry, BASE, "entry address");
			Assert.equals(fn.instructionCount(), 3, "all three instructions claimed");
			Assert.equals(fn.endAddr, BASE + 12, "extent covers the delay slot");
			Assert.equals(d.image.kindAt(BASE), Kind.Code, "the image knows it is code");
		}

		Assert.group("discovery: a call creates a second function");
		{
			// entry:  jal callee ; nop ; jr ra ; nop
			// callee: addu       ; jr ra ; nop
			final callee = BASE + 16;
			final d = discover([jal(callee), NOP, JR_RA, NOP, ADDU_V0_ZZ, JR_RA, NOP]);
			Assert.equals(Lambda.count(d.functions), 2, "caller and callee");
			Assert.isTrue(d.functions.exists(callee), "the callee was discovered");
			Assert.equals(d.functions.get(callee).confidence, Confidence.Called,
				"and is marked as reached by a call");
			Assert.equals(d.functions.get(BASE).calls.length, 1, "the call site is recorded");
			Assert.equals(d.functions.get(BASE).calls[0].target, callee, "with the right target");
		}

		Assert.group("discovery: branches make blocks, not functions");
		{
			// entry: bne $v0, $zero, +2 ; nop ; addu ; jr ra ; nop
			final d = discover([bnez(2), NOP, ADDU_V0_ZZ, JR_RA, NOP]);
			Assert.equals(Lambda.count(d.functions), 1, "still one function");
			final fn = d.functions.get(BASE);
			Assert.isTrue(Lambda.count(fn.blocks) >= 2, "the branch split it into blocks");
			Assert.equals(fn.instructionCount(), 5, "every instruction is claimed exactly once");
		}

		Assert.group("discovery: a backward branch is a loop, not a new block each time");
		{
			// entry: addu ; bne $v0,$zero,-2 ; nop ; jr ra ; nop
			final d = discover([ADDU_V0_ZZ, bnez(-2), NOP, JR_RA, NOP]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.instructionCount(), 5, "the loop body is not counted twice");
		}

		Assert.group("discovery: jr through a register is recorded, not guessed");
		{
			final d = discover([JR_T0, NOP]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.unresolvedJumps.length, 1, "the computed jump is recorded");
			Assert.equals(fn.unresolvedJumps[0], BASE, "at the right address");
			Assert.equals(fn.calls.length, 0, "and is not mistaken for a call");
		}

		Assert.group("discovery: jalr is an indirect call");
		{
			final d = discover([JALR_T0, NOP, JR_RA, NOP]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.calls.length, 1, "one call site");
			Assert.isTrue(fn.calls[0].indirect, "marked indirect");
			Assert.equals(d.indirectCalls.length, 1, "and collected for the coverage report");
		}

		Assert.group("discovery: j to a known function is a tail call");
		{
			// entry: jal other ; nop ; j other ; nop        (so `other` is known before the j)
			// other: jr ra ; nop
			final other = BASE + 16;
			final d = discover([jal(other), NOP, j(other), NOP, JR_RA, NOP]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.tailCalls.length, 1, "the j is a tail call");
			Assert.equals(fn.tailCalls[0].target, other, "to the right function");
		}

		Assert.group("discovery: j inside the function is control flow");
		{
			// entry: j +3 words ; nop ; nop ; jr ra ; nop
			final d = discover([j(BASE + 12), NOP, NOP, JR_RA, NOP]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.tailCalls.length, 0, "not treated as a tail call");
			Assert.equals(Lambda.count(d.functions), 1, "and no second function invented");
		}

		Assert.group("discovery: data read as code is rejected, with context");
		{
			// "PS-X" as a word decodes to nothing this machine can run.
			Assert.rejects(() -> discover([0x582D5350, NOP]), "cannot decode",
				"an undecodable word stops analysis");
			// The message must be actionable, not just an address.
			try {
				discover([0x582D5350, NOP]);
			} catch (e:AnalysisError) {
				Assert.isTrue(e.message.indexOf("jumpTableHint") >= 0,
					"the error suggests what to do about it");
				Assert.isTrue(e.message.indexOf(">>") >= 0,
					"and shows the surrounding disassembly");
			}
		}

		Assert.group("discovery: a branch in a delay slot is rejected");
		{
			Assert.rejects(() -> discover([bnez(2), bnez(2), NOP, JR_RA, NOP]), "delay slot",
				"no compiler emits this, so it means the region is data");
		}

		Assert.group("discovery: the prologue sweep finds unreachable functions");
		{
			// entry is a leaf; a second function follows that nothing calls, so only the sweep
			// can find it. It begins with a proper non-leaf prologue.
			final words = [
				JR_RA, NOP,                                       // entry, 2 instructions
				ADDIU_SP_M16, SW_RA_8, LW_RA_8, JR_RA, ADDIU_SP_P16  // an uncalled function
			];
			final without = discover(words, false);
			Assert.equals(Lambda.count(without.functions), 1, "the closure alone finds one");

			final with = discover(words, true);
			Assert.equals(Lambda.count(with.functions), 2, "the sweep finds the other");
			Assert.equals(with.functions.get(BASE + 8).confidence, Confidence.Swept,
				"and marks it as a guess rather than a fact");
		}

		Assert.group("discovery: zero words between functions are padding, not code");
		{
			final d = discover([JR_RA, NOP, 0, 0, 0, 0], true);
			Assert.equals(d.image.kindAt(BASE + 8), Kind.Padding, "trailing zeros are padding");
			Assert.equals(Lambda.count(d.functions), 1, "and do not become a function");
		}

		Assert.group("discovery: a switch table is recovered and its arms traced");
		{
			// The idiom every compiler emits for a dense switch. Laid out so the table sits in a
			// region the trace never executes, which is exactly how it appears in a real program.
			//  0 sltiu $v0, $a0, 3        bound check: three arms
			//  1 beq   $v0, $zero, +7     out of range -> default at word 9
			//  2  sll  $v0, $a0, 2        delay slot: scale the index
			//  3 lui   $at, 0x8001
			//  4 addu  $at, $at, $v0
			//  5 lw    $v0, 0x30($at)     table at BASE+0x30 (word 12)
			//  6 nop
			//  7 jr    $v0
			//  8  nop
			//  9 default: jr $ra
			// 10  nop
			// 11 (padding)
			// 12..14 the table
			// 15,17,19 the three arms
			final arm0 = BASE + 15 * 4, arm1 = BASE + 17 * 4, arm2 = BASE + 19 * 4;
			final d = discover([
				0x2C820003, 0x10400007, 0x00041080, 0x3C018001, 0x00220821, 0x8C220030,
				NOP, 0x00400008, NOP,
				JR_RA, NOP, NOP,
				arm0, arm1, arm2,
				JR_RA, NOP, JR_RA, NOP, JR_RA, NOP
			]);

			Assert.equals(Lambda.count(d.tables), 1, "one table recovered");
			final t = d.tables.get(BASE + 7 * 4);
			Assert.isTrue(t != null, "keyed by the address of the jr");
			if (t != null) {
				Assert.equals(t.base, BASE + 0x30, "table base folded from lui + lw offset");
				Assert.equals(t.count(), 3, "the compiler's own bound gives the arm count");
				Assert.equals(t.targets[0], arm0, "first arm");
				Assert.equals(t.targets[2], arm2, "last arm");
			}
			// The point of recovering it: the arms are now reachable code.
			Assert.equals(d.image.kindAt(arm0), Kind.Code, "arm 0 is traced");
			Assert.equals(d.image.kindAt(arm2), Kind.Code, "arm 2 is traced");
			Assert.equals(d.image.kindAt(BASE + 0x30), Kind.DataInText,
				"and the table itself is marked as data, not left as a gap");
			Assert.equals(d.functions.get(BASE).unresolvedJumps.length, 0,
				"the jump is no longer unresolved");
		}

		Assert.group("discovery: a BIOS call is recognised, not left as dispatch");
		{
			// addiu $t2, $zero, 0xB0 ; jr $t2 ; addiu $t1, $zero, 0x19
			// The Psy-Q kernel-call convention: vector in $t2, function number in the delay slot.
			final d = discover([0x240A00B0, 0x01400008, 0x24090019]);
			final fn = d.functions.get(BASE);
			Assert.equals(fn.kernelCalls.length, 1, "recognised as a kernel call");
			Assert.equals(fn.kernelCalls[0].vector, 0xB0, "the B0 vector");
			Assert.equals(fn.kernelCalls[0].fnNumber, 0x19,
				"and the function number, read from the delay slot");
			Assert.equals(fn.unresolvedJumps.length, 0, "so it is not counted as unresolved");
		}

		Assert.group("discovery: a table that fails validation is rejected");
		{
			// The same idiom, but the table holds values that cannot be jump targets — they point
			// outside the image. Guessing is only safe because the guess is checked.
			final d = discover([
				0x2C820003, 0x10400007, 0x00041080, 0x3C018001, 0x00220821, 0x8C220030,
				NOP, 0x00400008, NOP,
				JR_RA, NOP, NOP,
				0x11111111, 0x22222222, 0x33333333,
				JR_RA, NOP, JR_RA, NOP, JR_RA, NOP
			]);
			Assert.equals(Lambda.count(d.tables), 0, "no table claimed");
			Assert.equals(d.functions.get(BASE).unresolvedJumps.length, 1,
				"the jump stays unresolved, which is correct and safe");
		}

		Assert.group("discovery: calls outside the image are recorded but not chased");
		{
			// A jal to a kernel vector: outside the image, so nothing to trace.
			final d = discover([jal(0x800000A0), NOP, JR_RA, NOP]);
			Assert.equals(Lambda.count(d.functions), 1, "no phantom function is created");
			Assert.equals(d.functions.get(BASE).calls.length, 1, "but the call site is kept");
		}
	}
}
