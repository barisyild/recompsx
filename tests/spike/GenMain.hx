import core.CpuState;
import core.Runtime;

/**
	Entry point for the scale spike: link a whole recompiled program and report what it weighs.

	It does not run the game — the runtime has no GPU, no kernel and no disc yet. What it proves
	is the thing M1.5 exists to answer: that ~90,000 lines of machine-written Haxe compile, in
	what time, to what size. Those numbers decide whether the shard layout needs changing before
	the emitter is built out further, and whether a console with 32 MB of RAM is still in reach.
**/
class GenMain {
	public static function main():Void {
		final ctx = new CpuState();
		Runtime.bindDispatch(FnTable.call);
		Runtime.boot(ctx);

		// The image the recompiler was built from. Without it every load returns zero, so the
		// game runs on empty memory and its kernel arguments are meaningless.
		if (shim.Backend.argCount() >= 1) {
			kernel.ExeLoader.load(shim.Backend.arg(0), GameInfo.LOAD_ADDR, GameInfo.LOAD_SIZE);
		} else {
			shim.Backend.log(shim.Backend.LOG_WARN,
				"no image path given — running on empty memory, values read from RAM are not real");
		}

		ctx.pc = GameInfo.ENTRY_POINT;
		ctx.gp = GameInfo.INITIAL_GP;
		ctx.sp = GameInfo.INITIAL_SP;

		shim.Backend.log(shim.Backend.LOG_INFO,
			"recompiled program linked: " + GameInfo.FUNCTIONS + " functions in "
			+ GameInfo.SHARDS + " shards, entry " + hex(GameInfo.ENTRY_POINT));

		// Dispatch to the entry point purely to prove the table resolves. The runtime is not
		// complete enough to let it get far, and the unimplemented-call report is the output.
		if (!FnTable.call(GameInfo.ENTRY_POINT, ctx)) {
			shim.Backend.log(shim.Backend.LOG_ERROR, "entry point is not in the table");
		}
		shim.Backend.log(shim.Backend.LOG_INFO,
			"distinct unimplemented things reached: " + Runtime.reportedGaps);
	}

	static function hex(v:Int):String {
		final d = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += d.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
