package shim;

/**
	The JavaScript platform facade — same API as the C++ one, so runtime code compiles unchanged.

	Scope today is Node, headless: the point of this target is a fast, trustworthy feedback loop
	while the emulator is being written, and the determinism digest is what it has to produce.
	A browser backend (canvas + WebAudio + Gamepad) is a later addition; note that it will need
	the main loop inverted — a browser cannot block in `while (!quit)`, so the runtime will have
	to expose a `stepFrame()` that the platform drives. Consoles will want that shape too, so it
	is worth doing properly rather than bolting on.
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

	public static function init(title:String):Int {
		args = js.Syntax.code("(typeof process !== 'undefined' ? process.argv.slice(2) : [])");
		return 0;
	}

	public static function shutdown():Void {}

	public static function caps(capId:Int):Int return capId == 0 ? 4 : 0;

	public static function argCount():Int {
		if (args.length == 0) {
			args = js.Syntax.code("(typeof process !== 'undefined' ? process.argv.slice(2) : [])");
		}
		return args.length;
	}

	public static function arg(i:Int):String {
		argCount();
		return i >= 0 && i < args.length ? args[i] : "";
	}

	/** Headless: nothing to draw to. The digest, not the picture, is this target's product. */
	public static function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void {}

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
	public static function storageWrite(name:String, buf:RawBuf, len:Int):Int return -1;

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
		return js.Syntax.code("(function(p){ try { return require('fs').statSync(p).size|0; } catch (e) { return -1; } })({0})", path);
	}

	static function readInto(path:String, buf:RawBuf):Void {
		js.Syntax.code("{0}.u8.set(require('fs').readFileSync({1}))", buf, path);
	}

	/** No pacing headless: this target runs as fast as it can and is never watched live. */
	public static function paceFrame(targetUs:Int):Void {}

	public static function log(level:Int, msg:String):Void {
		js.Syntax.code("console.log({0})", (level >= LOG_WARN ? "[warn] " : "[info] ") + msg);
	}

	public static function fatal(msg:String):Void {
		js.Syntax.code("console.error({0})", "[fatal] " + msg);
		js.Syntax.code("(typeof process !== 'undefined' ? process.exit(1) : null)");
	}
}
