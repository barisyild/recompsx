package recomp.codegen;

import recomp.codegen.ScalarGraph.ScalarValue;

/** Sum original packed block costs by reach predicate, not by emitted statement. The CFG
    bounds each lane before this runs. Integer addition therefore preserves all three lanes. */
class ScalarAccounting {
	final predicates:ScalarPredicates;
	final graph:ScalarGraph;
	final terms:Map<String, {p:ScalarValue, cost:Int}> = [];
	var constant = 0;
	public function new(graph:ScalarGraph, predicates:ScalarPredicates) { this.graph = graph; this.predicates = predicates; }
	public function add(p:ScalarValue, cost:Int):Void {
		if (p == predicates.no) return;
		if (p == predicates.yes) { constant += cost; return; }
		final previous = terms.get(p.ref);
		if (previous == null) terms.set(p.ref, {p:p, cost:cost});
		else previous.cost += cost;
	}
	public function finish():ScalarValue {
		// Equal-cost disjoint paths can share one charge under their union. Restrict this
		// reduction to cases proved by Boolean algebra, never inferred from address order.
		var changed = true;
		while (changed) {
			changed = false;
			final keys = [for (key in terms.keys()) key]; keys.sort(Reflect.compare);
			for (i in 0...keys.length) {
				for (j in i + 1...keys.length) {
					final a = terms.get(keys[i]); final b = terms.get(keys[j]);
					if (a.cost != b.cost || predicates.both(a.p, b.p) != predicates.no) continue;
					terms.remove(keys[i]); terms.remove(keys[j]);
					add(predicates.either(a.p, b.p), a.cost); changed = true; break;
				}
				if (changed) break;
			}
		}
		final keys = [for (key in terms.keys()) key]; keys.sort(Reflect.compare);
		final used:Map<String, Bool> = [];
		final values:Array<ScalarValue> = [];
		for (key in keys) {
			if (used.exists(key)) continue;
			final a = terms.get(key); used.set(key, true);
			var other = 0;
			for (candidate in keys) if (!used.exists(candidate) && predicates.opposite(a.p, terms.get(candidate).p)) {
				other = terms.get(candidate).cost; used.set(candidate, true); break;
			}
			values.push(graph.make('${a.p.ref} ? ${a.cost} : $other', [a.p]));
		}
		var sum:Null<ScalarValue> = constant == 0 ? null : new ScalarValue(Std.string(constant), [], null, 0, constant);
		for (value in values) sum = sum == null ? value : graph.make('(${sum.ref} + ${value.ref}) | 0', [sum, value]);
		return sum == null ? graph.initial[0] : sum;
	}
}
