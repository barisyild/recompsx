package recomp.codegen;

import recomp.analysis.Func;
import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;
import recomp.mips.Op;
import recomp.codegen.ScalarGraph.ScalarValue;

/** Acyclic CFG -> value SSA. Predecessor predicates select phi inputs; only pure integer
	operations may be speculated. Checked memory operations execute under their block's reach
	predicate. Accounting follows reachability, not evaluation.
	Public interior entries keep the original body; this graph describes entry zero only.
**/
class ScalarCfg {
	public static function analyze(fn:Func, ir:FunctionIR, required:Int, suffix:String, ?callee:Int -> Null<ScalarCall>):Null<ScalarPlan> {
		final pending:Map<Int, Int> = [];
		final calls:Map<Int, ScalarCall> = [];
		var totalCycles = 0;
		var totalInstructions = fn.instructionCount(); var totalBlocks = ir.blocks.length;
		for (b in ir.blocks) {
			if (b.pump) return null;
			totalCycles += b.cycles;
			pending.set(b.addr, b.predecessors.length);
			final t = b.transfer;
			if (t == null) {
				if (b.successors.length != 1) return null;
			} else {
				if (b.delaySlot == null) return null;
				final i = t.decoded;
				if (b.conditional()) {
					if (b.successors.indexOf(i.target) < 0 || b.successors.indexOf(i.addr + 8) < 0
						|| b.successors.length > 2) return null;
				} else if (i.op == Op.JAL) {
					if (callee == null || b.successors.length != 1 || b.successors[0] != i.addr + 8) return null;
					final call = callee(i.target); if (call == null) return null;
					calls.set(b.addr, call);
					totalCycles += call.plan.bounds.cycles;
					totalInstructions += call.plan.bounds.instructions;
					totalBlocks += call.plan.bounds.blocks;
				} else if (i.op == Op.J) {
					if (b.successors.length != 1 || b.successors[0] != i.target) return null;
				} else if (i.op != Op.JR || i.rs != 31 || b.successors.length != 0) return null;
			}
		}
		// Ten bits per counter in the allocation-free accounting return word. Bound the entire
		// DAG, so even evaluating every reachable predicate cannot overflow a packed lane.
		if (totalCycles > 1023 || totalInstructions > 1023 || totalBlocks > 1023) return null;
		final hasCalls = calls.keys().hasNext();
		if (!hasCalls && fn.checkedReturns.keys().hasNext()) return null;
		final order:Array<BlockIR> = [];
		while (order.length < ir.blocks.length) {
			var next:Null<BlockIR> = null;
			for (b in ir.blocks) if (pending.get(b.addr) == 0) { next = b; break; }
			if (next == null) return null;
			pending.set(next.addr, -1); order.push(next);
			for (a in next.successors) pending.set(a, pending.get(a) - 1);
		}
		final graph = new ScalarGraph(false, hasCalls, hasCalls);
		final predicates = new ScalarPredicates(graph);
		final yes = predicates.yes;
		final accounting = new ScalarAccounting(graph, predicates);
		function merge(edges:Array<ScalarEdge>):ScalarEdge {
			final regs = edges[0].regs.copy(); var reach = edges[0].reach;
			for (n in 1...edges.length) {
				final e = edges[n];
				for (r in 1...32) regs[r] = predicates.select(e.reach, e.regs[r], regs[r]);
				reach = predicates.either(reach, e.reach);
			}
			return {reach:reach, regs:regs, memory:ScalarMemoryValues.intersect([for (e in edges) e.memory])};
		}
		final incoming:Map<Int, Array<ScalarEdge>> = [];
		incoming.set(fn.entry, [{reach:yes, regs:graph.initial.copy(), memory:new ScalarMemoryValues()}]);
		final exits:Array<ScalarEdge> = [];
		final callCosts:Array<ScalarValue> = [];
		for (b in order) {
			// No edge: no path from entry zero reaches the block — a constant branch's other arm.
			// It is not lifted, so its accesses need no preflight and its effects never run.
			final edges = incoming.get(b.addr);
			if (edges == null || edges.length == 0) continue;
			final state = merge(edges); final regs = state.regs;
			graph.beginBlock(state.reach == yes ? null : state.reach, state.memory);
			for (x in b.body) if (!graph.lift(x, regs, true)) return null;
			var branch:Null<ScalarValue> = null;
			if (b.conditional()) {
				final i = b.transfer.decoded; final a = regs[i.rs]; final c = regs[i.rt];
				branch = predicates.branch(i.op, a, c);
			}
			// Prove the sampled return target before executing its delay slot. Saving/restoring
			// ra is a value proof, including stack forwarding, never a calling-convention rule.
			if (b.transfer != null && b.transfer.decoded.op == Op.JR
				&& !regs[31].equivalent(graph.initial[31])) return null;
			final call = calls.get(b.addr);
			if (call != null) {
				final link = (b.transfer.decoded.addr + 8) | 0;
				regs[31] = new ScalarValue(Std.string(link), [], null, 0, link);
			}
			// The predicate is a value captured BEFORE the slot overwrites any operands.
			if (b.delaySlot != null && !graph.lift(b.delaySlot, regs, true)) return null;
			if (call != null) {
				final cost = call.lift(graph, regs); if (cost == null) return null;
				callCosts.push(cost);
			}
			state.memory = graph.memoryFacts();
			final cost = b.cycles | (b.instructions.length << 10) | (1 << 20);
			accounting.add(state.reach, cost);
			if (b.successors.length == 0) exits.push(state);
			for (a in b.successors) {
				var reach = state.reach;
				if (branch != null && b.successors.length == 2) {
					final p = a == b.transfer.decoded.target ? branch : predicates.negate(branch);
					reach = predicates.both(reach, p);
				}
				if (reach == predicates.no) continue;
				if (!incoming.exists(a)) incoming.set(a, []);
				incoming.get(a).push({reach:reach, regs:regs, memory:state.memory});
			}
		}
		if (exits.length == 0) return null;
		final output = merge(exits).regs;
		if (!output[31].equivalent(graph.initial[31])) return null;
		var cost = accounting.finish();
		for (part in callCosts) {
			if (cost.addressBase == 0 && part.addressBase == 0) {
				final packed = (cost.addressOffset + part.addressOffset) | 0;
				cost = new ScalarValue(Std.string(packed), [], null, 0, packed);
			} else cost = graph.make('(${cost.ref} + ${part.ref}) | 0', [cost, part]);
		}
		return ScalarPlan.fromGraph(fn, graph, output, ir.blocks[0], required, suffix, cost,
			{cycles:totalCycles, instructions:totalInstructions, blocks:totalBlocks, calls:hasCalls});
	}
}

private typedef ScalarEdge = {reach:ScalarValue, regs:Array<ScalarValue>, memory:ScalarMemoryValues};
