package shim;

/**
	The emulated machine's memories as link-time arrays (see `src/shims/cxx/native/
	recompsx_arena.h`, which this target shares).
**/
@:include("<recompsx_hatchet.h>")
extern class Arena {
	public static function ram():RawBuf;
	public static function scratch():RawBuf;
}
