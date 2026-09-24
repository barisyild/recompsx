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
		add("multiBlockLoop", [alu(0x21, 2, 0, 0), imm(4, 0, 4, 5), 0,
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
		final dead = add("deadWrites", [
			imm(9, 8, 0, 1), imm(9, 8, 0, 2), imm(9, 2, 8, 3)]);
		if (check) {
			Assert.isTrue(loop.indexOf(opt ? 'var a0 = ctx.a0' : 'ctx.a0 =') >= 0, "register representation");
			Assert.equals(loop.indexOf('switch (bb)') < 0, opt, "linear loop uses native control flow");
			Assert.isTrue(loop.indexOf('ctx.cycles = (ctx.cycles +') >= 0, "cycles wrap on both targets");
			Assert.equals(fused.indexOf('Ops.multLo(ctx') >= 0, opt, "fused signed multiply low");
			Assert.equals(fused.indexOf('Ops.multHi(ctx') >= 0, opt, "fused signed multiply high");
			Assert.equals(fused.indexOf('Ops.multuLo(ctx') >= 0, opt, "fused unsigned multiply low");
			Assert.equals(fused.indexOf('Ops.multuHi(ctx') >= 0, opt, "fused unsigned multiply high");
			Assert.equals(fused.indexOf('Ops.divLo(ctx') >= 0, opt, "fused signed divide low");
			Assert.equals(fused.indexOf('Ops.divHi(ctx') >= 0, opt, "fused signed divide high");
			Assert.equals(fused.indexOf('Ops.divuLo(ctx') >= 0, opt, "fused unsigned divide low");
			Assert.equals(fused.indexOf('Ops.divuHi(ctx') >= 0, opt, "fused unsigned divide high");
			Assert.equals(fused.indexOf('t6 = 0x12345678;') >= 0, opt, "fused constant formation");
			Assert.equals(stack.indexOf('t2 = t1;') >= 0, opt, "stack load forwarding");
			Assert.equals(stack.indexOf('Memory.write32(ctx.sp, ctx.t0);') >= 0, !opt,
				"superseded stack store shape");
			Assert.equals(dead.indexOf('t0 = 1;') >= 0, !opt, "dead pure write elimination");
			Assert.isTrue(dead.indexOf('t0 = 2;') >= 0, "live pure write retained");
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
