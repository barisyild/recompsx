/**
	Does reflaxe.CPP pass a static function to a native splice as its plain C++ name?

	A generated dispatch that keeps a function's address beside `FnTable`'s answer for it — a kept
	dynamic call as a load and a call instead of two dispatch switches — needs the address of the
	C++ static member a Haxe static function compiles to, taken at the splice (`&{arg0}`). That
	works only if the function arrives there as its name, not wrapped in a `std::function` or a
	lambda. (Built and measured on the Dreamcast 2026-09-29, then shelved: PROGRESS.md.) Two more
	facts from that work: a Haxe variable or return value of type `cxx.VoidPtr` compiles to
	`void**`, so an address must stay inside the splices; and an `@:include` on an extern class
	reaches no file that only splices its methods, so each such method carries its own. Three calls through a table of two such addresses must add up to
	127, with the entry block passed through. The table's header is included by the methods that
	use it: an include on the extern class itself reaches no file that only splices its methods.
**/
@:unsafePtrType
class Ctx {
	public var v = 0;

	public function new() {}
}

class Targets {
	public static function a(ctx:Ctx, entry:Int = 0):Void {
		ctx.v = (ctx.v + 1 + entry) | 0;
	}

	public static function b(ctx:Ctx, entry:Int = 0):Void {
		ctx.v = (ctx.v + 100 + entry) | 0;
	}
}

extern class FnPtr {
	@:nativeFunctionCode("((void*)(&{arg0}))")
	public static function of(f:(Ctx, Int) -> Void):cxx.VoidPtr;

	@:include("fnptr_table.h", true)
	@:nativeFunctionCode("(fnptr_table[({arg0})] = ({arg1}))")
	public static function keep(i:Int, p:cxx.VoidPtr):Void;

	@:include("fnptr_table.h", true)
	@:nativeFunctionCode("((void(*)(Ctx*, int))(fnptr_table[({arg0})]))(({arg1}), ({arg2}))")
	public static function call(i:Int, ctx:Ctx, entry:Int):Void;
}

class Main {
	public static function main():Void {
		final ctx = new Ctx();
		FnPtr.keep(0, FnPtr.of(Targets.a));
		FnPtr.keep(1, FnPtr.of(Targets.b));
		FnPtr.call(0, ctx, 0);
		FnPtr.call(1, ctx, 5);
		FnPtr.call(0, ctx, 20);
		trace("v=" + ctx.v);
	}
}
