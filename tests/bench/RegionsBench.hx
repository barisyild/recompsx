import core.CpuState;

/** Same registers and safe points; only region structuring differs between these two modes. */
class RegionsBench {
	public static function main():Void {
		final ctx = new CpuState();
		ctx.nextEvent = 0x7fffffff;
		final regions = shim.Backend.argCount() > 0 && shim.Backend.arg(0) == 'regions';
		var run = 0;
		while (run < 5) {
			ctx.a0 = 5000000;
			ctx.v1 = 0; ctx.a2 = 0; ctx.a3 = 0;
			if (regions) RegionsOptimized.diamondLoop(ctx);
			else RegionsScalar.diamondLoop(ctx);
			run++;
		}
		shim.Backend.log(shim.Backend.LOG_INFO,
			'result=' + ctx.v0 + ' slots=' + ctx.v1 + ' cycles=' + ctx.cycles);
	}
}
