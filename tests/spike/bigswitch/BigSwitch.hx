/**
	Does a wide dispatch switch still find its own labels?

	Reduced from the whole-game failure: the C++ build of a recompiled Crash Bash missed `case 14`
	of a 91-case switch on its very first dispatch, while the identical Haxe was correct on
	JavaScript. Everything above the machine code checked out — one definition, matching header,
	a real `switch` in clang's IR — so this rebuilds the *shape* in isolation: N static functions,
	a switch that calls them by slot, and a caller that asks for one in the middle.

	The functions take a state object and write to it, because the real ones do, and a switch over
	empty bodies is not the same switch after optimisation.
**/
class BigSwitch {
	public static var log = 0;
	static function f0(s:State):Void { s.v = (s.v + 1) | 0; s.hits++; }
	static function f1(s:State):Void { s.v = (s.v + 8) | 0; s.hits++; }
	static function f2(s:State):Void { s.v = (s.v + 15) | 0; s.hits++; }
	static function f3(s:State):Void { s.v = (s.v + 22) | 0; s.hits++; }
	static function f4(s:State):Void { s.v = (s.v + 29) | 0; s.hits++; }
	static function f5(s:State):Void { s.v = (s.v + 36) | 0; s.hits++; }
	static function f6(s:State):Void { s.v = (s.v + 43) | 0; s.hits++; }
	static function f7(s:State):Void { s.v = (s.v + 50) | 0; s.hits++; }
	static function f8(s:State):Void { s.v = (s.v + 57) | 0; s.hits++; }
	static function f9(s:State):Void { s.v = (s.v + 64) | 0; s.hits++; }
	static function f10(s:State):Void { s.v = (s.v + 71) | 0; s.hits++; }
	static function f11(s:State):Void { s.v = (s.v + 78) | 0; s.hits++; }
	static function f12(s:State):Void { s.v = (s.v + 85) | 0; s.hits++; }
	static function f13(s:State):Void { s.v = (s.v + 92) | 0; s.hits++; }
	static function f14(s:State):Void { s.v = (s.v + 99) | 0; s.hits++; }
	static function f15(s:State):Void { s.v = (s.v + 106) | 0; s.hits++; }
	static function f16(s:State):Void { s.v = (s.v + 113) | 0; s.hits++; }
	static function f17(s:State):Void { s.v = (s.v + 120) | 0; s.hits++; }
	static function f18(s:State):Void { s.v = (s.v + 127) | 0; s.hits++; }
	static function f19(s:State):Void { s.v = (s.v + 134) | 0; s.hits++; }
	static function f20(s:State):Void { s.v = (s.v + 141) | 0; s.hits++; }
	static function f21(s:State):Void { s.v = (s.v + 148) | 0; s.hits++; }
	static function f22(s:State):Void { s.v = (s.v + 155) | 0; s.hits++; }
	static function f23(s:State):Void { s.v = (s.v + 162) | 0; s.hits++; }
	static function f24(s:State):Void { s.v = (s.v + 169) | 0; s.hits++; }
	static function f25(s:State):Void { s.v = (s.v + 176) | 0; s.hits++; }
	static function f26(s:State):Void { s.v = (s.v + 183) | 0; s.hits++; }
	static function f27(s:State):Void { s.v = (s.v + 190) | 0; s.hits++; }
	static function f28(s:State):Void { s.v = (s.v + 197) | 0; s.hits++; }
	static function f29(s:State):Void { s.v = (s.v + 204) | 0; s.hits++; }
	static function f30(s:State):Void { s.v = (s.v + 211) | 0; s.hits++; }
	static function f31(s:State):Void { s.v = (s.v + 218) | 0; s.hits++; }
	static function f32(s:State):Void { s.v = (s.v + 225) | 0; s.hits++; }
	static function f33(s:State):Void { s.v = (s.v + 232) | 0; s.hits++; }
	static function f34(s:State):Void { s.v = (s.v + 239) | 0; s.hits++; }
	static function f35(s:State):Void { s.v = (s.v + 246) | 0; s.hits++; }
	static function f36(s:State):Void { s.v = (s.v + 253) | 0; s.hits++; }
	static function f37(s:State):Void { s.v = (s.v + 260) | 0; s.hits++; }
	static function f38(s:State):Void { s.v = (s.v + 267) | 0; s.hits++; }
	static function f39(s:State):Void { s.v = (s.v + 274) | 0; s.hits++; }
	static function f40(s:State):Void { s.v = (s.v + 281) | 0; s.hits++; }
	static function f41(s:State):Void { s.v = (s.v + 288) | 0; s.hits++; }
	static function f42(s:State):Void { s.v = (s.v + 295) | 0; s.hits++; }
	static function f43(s:State):Void { s.v = (s.v + 302) | 0; s.hits++; }
	static function f44(s:State):Void { s.v = (s.v + 309) | 0; s.hits++; }
	static function f45(s:State):Void { s.v = (s.v + 316) | 0; s.hits++; }
	static function f46(s:State):Void { s.v = (s.v + 323) | 0; s.hits++; }
	static function f47(s:State):Void { s.v = (s.v + 330) | 0; s.hits++; }
	static function f48(s:State):Void { s.v = (s.v + 337) | 0; s.hits++; }
	static function f49(s:State):Void { s.v = (s.v + 344) | 0; s.hits++; }
	static function f50(s:State):Void { s.v = (s.v + 351) | 0; s.hits++; }
	static function f51(s:State):Void { s.v = (s.v + 358) | 0; s.hits++; }
	static function f52(s:State):Void { s.v = (s.v + 365) | 0; s.hits++; }
	static function f53(s:State):Void { s.v = (s.v + 372) | 0; s.hits++; }
	static function f54(s:State):Void { s.v = (s.v + 379) | 0; s.hits++; }
	static function f55(s:State):Void { s.v = (s.v + 386) | 0; s.hits++; }
	static function f56(s:State):Void { s.v = (s.v + 393) | 0; s.hits++; }
	static function f57(s:State):Void { s.v = (s.v + 400) | 0; s.hits++; }
	static function f58(s:State):Void { s.v = (s.v + 407) | 0; s.hits++; }
	static function f59(s:State):Void { s.v = (s.v + 414) | 0; s.hits++; }
	static function f60(s:State):Void { s.v = (s.v + 421) | 0; s.hits++; }
	static function f61(s:State):Void { s.v = (s.v + 428) | 0; s.hits++; }
	static function f62(s:State):Void { s.v = (s.v + 435) | 0; s.hits++; }
	static function f63(s:State):Void { s.v = (s.v + 442) | 0; s.hits++; }
	static function f64(s:State):Void { s.v = (s.v + 449) | 0; s.hits++; }
	static function f65(s:State):Void { s.v = (s.v + 456) | 0; s.hits++; }
	static function f66(s:State):Void { s.v = (s.v + 463) | 0; s.hits++; }
	static function f67(s:State):Void { s.v = (s.v + 470) | 0; s.hits++; }
	static function f68(s:State):Void { s.v = (s.v + 477) | 0; s.hits++; }
	static function f69(s:State):Void { s.v = (s.v + 484) | 0; s.hits++; }
	static function f70(s:State):Void { s.v = (s.v + 491) | 0; s.hits++; }
	static function f71(s:State):Void { s.v = (s.v + 498) | 0; s.hits++; }
	static function f72(s:State):Void { s.v = (s.v + 505) | 0; s.hits++; }
	static function f73(s:State):Void { s.v = (s.v + 512) | 0; s.hits++; }
	static function f74(s:State):Void { s.v = (s.v + 519) | 0; s.hits++; }
	static function f75(s:State):Void { s.v = (s.v + 526) | 0; s.hits++; }
	static function f76(s:State):Void { s.v = (s.v + 533) | 0; s.hits++; }
	static function f77(s:State):Void { s.v = (s.v + 540) | 0; s.hits++; }
	static function f78(s:State):Void { s.v = (s.v + 547) | 0; s.hits++; }
	static function f79(s:State):Void { s.v = (s.v + 554) | 0; s.hits++; }
	static function f80(s:State):Void { s.v = (s.v + 561) | 0; s.hits++; }
	static function f81(s:State):Void { s.v = (s.v + 568) | 0; s.hits++; }
	static function f82(s:State):Void { s.v = (s.v + 575) | 0; s.hits++; }
	static function f83(s:State):Void { s.v = (s.v + 582) | 0; s.hits++; }
	static function f84(s:State):Void { s.v = (s.v + 589) | 0; s.hits++; }
	static function f85(s:State):Void { s.v = (s.v + 596) | 0; s.hits++; }
	static function f86(s:State):Void { s.v = (s.v + 603) | 0; s.hits++; }
	static function f87(s:State):Void { s.v = (s.v + 610) | 0; s.hits++; }
	static function f88(s:State):Void { s.v = (s.v + 617) | 0; s.hits++; }
	static function f89(s:State):Void { s.v = (s.v + 624) | 0; s.hits++; }
	static function f90(s:State):Void { s.v = (s.v + 631) | 0; s.hits++; }

	public static function dispatch(slot:Int, s:State):Void {
		switch (slot) {
			case 0: f0(s);
			case 1: f1(s);
			case 2: f2(s);
			case 3: f3(s);
			case 4: f4(s);
			case 5: f5(s);
			case 6: f6(s);
			case 7: f7(s);
			case 8: f8(s);
			case 9: f9(s);
			case 10: f10(s);
			case 11: f11(s);
			case 12: f12(s);
			case 13: f13(s);
			case 14: f14(s);
			case 15: f15(s);
			case 16: f16(s);
			case 17: f17(s);
			case 18: f18(s);
			case 19: f19(s);
			case 20: f20(s);
			case 21: f21(s);
			case 22: f22(s);
			case 23: f23(s);
			case 24: f24(s);
			case 25: f25(s);
			case 26: f26(s);
			case 27: f27(s);
			case 28: f28(s);
			case 29: f29(s);
			case 30: f30(s);
			case 31: f31(s);
			case 32: f32(s);
			case 33: f33(s);
			case 34: f34(s);
			case 35: f35(s);
			case 36: f36(s);
			case 37: f37(s);
			case 38: f38(s);
			case 39: f39(s);
			case 40: f40(s);
			case 41: f41(s);
			case 42: f42(s);
			case 43: f43(s);
			case 44: f44(s);
			case 45: f45(s);
			case 46: f46(s);
			case 47: f47(s);
			case 48: f48(s);
			case 49: f49(s);
			case 50: f50(s);
			case 51: f51(s);
			case 52: f52(s);
			case 53: f53(s);
			case 54: f54(s);
			case 55: f55(s);
			case 56: f56(s);
			case 57: f57(s);
			case 58: f58(s);
			case 59: f59(s);
			case 60: f60(s);
			case 61: f61(s);
			case 62: f62(s);
			case 63: f63(s);
			case 64: f64(s);
			case 65: f65(s);
			case 66: f66(s);
			case 67: f67(s);
			case 68: f68(s);
			case 69: f69(s);
			case 70: f70(s);
			case 71: f71(s);
			case 72: f72(s);
			case 73: f73(s);
			case 74: f74(s);
			case 75: f75(s);
			case 76: f76(s);
			case 77: f77(s);
			case 78: f78(s);
			case 79: f79(s);
			case 80: f80(s);
			case 81: f81(s);
			case 82: f82(s);
			case 83: f83(s);
			case 84: f84(s);
			case 85: f85(s);
			case 86: f86(s);
			case 87: f87(s);
			case 88: f88(s);
			case 89: f89(s);
			case 90: f90(s);
			default: s.missed = slot;
		}
	}

	public static function main():Void {
		final s = new State();
		// Every slot, and the report says which ones the switch could not find.
		var i = 0;
		while (i < 91) { dispatch(i, s); i++; }
		shim.Backend.log(shim.Backend.LOG_INFO, "hits=" + s.hits + " v=" + s.v + " missed=" + s.missed);
		// And the one the game actually asked for first.
		final t = new State();
		dispatch(14, t);
		shim.Backend.log(shim.Backend.LOG_INFO, "slot14 hits=" + t.hits + " v=" + t.v + " missed=" + t.missed);
	}
}

class State {
	public var v = 0;
	public var hits = 0;
	public var missed = -1;
	public function new() {}
}
