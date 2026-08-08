package shim;

import shim.RawBuf;

import cxx.CArray;
import cxx.ConstCharPtr;
import cxx.num.UInt8;

/**
	The platform facade the runtime sees. One of these exists per target — `src/shims/cxx` for
	native builds, `src/shims/jvm` for the JVM — and exactly one is on the classpath, so the
	runtime calls `Backend.present(...)` with no interface, no virtual dispatch and no `#if`
	anywhere above this line.

	A Haxe interface would also have worked, but a compile-time-swapped static class costs
	nothing at run time and does not depend on how well reflaxe.CPP handles interfaces — a
	question we have no reason to ask.
**/
class Backend {
	public static inline var LOG_DEBUG = 0;
	public static inline var LOG_INFO  = 1;
	public static inline var LOG_WARN  = 2;
	public static inline var LOG_ERROR = 3;

	public static inline var PRESENT_24BPP     = 1;
	public static inline var PRESENT_INTERLACE = 2;
	public static inline var PRESENT_PAL       = 4;

	public static inline function init(title:String):Int
		return BackendNative.bp_init(ConstCharPtr.fromString(title));

	public static inline function shutdown():Void BackendNative.bp_shutdown();
	public static inline function caps(capId:Int):Int return BackendNative.bp_caps(capId);

	public static inline function argCount():Int return BackendNative.bp_arg_count();
	public static inline function arg(i:Int):String return BackendNative.bp_arg(i).toString();

	/** `vram` is the whole 1024x512 halfword buffer; the rectangle selects what to show. */
	public static inline function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void
		BackendNative.bp_present(RawMem.u16Ptr(vram), sx, sy, sw, sh, flags);

	public static inline function audioPush(frames:RawBuf, frameCount:Int):Void
		BackendNative.bp_audio_push(RawMem.s16Ptr(frames), frameCount);

	public static inline function audioBuffered():Int return BackendNative.bp_audio_buffered();

	public static inline function inputPoll():Void BackendNative.bp_input_poll();
	public static inline function padConnected(pad:Int):Bool return BackendNative.bp_pad_connected(pad) != 0;
	public static inline function padType(pad:Int):Int return BackendNative.bp_pad_type(pad);
	public static inline function padButtons(pad:Int):Int return cast BackendNative.bp_pad_buttons(pad);
	public static inline function padAxis(pad:Int, axis:Int):Int return BackendNative.bp_pad_axis(pad, axis);
	public static inline function quitRequested():Bool return BackendNative.bp_quit_requested() != 0;

	public static inline function storageRead(name:String, buf:RawBuf, len:Int):Int
		return BackendNative.bp_storage_read(ConstCharPtr.fromString(name), RawMem.u8Ptr(buf), len);

	public static inline function storageWrite(name:String, buf:RawBuf, len:Int):Int
		return BackendNative.bp_storage_write(ConstCharPtr.fromString(name), RawMem.u8Ptr(buf), len);

	public static inline function fileOpen(slot:Int, path:String):Int
		return BackendNative.bp_file_open(slot, ConstCharPtr.fromString(path));

	public static inline function fileSize(slot:Int):Int return BackendNative.bp_file_size(slot);

	public static inline function fileRead(slot:Int, offset:Int, buf:RawBuf, len:Int):Int
		return BackendNative.bp_file_read(slot, offset, RawMem.u8Ptr(buf), len);

	public static inline function fileClose(slot:Int):Void BackendNative.bp_file_close(slot);

	/** Holds the frame to `targetUs` microseconds since the previous call. Host time never
	    crosses into Haxe — see the note in BackendNative. */
	public static inline function paceFrame(targetUs:Int):Void BackendNative.bp_pace_frame(targetUs);

	public static inline function log(level:Int, msg:String):Void
		BackendNative.bp_log(level, ConstCharPtr.fromString(msg));

	public static inline function fatal(msg:String):Void
		BackendNative.bp_fatal(ConstCharPtr.fromString(msg));
}
