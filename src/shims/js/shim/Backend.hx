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
	public static function quitRequested():Bool return quit;

	public static function storageRead(name:String, buf:RawBuf, len:Int):Int return -1;
	public static function storageWrite(name:String, buf:RawBuf, len:Int):Int return -1;

	public static function fileOpen(slot:Int, path:String):Int return -1;
	public static function fileSize(slot:Int):Int return -1;
	public static function fileRead(slot:Int, offset:Int, buf:RawBuf, len:Int):Int return -1;
	public static function fileClose(slot:Int):Void {}

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
