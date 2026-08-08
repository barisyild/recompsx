package;

class Main {
	static var log = "";
	static function mark(s:String):Void log += s;

	// 1 statement in the body
	static function one(x:Int):Void {
		if (x > 0) { mark("A"); }
	}
	// 2 statements
	static function two(x:Int):Void {
		if (x > 0) { mark("B1"); mark("B2"); }
	}
	// 3 statements
	static function three(x:Int):Void {
		if (x > 0) { mark("C1"); mark("C2"); mark("C3"); }
	}
	// 2 statements, with else
	static function twoElse(x:Int):Void {
		if (x > 0) { mark("D1"); mark("D2"); } else { mark("Dx"); }
	}
	// 2 statements, condition is a plain bool local
	static function twoLocalCond(x:Int):Void {
		final c = x > 0;
		if (c) { mark("E1"); mark("E2"); }
	}
	// 2 statements, no braces needed elsewhere: sequential ifs
	static function twoSeq(x:Int):Void {
		if (x > 0) mark("F1");
		if (x > 0) mark("F2");
	}

	// Candidate workarounds
	static function emptyElse(x:Int):Void {
		if (x > 0) { mark("G1"); mark("G2"); } else {}
	}
	static function extracted(x:Int):Void {
		if (x > 0) both();
	}
	static function both():Void { mark("H1"); mark("H2"); }
	static function negatedGuard(x:Int):Void {
		// The shape a guard clause becomes when inverted into if/else
		if (x <= 0) {} else { mark("I1"); mark("I2"); }
	}

	public static function main():Void {
		log = ""; one(1);           trace('1 stmt        : "$log" expect "A"');
		log = ""; two(1);           trace('2 stmts       : "$log" expect "B1B2"');
		log = ""; three(1);         trace('3 stmts       : "$log" expect "C1C2C3"');
		log = ""; twoElse(1);       trace('2 stmts + else: "$log" expect "D1D2"');
		log = ""; twoLocalCond(1);  trace('2 stmts, local: "$log" expect "E1E2"');
		log = ""; twoSeq(1);        trace('two ifs       : "$log" expect "F1F2"');
		log = ""; emptyElse(1);     trace('empty else    : "$log" expect "G1G2"');
		log = ""; extracted(1);     trace('extracted call: "$log" expect "H1H2"');
		log = ""; negatedGuard(1);  trace('inverted guard: "$log" expect "I1I2"');
	}
}
