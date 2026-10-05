import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import sys.FileSystem;
import sys.io.File;

/** Hand-assembled programs, compiled by the real emitter for both conformance targets. */
class TestCodegen {
	static inline var JR = 0x03e00008;
	static inline var BASE = 0x80010000;
	static var bodies:StringBuf;
	static var dispatch:StringBuf;
	static var next:Int;
	static var optimized:Bool;
	static var cls:String;

	static function imm(op:Int, rt:Int, rs:Int, value:Int):Int
		return (op << 26) | (rs << 21) | (rt << 16) | (value & 0xffff);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int
		return (rs << 21) | (rt << 16) | (rd << 11) | op;
	static function jal(addr:Int):Int return 0x0c000000 | ((addr & 0x0fffffff) >>> 2);

	static function add(name:String, words:Array<Int>, extra:Array<Int> = null):String {
		final bytes = Bytes.alloc(words.length * 4);
		for (i in 0...words.length) bytes.setInt32(i * 4, words[i]);
		final image = new Image(name, next, bytes);
		final d = new Discovery(image);
		d.addSeed(next, name, Confidence.Entry);
		if (extra != null) for (offset in extra) d.addSeed(next + offset, Discovery.defaultName(next + offset), Confidence.Entry);
		d.run(false);
		final emitter = new Emitter(image, d, optimized);
		emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
		// Program's write summaries, for the leaves a fixture calls: what they write, and every
		// register for a function that calls anything itself.
		emitter.writesOf = a -> {
			final f = d.functions.get(a);
			if (f == null) return Emitter.ALL_REGS;
			else {}
			var m = 0;
			for (b in new recomp.ir.FunctionIR(f, image).blocks) for (x in b.instructions) {
				if (x.effects.has(recomp.ir.Effect.CALL)) return Emitter.ALL_REGS;
				else {}
				m |= (x.writes : Int);
			}
			return m;
		};
		final order = [for (a in d.functions.keys()) a];
		order.sort((a, b) -> a - b);
		var first = "";
		for (addr in order) {
			final fn = d.functions.get(addr);
			final body = emitter.emitFunction(fn);
			bodies.add(body);
			if (addr == next) first = body;
			final blocks = Emitter.blockOrder(fn);
			for (i in 0...blocks.length)
				dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
		}
		next += 0x1000;
		return first;
	}

	static function source(opt:Bool, check:Bool):String {
		optimized = opt;
		cls = opt ? "CodegenOptimized" : "CodegenReference";
		bodies = new StringBuf(); dispatch = new StringBuf(); next = BASE;
		// Sum n..1. The branch sees the decremented counter; the slot counts iterations.
		final loop = add("sumLoop", [alu(0x21, 2, 0, 0), alu(0x21, 2, 2, 4),
			imm(9, 4, 4, -1), imm(7, 0, 4, -3), imm(9, 3, 3, 1), JR, 0]);
		// Branch reads a0 before its slot overwrites it.
		add("branchSlot", [imm(5, 0, 4, 4), imm(9, 4, 0, 0), imm(9, 2, 0, 11), JR, 0,
			imm(9, 2, 0, 22), JR, 0]);
		// Call observes slot arguments; caller observes callee changes in caller-saved registers.
		add("directCall", [imm(9, 4, 0, 5), jal(next + 28), imm(9, 5, 0, 7),
			alu(0x21, 3, 2, 4), JR, 0, 0, imm(9, 4, 4, 1), alu(0x21, 2, 4, 5), JR, 0]);
		// Both link opcodes link unconditionally, call conditionally, then resume the caller.
		for (kind in 0...2) add(kind == 0 ? "bltzal" : "bgezal", [
			imm(1, 16 + kind, 4, 5), imm(9, 4, 0, 9), imm(9, 3, 2, 1), JR, 0, 0,
			imm(9, 2, 4, 4), JR, 0]);
		// The target is latched before the slot clears t0. rd=zero is a tail transfer.
		add("indirectTail", [alu(9, 0, 8, 0), imm(9, 8, 0, 0), imm(9, 3, 2, 1), JR, 0,
			imm(9, 2, 4, 4), JR, 0], [20]);
		add("arithmetic", [imm(15, 8, 0, 0xffff), imm(13, 8, 8, 0xffff), imm(9, 8, 8, 1),
			alu(0x21, 9, 4, 5), alu(0x26, 10, 9, 4), alu(0x2b, 2, 4, 5),
			alu(0x19, 0, 4, 5), alu(0x12, 3, 0, 0), alu(0x10, 11, 0, 0), JR, 0]);
		add("memory", [imm(0x2b, 5, 4, 0), imm(0x23, 8, 4, 0), imm(0x20, 2, 4, 0),
			imm(0x24, 3, 4, 1), imm(0x21, 9, 4, 0), imm(0x25, 10, 4, 2), JR, 0]);
		add("discardRead", [imm(0x24, 0, 4, 0), imm(0x24, 2, 4, 0), JR, 0]);
		add("syscall", [imm(9, 4, 0, 1), 0x0000000c, imm(9, 3, 2, 4), JR, 0]);
		// A native idle loop must still pump and let a halt/nonlocal jump leave.
		add("spin", [imm(4, 0, 0, -1), imm(9, 2, 2, 1), JR, 0]);
		// A one-block unconditional jump also needs a dispatcher (it used to emit undeclared bb).
		add("jumpSpin", [0x08000000 | ((next & 0x0fffffff) >>> 2), imm(9, 2, 2, 1)]);
		// Recovered table, with duplicate targets and a delay-slot write to the jump register.
		final a = next;
		add("table", [imm(11, 2, 4, 3), imm(4, 0, 2, 7), alu(0, 2, 0, 4) | (2 << 6),
			imm(15, 1, 0, (a + 48 + 0x8000) >>> 16), alu(0x21, 1, 1, 2), imm(0x23, 2, 1, (a + 48) & 0xffff),
			0, alu(8, 0, 2, 0), imm(9, 2, 0, 99), JR, 0, 0,
			a + 60, a + 72, a + 60, imm(9, 3, 0, 11), JR, 0, imm(9, 3, 0, 22), JR, 0]);
		// Explicit runtime-dispatched call; used to exercise unwind without publishing stale locals.
		add("unwindCall", [imm(9, 16, 0, 77), jal(0x8000f000), imm(9, 4, 0, 12),
			imm(9, 16, 0, 88), JR, 0]);
		add("mixLoop", [alu(0, 8, 0, 2) | (13 << 6), alu(0x26, 2, 2, 8),
			alu(2, 8, 0, 2) | (17 << 6), alu(0x26, 2, 2, 8),
			alu(0, 8, 0, 2) | (5 << 6), alu(0x26, 2, 2, 8),
			imm(9, 4, 4, -1), imm(7, 0, 4, -8), 0, JR, 0]);
		// Reduced reflaxe regression: constant propagation leaves multiple assignments to the
		// same local before its first remaining read. They must never become duplicate TVars.
		add("constantStores", [imm(15, 2, 0, 0x8003), imm(0x2b, 0, 2, 0),
			imm(15, 2, 0, 0x8004), imm(0x29, 0, 2, 4), imm(15, 2, 0, 0x8004),
			imm(9, 3, 0, 312), imm(0x2b, 3, 2, 8), imm(9, 2, 2, 8), imm(9, 3, 0, 32),
			imm(15, 4, 0, 0x8004), imm(0x2b, 3, 2, 4), imm(0x2b, 0, 2, 8),
			imm(0x23, 2, 4, 20), imm(15, 3, 0, 2), alu(0x25, 2, 2, 3), JR, imm(0x2b, 2, 4, 20)]);
		add("selfMove", [imm(9, 2, 2, 0), alu(0x25, 2, 2, 0), JR, 0]);
		add("loopInSwitch", [alu(0x21, 2, 0, 0), alu(0x21, 2, 2, 4),
			imm(9, 4, 4, -1), imm(7, 0, 4, -3), imm(9, 3, 3, 1),
			imm(5, 0, 5, 3), 0, JR, imm(9, 2, 2, 100), JR, imm(9, 2, 2, 200)]);
		final multi = add("multiBlockLoop", [alu(0x21, 2, 0, 0), imm(4, 0, 4, 5), 0,
			alu(0x21, 2, 2, 4), imm(9, 4, 4, -1),
			0x08000000 | (((next + 4) & 0x0fffffff) >>> 2), 0, JR, 0]);
		// Initializer and nested-block reads must prevent a declaration from being moved past
		// those reads. Inlining Memory exposes both shapes to reflaxe's declaration mover.
		add("loadThenRedefine", [imm(0x24, 2, 4, 0), imm(0x24, 3, 4, 1), imm(9, 4, 0, 23), JR, 0]);
		add("storeThenRedefine", [imm(0x2b, 16, 4, 0), imm(15, 16, 0, 0x1234),
			imm(13, 16, 16, 0x5678), JR, 0]);
		add("linkedIndirect", [alu(9, 31, 8, 0), imm(9, 8, 0, 0), imm(9, 3, 2, 1), JR, 0,
			imm(9, 2, 4, 4), JR, 0], [20]);
		// Three native frames, then repeated yields inside the leaf's loop. Slots execute once.
		add("nestedCalls", [imm(9, 16, 0, 11), jal(next + 32), imm(9, 3, 3, 1),
			imm(9, 2, 2, 100), JR, imm(9, 16, 16, 2), 0, 0,
			imm(9, 4, 0, 3), jal(next + 64), imm(9, 3, 3, 2),
			imm(9, 2, 2, 10), JR, imm(9, 16, 16, 3), 0, 0,
			alu(0x21, 2, 2, 4), imm(9, 4, 4, -1), imm(7, 0, 4, -3),
			imm(9, 3, 3, 1), JR, imm(9, 16, 16, 4)]);
		add("nestedUnwind", [jal(next + 20), imm(9, 3, 3, 1), imm(9, 2, 0, 999), JR, 0,
			jal(0x8000f000), imm(9, 16, 0, 77), imm(9, 2, 0, 888), JR, 0]);
		add("loadSlot", [JR, imm(0x23, 2, 4, 0)]);
		final fused = add("fusedPatterns", [
			alu(0x18, 0, 4, 5), alu(0x12, 0, 0, 0), alu(0x10, 23, 0, 0),
			alu(0x18, 0, 4, 5), alu(0x12, 2, 0, 0),
			alu(0x18, 0, 4, 5), alu(0x10, 3, 0, 0),
			alu(0x19, 0, 4, 5), alu(0x12, 8, 0, 0),
			alu(0x19, 0, 4, 5), alu(0x10, 9, 0, 0),
			alu(0x1a, 0, 4, 5), alu(0x12, 10, 0, 0),
			alu(0x1a, 0, 4, 5), alu(0x10, 11, 0, 0),
			alu(0x1b, 0, 4, 5), alu(0x12, 12, 0, 0),
			alu(0x1b, 0, 4, 5), alu(0x10, 13, 0, 0),
			imm(15, 14, 0, 0x1234), imm(13, 14, 14, 0x5678), JR, 0]);
		final stack = add("stackForward", [
			imm(9, 8, 0, 11), imm(9, 9, 0, 22),
			imm(0x2b, 8, 29, 0), imm(0x2b, 9, 29, 0),
			imm(0x23, 10, 29, 0), imm(9, 29, 29, 4),
			imm(0x23, 11, 29, -4), imm(9, 29, 29, -4),
			imm(0x23, 12, 29, 0), JR, 0]);
		// A GTE command word is decoded at build time: RTPS with sf=1, then a word no operation owns.
		final gte = add("gteDirect", [0x4a180001, 0x4a000002, 0x4a000006, JR, 0]);
		final dead = add("deadWrites", [
			imm(9, 8, 0, 1), imm(9, 8, 0, 2), imm(9, 2, 8, 3)]);
		// libetc's VSync, hand-assembled: a timeout in a stack slot, a counter polled through a1
		// against a0. Only the optimized build gets the idle-loop prologue; the conformance test
		// holds both builds to the same registers, slot and cycle count.
		final idle = add("idleWait", [imm(9, 29, 29, -32), imm(9, 3, 0, -1), imm(0x2b, 6, 29, 16),
			imm(0x23, 2, 29, 16), imm(9, 2, 2, -1), imm(0x2b, 2, 29, 16), imm(4, 3, 2, 8), 0,
			imm(0x23, 2, 5, 0), alu(0x2b, 2, 2, 4), imm(5, 0, 2, -8), 0,
			imm(9, 2, 0, 1), JR, imm(9, 29, 29, 32),
			imm(9, 2, 0, 2), JR, imm(9, 29, 29, 32)]);
		// libetc's exact shape: the count stored, reloaded, and the branch reading the reload.
		final reload = add("idleReload", [imm(9, 29, 29, -32), imm(9, 3, 0, -1), imm(0x2b, 6, 29, 16),
			imm(0x23, 2, 29, 16), 0, imm(9, 2, 2, -1), imm(0x2b, 2, 29, 16), imm(0x23, 2, 29, 16), 0,
			imm(5, 3, 2, 4), 0, imm(9, 2, 0, 2), JR, imm(9, 29, 29, 32),
			imm(0x23, 2, 5, 0), alu(0x2b, 2, 2, 4), imm(5, 0, 2, -14), 0,
			imm(9, 2, 0, 1), JR, imm(9, 29, 29, 32)]);
		// The same wait with a call in the turn, and a counter carried in a register: not idle.
		final busy = add("idleCall", [jal(next + 32), 0, imm(0x23, 2, 5, 0), alu(0x2b, 2, 2, 4),
			imm(5, 0, 2, -5), 0, JR, 0, JR, 0]);
		final carried = add("idleCarried", [imm(9, 2, 2, -1), imm(5, 0, 2, -2), 0, JR, 0]);
		// A logical shift by zero, by register (SRLV, amount 32 & 31) and by immediate (SRL 0),
		// each compared with its source by BEQ. On JavaScript `x >>> 0` is the unsigned reading,
		// which `==` finds unequal to the signed value C++ holds; the result must be the word.
		final shift = add("shiftByZero", [alu(0x06, 2, 5, 4), alu(0x02, 3, 0, 4),
			imm(4, 4, 2, 3), imm(9, 8, 0, 0), JR, imm(9, 8, 0, 1),
			imm(4, 4, 3, 3), imm(9, 9, 0, 0), JR, imm(9, 9, 0, 1),
			JR, imm(9, 10, 0, 7)]);
		// A return to the caller's caller (ADR-0027): outer saves its $ra at 100($a2) and calls
		// helper; with a1 == 0 the helper loads that address and jumps to it, leaving both, so
		// outer's rest (v0 += 10, v1 += 1000) never runs. With a1 != 0 it returns normally.
		final nl = next;
		final nonlocal = add("nonlocalReturn", [
			imm(15, 6, 0, 0x8004), imm(9, 29, 29, -8), imm(0x2b, 31, 29, 0), jal(nl + 0x40),
			imm(9, 3, 0, 0), imm(9, 3, 3, 100), imm(0x23, 31, 29, 0), JR, imm(9, 29, 29, 8),
			0, 0, 0, 0, 0, 0, 0,
			imm(0x2b, 31, 6, 100), jal(nl + 0x80), imm(9, 2, 0, 1), imm(9, 2, 2, 10),
			imm(0x23, 31, 6, 100), JR, imm(9, 3, 3, 1000), 0, 0, 0, 0, 0, 0, 0, 0, 0,
			imm(5, 0, 5, 4), 0, imm(0x23, 31, 6, 100), JR, imm(9, 2, 0, 7),
			JR, imm(9, 2, 0, 3)]);
		// A register the caller wrote, a callee changed and the caller never reads again reaches
		// the next callee as that callee left it: g1 sets v1 = 7 and g2 copies v1 into v0. The
		// caller redefines v1 after both calls, so its own copy is dead after the first one.
		final sc = next;
		final stale = add("staleAcrossCalls", [imm(9, 3, 0, 5), jal(sc + 32), 0, jal(sc + 40), 0,
			imm(9, 3, 0, 9), JR, 0,
			JR, imm(9, 3, 0, 7),
			JR, alu(0x21, 2, 3, 0)]);
		// A pointer walked through memory: two loads a turn through a0, then a0 += 8. The step
		// moves a0's span (Memory.spanStep) instead of taking it again.
		final walk = add("pointerWalk", [alu(0x21, 2, 0, 0),
			imm(0x23, 8, 4, 0), imm(0x23, 9, 4, 4), imm(9, 4, 4, 8), alu(0x21, 2, 2, 8),
			imm(9, 5, 5, -1), imm(7, 0, 5, -6), alu(0x21, 2, 2, 9), JR, 0]);
		// A call through a register the function built from a constant: guessed, and called
		// directly under a compare when optimizing; the callee writes only t3 and v1, so the span
		// on a0 the caller reads through after the call is not taken again on that arm.
		final gc = next;
		final guessed = add("guessedCall", [imm(15, 23, 0, (gc + 48) >>> 16), imm(13, 23, 23, (gc + 48) & 0xffff),
			imm(0x23, 8, 4, 0), imm(0x23, 9, 4, 4), alu(9, 31, 23, 0), 0,
			imm(0x23, 10, 4, 8), alu(0x21, 2, 8, 9), alu(0x21, 2, 2, 10), JR, 0, 0,
			imm(9, 11, 0, 5), JR, alu(0x21, 3, 11, 0)], [48]);
		final scalarBase = next;
		final scalar = add("scalarArithmetic", [imm(9, 2, 4, 7), alu(0, 2, 0, 2) | (2 << 6),
			JR, alu(0x21, 2, 2, 5)]);
		final overwritten = add("scalarOverwrite", [alu(0x26, 2, 6, 7), alu(0x21, 2, 4, 5), JR, 0]);
		// Input v0 is needed here; input a0 is not. Every final scratch register stays visible.
		add("scalarInputResult", [imm(9, 2, 2, -3), JR, alu(0x26, 2, 2, 5)]);
		final twoResults = add("scalarTwoResults", [alu(0x21, 8, 4, 5), JR, alu(0x21, 2, 8, 0)]);
		final unsafeLoad = add("scalarDiscardLoad", [imm(0x23, 0, 4, 0), JR, imm(9, 2, 0, 1)]);
		final trapOp = add("scalarTrapOp", [imm(8, 2, 4, 1), JR, 0]);
		final raWrite = add("scalarRaWrite", [alu(0x21, 31, 4, 0), JR, imm(9, 2, 0, 1)]);
		final scalarChainAddr = next;
		final scalarChain = add("scalarChain", [alu(0x21, 16, 31, 0), jal(next + 48), imm(9, 5, 5, 3),
			alu(0x21, 4, 2, 0), jal(next + 68), imm(9, 5, 5, -1), alu(0x21, 31, 16, 0), JR, 0,
			0, 0, 0, imm(9, 2, 4, 7), alu(0, 2, 0, 2) | (2 << 6), JR, alu(0x21, 2, 2, 5), 0,
			imm(9, 2, 2, -3), JR, alu(0x26, 2, 2, 5)]);
		final scalarOpsAddr = next;
		final scalarOps = [for (op in [0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b]) alu(op, 2, 4, 5)];
		for (op in [9, 12, 13, 14, 10, 11, 15]) scalarOps.push(imm(op, 2, 4, 0x8000));
		for (op in [0, 2, 3]) for (shift in [0, 1, 31]) scalarOps.push(alu(op, 2, 0, 5) | (shift << 6));
		for (op in [4, 6, 7]) scalarOps.push(alu(op, 2, 4, 5));
		for (k in 0...scalarOps.length) add('scalarOp$k', [scalarOps[k], JR, 0]);
		final restored = add("scalarRestored", [alu(0x21, 2, 8, 0), alu(0x21, 8, 4, 0),
			alu(0x21, 8, 2, 0), imm(9, 2, 4, 1), JR, 0]);
		final longWords = [for (_ in 0...31) imm(9, 2, 2, 1)];
		longWords.push(JR); longWords.push(0);
		final tooLong = add("scalarTooLong", longWords);
		final tooManyInputs = add("scalarTooManyInputs", [alu(0x21, 2, 4, 5), alu(0x21, 2, 2, 6),
			alu(0x21, 2, 2, 7), alu(0x21, 2, 2, 8), alu(0x21, 2, 2, 9), JR, alu(0x21, 2, 2, 10)]);
		final readBase = next;
		final read32 = add("scalarRead32", [imm(0x23, 2, 4, 0), JR, imm(9, 2, 2, 7)]);
		add("scalarRead8s", [imm(0x20, 2, 4, 1), JR, 0]);
		add("scalarRead8u", [imm(0x24, 2, 4, 1), JR, 0]);
		add("scalarRead16s", [imm(0x21, 2, 4, 2), JR, 0]);
		add("scalarRead16u", [imm(0x25, 2, 4, 2), JR, 0]);
		final affine = add("scalarReadAffine", [imm(9, 2, 4, 4), imm(0x23, 2, 2, -4), JR, alu(0x21, 2, 2, 5)]);
		add("scalarReadMany", [imm(0x24, 0, 4, 0), imm(0x21, 2, 4, 2), imm(0x23, 2, 4, 4), JR, imm(9, 2, 2, -7)]);
		final aligned = add("scalarReadByteFirst", [imm(0x24, 0, 4, 1), imm(0x23, 2, 4, 4), JR, 0]);
		final constantRead = add("scalarReadConstant", [imm(15, 2, 0, 0x8004), imm(13, 2, 2, 0x20), imm(0x23, 2, 2, 0), JR, 0]);
		add("scalarReadWrap", [imm(9, 2, 4, -16), imm(0x23, 2, 2, 16), JR, 0]);
		add("scalarReadBackwards", [imm(0x23, 0, 4, 0), imm(0x23, 2, 4, -4), JR, 0]);
		final chase = add("scalarReadChase", [imm(0x23, 2, 4, 0), imm(0x23, 2, 2, 0), JR, 0]);
		final bases = add("scalarReadTwoBases", [imm(0x23, 2, 4, 0), imm(0x23, 2, 5, 0), JR, 0]);
		final io = add("scalarReadKnownIo", [imm(15, 2, 0, 0x1f80), imm(0x23, 2, 2, 0x1814), JR, 0]);
		final incompatible = add("scalarReadUnaligned", [imm(0x21, 0, 4, 1), imm(0x23, 2, 4, 0), JR, 0]);
		final store = add("scalarMemoryStore", [imm(0x2b, 0, 4, 0), JR, imm(9, 2, 0, 1)]);
		add("scalarReadFifo", [imm(0x24, 0, 4, 0), imm(0x24, 2, 4, 0), JR, imm(14, 2, 2, 0x55)]);
		add("scalarReadDeadFifo", [imm(0x24, 0, 4, 0), imm(0x24, 2, 4, 0), JR, imm(9, 2, 0, 1)]);
		final readChain = next;
		add("scalarReadChain", [alu(0x21, 16, 31, 0), jal(next + 28), 0, alu(0x21, 31, 16, 0), JR, 0, 0,
			imm(0x23, 2, 4, 0), JR, imm(9, 2, 2, 7)]);
		// A function span only one path needs (Emitter.deferEntryTakes): with a0 < 0 the function
		// returns 7 without touching a1's memory; otherwise it sums the two words at a1, through a
		// span taken at that block, not at the entry. The `addi` (an overflow trap, never taken
		// here) keeps it out of scalar recovery, so the span is the general body's.
		final deferred = add("deferredSpan", [imm(1, 1, 4, 4), 0, imm(9, 2, 0, 7), JR, 0,
			imm(0x23, 2, 5, 0), imm(0x23, 3, 5, 4), alu(0x21, 2, 2, 3), imm(8, 2, 2, 1), JR, 0]);
		// Ports reached the libraries' ways (PortBases): through a pointer the executable keeps — a word
		// of the image holding libetc's I_STAT, loaded, then read through — and through a base built as
		// a port's constant. Both decode their address on fastmem rather than trap (Memory's `*pt`,
		// `*pf`); a load through a0, which holds anything, stays `*bt`. The `addi` keeps it out of
		// scalar recovery.
		final pp = next;
		final portPtr = add("portPointer", [imm(15, 2, 0, (pp + 32 + 0x8000) >>> 16), imm(0x23, 2, 2, (pp + 32) & 0xffff),
			imm(0x25, 5, 2, 0), imm(15, 3, 0, 0x1f80), imm(0x23, 6, 3, 0x1814), imm(8, 7, 4, 1), JR,
			imm(0x23, 8, 4, 0), 0x1f801070]);
		bodies.add('public static inline var SCALAR_READS = $readBase;\n');
		bodies.add('public static inline var SCALAR_READ_CHAIN = $readChain;\n');
		bodies.add('public static inline var SCALAR_BASE = $scalarBase;\n');
		bodies.add('public static inline var SCALAR_CHAIN = $scalarChainAddr;\n');
		bodies.add('public static inline var SCALAR_OPS = $scalarOpsAddr;\n');
		bodies.add('public static inline var SCALAR_COUNT = ${scalarOps.length};\n');
		if (check) {
			Assert.equals(portPtr.indexOf('Memory.read16up') >= 0, opt, "a port through a pointer the image keeps decodes its address");
			Assert.equals(portPtr.indexOf('Memory.read32pt(ctx.v1, 6164') >= 0, opt, "a port's constant base decodes its address");
			Assert.isTrue(portPtr.indexOf('Memory.read32pt(ctx.a0') < 0 && portPtr.indexOf('Memory.read32pf(ctx.a0') < 0,
				"a base that may hold anything goes through the MMU");
			Assert.isTrue(deferred.indexOf('_value(') < 0, "the deferred-span fixture keeps its general body");
			Assert.equals(deferred.indexOf('var fspan_a1 = entry == 0 ? Memory.spanNone()') >= 0, opt,
				"a span one path needs is not taken at the entry");
			Assert.equals(deferred.indexOf('\tfspan_a1 = Memory.span(ctx.a1, 0, 7);') >= 0, opt,
				"the span is taken at the block that needs it");
			Assert.equals(restored.indexOf('scalarRestored_value(a0:Int):Int') >= 0, opt,
				"SSA proves a scratch register is restored without reading it into the helper");
			Assert.equals(tooLong.indexOf('_value(') >= 0, opt, "compact recovery may exceed 32 guest instructions");
			Assert.isTrue(tooManyInputs.indexOf('_value(') < 0, "scalar recovery limits argument pressure");
			Assert.equals(scalar.indexOf('scalarArithmetic_value(a0:Int, a1:Int):Int') >= 0, opt,
				"scalar signature comes from values read before definition");
			Assert.equals(overwritten.indexOf('scalarOverwrite_value(a0:Int, a1:Int):Int') >= 0, opt,
				"overwritten pure values do not become parameters");
			Assert.equals(twoResults.indexOf('_value(') >= 0, opt, "multiple observable outputs use the scalar return ABI");
			if (opt) Assert.isTrue(twoResults.indexOf('ctx.t0 = ') >= 0, "scratch register output is published too");
			Assert.equals(unsafeLoad.indexOf('Memory.spanOk(memory0)') >= 0, opt, "even a dead load needs a memory guard");
			Assert.isTrue(unsafeLoad.indexOf('Memory.read32') >= 0, "a discarded MMIO read survives in the fallback");
			Assert.equals(read32.indexOf('scalarRead32_value(memory0:shim.Span):Int') >= 0, opt,
				"a memory getter receives checked storage, not CpuState");
			Assert.equals(affine.indexOf('scalarReadAffine_value(a1:Int, memory0:shim.Span):Int') >= 0, opt,
				"affine address input is consumed by the guard, data input by the helper");
			Assert.equals(aligned.indexOf('(memory0Address & 3) == 1') >= 0, opt,
				"alignment is relative to each actual access, not only the first byte");
			Assert.equals(constantRead.indexOf('memory0Address = -2147221472;') >= 0, opt,
				"LUI and ORI form a known address before any load");
			for (rejected in [io, incompatible]) Assert.isTrue(rejected.indexOf('_value(') < 0,
				"known IO and incompatible alignment retain original code");
			Assert.equals(chase.indexOf('_value(') >= 0, opt, 'checked dependent reads use recovered signatures');
			for (accepted in [bases, store]) Assert.equals(accepted.indexOf('_value(') >= 0, opt,
				"multiple checked bases and ordered writes use recovered signatures");
			Assert.isTrue(trapOp.indexOf('_value(') < 0, "overflow-trapping operations are not pure helpers");
			Assert.isTrue(raWrite.indexOf('_value(') < 0, "changing ra is not an ordinary scalar return");
			Assert.equals(scalarChain.indexOf('_value(ctx.a0, ctx.a1)') >= 0, opt,
				"direct calls use the scalar signature");
			Assert.equals(scalarChain.indexOf('core.Cooperative.deadline') >= 0, opt,
				"scalar direct calls retain due checkpoint fallback");
			if (opt) Assert.isTrue(scalar.substring(scalar.indexOf('public static function scalarArithmetic_value')).indexOf('ctx') < 0,
				"scalar computation has no CpuState access");
			Assert.equals(walk.indexOf('Memory.spanStep(') >= 0, opt, "a stepped pointer keeps its span");
			Assert.equals(guessed.indexOf('== 0x${StringTools.hex(gc + 48, 8).toLowerCase()})) {') >= 0
				|| guessed.indexOf('== ${gc + 48})) {') >= 0 || guessed.indexOf('== 0x${StringTools.hex(gc + 48, 8)})) {') >= 0, opt,
				"a register call to the function it was built from goes there directly, under a compare");
			final fast = guessed.indexOf('CodegenOptimized.f_');
			final slow = guessed.indexOf('} else {', fast);
			Assert.equals(fast >= 0 && slow > fast && guessed.substring(fast, slow).indexOf('Memory.span(') < 0
				&& guessed.indexOf('Memory.span(', slow) > slow, opt,
				"a span the callee cannot change is kept on the direct arm, taken again on the other");
			Assert.isTrue(loop.indexOf(opt ? 'var a0 = ctx.a0' : 'ctx.a0') >= 0, "a leaf keeps its registers in locals when optimizing");
			Assert.isTrue(stale.indexOf('var v1') < 0 && stale.indexOf('ctx.v1 = 5;') >= 0, "a function that calls keeps them in CpuState");
			Assert.equals(loop.indexOf('switch (bb)') < 0, opt, "linear loop uses native control flow");
			Assert.isTrue(loop.indexOf(opt ? 'cyc = (cyc +' : 'ctx.cycles = (ctx.cycles +') >= 0, "cycles wrap on both targets");
			// An optimized function counts in its local `cyc`: CpuState has it before a call and
			// the function reads it back after, and a load's slow path is handed it.
			Assert.equals(nonlocal.indexOf('var cyc = ctx.cycles;') >= 0, opt, "the clock in a local when optimizing");
			Assert.equals(nonlocal.indexOf('ctx.cycles = cyc;\n') >= 0 && nonlocal.indexOf('cyc = ctx.cycles;\n') >= 0, opt,
				"the clock written before a call and read back after it");
			Assert.equals(nonlocal.indexOf('Memory.read32bt(') >= 0 || nonlocal.indexOf('Memory.read32bf(') >= 0
				|| nonlocal.indexOf('Memory.read32t(') >= 0 || nonlocal.indexOf('Memory.read32f(') >= 0, opt,
				"a load's slow path is handed the clock");
			Assert.equals(fused.indexOf('Ops.multLo(ctx') >= 0, opt, "fused signed multiply low");
			Assert.equals(fused.indexOf('Ops.multHi(ctx') >= 0, opt, "fused signed multiply high");
			Assert.equals(fused.indexOf('Ops.multuLo(ctx') >= 0, opt, "fused unsigned multiply low");
			Assert.equals(fused.indexOf('Ops.multuHi(ctx') >= 0, opt, "fused unsigned multiply high");
			Assert.equals(fused.indexOf('Ops.divLo(ctx') >= 0, opt, "fused signed divide low");
			Assert.equals(fused.indexOf('Ops.divHi(ctx') >= 0, opt, "fused signed divide high");
			Assert.equals(fused.indexOf('Ops.divuLo(ctx') >= 0, opt, "fused unsigned divide low");
			Assert.equals(fused.indexOf('Ops.divuHi(ctx') >= 0, opt, "fused unsigned divide high");
			Assert.equals(fused.indexOf('t6 = 0x12345678;') >= 0, opt, "fused constant formation");
			Assert.equals(stack.indexOf('ctx.t2 = ctx.t1;') >= 0 || stack.indexOf('\tt2 = t1;') >= 0, opt, "stack load forwarding");
			Assert.equals(stack.indexOf('Memory.write32(ctx.sp & 0x1FFFFFFF, ctx.t0);') >= 0, !opt,
				"superseded stack store shape");
			Assert.equals(dead.indexOf('t0 = 1;') >= 0, !opt, "only unobserved definitions inside a pure value region disappear");
			Assert.equals(multi.indexOf('while (true) {') >= 0, opt, "multi-block loop is a native loop");
			Assert.equals(multi.indexOf('switch (bb)') < 0, opt, "multi-block loop needs no dispatcher");
			Assert.equals(multi.indexOf('; break;') >= 0, opt, "loop exit records its target and breaks");
			Assert.isTrue(dead.indexOf('t0 = 2;') >= 0, "live pure write retained");
			Assert.equals(gte.indexOf('Gte.cmdRtps(12, false);') >= 0, !opt, "known GTE command called by name");
			Assert.equals(gte.indexOf('gte.GteQuick.rtps(12, false);') >= 0, opt, "RTPS runs at its call site when optimizing");
			Assert.isTrue(gte.indexOf('Gte.execute(ctx, 0x00000002);') >= 0, "unknown GTE command falls back to execute");
			Assert.equals(gte.indexOf('gte.GteQuick.nclip();') >= 0, opt, "NCLIP runs at its call site when optimizing");
			Assert.equals(idle.indexOf('core.IdleLoop.untilEvent(cyc, core.Runtime.deadline(ctx), ') >= 0, opt, "idle loop prologue when optimizing");
			Assert.equals(idle.indexOf('core.IdleLoop.untilEqual(idleTop, -1, v1)') >= 0, opt, "idle loop counter exit");
			Assert.equals(reload.indexOf('core.IdleLoop.untilEqual(idleTop, -1, v1)') >= 0, opt, "stored-and-reloaded counter exit");
			Assert.equals(reload.indexOf('idle_v0 = idleStored;') >= 0, opt, "a reload yields the stored count in the dry turn");
			Assert.isTrue(busy.indexOf('core.IdleLoop.') < 0, "a loop with a call is not idle");
			Assert.isTrue(carried.indexOf('core.IdleLoop.') < 0, "a register-carried counter is not idle");
			Assert.isTrue(shift.indexOf('>>> 0') < 0, "a logical shift by zero is the value itself");
			Assert.isTrue(shift.indexOf('& 31)) | 0;') >= 0, "a logical shift by register is truncated to a word");
			Assert.isTrue(nonlocal.indexOf('Runtime.unwinding(ctx, 0x${StringTools.hex(nl + 0x14, 8).toLowerCase()})') >= 0,
				"a call's after-check names the address it returns to");
			Assert.isTrue(nonlocal.indexOf('entryRa') < 0, "a return from the own stack slot is not checked");
			Assert.isTrue(bodies.toString().indexOf('Runtime.returnTo(ctx, ') >= 0,
				"a return through a loaded ra is checked against the entry ra");
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
			+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n' + bodies.toString()
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool {\nswitch (addr) {\n'
			+ dispatch.toString() + 'default: return false;\n}\n}\n}\n';
	}

	public static function main():Void { generate(false); }
	public static function run():Void {
		Assert.group("codegen: real emitted fixtures, optimized and reference");
		generate(true);
	}
	static function generate(check:Bool):Void {
		final dir = "out/_codegen/fixtures";
		FileSystem.createDirectory(dir);
		for (opt in [false, true]) {
			final text = source(opt, check);
			if (check) Assert.equals(source(opt, false), text, "deterministic emission");
			File.saveContent('$dir/$cls.hx', text);
		}
		TestRegions.generate(check);
	}
}
