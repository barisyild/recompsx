/**
	The same shape that reflaxe.CPP miscompiles, with no externs and no C++ involved:
	an `if` inside a `while` whose body assigns to the loop-condition variable.

	Expected result: w3 = 99. If a target prints 0, that target dropped the branch.
**/
class Plain {
	static function argc():Int return 3;

	public static function main():Void {
		var w3 = 0;
		var i = 0;
		final n = argc();
		while (i < n) {
			if (i == 0 && i + 1 < n) { w3 = 99; i++; }
			i++;
		}
		trace("w3 = " + w3 + " (expected 99)");
	}
}
