package shim;

import sys.io.FileInput;

/**
	The platform facade on the JVM — the same API as the others, so runtime code compiles
	unchanged. Headless, like JavaScript under Node: it reads the disc through `sys.io`, draws
	nothing, plays nothing, and its product is the determinism digest (`--headless-hash N`).

	There is no C ABI on this target (docs/specs/backend.md §0), so this is the whole backend: no
	rasteriser capability is offered (`caps(4)` is 0), so the GPU runs its software path and the
	`gpu*` entries are never called, and there is no sampler (`caps(5)`), so the SPU mixes in
	software and its output is dropped.
**/
class Backend {
	public static inline var LOG_DEBUG = 0;
	public static inline var LOG_INFO  = 1;
	public static inline var LOG_WARN  = 2;
	public static inline var LOG_ERROR = 3;

	public static inline var PROFILE_SPU = 0;
	public static inline var PROFILE_GTE = 1;
	public static inline var PROFILE_GPU = 2;
	public static inline function profileMark(section:Int, begin:Int):Void {}

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

	public static function init(title:String):Int {
		args = Sys.args();
		return 0;
	}

	public static function shutdown():Void {}

	public static function caps(capId:Int):Int {
		if (capId == 0) return 4;
		else return 0;
	}

	// Never called: caps(4) is 0, so the runtime keeps drawing in software.
	public static function gpuVram(vram:RawBuf):Void {}
	public static function gpuState(texBaseX:Int, texBaseY:Int, texDepth:Int,
			clutX:Int, clutY:Int, semiMode:Int, flags:Int, texWindow:Int,
			drawX:Int, drawY:Int):Void {}
	public static function gpuTri(x0:Int, y0:Int, c0:Int, u0:Int, v0:Int,
			x1:Int, y1:Int, c1:Int, u1:Int, v1:Int,
			x2:Int, y2:Int, c2:Int, u2:Int, v2:Int):Void {}
	public static function gpuTriWords():Void {}
	public static function gpuStateWords():Void {}
	public static function gpuStateAfterTri():Void {}
	public static function gpuRect(x:Int, y:Int, w:Int, h:Int, bgr:Int, semi:Int,
			semiMode:Int):Void {}
	public static function gpuDirty(x:Int, y:Int, w:Int, h:Int):Void {}
	public static function gpuCopy(sx:Int, sy:Int, dx:Int, dy:Int, w:Int, h:Int, changed:Int):Void {}
	public static function gpuClip(x0:Int, y0:Int, x1:Int, y1:Int):Void {}
	public static function gpuMask(setBit:Int, checkBit:Int):Void {}

	public static function argCount():Int {
		if (args.length == 0) args = Sys.args();
		else {}
		return args.length;
	}

	public static function arg(i:Int):String {
		argCount();
		return i >= 0 && i < args.length ? args[i] : "";
	}

	/** Headless: nothing to draw to; the digest is the product. */
	public static function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void {}

	/** Headless: nobody is listening, and nothing waits on the sound. */
	public static function audioPush(frames:RawBuf, frameCount:Int):Void {}

	public static function audioBuffered():Int return 0;

	public static function inputPoll():Void {}
	public static function padConnected(pad:Int):Bool return pad == 0;
	public static function padType(pad:Int):Int return pad == 0 ? 1 : 0;
	public static function padButtons(pad:Int):Int return 0;
	public static function padAxis(pad:Int, axis:Int):Int return 0x80;
	/** Headless: no motors to turn. */
	public static function padRumble(pad:Int, small:Int, large:Int):Void {}
	/** Headless: no keyboard, so nothing is ever typed. */
	public static function keyText(on:Bool):Void {}
	public static function keyNext():Int return -1;
	/** Headless: no mouse, never over the picture. */
	public static function mouse(field:Int):Int return 0;
	public static function mousePointer(state:Int):Void {}
	/** No network here (ADR-0040): the i-mode adaptor's phone finds none. */
	public static function httpOpen(host:String, port:Int, request:RawBuf, len:Int):Int return -1;
	public static function httpRead(handle:Int, buf:RawBuf, cap:Int):Int return -2;
	public static function httpClose(handle:Int):Void {}

	public static function requestQuit():Void {
		quit = true;
	}

	public static function quitRequested():Bool return quit;

	/** No host menu here: the program ends. */
	public static function exitToMenu():Void Sys.exit(0);

	public static function storageRead(name:String, buf:RawBuf, len:Int):Int return -1;

	/** Writes a blob beside the program. Used by the VRAM dump, which is how a frame is looked at. */
	public static function storageWrite(name:String, buf:RawBuf, len:Int):Int {
		sys.io.File.saveBytes(name, buf.bytes.sub(0, len));
		return 0;
	}

	/** No memory card is kept (ADR-0037): every run starts with a blank one, as a headless run does. */
	public static function cardLoad(game:String, buf:RawBuf, cap:Int):Int return -1;
	public static function cardSave(game:String, title:String, buf:RawBuf, len:Int):Int return -1;

	// ---- file slots ---------------------------------------------------------------------------
	//
	// A dumb byte server, as the backend ABI's bp_file_* is: the CUE and ISO9660 logic stays in
	// portable Haxe. Unlike the JavaScript shim, which reads a whole file into memory, a slot
	// keeps the file open and reads what is asked for — a disc image is hundreds of megabytes.

	static final SLOTS = 8;
	static var inputs:Array<Null<FileInput>> = [];
	static var sizes:Array<Int> = [];

	public static function fileOpen(slot:Int, path:String):Int {
		if (slot < 0 || slot >= SLOTS) return -1;
		else {}
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) return -1;
		else {}
		fileClose(slot);
		inputs[slot] = sys.io.File.read(path, true);
		sizes[slot] = sys.FileSystem.stat(path).size;
		return 0;
	}

	public static function fileSize(slot:Int):Int {
		if (slot < 0 || slot >= SLOTS || inputs[slot] == null) return -1;
		else return sizes[slot];
	}

	public static function fileRead(slot:Int, offset:Int, buf:RawBuf, len:Int):Int {
		if (slot < 0 || slot >= SLOTS) return -1;
		else {}
		final input = inputs[slot];
		if (input == null) return -1;
		else {}
		// A short read at the end is not an error — it is what a byte server does.
		var n = len;
		if (offset + n > sizes[slot]) n = sizes[slot] - offset;
		else {}
		if (n <= 0) return 0;
		else {}
		input.seek(offset, sys.io.FileSeek.SeekBegin);
		var got = 0;
		while (got < n) {
			final r = input.readBytes(buf.bytes, got, n - got);
			if (r <= 0) break;
			else got += r;
		}
		return got;
	}

	public static function fileClose(slot:Int):Void {
		if (slot < 0 || slot >= SLOTS) return;
		else {}
		final input = inputs[slot];
		if (input != null) {
			input.close();
			inputs[slot] = null;
		} else {}
	}

	/** No pacing headless: this target runs as fast as it can and is never watched live. */
	public static function paceFrame(targetUs:Int):Void {}

	public static function log(level:Int, msg:String):Void {
		Sys.println((level >= LOG_WARN ? "[warn] " : "[info] ") + msg);
	}

	public static function fatal(msg:String):Void {
		Sys.stderr().writeString("[fatal] " + msg + "\n");
		Sys.exit(1);
	}
}
