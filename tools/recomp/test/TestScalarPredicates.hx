import recomp.codegen.ScalarGraph;
import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.codegen.ScalarPredicates;
import recomp.codegen.ScalarAccounting;
import recomp.mips.Op;

@:access(recomp.codegen.ScalarPredicates)
class TestScalarPredicates {
	/** All eight assignments of three independent Boolean inputs, evaluated independently
	    of the algebra's rewrite rules. Masks are truth tables, not sampled branch outcomes. */
	static function truth(p:ScalarPredicates, value:ScalarValue, inputs:Map<String, Int>):Int {
		if (value == p.yes) return 255;
		if (value == p.no) return 0;
		final node = p.nodes.get(value.ref);
		if (node == null) return inputs.get(value.ref);
		final a = truth(p, node.a, inputs);
		return switch(node.kind) {
			case 0: a ^ 255;
			case 1: a & truth(p, node.b, inputs);
			case _: a | truth(p, node.b, inputs);
		};
	}
	public static function run():Void {
		Assert.group('scalar predicates: truth tables, SSA identity and packed costs');
		final graph = new ScalarGraph(); final p = new ScalarPredicates(graph);
		final a = p.atom('a', []); final b = p.atom('b', []); final c = p.atom('c', []);
		final inputs = [a.ref => 0xaa, b.ref => 0xcc, c.ref => 0xf0];
		var forms = [{v:a, bits:0xaa}, {v:b, bits:0xcc}, {v:c, bits:0xf0}, {v:p.yes, bits:255}, {v:p.no, bits:0}];
		for (f in forms.copy()) forms.push({v:p.negate(f.v), bits:f.bits ^ 255});
		for (_ in 0...2) {
			final before = forms.copy(); final seen:Map<String, Bool> = [];
			for (f in forms) seen.set(f.v.ref, true);
			for (x in before) for (y in before) {
				for (f in [{v:p.both(x.v, y.v), bits:x.bits & y.bits}, {v:p.either(x.v, y.v), bits:x.bits | y.bits}]) {
					Assert.equals(truth(p, f.v, inputs), f.bits, 'Boolean rewrite preserves complete truth table');
					if (forms.length < 64 && !seen.exists(f.v.ref)) { seen.set(f.v.ref, true); forms.push(f); }
				}
			}
		}
		Assert.isTrue(p.either(a, p.negate(a)) == p.yes, 'complementary paths reach their join');
		Assert.isTrue(p.either(p.both(a, b), p.both(a, p.negate(b))) == a, 'nested paths recover parent reach');
		Assert.isTrue(p.both(p.both(a, b), p.both(a, p.negate(b))) == p.no, 'nested arms are disjoint');
		Assert.isTrue(p.either(a, p.both(a, b)) == a, 'absorption');
		final eq = p.branch(Op.BEQ, graph.initial[4], graph.initial[5]);
		Assert.isTrue(eq == p.branch(Op.BEQ, graph.initial[5], graph.initial[4]), 'equal comparisons commute');
		Assert.isTrue(p.branch(Op.BNE, graph.initial[4], graph.initial[5]) == p.negate(eq), 'BNE shares BEQ capture');
		final oldRead = graph.make('read0', []); final newRead = graph.make('read1', []);
		Assert.isTrue(p.branch(Op.BEQ, oldRead, graph.initial[0]) != p.branch(Op.BEQ, newRead, graph.initial[0]), 'different memory versions never share comparisons');
		for (op in [Op.BEQ, Op.BNE, Op.BLEZ, Op.BGTZ, Op.BLTZ, Op.BGEZ])
			for (x in [0, 1, -1, 0x80000000, 0x7fffffff]) {
				final value = new ScalarValue(Std.string(x), [], null, 0, x);
				final expected = switch(op) { case BEQ: x == 0; case BNE: x != 0; case BLEZ: x <= 0; case BGTZ: x > 0; case BLTZ: x < 0; case _: x >= 0; };
				Assert.isTrue(p.branch(op, value, graph.initial[0]) == (expected ? p.yes : p.no), 'constant signed branch');
			}
		final costs = new ScalarAccounting(graph, p); final cost = 5 | (3 << 10) | (1 << 20);
		costs.add(p.yes, 7); costs.add(a, cost); costs.add(p.negate(a), cost);
		Assert.equals(costs.finish().ref, Std.string(cost + 7), 'equal complementary charges become constant');
		final nested = new ScalarAccounting(graph, p);
		nested.add(p.both(a, b), cost); nested.add(p.both(a, p.negate(b)), cost);
		final total = nested.finish();
		Assert.equals(total.args.length, 1, 'factored nested charge needs one predicate');
		Assert.isTrue(total.args[0] == a, 'inner condition removed from accounting');
	}
}
