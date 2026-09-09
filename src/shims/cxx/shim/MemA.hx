package shim;

import shim.RawBuf;

/**
	Aligned 16/32-bit access — the C++ half of the seam docs/specs/backend.md §4 promised
	("a per-target unaligned-load fast path added later behind a define, once measured").
	It is now measured twice over: 35,581 of these sit inlined in generated code, they are the
	bulk of the hottest emulated function's body, and byte-composing one 32-bit value costs ~10
	fixed-length instructions on SH-4 against one `mov.l`.

	**Callers guarantee alignment, and may only be paths where the emulated machine already
	guarantees it.** MIPS traps misaligned `lw`/`lh` on real hardware, so addresses arriving
	through `Memory`'s fast path are aligned by architecture; kernel HLE structures are
	word-aligned by construction. Anything that walks byte-offset records — Iso9660 directory
	entries above all — stays on `RawMem`'s byte-composed accessors, which tolerate anything.
	On SH-4 a misaligned access through *this* class traps exactly as the original console would
	have, which is the honest behaviour; the JS shim's copy of this class stays byte-composed,
	so the reference target never traps and the digest gate would surface any caller that
	breaks the contract.

	Little-endian direct loads match the byte composition bit for bit, which is why every digest
	must hold across this change. A big-endian target (GameCube/Wii) flips `recompsx_bigendian`
	and gets the byte-composed fallback below — byte order stays a shim concern, never a backend
	one.

	`@:nativeFunctionCode` on an extern is the sanctioned spelling (golden rule 1); every
	placeholder is parenthesised by hand because splicing is textual. The generated C++ needs
	`-fno-strict-aliasing` (set in the CMake template beside `-fwrapv`): emulated memory is
	untyped bytes accessed as bytes, halfwords and words interchangeably, and that flag is the
	standard way to tell a C++ compiler so.
**/
#if recompsx_bigendian
class MemA {
	public static inline function get16(m:RawBuf, a:Int):Int return RawMem.get16(m, a);
	public static inline function get32(m:RawBuf, a:Int):Int return RawMem.get32(m, a);
	public static inline function set16(m:RawBuf, a:Int, v:Int):Void RawMem.set16(m, a, v);
	public static inline function set32(m:RawBuf, a:Int, v:Int):Void RawMem.set32(m, a, v);
}
#else
extern class MemA {
	@:nativeFunctionCode("((int)(*((unsigned short*)(({arg0}) + ({arg1})))))")
	public static function get16(m:RawBuf, a:Int):Int;

	@:nativeFunctionCode("(*((int*)(({arg0}) + ({arg1}))))")
	public static function get32(m:RawBuf, a:Int):Int;

	@:nativeFunctionCode("((void)(*((unsigned short*)(({arg0}) + ({arg1}))) = ((unsigned short)({arg2}))))")
	public static function set16(m:RawBuf, a:Int, v:Int):Void;

	@:nativeFunctionCode("((void)(*((int*)(({arg0}) + ({arg1}))) = ({arg2})))")
	public static function set32(m:RawBuf, a:Int, v:Int):Void;
}
#end
