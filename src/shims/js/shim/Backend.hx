package shim;

/**
	The JavaScript platform facade — same API as the C++ one, so runtime code compiles unchanged.

	Two hosts, one build. Under Node it is headless and reads the disc with `fs`, which is the
	fast, trustworthy feedback loop the development target exists to be, and the determinism
	digest is its product. Under a browser there is no `fs` and no `process`, so the page supplies
	a **host object** — `globalThis.recompsxHost` — carrying the files as byte arrays and a place
	to put frames.

	Detected rather than configured, and detected once. Neither host is a special case of the
	other in the code below: every entry point asks whether a host object is present and takes one
	of two paths, so the Node path is exactly what it was and the browser path never has to
	pretend to be a filesystem.

	The browser build enables portable cooperative continuations. BrowserLoop schedules slices
	on the main thread; the page receives raw VRAM through `present`. No worker is involved.
**/
class Backend {
	public static inline var LOG_DEBUG = 0;
	public static inline var LOG_INFO  = 1;
	public static inline var LOG_WARN  = 2;
	public static inline var LOG_ERROR = 3;

	/** The C backends can time a stretch of the runtime's work (see bp_profile_mark); here the
	    browser's and Node's own profilers already see every function, so it compiles to nothing. */
	public static inline var PROFILE_SPU = 0;
	public static inline var PROFILE_GTE = 1;
	public static inline var PROFILE_GPU = 2;
	public static inline function profileMark(section:Int, begin:Int):Void {}

	/** No sampler here (caps(5) is 0), so the runtime never calls these; they compile to nothing. */
	public static inline function spuRam(ram:RawBuf):Void {}
	public static inline function spuDirty(addr:Int, len:Int):Void {}
	public static inline function spuVoice(v:Int, key:Int, on:Int, start:Int, pitch:Int, volL:Int, volR:Int):Int return 0;

	public static inline var PRESENT_24BPP     = 1;
	public static inline var PRESENT_INTERLACE = 2;
	public static inline var PRESENT_PAL       = 4;
	public static inline var PRESENT_FAST      = 8;
	public static inline var PRESENT_DRAWING   = 16;

	static var args:Array<String> = [];
	static var quit = false;

	/**
		`--gpu-hash N` under Node: what the null backend does with it (src/backend/null), here. The
		shim says it draws, so a run with `--video-hw` takes the runtime's hardware path, and every
		gpu* call below folds its arguments into one 64-bit FNV-1a hash — the same bytes in the same
		order and from the same seed as the C backend, so the two targets print the same hash
		(`--gpu-hash-frames` prints it at every present, `--gpu-hash-trace N` the first N calls,
		to find where they part) — printed when the run ends
		at its Nth present. It is how a change to the hardware path is shown to hand the backend
		exactly what it did before, in seconds (Crash 3's 4,050 frames take four): `--headless-hash`
		cannot, since a run that hashes VRAM never takes that path. -1 until asked.
	**/
	static var gpuHashing = -1;
	static var gpuHashStop = 0;
	static var gpuHashPresents = 0;
	/** `--gpu-hash-frames`: the running hash at every present, to find where two targets part. */
	static var gpuHashFrames = false;
	/** `--gpu-hash-trace N`: the first N calls printed value by value, as the null backend does. */
	static var gpuHashTrace = 0;

	static function gpuHashOn():Bool {
		if (gpuHashing < 0) {
			gpuHashing = 0;
			if (!hosted()) {
				final a = readArgs();
				for (i in 0...a.length) {
					if (a[i] == "--gpu-hash-frames") gpuHashFrames = true;
					else {}
					if (a[i] == "--gpu-hash-trace" && i + 1 < a.length) gpuHashTrace = Std.parseInt(a[i + 1]);
					else {}
					if (a[i] == "--gpu-hash" && gpuHashing == 0) {
						gpuHashing = 1;
						gpuHashStop = i + 1 < a.length ? Std.parseInt(a[i + 1]) : 0;
						// The null backend's seed, 1469598103934665603: FNV-1a's offset basis with its last digit
						// missing. Kept, not corrected: every hash recorded so far was made with it.
						js.Syntax.code("globalThis.__recompsxGpuHash = { lo: 0x739d0383, hi: 0x14650fb0, calls: 0 }");
						js.Syntax.code("process.on('exit', function () { const h = globalThis.__recompsxGpuHash; const x = function (v) { return ('0000000' + v.toString(16)).slice(-8); }; console.log('[info] gpu-stream hash ' + x(h.hi) + x(h.lo) + ' over ' + h.calls + ' calls'); })");
					} else {}
				}
			} else {}
		} else {}
		return gpuHashing == 1;
	}

	/** The call's tag, counted, then each argument: four bytes each, low first, as gpu_mix does. */
	static function gpuHashCall(tag:Int):Void {
		js.Syntax.code("(function (h, n) { h.calls++; if (h.calls <= n) process.stdout.write('\\ngpu-call ' + h.calls + ':'); })(globalThis.__recompsxGpuHash, {0})", gpuHashTrace);
		gpuHashMix(tag);
	}

	/** h = (h ^ byte) * 0x100000001B3 on 64 bits held as two words: the low word times 0x1B3, its
		carry, and the low word shifted by 40 are the high word's share. */
	static function gpuHashMix(v:Int):Void {
		js.Syntax.code("(function (h, n, v) { if (h.calls <= n) process.stdout.write(' ' + v); })(globalThis.__recompsxGpuHash, {0}, {1})", gpuHashTrace, v);
		js.Syntax.code("(function (h, v) { let lo = h.lo, hi = h.hi; for (let k = 0; k < 4; k++) { const x = (lo ^ ((v >>> (8 * k)) & 0xFF)) >>> 0; const p = x * 0x1B3; hi = (Math.imul(hi, 0x1B3) + Math.floor(p / 4294967296) + (x << 8)) >>> 0; lo = p >>> 0; } h.lo = lo; h.hi = hi; })(globalThis.__recompsxGpuHash, {0})", v);
	}

	/** The page's object, or null under Node. Asked for rather than assumed, once per call site. */
	static inline function host():Dynamic {
		return js.Syntax.code("(typeof globalThis !== 'undefined' ? globalThis.recompsxHost : null)");
	}

	static inline function hosted():Bool {
		return js.Syntax.code("({0} != null)", host());
	}

	public static function init(title:String):Int {
		args = readArgs();
		return 0;
	}

	static function readArgs():Array<String> {
		if (hosted()) return js.Syntax.code("({0}.args || [])", host());
		else return js.Syntax.code("(typeof process !== 'undefined' ? process.argv.slice(2) : [])");
	}

	public static function shutdown():Void {}

	/**
		Capability 4 is hardware drawing, and it is the page's to offer: a host that carries a
		`gpu` object (the WebGL2 renderer in `web/gpu-webgl.js`) can be handed the primitives.
		Under Node there is no host and the answer is zero, so `gpu.Gpu.hw` never becomes true in
		a headless run and the digest stays with the software rasteriser — the same rule every
		backend follows (ADR-0008).
	**/
	public static function caps(capId:Int):Int {
		if (capId == 0) return 4;
		else if (capId == 4) return (hasGpu() || gpuHashOn()) ? 1 : 0;
		// The page's WebGL renderer samples what it drew (web/gpu-webgl.js), so it must hear of
		// every upload, not only of those that changed emulated VRAM (BP_CAP_GPU_UPLOADS).
		else if (capId == 6) return hasGpu() ? 1 : 0;
		else return 0;
	}

	static inline function hasGpu():Bool {
		return js.Syntax.code("({0} != null && {0}.gpu != null)", host());
	}

	/**
		The hardware-drawing seam. Each call forwards to the host's renderer, which decodes
		textures out of the same VRAM halfwords the runtime writes. The runtime only calls these
		once `caps(4)` said yes, so the renderer is present whenever they run.
	**/
	public static function gpuVram(vram:RawBuf):Void {
		if (gpuHashOn()) return;
		else {}
		js.Syntax.code("{0}.gpu.vram({1}.u16)", host(), vram);
	}

	public static function gpuState(texBaseX:Int, texBaseY:Int, texDepth:Int,
			clutX:Int, clutY:Int, semiMode:Int, flags:Int, texWindow:Int,
			drawX:Int, drawY:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(2); gpuHashMix(texBaseX); gpuHashMix(texBaseY); gpuHashMix(texDepth);
			gpuHashMix(clutX); gpuHashMix(clutY); gpuHashMix(semiMode); gpuHashMix(flags);
			gpuHashMix(texWindow); gpuHashMix(drawX); gpuHashMix(drawY);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.state({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10})",
			host(), texBaseX, texBaseY, texDepth, clutX, clutY, semiMode, flags, texWindow, drawX, drawY);
	}

	public static function gpuTri(x0:Int, y0:Int, c0:Int, u0:Int, v0:Int,
			x1:Int, y1:Int, c1:Int, u1:Int, v1:Int,
			x2:Int, y2:Int, c2:Int, u2:Int, v2:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(1); gpuHashMix(x0); gpuHashMix(y0); gpuHashMix(c0); gpuHashMix(u0); gpuHashMix(v0);
			gpuHashMix(x1); gpuHashMix(y1); gpuHashMix(c1); gpuHashMix(u1); gpuHashMix(v1);
			gpuHashMix(x2); gpuHashMix(y2); gpuHashMix(c2); gpuHashMix(u2); gpuHashMix(v2);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.tri({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11}, {12}, {13}, {14}, {15})",
			host(), x0, y0, c0, u0, v0, x1, y1, c1, u1, v1, x2, y2, c2, u2, v2);
	}

	/** The state the GPU file's words 52-61 hold (the polygon core's, ADR-0047), as bp_gpu_state_w
	    takes it: gpuState with the words in order. */
	public static function gpuStateWords():Void {
		gpuState(GpuFile.get(52), GpuFile.get(53), GpuFile.get(54), GpuFile.get(55), GpuFile.get(56),
			GpuFile.get(57), GpuFile.get(58), GpuFile.get(59), GpuFile.get(60), GpuFile.get(61));
	}

	/** The triangle the GPU file's words 36-47 hold (gpu.Gpu.triWords: x, y, the colour word, the
	    texture word a vertex), as bp_gpu_tri_w takes it: gpuTri with the words unpacked. */
	public static function gpuTriWords():Void {
		final t0 = GpuFile.get(39), t1 = GpuFile.get(43), t2 = GpuFile.get(47);
		gpuTri(GpuFile.get(36), GpuFile.get(37), GpuFile.get(38) & 0xFFFFFF, t0 & 0xFF, (t0 >>> 8) & 0xFF,
			GpuFile.get(40), GpuFile.get(41), GpuFile.get(42) & 0xFFFFFF, t1 & 0xFF, (t1 >>> 8) & 0xFF,
			GpuFile.get(44), GpuFile.get(45), GpuFile.get(46) & 0xFFFFFF, t2 & 0xFF, (t2 >>> 8) & 0xFF);
	}

	public static function gpuRect(x:Int, y:Int, w:Int, h:Int, bgr:Int, semi:Int,
			semiMode:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(3); gpuHashMix(x); gpuHashMix(y); gpuHashMix(w); gpuHashMix(h); gpuHashMix(bgr);
			gpuHashMix(semi); gpuHashMix(semiMode);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.rect({1}, {2}, {3}, {4}, {5}, {6}, {7})",
			host(), x, y, w, h, bgr, semi, semiMode);
	}

	public static function gpuDirty(x:Int, y:Int, w:Int, h:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(4); gpuHashMix(x); gpuHashMix(y); gpuHashMix(w); gpuHashMix(h);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.dirty({1}, {2}, {3}, {4})", host(), x, y, w, h);
	}

	public static function gpuClip(x0:Int, y0:Int, x1:Int, y1:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(5); gpuHashMix(x0); gpuHashMix(y0); gpuHashMix(x1); gpuHashMix(y1);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.clip({1}, {2}, {3}, {4})", host(), x0, y0, x1, y1);
	}

	public static function gpuMask(setBit:Int, checkBit:Int):Void {
		if (gpuHashOn()) {
			gpuHashCall(6); gpuHashMix(setBit); gpuHashMix(checkBit);
			return;
		} else {}
		js.Syntax.code("{0}.gpu.mask({1}, {2})", host(), setBit, checkBit);
	}

	public static function argCount():Int {
		if (args.length == 0) args = readArgs();
		else {}
		return args.length;
	}

	public static function arg(i:Int):String {
		argCount();
		return i >= 0 && i < args.length ? args[i] : "";
	}

	/**
		Under Node: nothing to draw to, and the digest rather than the picture is the product.

		Under a browser: the window of VRAM, handed over as it is. No conversion here — the host
		gets the same BGR555 halfwords the GPU wrote, because the moment this shim starts turning
		them into RGBA it becomes a second renderer that can disagree with the first.
	**/
	/** The last present asked not to be held to the video rate (PRESENT_FAST); `BrowserLoop`
	    runs such frames as it runs them with the speed limit off. */
	public static var fast = false;

	public static function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void {
		fast = (flags & PRESENT_FAST) != 0;
		// The null backend's rule: a hashed run ends at its Nth present, and prints at exit.
		if (gpuHashing == 1 && gpuHashStop > 0) {
			gpuHashPresents++;
			if (gpuHashFrames) js.Syntax.code("(function (h, n) { const x = function (v) { return ('0000000' + v.toString(16)).slice(-8); }; console.log('gpu-frame ' + n + ' ' + x(h.hi) + x(h.lo) + ' ' + h.calls); })(globalThis.__recompsxGpuHash, {0})", gpuHashPresents);
			else {}
			if (gpuHashPresents >= gpuHashStop) js.Syntax.code("process.exit(0)");
			else {}
		} else {}
		if (!hosted()) return;
		else {}
		js.Syntax.code("{0}.present({1}.u8, {2}, {3}, {4}, {5}, {6})",
			host(), vram, sx, sy, sw, sh, flags);
	}

	/**
		Stereo 16-bit pairs, 44100 a second, as the SPU produced them.

		Under a browser they go to the page, which owns the only clock that matters for sound.
		Under Node there is nobody listening, so they are appended to `audio.pcm` — a raw file is
		the honest artifact for a headless target: it can be measured, converted and listened to,
		and it does not require this shim to have an opinion about playback.

		Batched before touching the disc. A push arrives every 128 samples, which is about three
		milliseconds of sound and far too often to be a filesystem call.
	**/
	public static function audioPush(frames:RawBuf, frameCount:Int):Void {
		if (hosted()) {
			// The buffer itself, lent for the call, and how many bytes of it are this batch: the
			// page copies what it keeps. A `slice` here was a new ArrayBuffer every 128 frames of
			// sound, the collector's to find, and more of them the faster the loop ran. A page
			// that predates the loan (a cached copy, say) still gets its own slice by the old name.
			js.Syntax.code("({0}.audioLend ? {0}.audioLend({1}.u8, {2} * 4) : {0}.audioPush({1}.u8.slice(0, {2} * 4)))",
				host(), frames, frameCount);
			return;
		} else {}
		js.Syntax.code("(function(u8, n){
			if (typeof require === 'undefined') return;
			globalThis.__recompsxPcm = globalThis.__recompsxPcm || [];
			var q = globalThis.__recompsxPcm;
			q.push(Buffer.from(u8.slice(0, n * 4)));
			var total = 0;
			for (var i = 0; i < q.length; i++) total += q[i].length;
			if (total >= 1 << 20) {
				require('fs').appendFileSync('audio.pcm', Buffer.concat(q));
				q.length = 0;
			}
		})({0}.u8, {1})", frames, frameCount);
	}

	/**
		What the page still holds, for the SPU's pacing (see `spu.Spu.flush`). A page without
		the function is reported as holding nothing, which switches the pacing off; Node holds
		nothing because nobody is listening.
	**/
	public static function audioBuffered():Int {
		if (!hosted()) return 0;
		else return js.Syntax.code("({0}.audioBuffered ? ({0}.audioBuffered() | 0) : 0)", host());
	}

	/** The keyboard and gamepads in a page (shim.Input); under Node, no pad at all. */
	public static function inputPoll():Void Input.poll();
	public static function padConnected(pad:Int):Bool return Input.connected(pad);
	public static function padType(pad:Int):Int return Input.connected(pad) ? 1 : 0;
	public static function padButtons(pad:Int):Int return Input.buttons(pad);
	public static function padAxis(pad:Int, axis:Int):Int return 0x80;
	/** The page's keyboard as text (shim.Input); under Node nothing is ever typed. */
	public static function keyText(on:Bool):Void Input.textEntry(on);
	public static function keyNext():Int return Input.nextTyped();
	/** The pointer over the page's picture (shim.Input); under Node there is none. */
	public static function mouse(field:Int):Int return Input.mouse(field);
	public static function mousePointer(state:Int):Void Input.showPointer(state);

	/**
		HTTP for the i-mode adaptor's phone (backend_c_api.h, ADR-0040): the page's `fetch`, through
		its host (web/index.html); under Node, no network.
	**/
	public static function httpOpen(name:String, port:Int, request:RawBuf, len:Int):Int {
		var h = -1;
		if (hosted()) {
			h = js.Syntax.code("(typeof {0}.httpOpen === 'function' ? ({0}.httpOpen({1}, {2}, {3}.u8.slice(0, {4})) | 0) : -1)",
				host(), name, port, request, len);
		} else {}
		return h;
	}

	public static function httpRead(handle:Int, buf:RawBuf, cap:Int):Int {
		var n = -2;
		if (hosted()) {
			n = js.Syntax.code("(typeof {0}.httpRead === 'function' ? ({0}.httpRead({1}, {2}.u8.subarray(0, {3})) | 0) : -2)",
				host(), handle, buf, cap);
		} else {}
		return n;
	}

	public static function httpClose(handle:Int):Void {
		if (hosted()) js.Syntax.code("(typeof {0}.httpClose === 'function' && {0}.httpClose({1}))", host(), handle);
		else {}
	}
	public static function requestQuit():Void {
		quit = true;
	}

	public static function quitRequested():Bool return quit;

	/**
		The host's own menu (bp_exit_to_menu): the page goes back to its start screen, and a program
		under Node ends.
	**/
	public static function exitToMenu():Void {
		quit = true;
		if (hosted()) js.Syntax.code("(typeof {0}.exitToMenu === 'function' && {0}.exitToMenu())", host());
		else js.Syntax.code("(typeof process !== 'undefined' && process.exit(0))");
	}

	/**
		Reads a kept blob: the page's (its local storage), or under Node a file beside the program,
		where `storageWrite` puts it. -1 when there is none.
	**/
	public static function storageRead(name:String, buf:RawBuf, len:Int):Int {
		var n = -1;
		if (hosted()) {
			n = js.Syntax.code("(typeof {0}.storageRead === 'function' ? {0}.storageRead({1}, {2}.u8.subarray(0, {3})) : -1)",
				host(), name, buf, len);
		} else {
			n = js.Syntax.code("(function (fs, name, into) { if (!fs.existsSync(name)) return -1; const b = fs.readFileSync(name); const k = Math.min(b.length, into.length); into.set(b.subarray(0, k)); return k; })(require('fs'), {0}, {1}.u8.subarray(0, {2}))",
				name, buf, len);
		}
		return n;
	}

	/** Writes a blob beside the program. Used by the VRAM dump, which is how a frame is looked at. */
	public static function storageWrite(name:String, buf:RawBuf, len:Int):Int {
		if (hosted()) {
			js.Syntax.code("{0}.storageWrite({1}, {2}.u8.subarray(0, {3}))", host(), name, buf, len);
			return 0;
		} else {}
		js.Syntax.code("require('fs').writeFileSync({0}, Buffer.from({1}.u8.buffer, 0, {2}))",
			name, buf, len);
		return 0;
	}

	/**
		The game's memory card in the card format (ADR-0037): the page's, from its local storage, or
		under Node `<game>.card` beside the program. Its length, or -1 when there is none.
	**/
	public static function cardLoad(game:String, buf:RawBuf, cap:Int):Int {
		var n = -1;
		if (hosted()) {
			n = js.Syntax.code("(typeof {0}.cardLoad === 'function' ? {0}.cardLoad({1}, {2}.u8.subarray(0, {3})) : -1)",
				host(), game, buf, cap);
		} else {
			n = storageRead(game + ".card", buf, cap);
		}
		return n;
	}

	/** The card back to the host; one with no blocks on it (16 bytes) removes the host's copy. */
	public static function cardSave(game:String, title:String, buf:RawBuf, len:Int):Int {
		var n = -1;
		if (hosted()) {
			n = js.Syntax.code("(typeof {0}.cardSave === 'function' ? {0}.cardSave({1}, {2}, {3}.u8.subarray(0, {4})) : -1)",
				host(), game, title, buf, len);
		} else {
			n = js.Syntax.code("(function (fs, name, from) { if (from.length <= 16) { if (fs.existsSync(name)) fs.unlinkSync(name); return 0; } const tmp = name + '.tmp'; fs.writeFileSync(tmp, from); fs.renameSync(tmp, name); return 0; })(require('fs'), {0}, {1}.u8.subarray(0, {2}))",
				game + ".card", buf, len);
		}
		return n;
	}

	// ---- file slots ---------------------------------------------------------------------------
	//
	// How the runtime reaches the game's own bytes: the executable payload now, disc sectors
	// later. The C++ side of this is the backend's `bp_file_*`, deliberately a dumb byte server
	// so that all CUE and ISO9660 logic stays in portable Haxe (shared/psxdisc) and a console
	// port has nothing to reimplement but reads.
	//
	// Here the whole file is read once into a RawBuf rather than kept as a handle. A PS-EXE is a
	// megabyte and this is the development target, so the simplicity is worth more than the
	// memory — and it keeps the slot array typed, with no Dynamic anywhere.

	static final SLOTS = 8;
	static var slots:Array<Null<RawBuf>> = [for (_ in 0...SLOTS) null];

	public static function fileOpen(slot:Int, path:String):Int {
		if (slot < 0 || slot >= SLOTS) return -1;
		else {}
		final size = statSize(path);
		if (size < 0) return -1;
		else {}
		final buf = new RawBuf(size);
		readInto(path, buf);
		slots[slot] = buf;
		return 0;
	}

	public static function fileSize(slot:Int):Int {
		if (slot < 0 || slot >= SLOTS) return -1;
		else {}
		final b = slots[slot];
		return b == null ? -1 : b.u8.length;
	}

	public static function fileRead(slot:Int, offset:Int, buf:RawBuf, len:Int):Int {
		if (slot < 0 || slot >= SLOTS) return -1;
		else {}
		final src = slots[slot];
		if (src == null) return -1;
		else {}
		// A short read at the end is not an error — it is what a byte server does.
		var n = len;
		if (offset + n > src.u8.length) n = src.u8.length - offset;
		else {}
		if (n <= 0) return 0;
		else {}
		// A copy loop rather than `set(subarray(...))`: the view is a fresh object on every
		// sector, and a game streaming from the disc made it a measurable share of the
		// collector's work (15 % of scavenges over 3000 frames). The runtime allocates nothing
		// after init; the shim keeps to that too.
		js.Syntax.code("{ const d = {0}.u8, q = {1}.u8; for (let i = 0; i < {2}; i++) d[i] = q[{3} + i]; }", buf, src, n, offset);
		return n;
	}

	public static function fileClose(slot:Int):Void {
		if (slot >= 0 && slot < SLOTS) slots[slot] = null;
		else {}
	}

	/** -1 if the path does not exist, rather than throwing: the caller reports, we do not. */
	static function statSize(path:String):Int {
		if (hosted()) {
			return js.Syntax.code("(function(h,p){ var f = h.files[p]; return f ? f.length|0 : -1; })({0}, {1})",
				host(), path);
		} else {}
		return js.Syntax.code("(function(p){ try { return require('fs').statSync(p).size|0; } catch (e) { return -1; } })({0})", path);
	}

	static function readInto(path:String, buf:RawBuf):Void {
		if (hosted()) {
			js.Syntax.code("{0}.u8.set({1}.files[{2}])", buf, host(), path);
			return;
		} else {}
		js.Syntax.code("{0}.u8.set(require('fs').readFileSync({1}))", buf, path);
	}

	/** No pacing headless: this target runs as fast as it can and is never watched live. */
	public static function paceFrame(targetUs:Int):Void {}

	public static function log(level:Int, msg:String):Void {
		final line = (level >= LOG_WARN ? "[warn] " : "[info] ") + msg;
		if (hosted()) js.Syntax.code("{0}.log({1}, {2})", host(), level, line);
		else js.Syntax.code("console.log({0})", line);
	}

	public static function fatal(msg:String):Void {
		final line = "[fatal] " + msg;
		if (hosted()) {
			js.Syntax.code("{0}.log({1}, {2})", host(), LOG_ERROR, line);
			quit = true;
			return;
		} else {}
		js.Syntax.code("console.error({0})", line);
		js.Syntax.code("(typeof process !== 'undefined' ? process.exit(1) : null)");
	}
}
