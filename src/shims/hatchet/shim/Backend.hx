package shim;

/**
	The platform facade the runtime sees (see the C++ twin). Hatchet half: every function is an
	inline call into the C backend ABI (`src/backend/api/backend_c_api.h`) in
	`native/recompsx_hatchet.h`; strings cross as `std::string` and leave as `const char*`.
**/
@:include("<recompsx_hatchet.h>")
extern class Backend {
	public static inline var LOG_DEBUG:Int = 0;
	public static inline var LOG_INFO:Int = 1;
	public static inline var LOG_WARN:Int = 2;
	public static inline var LOG_ERROR:Int = 3;
	public static inline var PRESENT_24BPP:Int = 1;
	public static inline var PRESENT_INTERLACE:Int = 2;
	public static inline var PRESENT_PAL:Int = 4;
	public static inline var PROFILE_SPU:Int = 0;

	public static function init(title:String):Int;
	public static function shutdown():Void;
	public static function caps(capId:Int):Int;
	public static function argCount():Int;
	public static function arg(i:Int):String;
	public static function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void;
	public static function gpuVram(vram:RawBuf):Void;
	public static function gpuState(texBaseX:Int, texBaseY:Int, texDepth:Int, clutX:Int, clutY:Int,
		semiMode:Int, flags:Int, texWindow:Int, drawX:Int, drawY:Int):Void;
	public static function gpuTri(x0:Int, y0:Int, c0:Int, u0:Int, v0:Int, x1:Int, y1:Int, c1:Int,
		u1:Int, v1:Int, x2:Int, y2:Int, c2:Int, u2:Int, v2:Int):Void;
	public static function gpuRect(x:Int, y:Int, w:Int, h:Int, bgr:Int, semi:Int, semiMode:Int):Void;
	public static function gpuDirty(x:Int, y:Int, w:Int, h:Int):Void;
	public static function gpuClip(x0:Int, y0:Int, x1:Int, y1:Int):Void;
	public static function gpuMask(setBit:Int, checkBit:Int):Void;
	public static function audioPush(frames:RawBuf, frameCount:Int):Void;
	public static function audioBuffered():Int;
	public static function profileMark(section:Int, begin:Int):Void;
	public static function spuRam(ram:RawBuf):Void;
	public static function spuDirty(addr:Int, len:Int):Void;
	public static function spuVoice(v:Int, key:Int, on:Int, start:Int, pitch:Int, volL:Int, volR:Int):Int;
	public static function inputPoll():Void;
	public static function padConnected(pad:Int):Bool;
	public static function padType(pad:Int):Int;
	public static function padButtons(pad:Int):Int;
	public static function padAxis(pad:Int, axis:Int):Int;
	public static function requestQuit():Void;
	public static function quitRequested():Bool;
	public static function storageRead(name:String, buf:RawBuf, len:Int):Int;
	public static function storageWrite(name:String, buf:RawBuf, len:Int):Int;
	public static function fileOpen(slot:Int, path:String):Int;
	public static function fileSize(slot:Int):Int;
	public static function fileRead(slot:Int, offset:Int, buf:RawBuf, len:Int):Int;
	public static function fileClose(slot:Int):Void;
	public static function paceFrame(targetUs:Int):Void;
	public static function log(level:Int, msg:String):Void;
	public static function fatal(msg:String):Void;
}
