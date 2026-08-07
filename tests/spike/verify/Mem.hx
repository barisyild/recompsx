package;

import cxx.CArray;
import cxx.Ptr;
import cxx.Stdlib;
import cxx.num.UInt8;
import cxx.num.UInt16;

/**
	The shape `src/runtime/mem/Memory.hx` will actually take.

	Static fields + static inline methods. This is deliberate, not stylistic: reflaxe.CPP emits
	`T& _this = <receiver>;` for every inlined *instance* method call and does not uniquify the
	name, so two such calls in one scope produce "redefinition of '_this'". Static methods have
	no receiver, so no temporary is emitted and the problem cannot occur.

	Generated code performs several memory accesses per MIPS function, so this constraint is
	load-bearing. See PROGRESS.md [M0-VERIFY] #6/#12.
**/
class Mem {
	public static var ram:CArray<UInt8>;
	public static var ramSize:Int = 0;

	public static function alloc(size:Int):Void {
		ram = Stdlib.ccast(Stdlib.malloc(size));
		ramSize = size;
		var i = 0;
		while (i < size) { ram[i] = 0; i++; }
	}

	public static inline function get8(a:Int):Int return ram[a];
	public static inline function set8(a:Int, v:Int):Void ram[a] = v & 0xFF;

	// Endian-neutral by construction: identical bytes on little- and big-endian hosts.
	public static inline function get16(a:Int):Int return get8(a) | (get8(a + 1) << 8);
	public static inline function get32(a:Int):Int
		return get8(a) | (get8(a + 1) << 8) | (get8(a + 2) << 16) | (get8(a + 3) << 24);
	public static inline function set16(a:Int, v:Int):Void { set8(a, v); set8(a + 1, v >>> 8); }
	public static inline function set32(a:Int, v:Int):Void {
		set8(a, v); set8(a + 1, v >>> 8); set8(a + 2, v >>> 16); set8(a + 3, v >>> 24);
	}

	public static inline function u8Ptr(offset:Int):Ptr<UInt8> return ram.toPtr();
	public static inline function u16Ptr(offset:Int):Ptr<UInt16> return Stdlib.ccast(ram.toPtr());
}
