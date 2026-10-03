package recomp.codegen;

import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.mips.Op;

/** Build-time Boolean algebra over immutable SSA comparisons. Interning never equates two
    reads by guest address: their distinct value references remain distinct operands. */
class ScalarPredicates {
	public final yes = new ScalarValue('true', []);
	public final no = new ScalarValue('false', []);
	final graph:ScalarGraph;
	final expressions:Map<String, ScalarValue> = [];
	final nodes:Map<String, PredicateNode> = [];
	final choices:Map<String, {p:ScalarValue, a:ScalarValue, b:ScalarValue}> = [];
	public function new(graph:ScalarGraph) { this.graph = graph; }
	public function atom(expr:String, args:Array<ScalarValue>):ScalarValue {
		if (!expressions.exists(expr)) expressions.set(expr, graph.make(expr, args));
		return expressions.get(expr);
	}
	public function negate(a:ScalarValue):ScalarValue {
		if (a == yes) return no;
		if (a == no) return yes;
		final node = nodes.get(a.ref);
		if (node != null && node.kind == 0) return node.a;
		final value = atom('!${a.ref}', [a]);
		nodes.set(value.ref, {kind:0, a:a, b:a});
		return value;
	}
	public function opposite(a:ScalarValue, b:ScalarValue):Bool {
		final x = nodes.get(a.ref); final y = nodes.get(b.ref);
		return (a == yes && b == no) || (a == no && b == yes)
			|| (x != null && x.kind == 0 && x.a == b) || (y != null && y.kind == 0 && y.a == a);
	}
	public function both(a:ScalarValue, b:ScalarValue):ScalarValue return combine(a, b, 1);
	public function either(a:ScalarValue, b:ScalarValue):ScalarValue return combine(a, b, 2);
	function contains(value:ScalarValue, term:ScalarValue, kind:Int):Bool {
		if (value == term) return true;
		final node = nodes.get(value.ref);
		return node != null && node.kind == kind && (contains(node.a, term, kind) || contains(node.b, term, kind));
	}
	function contradiction(a:ScalarValue, b:ScalarValue, kind:Int):Bool {
		if (opposite(a, b)) return true;
		final x = nodes.get(a.ref); final y = nodes.get(b.ref);
		if (x != null && x.kind == kind) return contradiction(x.a, b, kind) || contradiction(x.b, b, kind);
		return y != null && y.kind == kind && (contradiction(a, y.a, kind) || contradiction(a, y.b, kind));
	}
	function combine(a:ScalarValue, b:ScalarValue, kind:Int):ScalarValue {
		final identity = kind == 1 ? yes : no;
		final absorbing = kind == 1 ? no : yes;
		if (a == absorbing || b == absorbing || contradiction(a, b, kind)) return absorbing;
		if (a == identity || a == b) return b;
		if (b == identity) return a;
		final x = nodes.get(a.ref); final y = nodes.get(b.ref);
		final other = 3 - kind;
		if (contains(a, b, kind)) return a;
		if (contains(b, a, kind)) return b;
		// Absorption: p OR (p AND q), and its dual.
		if (contains(a, b, other)) return b;
		if (contains(b, a, other)) return a;
		// Factor the shared incoming reach predicate at a join. In particular,
		// (reach AND p) OR (reach AND !p) reduces to reach, including nested diamonds.
		if (x != null && y != null && x.kind == other && y.kind == other) {
			if (x.a == y.a) return combine(x.a, combine(x.b, y.b, kind), other);
			if (x.a == y.b) return combine(x.a, combine(x.b, y.a, kind), other);
			if (x.b == y.a) return combine(x.b, combine(x.a, y.b, kind), other);
			if (x.b == y.b) return combine(x.b, combine(x.a, y.a, kind), other);
		}
		// Operand order is irrelevant for already captured pure Boolean values.
		if (a.ref > b.ref) { final swap = a; a = b; b = swap; }
		final value = atom('${a.ref} ${kind == 1 ? "&&" : "||"} ${b.ref}', [a, b]);
		nodes.set(value.ref, {kind:kind, a:a, b:b});
		return value;
	}
	public function branch(op:Op, a:ScalarValue, b:ScalarValue):ScalarValue {
		if (op == Op.BEQ || op == Op.BNE) {
			var eq:ScalarValue;
			if (a.equivalent(b)) eq = yes;
			else if (a.addressBase == 0 && b.addressBase == 0) eq = no;
			else {
				if (a.ref > b.ref) { final swap = a; a = b; b = swap; }
				eq = atom('${a.ref} == ${b.ref}', [a, b]);
			}
			return op == Op.BEQ ? eq : negate(eq);
		}
		final less = op == Op.BLTZ || op == Op.BGEZ;
		final p = a.addressBase == 0 ? ((less ? a.addressOffset < 0 : a.addressOffset > 0) ? yes : no)
			: atom('${a.ref} ${less ? "<" : ">"} 0', [a]);
		return op == Op.BGEZ || op == Op.BLEZ ? negate(p) : p;
	}
	public function select(p:ScalarValue, a:ScalarValue, b:ScalarValue):ScalarValue {
		if (p == yes || a.equivalent(b)) return a;
		if (p == no) return b;
		// Selecting a previous phi under the same predicate needs only that phi's chosen
		// value. This does not move memory operations; their SSA definitions stay ordered.
		final x = choices.get(a.ref); final y = choices.get(b.ref);
		if (x != null) {
			if (x.p == p) a = x.a;
			else if (opposite(x.p, p)) a = x.b;
		}
		if (y != null) {
			if (y.p == p) b = y.b;
			else if (opposite(y.p, p)) b = y.a;
		}
		if (a.equivalent(b)) return a;
		final value = atom('${p.ref} ? ${a.ref} : ${b.ref}', [p, a, b]);
		choices.set(value.ref, {p:p, a:a, b:b});
		return value;
	}
}

private typedef PredicateNode = {kind:Int, a:ScalarValue, b:ScalarValue};
