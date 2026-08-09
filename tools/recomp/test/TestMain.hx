/**
	Runs the recompiler tool's own tests.

	These run on `haxe --interp` because the tool does: it has no target constraints and no second
	implementation to compare against. Cross-target testing lives in `tests/conformance/` and
	covers the runtime, whose code must behave identically everywhere.
**/
class TestMain {
	public static function main():Void {
		Sys.println("recompsx tool tests");
		Sys.println("");
		TestPsxExe.run();
		TestDecoder.run();
		TestDiscovery.run();
		TestOverlay.run();
		Sys.exit(Assert.summary());
	}
}
