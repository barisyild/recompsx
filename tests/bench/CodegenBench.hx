import core.CpuState;

/** Same MIPS xorshift loop through both emitters; run each mode in a fresh process. */
class CodegenBench {
	public static function main():Void {
		final ctx = new CpuState();
		ctx.nextEvent = 0x7fffffff;
		final optimized = shim.Backend.argCount() > 0 && shim.Backend.arg(0) == "optimized";
		var n = 0;
		while (n < 5) {
			ctx.a0 = 10000000;
			ctx.v0 = 0x12345678;
			if (optimized) CodegenOptimized.mixLoop(ctx);
			else CodegenReference.mixLoop(ctx);
			n++;
		}
		shim.Backend.log(shim.Backend.LOG_INFO, "result=" + ctx.v0 + " cycles=" + ctx.cycles);
	}
}
