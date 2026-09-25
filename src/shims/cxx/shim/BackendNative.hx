package shim;

import cxx.Ptr;
import cxx.ConstCharPtr;
import cxx.num.UInt8;
import cxx.num.UInt16;
import cxx.num.Int16;
import cxx.num.UInt32;

/**
	One extern per function in `src/backend/api/backend_c_api.h`. Nothing else in the project
	touches the C boundary; the runtime goes through `shim.Backend`.

	The ABI is deliberately flat — pointers and plain ints only, no structs — so this file needs
	no agreement about type layout between Haxe and C, which is exactly the kind of assumption
	that would be expensive to get wrong on a console toolchain we cannot debug easily.
**/
@:include("backend_c_api.h") @:topLevel extern function bp_init(title:ConstCharPtr):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_shutdown():Void;
@:include("backend_c_api.h") @:topLevel extern function bp_caps(capId:Int):Int;

@:include("backend_c_api.h") @:topLevel extern function bp_arg_count():Int;
@:include("backend_c_api.h") @:topLevel extern function bp_arg(index:Int):ConstCharPtr;

@:include("backend_c_api.h") @:topLevel
extern function bp_present(vram:Ptr<UInt16>, sx:Int, sy:Int, sw:Int, sh:Int, flags:Int):Void;

@:include("backend_c_api.h") @:topLevel extern function bp_gpu_vram(vram:Ptr<UInt16>):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_state(texBaseX:Int, texBaseY:Int, texDepth:Int, clutX:Int, clutY:Int,
	semiMode:Int, flags:Int, texWindow:Int, drawX:Int, drawY:Int):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_tri(x0:Int, y0:Int, c0:Int, u0:Int, v0:Int,
	x1:Int, y1:Int, c1:Int, u1:Int, v1:Int,
	x2:Int, y2:Int, c2:Int, u2:Int, v2:Int):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_rect(x:Int, y:Int, w:Int, h:Int, bgr:Int, semi:Int, semiMode:Int):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_dirty(x:Int, y:Int, w:Int, h:Int):Void;

// Metadata binds to the one declaration after it: without their own `@:topLevel` these two were
// emitted as members of the module's field class, and the C++ build stopped at gpu_Gpu.cpp.
@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_clip(x0:Int, y0:Int, x1:Int, y1:Int):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_gpu_mask(setBit:Int, checkBit:Int):Void;

@:include("backend_c_api.h") @:topLevel
extern function bp_audio_push(frames:Ptr<Int16>, frameCount:Int):Void;
@:include("backend_c_api.h") @:topLevel extern function bp_audio_buffered():Int;

@:include("backend_c_api.h") @:topLevel extern function bp_input_poll():Void;
@:include("backend_c_api.h") @:topLevel extern function bp_pad_connected(pad:Int):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_pad_type(pad:Int):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_pad_buttons(pad:Int):UInt32;
@:include("backend_c_api.h") @:topLevel extern function bp_pad_axis(pad:Int, axis:Int):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_quit_requested():Int;

@:include("backend_c_api.h") @:topLevel
extern function bp_storage_read(name:ConstCharPtr, buf:Ptr<UInt8>, len:Int):Int;
@:include("backend_c_api.h") @:topLevel
extern function bp_storage_write(name:ConstCharPtr, buf:Ptr<UInt8>, len:Int):Int;

@:include("backend_c_api.h") @:topLevel extern function bp_file_open(slot:Int, path:ConstCharPtr):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_file_size(slot:Int):Int;
@:include("backend_c_api.h") @:topLevel
extern function bp_file_read(slot:Int, offset:Int, buf:Ptr<UInt8>, len:Int):Int;
@:include("backend_c_api.h") @:topLevel extern function bp_file_close(slot:Int):Void;

// bp_time_us / bp_sleep_us are deliberately NOT bound here. Host time must have no path into
// Haxe at all; pacing is expressed as "hold this frame to N microseconds" and executed entirely
// on the C side, which also spares us 64-bit clock arithmetic in the portable subset.
@:include("backend_c_api.h") @:topLevel extern function bp_pace_frame(targetUs:Int):Void;
@:include("backend_c_api.h") @:topLevel extern function bp_profile_mark(section:Int, begin:Int):Void;
@:include("backend_c_api.h") @:topLevel extern function bp_log(level:Int, msg:ConstCharPtr):Void;
@:include("backend_c_api.h") @:topLevel extern function bp_fatal(msg:ConstCharPtr):Void;
