package;

@:include("stub2.h") @:topLevel extern function s_argc():Int;
@:include("stub2.h") @:topLevel extern function s_arg(i:Int):cxx.ConstCharPtr;

class Main {
	public static function main():Void {
		final n = s_argc();

		// P1: condition is a CALL, body is a constant assignment
		var p1 = 0; var i = 0;
		while (i < n) {
			if (s_arg(i).toString() == "--flag") { p1 = 1; }
			i++;
		}
		trace("P1 call-in-cond = " + p1);

		// P2: condition uses a LOCAL bound first, body constant
		var p2 = 0; i = 0;
		while (i < n) {
			final a = s_arg(i).toString();
			if (a == "--flag") { p2 = 1; }
			i++;
		}
		trace("P2 local-in-cond = " + p2);

		// P3: local in cond, body is a TERNARY
		var p3 = 0; i = 0;
		while (i < n) {
			final a = s_arg(i).toString();
			if (a == "--flag") { p3 = (i + 1 < n) ? 7 : 0; }
			i++;
		}
		trace("P3 ternary-body = " + p3);

		// P4: pure ints, condition is a call
		var p4 = 0; i = 0;
		while (i < n) {
			if (s_argc() > i) { p4 = 1; }
			i++;
		}
		trace("P4 int call-in-cond = " + p4);
	}
}
