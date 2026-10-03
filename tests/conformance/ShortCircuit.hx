/** Inlined argument bindings must stay on the guarded side of && and ||. */
class ShortCircuit {
	static var reads = 0;
	static var order = 0;
	static var flag = false;
	static function probe(value:Int):Int {
		reads++;
		order = ((order << 4) | value) | 0;
		return value;
	}
	static function lhs(value:Bool):Bool {
		order = ((order << 4) | 1) | 0;
		return value;
	}
	static inline function twice(value:Int):Bool return value + value == 4;
	static function testAnd(value:Bool):Bool return lhs(value) && twice(probe(2));
	static function testOr(value:Bool):Bool return lhs(value) || twice(probe(2));
	static function assignAnd(value:Bool):Bool return lhs(value) && (flag = true);
	static function assignOr(value:Bool):Bool return lhs(value) || (flag = true);
	static function branch(value:Bool):Bool return lhs(value) && (flag ? twice(probe(2)) : twice(probe(3)));
	static function reset():Void { reads = 0; order = 0; }
	public static function main():Void {
		for (value in [false, true]) {
			reset();
			Conf.expect("and value", testAnd(value) ? 1 : 0, value ? 1 : 0);
			Conf.expect("and conditional read", reads, value ? 1 : 0);
			Conf.expect("and evaluation order", order, value ? 0x12 : 1);
			reset();
			Conf.expect("or value", testOr(value) ? 1 : 0, 1);
			Conf.expect("or conditional read", reads, value ? 0 : 1);
			Conf.expect("or evaluation order", order, value ? 1 : 0x12);
			reset(); flag = value;
			var count = 0;
			while (flag && twice(probe(2))) { count++; flag = false; }
			Conf.expect("while body", count, value ? 1 : 0);
			Conf.expect("while conditional read", reads, value ? 1 : 0);
			reset(); flag = value;
			final nested = lhs(value) || (twice(probe(2)) && twice(probe(3)));
			Conf.expect("nested value", nested ? 1 : 0, value ? 1 : 0);
			Conf.expect("nested conditional reads", reads, value ? 0 : 2);
			Conf.expect("nested evaluation order", order, value ? 1 : 0x123);
			reset(); flag = false;
			Conf.expect("and assignment value", assignAnd(value) ? 1 : 0, value ? 1 : 0);
			Conf.expect("and conditional assignment", flag ? 1 : 0, value ? 1 : 0);
			Conf.expect("and assignment lhs once", order, 1);
			reset(); flag = false;
			Conf.expect("or assignment value", assignOr(value) ? 1 : 0, 1);
			Conf.expect("or conditional assignment", flag ? 1 : 0, value ? 0 : 1);
			Conf.expect("or assignment lhs once", order, 1);
			for (choice in [false, true]) {
				reset(); flag = choice;
				Conf.expect("conditional rhs value", branch(value) ? 1 : 0, value && choice ? 1 : 0);
				Conf.expect("conditional rhs reads", reads, value ? 1 : 0);
				Conf.expect("conditional rhs order", order, value ? (choice ? 0x12 : 0x13) : 1);
			}
			reset(); flag = value; count = 0;
			do { count++; } while (flag && twice(probe(3)));
			Conf.expect("do while body", count, 1);
			Conf.expect("do while conditional read", reads, value ? 1 : 0);
		}
		reset();
		final both = twice(probe(2)) && twice(probe(3));
		Conf.expect("both inlined value", both ? 1 : 0, 0);
		Conf.expect("both inlined reads", reads, 2);
		Conf.expect("both inlined order", order, 0x23);
		Conf.report("ShortCircuit");
	}
}
