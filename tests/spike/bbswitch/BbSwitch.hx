/**
	Do the statements inside a switch case survive to C++?

	This is the shape of every recompiled function: a basic-block state machine, `while(true)
	switch(bb)`, whose cases assign to fields of a context object and then move to the next block.
	Haxe has no `goto`, so there is no other way to express a control-flow graph, which makes this
	shape non-negotiable rather than a style choice.

	In the whole-game C++ build, 1119 of shard 4's 1296 case blocks compiled to a bare `break;` —
	the assignments gone — while JavaScript kept them. This reduces that to something a compiler
	maintainer can run in a second.
**/
class BbSwitch {
	public static function run(ctx:Ctx):Void {
		var bb = 0;
		while (true) switch (bb) {
			case 0:
				ctx.a = 0x80070000;
				ctx.a = (ctx.a + -5648) | 0;
				bb = 1; continue;
			case 1:
				ctx.b = 0x80080000;
				ctx.b = (ctx.b + -29552) | 0;
				bb = 2; continue;
			case 2:
				ctx.c = (ctx.a + ctx.b) | 0;
				bb = 3; continue;
			// A case whose work is only reachable through a later block, so nothing here can be
			// folded away by looking at this block alone.
			case 3:
				ctx.d = (ctx.c ^ 0x5A5A5A5A) | 0;
				bb = 4; continue;
			default:
				return;
		}
	}

	public static function main():Void {
		final ctx = new Ctx();
		run(ctx);
		shim.Backend.log(shim.Backend.LOG_INFO,
			"a=" + ctx.a + " b=" + ctx.b + " c=" + ctx.c + " d=" + ctx.d);
	}
}

class Ctx {
	public var a = 0;
	public var b = 0;
	public var c = 0;
	public var d = 0;
	public function new() {}
}
