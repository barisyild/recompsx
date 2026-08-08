/**
	Does reflaxe.CPP support a default argument?

	It decides how `longjmp` can work. Unwinding has to resume in the *middle* of the function
	that called `setjmp` — at the block holding the saved return address — and the cheapest way to
	express that is an optional entry-block parameter on every generated function. If defaults do
	not survive, every one of the 861 functions grows a second parameter at every call site
	instead, which is a much larger change to make on a guess.
**/
class DefArg {
	static var log = 0;

	static function body(ctx:Ctx, bb:Int = 0):Void {
		var b = bb;
		while (true) switch (b) {
			case 0: ctx.v = (ctx.v + 1) | 0; b = 1; continue;
			case 1: ctx.v = (ctx.v + 10) | 0; b = 2; continue;
			case 2: ctx.v = (ctx.v + 100) | 0; return;
			default: return;
		}
	}

	public static function main():Void {
		final a = new Ctx();
		body(a);            // from the top
		final b = new Ctx();
		body(b, 1);         // resumed part-way, which is what longjmp needs
		shim.Backend.log(shim.Backend.LOG_INFO, "fromStart=" + a.v + " resumed=" + b.v);
	}
}

class Ctx {
	public var v = 0;
	public function new() {}
}
