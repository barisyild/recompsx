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
		TestSystemCnf.run();
		TestDecoder.run();
		TestDiscovery.run();
		TestOverlay.run();
		TestMods.run();
		TestRelocatable.run();
		TestFunctionSummary.run();
		TestRegisterRanges.run();
		TestRangeCodegen.run();
		TestScalarCfg.run();
		TestScalarPredicates.run();
		TestScalarResults.run();
		TestScalarEffects.run();
		TestScalarMemoryCfg.run();
		TestValueRegions.run();
		TestValueCfg.run();
		TestScalarCalls.run();
		TestScalarCompose.run();
		TestScalarPointers.run();
		TestCallAliases.run();
		TestScalarBorrow.run();
		TestScalarPool.run();
		TestProjectionShare.run();
		TestScalarCop.run();
		TestHandOver.run();
		TestCodegen.run();
		Sys.exit(Assert.summary());
	}
}
