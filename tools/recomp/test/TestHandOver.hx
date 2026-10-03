import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;

/**
	Hand-overs between functions that share code (Discovery.cutAtEntries): where a function stops
	and hands over, where it keeps its copy, and the `HandOver` conformance fixture, which runs the
	same program traced both ways — every function carrying its copies (`HandWhole`) and handing
	over (`HandCut`) — on every target and compares everything the machine can see, including where
	events are taken and where a slice yields.
**/
@:access(TestCodegen)
class TestHandOver {
	static inline var FBASE = 0x80180000;
	static inline var JR_RA = 0x03e00008;

	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function addiu(rt:Int, rs:Int, n:Int):Int return imm(0x09, rt, rs, n);
	static function lw(rt:Int, rs:Int, n:Int):Int return imm(0x23, rt, rs, n);
	static function sw(rt:Int, rs:Int, n:Int):Int return imm(0x2B, rt, rs, n);
	static function addu(rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(0x21, rd, rs, rt);
	static function move(rd:Int, rs:Int):Int return addu(rd, rs, 0);
	static function jr(rs:Int):Int return (rs << 21) | 8;

	/** Cluster `c` starts at FBASE + 0x100 c. */
	static function program():{words:Array<Int>, labels:Map<String, Int>, seeds:Array<String>} {
		final labels:Map<String, Int> = [];
		final pending:Array<{at:Int, op:Int, rs:Int, rt:Int, label:String}> = [];
		final words = [for (_ in 0...0x400) 0];
		var at = 0;
		function org(cluster:Int):Void at = cluster << 6;
		function label(name:String):Void labels.set(name, FBASE + at * 4);
		function emit(w:Int):Void words[at++] = w;
		function branch(op:Int, rs:Int, rt:Int, name:String):Void {
			pending.push({at: at, op: op, rs: rs, rt: rt, label: name});
			emit(0);
		}
		function jal(name:String):Void {
			pending.push({at: at, op: 3, rs: 0, rt: 0, label: name});
			emit(0);
		}
		final seeds = [];
		function entry(name:String):Void { label(name); seeds.push(name); }
		// v0 2, v1 3, a0 4, a1 5, a2 6, t0 8, t1 9, s0 16, t9 25, ra 31.
		// 0: runs on into another entry.
		org(0); entry('A0'); emit(addiu(2, 4, 1)); emit(addiu(3, 5, 2));
		entry('B0'); emit(addu(2, 2, 3)); emit(sw(2, 6, 0)); emit(JR_RA); emit(addiu(2, 2, 3));
		// 1: a forward branch to another entry, a write in its delay slot, dead code after it.
		org(1); entry('C1'); emit(addiu(8, 4, 5)); branch(4, 0, 0, 'D1'); emit(addiu(9, 5, 7)); emit(addiu(8, 8, 99)); emit(0);
		entry('D1'); emit(addu(2, 8, 9)); emit(JR_RA); emit(0);
		// 2: a branch back to another entry: its block pumped in the copy, so the hand-over does.
		org(2); entry('E2'); emit(addiu(2, 2, 1)); emit(JR_RA); emit(addu(3, 2, 5));
		entry('F2'); emit(addiu(2, 4, 0)); branch(4, 0, 0, 'E2'); emit(0);
		// 3: two entries branching to each other in a loop: a cycle, so both keep their copies.
		org(3); entry('G3'); branch(6, 4, 0, 'X3'); emit(addiu(4, 4, -1)); branch(4, 0, 0, 'H3'); emit(addiu(2, 2, 3));
		label('X3'); emit(JR_RA); emit(0);
		entry('H3'); emit(addiu(3, 3, 1)); branch(4, 0, 0, 'G3'); emit(0);
		// 4: a call whose continuation is another entry.
		org(4); entry('I4'); emit(move(16, 31)); jal('L6'); emit(addiu(4, 4, 1));
		entry('J4'); emit(addu(2, 2, 4)); emit(move(31, 16)); emit(JR_RA); emit(0);
		// 5: `$ra` loaded from memory before the hand-over: the caller checks the return after it.
		org(5); entry('M5'); emit(lw(31, 5, 0)); branch(4, 0, 0, 'N5'); emit(0);
		entry('N5'); emit(addiu(2, 4, 1)); emit(JR_RA); emit(0);
		// 6: a leaf, and `$ra` built before a branch to another entry whose `jr $ra` it reaches:
		// the copy jumps to the built address, so O6 keeps it.
		org(6); entry('L6'); emit(addiu(2, 4, 10)); emit(JR_RA); emit(0);
		entry('O6'); emit(move(16, 31)); pendingLui(pending, at); emit(0); pendingOri(pending, at); emit(0);
		branch(4, 0, 0, 'Q6'); emit(0);
		entry('Q6'); emit(addiu(2, 4, 1)); emit(JR_RA); emit(0);
		label('P6'); emit(addiu(2, 2, 100)); emit(move(31, 16)); emit(JR_RA); emit(0);
		// 7: a call, then a hand-over to a function that loads `$ra` and returns through it: its
		// check compares with the entry value of the function that handed over (Runtime.hopRa).
		org(7); entry('R7'); emit(move(16, 31)); jal('L6'); emit(0); branch(4, 0, 0, 'S7'); emit(0);
		entry('S7'); emit(lw(31, 5, 0)); emit(JR_RA); emit(addiu(2, 2, 7));
		// 8: running on into a loop's head: the hand-over pumps, and so does the loop.
		org(8); entry('T8'); emit(addiu(4, 4, 3));
		entry('U8'); emit(addiu(2, 2, 2)); emit(addiu(4, 4, -1)); branch(7, 4, 0, 'U8'); emit(0); emit(JR_RA); emit(0);
		// 9: the function handed over to jumps through a register: the tail jump is its caller's.
		org(9); entry('W9'); emit(addiu(2, 4, 1)); branch(4, 0, 0, 'X9'); emit(0);
		entry('X9'); emit(addiu(2, 2, 1)); emit(jr(25)); emit(0);
		// 10: a hand-over on one arm of a branch, the other arm carrying on.
		org(10); entry('Y10'); branch(4, 4, 0, 'Z10'); emit(addiu(2, 5, 4)); emit(addiu(2, 2, 9)); emit(JR_RA); emit(0);
		entry('Z10'); emit(addiu(3, 2, 5)); emit(JR_RA); emit(0);
		// 11: a chain of hand-overs, each running on into the next.
		org(11); entry('AA11'); emit(addiu(2, 4, 1));
		entry('BB11'); emit(addiu(2, 2, 2));
		entry('CC11'); emit(addiu(2, 2, 4)); emit(JR_RA); emit(0);
		// 12: P12 branches back into Q12's middle as well as to its entry: that block pumped in
		// P12's copy for an edge Q12 does not have, so P12 keeps its copy.
		org(12); entry('Q12'); emit(addiu(2, 2, 1));
		label('X12'); emit(addiu(3, 3, 3)); emit(JR_RA); emit(0);
		entry('P12'); branch(4, 4, 0, 'X12'); emit(0); branch(4, 0, 0, 'Q12'); emit(0);
		for (p in pending) {
			final target = labels.get(p.label);
			final pc = FBASE + p.at * 4;
			words[p.at] = switch (p.op) {
				case 3: TestCodegen.jal(target);
				case 0x0F: imm(0x0F, 31, 0, (target >>> 16) & 0xFFFF);
				case 0x0D: imm(0x0D, 31, 31, target & 0xFFFF);
				case _: (p.op << 26) | (p.rs << 21) | (p.rt << 16) | (((target - (pc + 4)) >> 2) & 0xFFFF);
			}
		}
		return {words: words, labels: labels, seeds: seeds};
	}

	/** O6's `lui $ra, P6 >> 16` and `ori $ra, $ra, P6 & 0xFFFF`, resolved with the branches. */
	static function pendingLui(pending:Array<{at:Int, op:Int, rs:Int, rt:Int, label:String}>, at:Int):Void
		pending.push({at: at, op: 0x0F, rs: 0, rt: 31, label: 'P6'});
	static function pendingOri(pending:Array<{at:Int, op:Int, rs:Int, rt:Int, label:String}>, at:Int):Void
		pending.push({at: at, op: 0x0D, rs: 31, rt: 31, label: 'P6'});

	/** The functions the conformance test calls, outer entries first in each cluster. */
	public static final CALLS = ['A0', 'B0', 'C1', 'D1', 'E2', 'F2', 'G3', 'H3', 'I4', 'J4', 'M5', 'N5', 'L6', 'O6', 'Q6',
		'R7', 'S7', 'T8', 'U8', 'W9', 'X9', 'Y10', 'Z10', 'AA11', 'BB11', 'CC11', 'Q12', 'P12'];

	static function discover(cut:Bool):{d:Discovery, image:Image, labels:Map<String, Int>} {
		final p = program();
		final bytes = Bytes.alloc(p.words.length * 4);
		for (i in 0...p.words.length) bytes.setInt32(i * 4, p.words[i]);
		final image = new Image('hand-over', FBASE, bytes);
		final d = new Discovery(image);
		d.cutShared = cut;
		for (s in p.seeds) d.addSeed(p.labels.get(s), Discovery.defaultName(p.labels.get(s)), Confidence.Entry);
		d.run(false);
		return {d: d, image: image, labels: p.labels};
	}

	static function source(cut:Bool, check:Bool):String {
		final cls = cut ? 'HandCut' : 'HandWhole';
		final x = discover(cut);
		final d = x.d, image = x.image, labels = x.labels;
		final emitter = new Emitter(image, d, true);
		emitter.staticTargetOf = a -> d.functions.exists(a) ? cls : null;
		final summaries = [for (a in d.functions.keys()) a => new recomp.analysis.FunctionSummary(d.functions.get(a), image, _ -> null)];
		for (s in summaries) for (c in s.calls) if (c.target != null) c.callee = summaries.get(Vaddr.canonRam(c.target));
		recomp.analysis.FunctionSummary.solve([for (s in summaries) s]);
		emitter.writesOf = a -> summaries.exists(a) ? summaries.get(a).writes : Emitter.ALL_REGS;
		final bodies = new StringBuf(), dispatch = new StringBuf(), resume = new StringBuf();
		final order = [for (a in d.functions.keys()) a];
		order.sort((p, q) -> (p ^ 0x80000000) < (q ^ 0x80000000) ? -1 : ((p ^ 0x80000000) > (q ^ 0x80000000) ? 1 : 0));
		// By address: a function's entry is itself; a block other functions also hold is the
		// first holder's, by entry order.
		final routed:Map<Int, Bool> = [];
		for (a in order) {
			final fn = d.functions.get(a);
			bodies.add(emitter.emitFunction(fn));
			resume.add('case ${fn.entry}: ${fn.name}(ctx, entry);\n');
			dispatch.add('case ${fn.entry}: ${fn.name}(ctx, 0); return true;\n');
			routed.set(fn.entry, true);
		}
		for (a in order) {
			final fn = d.functions.get(a);
			final blocks = Emitter.blockOrder(fn);
			for (i in 1...blocks.length) if (!routed.exists(blocks[i])) {
				routed.set(blocks[i], true);
				dispatch.add('case ${blocks[i]}: ${fn.name}(ctx, $i); return true;\n');
			} else {}
		}
		final calls = [for (n in CALLS) '${labels.get(n)}'];
		if (check) {
			final fn = n -> d.functions.get(labels.get(n));
			final hops = n -> [for (h in fn(n).hops.keys()) h];
			if (cut) {
				Assert.isTrue(hops('A0').indexOf(labels.get('B0')) >= 0, 'hand-over: running on into an entry');
				Assert.isTrue(hops('C1').indexOf(labels.get('D1')) >= 0, 'hand-over: a branch to an entry');
				Assert.isTrue(fn('F2').pumpedHops.exists(labels.get('E2')), 'hand-over: a branch back pumps on the way in');
				Assert.isTrue(!fn('A0').pumpedHops.exists(labels.get('B0')), 'hand-over: running on does not pump');
				Assert.equals(hops('G3').length + hops('H3').length, 0, 'hand-over: a cycle keeps its copies');
				Assert.equals(hops('I4').length, 0, 'hand-over: never at a call\'s continuation (a slice resumes there)');
				Assert.isTrue(fn('M5').checkedHops.keys().hasNext(), 'hand-over: a foreign $$ra is checked after it');
				Assert.equals(hops('O6').length, 0, 'hand-over: a built $$ra keeps the copy');
				Assert.isTrue(hops('R7').indexOf(labels.get('S7')) >= 0, 'hand-over: to a checked function after a call');
				Assert.isTrue(hops('T8').indexOf(labels.get('U8')) >= 0 && !fn('T8').pumpedHops.exists(labels.get('U8')),
					'hand-over: into a loop\'s head, which pumps of its own');
				Assert.isTrue(hops('Y10').indexOf(labels.get('Z10')) >= 0 && fn('Y10').blocks.keys().hasNext(), 'hand-over: on one arm');
				Assert.isTrue(hops('AA11').indexOf(labels.get('BB11')) >= 0 && hops('BB11').indexOf(labels.get('CC11')) >= 0,
					'hand-over: a chain');
				Assert.equals(hops('P12').length, 0, 'hand-over: a block pumped for an edge left behind keeps the copy');
				final text = emitter.emitFunction(fn('A0'));
				Assert.isTrue(text.indexOf('$cls.${Discovery.defaultName(labels.get('B0'))}(ctx, -2)') >= 0, 'hand-over: emitted as a call past the pump');
				Assert.isTrue(emitter.emitFunction(fn('F2')).indexOf('(ctx, -3)') >= 0, 'hand-over: through the pump where the copy pumped');
				Assert.isTrue(emitter.emitFunction(fn('B0')).indexOf('final hopped = entry <= -2;') >= 0, 'hand-over: its target knows');
			} else {
				for (n in CALLS) Assert.equals(hops(n).length, 0, 'whole: $n hands over nothing');
			}
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport mem.Memory;\nclass $cls {\n'
			+ 'public static final CALLS = [' + calls.join(', ') + '];\n'
			+ 'public static inline var L6 = ${labels.get('L6')};\n'
			+ 'public static inline var P6 = ${labels.get('P6')};\n'
			+ bodies.toString()
			+ 'public static function resume(fn:Int, entry:Int, ctx:CpuState):Void { switch(fn) {\n' + resume.toString() + 'default: } }\n'
			+ 'public static function dispatch(addr:Int, ctx:CpuState):Bool { switch(addr) {\n' + dispatch.toString() + 'default: return false; } }\n}\n';
	}

	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		sys.io.File.saveContent('out/_codegen/fixtures/HandCut.hx', source(true, check));
		sys.io.File.saveContent('out/_codegen/fixtures/HandWhole.hx', source(false, check));
	}

	public static function main():Void generate(false);

	public static function run():Void {
		Assert.group('hand-overs: where functions stop, where they keep copies, the HandOver fixture');
		generate(true);
	}
}
