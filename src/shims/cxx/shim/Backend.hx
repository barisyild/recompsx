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
	public static inline var PRESENT_FAST      = 8;
	public static inline var PRESENT_DRAWING   = 16;
	public static inline var PRESENT_HOLD      = 32;
	public static inline var PRESENT_WIDE      = 64;
	public static inline var PRESENT_WIDE_FILL = 128;

	public static inline function init(title:String):Int
		return BackendNative.bp_init(ConstCharPtr.fromString(title));

	public static inline function shutdown():Void BackendNative.bp_shutdown();
	public static inline function caps(capId:Int):Int return BackendNative.bp_caps(capId);

	public static inline function argCount():Int return BackendNative.bp_arg_count();
	public static inline function arg(i:Int):String return BackendNative.bp_arg(i).toString();

	/** `vram` is the whole 1024x512 halfword buffer; the rectangle selects what to show. */
	public static inline function present(vram:RawBuf, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void
		BackendNative.bp_present(RawMem.u16Ptr(vram), sx, sy, sw, sh, flags);

	/**
		The hardware-drawing seam. Only reached when the runtime has been told to take it and this
		backend answered `BP_CAP_GPU_DRAW` — see `gpu.Gpu.hw` and ADR-0008.
	**/
	public static inline function gpuVram(vram:RawBuf):Void
		BackendNative.bp_gpu_vram(RawMem.u16Ptr(vram));

	public static inline function gpuState(texBaseX:Int, texBaseY:Int, texDepth:Int,
			clutX:Int, clutY:Int, semiMode:Int, flags:Int, texWindow:Int,
			drawX:Int, drawY:Int):Void
		BackendNative.bp_gpu_state(texBaseX, texBaseY, texDepth, clutX, clutY, semiMode, flags,
			texWindow, drawX, drawY);

	public static inline function gpuTri(x0:Int, y0:Int, c0:Int, u0:Int, v0:Int,
			x1:Int, y1:Int, c1:Int, u1:Int, v1:Int,
			x2:Int, y2:Int, c2:Int, u2:Int, v2:Int):Void
		BackendNative.bp_gpu_tri(x0, y0, c0, u0, v0, x1, y1, c1, u1, v1, x2, y2, c2, u2, v2);

	/** The state the GPU file's words 52-61 hold (the polygon core's, ADR-0047): bp_gpu_state_w. */
	public static inline function gpuStateWords():Void
		GpuFile.backendState();

	/** The triangle the GPU file's words 36-47 hold (gpu.Gpu.triWords): bp_gpu_tri_w. */
	public static inline function gpuTriWords():Void
		GpuFile.backendTri();

	/** The state words 52-61 hold, after the SH-4's polygon core recorded a triangle under the
	    backend's last one (ADR-0051): bp_gpu_state_after_tri. */
	public static inline function gpuStateAfterTri():Void
		GpuFile.backendStateAfterTri();

	public static inline function gpuRect(x:Int, y:Int, w:Int, h:Int, bgr:Int, semi:Int,
			semiMode:Int):Void
		BackendNative.bp_gpu_rect(x, y, w, h, bgr, semi, semiMode);

	public static inline function gpuSprite(x:Int, y:Int, w:Int, h:Int, u:Int, v:Int, bgr:Int,
			flip:Int):Void
		BackendNative.bp_gpu_sprite(x, y, w, h, u, v, bgr, flip);

	public static inline function gpuDirty(x:Int, y:Int, w:Int, h:Int):Void
		BackendNative.bp_gpu_dirty(x, y, w, h);

	public static inline function gpuCopy(sx:Int, sy:Int, dx:Int, dy:Int, w:Int, h:Int, changed:Int):Void
		BackendNative.bp_gpu_copy(sx, sy, dx, dy, w, h, changed);

	public static inline function gpuClip(x0:Int, y0:Int, x1:Int, y1:Int):Void
		BackendNative.bp_gpu_clip(x0, y0, x1, y1);

	public static inline function gpuMask(setBit:Int, checkBit:Int):Void
		BackendNative.bp_gpu_mask(setBit, checkBit);

	public static inline function gpuScale(percent:Int):Void
		BackendNative.bp_gpu_scale(percent);

	public static inline function audioPush(frames:RawBuf, frameCount:Int):Void
		BackendNative.bp_audio_push(RawMem.s16Ptr(frames), frameCount);

	public static inline function audioBuffered():Int return BackendNative.bp_audio_buffered();

	/** Brackets a stretch of the runtime's own work for a backend that times it (the Dreamcast's
	    overlay). One-way: nothing about the host's clock comes back. */
	public static inline var PROFILE_SPU = 0;
	public static inline var PROFILE_GTE = 1;
	public static inline var PROFILE_GPU = 2;
	public static inline function profileMark(section:Int, begin:Int):Void BackendNative.bp_profile_mark(section, begin);

	/** The SPU's voices on a backend's own sampler (BP_CAP_SPU_VOICES); see backend_c_api.h. */
	public static inline function spuRam(ram:RawBuf):Void BackendNative.bp_spu_ram(RawMem.u8Ptr(ram));
	public static inline function spuDirty(addr:Int, len:Int):Void BackendNative.bp_spu_dirty(addr, len);
	public static inline function spuVoice(v:Int, key:Int, on:Int, start:Int, pitch:Int, volL:Int, volR:Int):Int
		return BackendNative.bp_spu_voice(v, key, on, start, pitch, volL, volR);

	/**
		A native host has one thread and nothing to hand it back to, so a suspended program is
		simply resumed until it ends.

		The machinery still compiles and still works here — that is what the forced-yield test
		proves on this target — but nothing in a PC or console build asks for a suspension, so in
		practice this loop runs zero times.
	**/
	public static function driveYields(step:Void -> Bool):Void {
		while (step()) {}
	}

	public static inline function inputPoll():Void BackendNative.bp_input_poll();
	public static inline function padConnected(pad:Int):Bool return BackendNative.bp_pad_connected(pad) != 0;
	public static inline function padType(pad:Int):Int return BackendNative.bp_pad_type(pad);
	public static inline function padButtons(pad:Int):Int return cast BackendNative.bp_pad_buttons(pad);
	public static inline function padAxis(pad:Int, axis:Int):Int return BackendNative.bp_pad_axis(pad, axis);
	public static inline function padRumble(pad:Int, small:Int, large:Int):Void BackendNative.bp_pad_rumble(pad, small, large);
	public static inline function keyText(on:Bool):Void BackendNative.bp_key_text(on ? 1 : 0);
	public static inline function keyNext():Int return BackendNative.bp_key_next();
	public static inline function mouse(field:Int):Int return BackendNative.bp_mouse(field);
	public static inline function mousePointer(state:Int):Void BackendNative.bp_mouse_pointer(state);
	/** HTTP for the i-mode adaptor's phone (backend_c_api.h, ADR-0040). */
	public static inline function httpOpen(host:String, port:Int, request:RawBuf, len:Int):Int
		return BackendNative.bp_http_open(ConstCharPtr.fromString(host), port, RawMem.u8Ptr(request), len);
	public static inline function httpRead(handle:Int, buf:RawBuf, cap:Int):Int
		return BackendNative.bp_http_read(handle, RawMem.u8Ptr(buf), cap);
	public static inline function httpClose(handle:Int):Void BackendNative.bp_http_close(handle);
	public static inline function requestQuit():Void {
		quitting = true;
	}

	static var quitting = false;

	public static inline function quitRequested():Bool return BackendNative.bp_quit_requested() != 0;

	/** The host's own menu (bp_exit_to_menu): the Dreamcast's BIOS menu, the desktop. */
	public static inline function exitToMenu():Void BackendNative.bp_exit_to_menu();

	public static inline function storageRead(name:String, buf:RawBuf, len:Int):Int
		return BackendNative.bp_storage_read(ConstCharPtr.fromString(name), RawMem.u8Ptr(buf), len);

	public static inline function storageWrite(name:String, buf:RawBuf, len:Int):Int
		return BackendNative.bp_storage_write(ConstCharPtr.fromString(name), RawMem.u8Ptr(buf), len);

	/** The game's memory card in the card format (ADR-0037), into `buf`: its length, or -1. */
	public static inline function cardLoad(game:String, buf:RawBuf, cap:Int):Int
		return BackendNative.bp_card_load(ConstCharPtr.fromString(game), RawMem.u8Ptr(buf), cap);

	public static inline function cardSave(game:String, title:String, buf:RawBuf, len:Int):Int
		return BackendNative.bp_card_save(ConstCharPtr.fromString(game), ConstCharPtr.fromString(title),
			RawMem.u8Ptr(buf), len);

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
