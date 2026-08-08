/**
	Guard clauses: `if (cond) { ...; return; }` in a Void function.
	Expected output: "guarded" only, then nothing else.
**/
class Guard {
	static var log = "";

	static function withGuard(x:Int):Void {
		if (x > 0) {
			log += "guarded;";
			return;
		}
		log += "fellthrough;";
	}

	static function withElse(x:Int):Void {
		if (x > 0) log += "guarded;";
		else log += "fellthrough;";
	}

	public static function main():Void {
		log = ""; withGuard(1); trace('early-return guard: "$log" (expected "guarded;")');
		log = ""; withElse(1);  trace('if/else instead:    "$log" (expected "guarded;")');
	}
}
