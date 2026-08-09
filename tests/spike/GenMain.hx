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
		// Which windows this game loads code into. After boot, because it fills in state the
		// runtime clears on the way up.
		Overlays.register();

		// The image the recompiler was built from. Without it every load returns zero, so the
		// game runs on empty memory and its kernel arguments are meaningless.
		if (shim.Backend.argCount() >= 1) {
			kernel.ExeLoader.load(shim.Backend.arg(0), GameInfo.LOAD_ADDR, GameInfo.LOAD_SIZE);
		} else {
			shim.Backend.log(shim.Backend.LOG_WARN,
				"no image path given — running on empty memory, values read from RAM are not real");
		}

		// The disc, if one was named. Either shape: a BIN/CUE or ISO image, or a directory of
		// files already extracted from one. The image is tried first because it is the stricter
		// test — it either has a volume descriptor or it does not.
		if (shim.Backend.argCount() >= 2) mountDisc(shim.Backend.arg(1));
		else {}

		ctx.pc = GameInfo.ENTRY_POINT;
		ctx.gp = GameInfo.INITIAL_GP;
		ctx.sp = GameInfo.INITIAL_SP;

		shim.Backend.log(shim.Backend.LOG_INFO,
			"recompiled program linked: " + GameInfo.FUNCTIONS + " functions in "
			+ GameInfo.SHARDS + " shards, entry " + hex(GameInfo.ENTRY_POINT));

		// Dispatch to the entry point purely to prove the table resolves. The runtime is not
		// complete enough to let it get far, and the unimplemented-call report is the output.
		// The game's main loop never returns, so the frame that proves rendering works has to be
		// taken from inside it. kernel.Kernel's heartbeat asks for this once the game has drawn.
		kernel.Kernel.vramDump = true;
		kernel.Kernel.reportOps = true;
		Runtime.callAndResume(ctx, GameInfo.ENTRY_POINT);
		if (false) {
			shim.Backend.log(shim.Backend.LOG_ERROR, "entry point is not in the table");
		}
		// What the machine actually did, not just what it could not do. Every one of these is
		// deterministic, so two runs — or two targets — that disagree here have diverged.
		shim.Backend.log(shim.Backend.LOG_INFO,
			"frames " + kernel.Kernel.vblankCount
			+ " | events fired " + core.Scheduler.fired
			+ " | irqs delivered " + core.Irq.delivered
			+ " | handler calls " + kernel.KHandlers.calls
			+ " | kernel events delivered " + kernel.KEvents.delivered
			+ " (" + kernel.KEvents.callbacks + " callbacks)"
			+ " | gpu words " + gpu.Gpu.wordsReceived + "/" + gpu.Gpu.commandsReceived + "cmd"
			+ " | cycles " + ctx.cycles);
		shim.Backend.log(shim.Backend.LOG_INFO,
			"distinct unimplemented things reached: " + Runtime.reportedGaps);
	}

	static function mountDisc(path:String):Void {
		if (!kernel.KFiles.mountImage(path)) kernel.KFiles.mountDirectory(path);
		else {}
	}

	static function hex(v:Int):String {
		final d = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += d.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
