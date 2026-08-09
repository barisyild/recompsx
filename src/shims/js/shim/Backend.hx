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

	The main loop is still the game's own — `main()` does not return, which a browser tab cannot
	survive. So the page runs this in a **worker**, where blocking is allowed, and frames arrive
	on the main thread through the host's `present`. Consoles will eventually want an inverted
	`stepFrame()` shape for the same reason; a worker is what makes the browser not need it yet.
**/
class Backend {
	public static inline var LOG_DEBUG = 0;
	public static inline var LOG_INFO  = 1;
	public static inline var LOG_WARN  = 2;
	public static inline var LOG_ERROR = 3;

	public static inline var PRESENT_24BPP     = 1;
	public static inline var PRESENT_INTERLACE = 2;
	public static inline var PRESENT_PAL       = 4;

	static var args:Array<String> = [];
	static var quit = false;

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

	public static function caps(capId:Int):Int return capId == 0 ? 4 : 0;

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
	public static function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void {
		if (!hosted()) return;
		else {}
		js.Syntax.code("{0}.present({1}.u8, {2}, {3}, {4}, {5}, {6})",
			host(), vram, sx, sy, sw, sh, flags);
	}

	public static function audioPush(frames:RawBuf, frameCount:Int):Void {}
	public static function audioBuffered():Int return 0;

	public static function inputPoll():Void {}
	public static function padConnected(pad:Int):Bool return pad == 0;
	public static function padType(pad:Int):Int return pad == 0 ? 1 : 0;
	public static function padButtons(pad:Int):Int return 0;
	public static function padAxis(pad:Int, axis:Int):Int return 0x80;
	public static function requestQuit():Void {
		quit = true;
	}

	public static function quitRequested():Bool return quit;

	public static function storageRead(name:String, buf:RawBuf, len:Int):Int return -1;

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
		buf.u8.set(src.u8.subarray(offset, offset + n), 0);
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
