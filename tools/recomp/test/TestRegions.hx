import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.RegionPlan;
import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.ir.Effect;
import recomp.mips.Decoder;
import sys.io.File;

/** Synthetic MIPS only: region rules must work without a game, symbol map or library pattern. */
class TestRegions {
	static final BASE = 0x80100000;
	static var words:Array<Int>;
	static var labels:Map<String, Int>;
	static var fixes:Array<{at:Int, label:String, jump:Bool}>;
	static var programs:Array<Array<Int>>;
	static var names:Array<String>;

	static function imm(op:Int, rt:Int, rs:Int, value:Int):Int
		return (op << 26) | (rs << 21) | (rt << 16) | (value & 0xffff);
	static function add(rt:Int, rs:Int, value:Int):Void words.push(imm(9, rt, rs, value));
	static function mark(name:String):Void labels.set(name, words.length);
	static function branch(rs:Int, rt:Int, label:String, slot:Int = 0, op:Int = 4):Void {
		fixes.push({at: words.length, label: label, jump: false});
		words.push(imm(op, rt, rs, 0)); words.push(slot);
	}
	static function jump(label:String, slot:Int = 0):Void {
		fixes.push({at: words.length, label: label, jump: true});
		words.push(0); words.push(slot);
	}
	static function ret(slot:Int = 0):Void { words.push(0x03e00008); words.push(slot); }
	static function begin(name:String):Void {
		names.push(name); words = []; labels = []; fixes = [];
	}
	static function finish():Void {
		final base = BASE + programs.length * 0x1000;
		for (fix in fixes) {
			final to = labels.get(fix.label);
			if (to == null) throw 'missing synthetic label ${fix.label}';
			words[fix.at] = fix.jump ? 0x08000000 | (((base + to * 4) & 0x0fffffff) >>> 2)
				: words[fix.at] | ((to - fix.at - 1) & 0xffff);
		}
		programs.push(words);
	}

	static function fixtures():Void {
		programs = []; names = [];
		begin('diamond');
		add(2, 0, 0); add(3, 0, 0);
		branch(4, 0, 'taken', imm(9, 4, 0, 0)); // slot changes the tested register
		add(2, 2, 11); jump('join', imm(9, 3, 3, 1));
		mark('taken'); add(2, 2, 21); add(3, 3, 2);
		mark('join'); words.push((2 << 21) | (3 << 16) | (2 << 11) | 0x21); ret(); finish();

		begin('nested');
		branch(4, 0, 'outer'); branch(5, 0, 'inner');
		add(2, 0, 11); jump('join');
		mark('inner'); add(2, 0, 22); jump('join');
		mark('outer'); add(2, 0, 33);
		mark('join'); ret(imm(9, 3, 3, 1)); finish();

		begin('diamondLoop');
		add(2, 0, 0);
		mark('head'); branch(4, 0, 'end', imm(9, 3, 3, 1));
		words.push(imm(12, 8, 4, 1)); branch(8, 0, 'even');
		add(2, 2, 3); jump('next', imm(9, 6, 6, 1));
		mark('even'); add(2, 2, 7);
		mark('next'); add(4, 4, -1); jump('head', imm(9, 7, 7, 1));
		mark('end'); ret(); finish();

		begin('sideEntry');
		branch(5, 0, 'arm', imm(9, 3, 3, 1), 5);
		branch(4, 0, 'taken');
		mark('arm'); add(2, 2, 11); jump('join');
		mark('taken'); add(2, 2, 22);
		mark('join'); ret(); finish();

		begin('irreducible');
		branch(5, 0, 'A'); jump('B');
		mark('A'); add(4, 4, -1); branch(4, 0, 'end', imm(9, 2, 2, 1), 6);
		jump('B', imm(9, 3, 3, 1));
		mark('B'); add(4, 4, -1); branch(4, 0, 'end', imm(9, 2, 2, 2), 6);
		jump('A', imm(9, 3, 3, 2));
		mark('end'); ret(); finish();

		begin('callArm');
		add(5, 0, 17); branch(4, 0, 'plain');
		words.push(0x0c000000 | ((0x8000f100 & 0x0fffffff) >>> 2));
		words.push(imm(9, 5, 5, 1)); jump('join');
		mark('plain'); add(2, 0, 30);
		mark('join'); add(2, 2, 4); ret(); finish();

		begin('reverseLayout');
		jump('header');
		mark('taken'); add(2, 2, 21); jump('join');
		mark('other'); add(2, 2, 11); jump('join');
		mark('header'); branch(4, 0, 'taken'); jump('other');
		mark('join'); ret(); finish();

		begin('sameSuccessor');
		branch(4, 0, 'next', imm(9, 2, 2, 1));
		mark('next'); ret(imm(9, 3, 3, 1)); finish();

		begin('fallthroughBlock');
		branch(4, 0, 'join'); add(2, 2, 11); add(3, 3, 2);
		mark('join'); ret(); finish();

		begin('externalBranch');
		words.push(imm(4, 0, 4, 0x03ff)); words.push(imm(9, 3, 3, 1));
		add(2, 2, 1); ret(); finish();

		// Different forward graphs, including cross edges into regions that must stay separate.
		var seed = 0x31415926;
		for (program in 0...8) {
			begin('dag_$program');
			for (block in 0...8) {
				mark('b$block');
				seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
				add(2, 2, (seed & 31) + 1);
				final to = block + 1 + ((seed >>> 8) % (8 - block));
				branch((block & 1) == 0 ? 4 : 5, 0, 'b$to', imm(9, 3, 3, block + 1),
					(seed & 1) == 0 ? 4 : 5);
			}
			mark('b8'); ret(); finish();
		}
	}

	public static function generate(check:Bool):Void {
		fixtures();
		if (check) checkEffects();
		for (mode in 0...3) {
			final optimized = mode != 0;
			final cls = mode == 0 ? 'RegionsReference' : (mode == 1 ? 'RegionsScalar' : 'RegionsOptimized');
			final out = new StringBuf();
			out.add('import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\n'
				+ 'import kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n');
			final counts = [];
			for (kind in 0...programs.length) {
				final bytes = Bytes.alloc(programs[kind].length * 4);
				for (i in 0...programs[kind].length) bytes.setInt32(i * 4, programs[kind][i]);
				final base = BASE + kind * 0x1000;
				final image = new Image(names[kind], base, bytes);
				final discovery = new Discovery(image);
				discovery.addSeed(base, names[kind], Confidence.Entry); discovery.run(false);
				final fn = discovery.functions.get(base);
				final ir = new FunctionIR(fn, image);
				final body = new Emitter(image, discovery, optimized, mode == 2).emitFunction(fn);
				counts.push(ir.blocks.length); out.add(body);
				if (check && mode == 2) {
					final plan = new RegionPlan(ir);
					final ids = [for (root in plan.roots) for (id in root.members) id];
					ids.sort((a, b) -> a - b);
					Assert.equals(ids.length, ir.blocks.length, 'region owns every block once');
					for (id in 0...ids.length) Assert.equals(ids[id], id, 'stable region resume ID');
					if (kind == 0 || kind == 1) Assert.isTrue(body.indexOf('switch (bb)') < 0, 'diamond has native branches');
					if (kind == 2) Assert.isTrue(body.indexOf('switch (bb)') < 0, 'diamond loop is a native loop');
					if (kind == 2) Assert.isTrue(body.indexOf('while (true) {') >= 0, 'diamond loop has a while');
					if (kind == 4) Assert.isTrue(body.indexOf('switch (bb)') >= 0, 'irreducible loop retains fallback');
				}
			}
			out.add('public static function count():Int return ${names.length};\n');
			out.add('public static function entries(kind:Int):Int { return switch(kind) {\n');
			for (i in 0...counts.length) out.add('case $i: ${counts[i]};\n');
			out.add('case _: 0; }; }\n');
			out.add('public static function run(kind:Int, ctx:CpuState, entry:Int = 0):Void { switch(kind) {\n');
			for (i in 0...names.length) out.add('case $i: ${names[i]}(ctx, entry);\n');
			out.add('case _: } }\n');
			// Runtime continuation dispatch identifies the owning function; its entry ID is
			// consumed by the emitted cooperative prologue.
			out.add('public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n');
			for (i in 0...names.length) out.add('case ${BASE + i * 0x1000}: ${names[i]}(ctx); return true;\n');
			out.add('case _: return false; } }\n}\n');
			File.saveContent('out/_codegen/fixtures/$cls.hx', out.toString());
		}
	}

	static function checkEffects():Void {
		final load = new InstructionIR(Decoder.decode(BASE, imm(0x24, 0, 4, 0)));
		Assert.isTrue(load.effects.has(Effect.READ_MEMORY), 'discarded load keeps MMIO effect');
		Assert.equals((load.writes:Int), 0, 'zero is not a stored register');
		Assert.isTrue(load.reads.has(4), 'load keeps address dependency');
		final merge = new InstructionIR(Decoder.decode(BASE, imm(0x22, 2, 4, 0)));
		Assert.isTrue(merge.reads.has(2) && merge.writes.has(2), 'unaligned load merges old destination');
		final store = new InstructionIR(Decoder.decode(BASE, imm(0x2a, 2, 4, 0)));
		Assert.isTrue(store.effects.has(Effect.READ_MEMORY) && store.effects.has(Effect.WRITE_MEMORY), 'unaligned store is read-modify-write');
		final link = new InstructionIR(Decoder.decode(BASE, 0x04110000));
		Assert.isTrue(link.writes.has(31) && link.effects.has(Effect.CALL), 'conditional link writes ra');
		final trap = new InstructionIR(Decoder.decode(BASE, 0x0000000c));
		Assert.isTrue(trap.effects.has(Effect.TRAP), 'syscall is an explicit barrier');
	}
}
