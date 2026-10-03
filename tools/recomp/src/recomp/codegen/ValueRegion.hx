package recomp.codegen;

import recomp.ir.FunctionIR.InstructionIR;
import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.mips.Instr;

/** Pure straight-line values between architectural observations. No value survives the
    publication boundary: the next region reads the current state, including callback writes.
    This is value SSA and dead-definition removal, not a register cache across guest calls.
**/
class ValueRegion {
	public final end:Int;
	final graph:ScalarGraph;
	final regs:Array<ScalarValue>;
	final outputs:Array<Int>;
	function new(end:Int, graph:ScalarGraph, regs:Array<ScalarValue>) {
		this.end = end; this.graph = graph; this.regs = regs;
		outputs = [for (r in 1...32) if (!regs[r].equivalent(graph.initial[r])) r];
		for (r in outputs) mark(regs[r]);
	}

	/** The caller may shorten the interval at a span refresh. Memory, traps, coprocessors,
	    HI/LO, control and return-address writes end it before that instruction executes. */
	public static function analyze(body:Array<InstructionIR>, start:Int, limit:Int):Null<ValueRegion> {
		final graph = new ScalarGraph(true); final regs = graph.initial.copy();
		var end = start;
		while (end < limit && end - start < 32 && graph.lift(body[end], regs, false)) end++;
		return end - start < 2 ? null : new ValueRegion(end, graph, regs);
	}

	function mark(v:ScalarValue):Void {
		if (v.live) return;
		v.live = true;
		// Exact constants/affine values can be reconstructed without their original chain.
		if (v.addressBase > 0) graph.initial[v.addressBase].live = true;
		else if (v.addressBase < 0) for (a in v.args) mark(a);
	}

	public function emit(ind:String, prefix:String, ?registerName:Int -> String):String {
		if (registerName == null) registerName = r -> 'ctx.' + Instr.regName(r);
		final buf = new StringBuf(); final names:Map<String, String> = [];
		for (r in 1...32) if (graph.initial[r].live) {
			final name = prefix + 'i$r'; names.set(Instr.regName(r), name);
			buf.add('${ind}final $name = ${registerName(r)};\n');
		}
		final tokens = ~/\b[A-Za-z_][A-Za-z0-9_]*\b/g;
		function rename(expr:String):String return tokens.map(expr, token -> {
			final id = token.matched(0); return names.exists(id) ? names.get(id) : id;
		});
		var next = 0;
		for (v in graph.values) if (v.live) {
			if (v.addressBase == 0) { names.set(v.ref, Std.string(v.addressOffset)); continue; }
			if (v.addressBase > 0 && v.addressOffset == 0) {
				names.set(v.ref, names.get(Instr.regName(v.addressBase))); continue;
			}
			final name = prefix + 'v${next++}';
			final expr = v.addressBase > 0
				? '(' + names.get(Instr.regName(v.addressBase)) + ' + ${v.addressOffset}) | 0'
				: rename(v.expr);
			buf.add('${ind}final $name = $expr;\n'); names.set(v.ref, name);
		}
		// Every input and computed value is captured before the first publication. Register
		// swaps and overwritten inputs therefore cannot observe an earlier output store.
		for (r in outputs) buf.add('${ind}${registerName(r)} = ${rename(regs[r].ref)};\n');
		return buf.toString();
	}
}
