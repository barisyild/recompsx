/**
	A test harness small enough to not need explaining.

	The recompiler tool runs on `haxe --interp`, where the full language is available and there is
	no second target to compare against — so unlike `tests/conformance`, these are ordinary
	assertions. What they check is mostly *golden data*: a raw instruction word and the text it
	must produce, a header and the fields it must yield. Golden tests suit a disassembler
	unusually well, because the encoding is fixed by hardware and any change to the expected text
	is a change a reviewer should see in the diff.
**/
class Assert {
	public static var checks = 0;
	public static var failures = 0;
	static var currentGroup = "";

	public static function group(name:String):Void {
		currentGroup = name;
		Sys.println("  " + name);
	}

	public static function equals<T>(actual:T, expected:T, ?what:String):Void {
		checks++;
		if (actual != expected) {
			failures++;
			Sys.println('    FAIL ${what == null ? "" : what}');
			Sys.println('      expected: $expected');
			Sys.println('      actual:   $actual');
		}
	}

	public static function isTrue(cond:Bool, what:String):Void {
		checks++;
		if (!cond) {
			failures++;
			Sys.println('    FAIL $what');
		}
	}

	/** Asserts that `f` rejects its input, and that the complaint mentions `expectFragment` —
	    because an error message nobody can act on is barely better than no error at all. */
	public static function rejects(f:Void->Void, expectFragment:String, what:String):Void {
		checks++;
		try {
			f();
			failures++;
			Sys.println('    FAIL $what: expected a rejection, none happened');
		} catch (e:Dynamic) {
			final msg = Std.string(e);
			if (msg.indexOf(expectFragment) < 0) {
				failures++;
				Sys.println('    FAIL $what: message did not mention "$expectFragment"');
				Sys.println('      message: $msg');
			}
		}
	}

	public static function summary():Int {
		Sys.println("");
		if (failures == 0) {
			Sys.println('all ${checks} checks passed');
			return 0;
		}
		Sys.println('${failures} of ${checks} checks FAILED');
		return 1;
	}
}
