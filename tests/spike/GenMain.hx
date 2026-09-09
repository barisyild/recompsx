import core.CpuState;
import core.Runtime;

/** Shared launcher for generated games: synchronous or cooperatively sliced from the same Haxe. */
class GenMain {
	#if recompsx_cooperative
	static var running:CpuState;
	static function step():Bool {
		final more = core.Cooperative.step(running, GameInfo.ENTRY_POINT, core.TimeBase.cyclesPerFrame() >> 2);
		if (!more) report(running);
		else {}
		return more;
	}
	#end

	public static function main():Void {
		final ctx = new CpuState();
		Runtime.bindDispatch(FnTable.call);
		Runtime.boot(ctx);
		FnTable.init();
		Overlays.init();
		#if recompsx_cooperative
		core.Cooperative.bind(FnTable.dispatch);
		#end
		kernel.Kernel.haltAt = headlessFrames();
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

		// Hardware drawing, if this host asked for it and its backend can actually do it. Both
		// halves are required: the flag alone is a wish, and the capability alone is a facility
		// nobody asked to use. Headless digests always use the deterministic software renderer.
		if (kernel.Kernel.haltAt == 0 && videoHw()) {
			if (shim.Backend.caps(4) != 0) {
				gpu.Gpu.hw = true;
				shim.Backend.gpuVram(gpu.Vram.data);
				shim.Backend.log(shim.Backend.LOG_INFO, "video: primitives go to the backend");
			} else {
				shim.Backend.log(shim.Backend.LOG_WARN,
					"--video-hw asked for, but this backend has no rasteriser — drawing in software");
			}
		} else {}

		ctx.pc = GameInfo.ENTRY_POINT;
		ctx.gp = GameInfo.INITIAL_GP;
		ctx.sp = GameInfo.INITIAL_SP;

		shim.Backend.log(shim.Backend.LOG_INFO,
			"recompiled program linked: " + GameInfo.FUNCTIONS + " functions in "
			+ GameInfo.SHARDS + " shards, entry " + hex(GameInfo.ENTRY_POINT));

		// Frame capture is requested inside the game loop, which need never return normally.
		kernel.Kernel.vramDump = true;
		kernel.Kernel.reportOps = true;
		#if recompsx_cooperative
		running = ctx;
		core.Cooperative.every = optionInt('--yield-every');
		#if js
		shim.BrowserLoop.drive(step);
		#else
		while (step()) {}
		#end
		#else
		Runtime.callAndResume(ctx, GameInfo.ENTRY_POINT);
		report(ctx);
		#end
	}

	static function report(ctx:CpuState):Void {
		#if recompsx_insns
		shim.Backend.log(shim.Backend.LOG_INFO, "insns " + Runtime.insns + " | blocks "
			+ Runtime.blocks + " | dispatches " + Runtime.dispatches);
		#end
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
		if (kernel.Kernel.haltAt > 0) reportDigest(ctx);
		else {}
	}

	/**
		What the machine had done by the frame it was told to stop at, as one comparable number.

		Two things go in, because either alone can agree while the machine differs. VRAM says what
		was drawn — the whole of it, not the visible window, since a game composes offscreen and a
		digest that ignored that would call two different pictures identical. The counters say what
		was *done* to arrive there, which catches a run that reached the same picture by a
		different road: a dropped interrupt, a sector served twice, an overlay that activated on
		one target and not the other.

		Every input is emulated state. Nothing here reads host time, host input or iteration order,
		so JavaScript and C++ must print the same value or one of them is wrong.
	**/
	static function reportDigest(ctx:CpuState):Void {
		var d = core.Hash.rect(core.Hash.FNV_OFFSET, gpu.Vram.data, gpu.Vram.WIDTH,
			0, 0, gpu.Vram.WIDTH, gpu.Vram.HEIGHT);
		d = core.Hash.word(d, kernel.Kernel.vblankCount);
		d = core.Hash.word(d, core.Scheduler.fired);
		d = core.Hash.word(d, core.Irq.delivered);
		d = core.Hash.word(d, kernel.KHandlers.calls);
		d = core.Hash.word(d, kernel.KEvents.delivered);
		d = core.Hash.word(d, kernel.KEvents.callbacks);
		d = core.Hash.word(d, gpu.Gpu.wordsReceived);
		d = core.Hash.word(d, gpu.Gpu.commandsReceived);
		d = core.Hash.word(d, gpu.Gpu.primitives);
		d = core.Hash.word(d, gpu.Gpu.uploaded);
		d = core.Hash.word(d, dma.Dma.listsWalked);
		d = core.Hash.word(d, dma.Dma.wordsFromCd);
		d = core.Hash.word(d, dma.Dma.wordsToSpu);
		d = core.Hash.word(d, cd.Cdrom.commands);
		d = core.Hash.word(d, cd.Cdrom.sectorsDelivered);
		d = core.Hash.word(d, cd.Cdrom.raised);
		d = core.Hash.word(d, cd.Cdrom.swallowed);
		d = core.Hash.word(d, spu.Spu.keyedOn);
		d = core.Hash.word(d, spu.Spu.samplesOut);
		d = core.Hash.word(d, spu.Spu.nonSilent);
		d = core.Hash.word(d, kernel.OverlayMgr.activations);
		d = core.Hash.word(d, kernel.OverlayMgr.evictions);
		d = core.Hash.word(d, ctx.cycles);
		// The same shape scripts/test.sh greps for, so a game digest quotes like a demo one.
		shim.Backend.log(shim.Backend.LOG_INFO,
			"frames=" + kernel.Kernel.vblankCount + " digest=" + core.Hash.hex(d));
	}

	/**
		`--headless-hash <frames>`, wherever it appears among the paths.

		Scanned rather than positional: the exe and the disc are already positional, and a third
		positional argument that is sometimes a number and sometimes absent is the kind of
		interface that eventually runs the wrong thing.
	**/
	static function headlessFrames():Int {
		return optionInt('--headless-hash');
	}

	static function optionInt(name:String):Int {
		final argc = shim.Backend.argCount();
		var i = 0;
		while (i + 1 < argc) {
			if (shim.Backend.arg(i) == name) return parseInt(shim.Backend.arg(i + 1));
			else {}
			i++;
		}
		return 0;
	}

	static function videoHw():Bool {
		final argc = shim.Backend.argCount();
		var i = 0;
		while (i < argc) {
			if (shim.Backend.arg(i) == "--video-hw") return true;
			else {}
			i++;
		}
		return false;
	}


	/** Small non-negative integer parser; `Std.parseInt` pulls in machinery a runtime need not carry. */
	static function parseInt(s:String):Int {
		var v = 0;
		var i = 0;
		while (i < s.length) {
			final c = s.charCodeAt(i);
			if (c == null || c < 48 || c > 57) return v;
			else {}
			v = v * 10 + (c - 48);
			i++;
		}
		return v;
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
