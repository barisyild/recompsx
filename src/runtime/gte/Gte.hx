package gte;

import core.CpuState;
import core.Runtime;
import shim.I64;
import shim.IntMath;
import shim.Acc;
import shim.Backend;
import shim.MemA;
import shim.RawBuf;
import shim.RawMem;

/**
	The Geometry Transformation Engine — coprocessor 2, and the reason PlayStation games have
	3D at all.

	It is a fixed-point vector unit: matrix transforms, perspective division, lighting and colour,
	all in integers. Every 3D game leans on it heavily, and its results have to be bit-exact
	because games feed them straight into geometry that is then depth-sorted — a value off by one
	changes which polygon is drawn in front.

	The register file is **named static fields, not an array**, for the same reason `CpuState` is:
	every access is at a constant index (the emitter bakes it in), so a switch over constants
	compiles to a direct field access, while an array would be an indexed load the compiler cannot
	keep in a machine register. Matrices are stored unpacked — nine signed halfwords rather than
	five packed words — because every operation reads them element by element and only the rare
	`CFC2` needs them packed again.

	Accumulation happens in `shim.I64`, because the hardware's MAC registers are 44 bits wide and
	the overflow flags are defined on the *intermediate* value after each multiply-add. Truncation
	to 44 bits after each step is not an approximation of the hardware; it is what the hardware
	does, and a game reads the flags.

	Semantics are `docs/specs/runtime.md` §5, which is normative and was written from psx-spx. The
	acceptance gate is `tests/conformance/GteOps.hx` on both targets, and eventually amidog's
	`psxtest_gte`, which checks values *and* flag bits for every operation.
**/
class Gte {
	// ---- the data registers ----------------------------------------------------------------------
	//
	// Stored in the form operations want them, so that reading one back is a plain return: vectors
	// keep their packed word because that is what `MFC2` hands over, and the components are
	// extracted where they are used.

	static var vxy0 = 0; static var vz0 = 0;
	static var vxy1 = 0; static var vz1 = 0;
	static var vxy2 = 0; static var vz2 = 0;

	/** Colour and the "code" byte a game keeps its own meaning in. */
	static var rgbc = 0;

	static var otz = 0;

	static var ir0 = 0; static var ir1 = 0; static var ir2 = 0; static var ir3 = 0;

	/** The screen-coordinate FIFO: three deep, oldest first. */
	static var sxy0 = 0; static var sxy1 = 0; static var sxy2 = 0;

	/** The depth FIFO, four deep. */
	static var sz0 = 0; static var sz1 = 0; static var sz2 = 0; static var sz3 = 0;

	/** The colour FIFO, three deep. */
	static var rgb0 = 0; static var rgb1 = 0; static var rgb2 = 0;

	/** Scratch, with no meaning to the hardware — but it stores and reads back. */
	static var res1 = 0;

	static var mac0 = 0; static var mac1 = 0; static var mac2 = 0; static var mac3 = 0;

	static var lzcs = 0; static var lzcr = 32;

	// ---- the control registers -------------------------------------------------------------------

	// Rotation matrix, unpacked.
	static var rt11 = 0; static var rt12 = 0; static var rt13 = 0;
	static var rt21 = 0; static var rt22 = 0; static var rt23 = 0;
	static var rt31 = 0; static var rt32 = 0; static var rt33 = 0;
	static var trX = 0; static var trY = 0; static var trZ = 0;

	// Light-source matrix.
	static var l11 = 0; static var l12 = 0; static var l13 = 0;
	static var l21 = 0; static var l22 = 0; static var l23 = 0;
	static var l31 = 0; static var l32 = 0; static var l33 = 0;
	static var rbk = 0; static var gbk = 0; static var bbk = 0;

	// Light-colour matrix.
	static var lr1 = 0; static var lr2 = 0; static var lr3 = 0;
	static var lg1 = 0; static var lg2 = 0; static var lg3 = 0;
	static var lb1 = 0; static var lb2 = 0; static var lb3 = 0;
	static var rfc = 0; static var gfc = 0; static var bfc = 0;

	static var ofx = 0; static var ofy = 0;

	/**
		The projection plane distance.

		Stored sign-extended and read back that way, which is a hardware bug faithfully reproduced:
		`H` is an unsigned 16-bit value everywhere it is *used*, but `CFC2` returns it
		sign-extended, so a game that writes 0x8000 and reads it back sees 0xFFFF8000. Games have
		been written against that.
	**/
	static var h = 0;

	static var dqa = 0; static var dqb = 0;
	static var zsf3 = 0; static var zsf4 = 0;

	static var flag = 0;

	// ---- FLAG bits, docs/specs/runtime.md §5 -------------------------------------------------------

	static inline var F_MAC1_POS = 30;
	static inline var F_MAC2_POS = 29;
	static inline var F_MAC3_POS = 28;
	static inline var F_MAC1_NEG = 27;
	static inline var F_MAC2_NEG = 26;
	static inline var F_MAC3_NEG = 25;
	static inline var F_IR1 = 24;
	static inline var F_IR2 = 23;
	static inline var F_IR3 = 22;
	static inline var F_COLOR_R = 21;
	static inline var F_COLOR_G = 20;
	static inline var F_COLOR_B = 19;
	static inline var F_SZ3 = 18;
	static inline var F_DIVIDE = 17;
	static inline var F_MAC0_POS = 16;
	static inline var F_MAC0_NEG = 15;
	static inline var F_SX2 = 14;
	static inline var F_SY2 = 13;
	static inline var F_IR0 = 12;

	/** Bit 31 is the OR of the bits the hardware calls errors — not of every bit in the word. */
	static inline var F_ERROR_MASK = 0x7F87E000;

	public static function init():Void {
		vxy0 = 0; vz0 = 0; vxy1 = 0; vz1 = 0; vxy2 = 0; vz2 = 0;
		rgbc = 0; otz = 0;
		ir0 = 0; ir1 = 0; ir2 = 0; ir3 = 0;
		sxy0 = 0; sxy1 = 0; sxy2 = 0;
		sz0 = 0; sz1 = 0; sz2 = 0; sz3 = 0;
		rgb0 = 0; rgb1 = 0; rgb2 = 0;
		res1 = 0;
		mac0 = 0; mac1 = 0; mac2 = 0; mac3 = 0;
		lzcs = 0; lzcr = 32;
		rt11 = 0; rt12 = 0; rt13 = 0; rt21 = 0; rt22 = 0; rt23 = 0; rt31 = 0; rt32 = 0; rt33 = 0;
		trX = 0; trY = 0; trZ = 0;
		l11 = 0; l12 = 0; l13 = 0; l21 = 0; l22 = 0; l23 = 0; l31 = 0; l32 = 0; l33 = 0;
		rbk = 0; gbk = 0; bbk = 0;
		lr1 = 0; lr2 = 0; lr3 = 0; lg1 = 0; lg2 = 0; lg3 = 0; lb1 = 0; lb2 = 0; lb3 = 0;
		rfc = 0; gfc = 0; bfc = 0;
		ofx = 0; ofy = 0; h = 0; dqa = 0; dqb = 0; zsf3 = 0; zsf4 = 0;
		flag = 0;
		buildUnrTable();
		buildClzTable();
	}

	// ---- data register access ----------------------------------------------------------------------

	public static inline function getData(ctx:CpuState, reg:Int):Int {
		return switch (reg) {
			case 0: vxy0;
			case 1: vz0;
			case 2: vxy1;
			case 3: vz1;
			case 4: vxy2;
			case 5: vz2;
			case 6: rgbc;
			case 7: otz & 0xFFFF;
			case 8: ir0;
			case 9: ir1;
			case 10: ir2;
			case 11: ir3;
			case 12: sxy0;
			case 13: sxy1;
			case 14: sxy2;
			// Reading the FIFO's mirror does not pop it. Only a *write* moves the queue along,
			// which is why the emitter dropping `mfc2 $zero, $15` costs nothing.
			case 15: sxy2;
			case 16: sz0 & 0xFFFF;
			case 17: sz1 & 0xFFFF;
			case 18: sz2 & 0xFFFF;
			case 19: sz3 & 0xFFFF;
			case 20: rgb0;
			case 21: rgb1;
			case 22: rgb2;
			case 23: res1;
			case 24: mac0;
			case 25: mac1;
			case 26: mac2;
			case 27: mac3;
			case 28: orgb();
			case 29: orgb();
			case 30: lzcs;
			case 31: lzcr;
			case _: 0;
		}
	}

	public static inline function setData(ctx:CpuState, reg:Int, value:Int):Void {
		switch (reg) {
			case 0: vxy0 = value;
			case 1: vz0 = sext16(value);
			case 2: vxy1 = value;
			case 3: vz1 = sext16(value);
			case 4: vxy2 = value;
			case 5: vz2 = sext16(value);
			case 6: rgbc = value;
			case 7: otz = value & 0xFFFF;
			case 8: ir0 = sext16(value);
			case 9: ir1 = sext16(value);
			case 10: ir2 = sext16(value);
			case 11: ir3 = sext16(value);
			case 12: sxy0 = value;
			case 13: sxy1 = value;
			case 14: sxy2 = value;
			// Writing the mirror pushes the queue: this is how a game feeds three projected
			// vertices in and reads them back as a triangle.
			case 15: pushSxy(value);
			case 16: sz0 = value & 0xFFFF;
			case 17: sz1 = value & 0xFFFF;
			case 18: sz2 = value & 0xFFFF;
			case 19: sz3 = value & 0xFFFF;
			case 20: rgb0 = value;
			case 21: rgb1 = value;
			case 22: rgb2 = value;
			case 23: res1 = value;
			case 24: mac0 = value;
			case 25: mac1 = value;
			case 26: mac2 = value;
			case 27: mac3 = value;
			// Writing the packed colour spreads it back over the three IR registers, scaled by
			// 0x80 — the inverse of how `orgb` reads them.
			case 28: setIrgb(value);
			case 29: {}   // read-only: the hardware ignores this write
			case 30: setLzcs(value);
			case 31: {}   // read-only: LZCR is whatever counting LZCS produced
			case _: {}
		}
	}

	static function pushSxy(value:Int):Void {
		sxy0 = sxy1;
		sxy1 = sxy2;
		sxy2 = value;
	}

	/** The three IR registers as five bits each, which is what a game hands the GPU. */
	static function orgb():Int {
		return clamp5(ir1 >> 7) | (clamp5(ir2 >> 7) << 5) | (clamp5(ir3 >> 7) << 10);
	}

	static inline function clamp5(v:Int):Int {
		return v < 0 ? 0 : (v > 0x1F ? 0x1F : v);
	}

	static function setIrgb(value:Int):Void {
		ir1 = (value & 0x1F) * 0x80;
		ir2 = ((value >> 5) & 0x1F) * 0x80;
		ir3 = ((value >> 10) & 0x1F) * 0x80;
	}

	/**
		Counts the leading bits that match the sign — ones for a negative value, zeroes otherwise.

		A game uses it to normalise a fixed-point number before dividing, and both extremes answer
		32: all zeroes and all ones are equally uniform.
	**/
	static function setLzcs(value:Int):Void {
		lzcs = value;
		final bits = value < 0 ? ~value : value;
		var n = 0;
		var probe = 0x80000000;
		while (n < 32 && (bits & probe) == 0) {
			n++;
			probe = probe >>> 1;
		}
		lzcr = n;
	}

	// ---- control register access ---------------------------------------------------------------------

	public static inline function getCtrl(ctx:CpuState, reg:Int):Int {
		return switch (reg) {
			case 0: pack(rt11, rt12);
			case 1: pack(rt13, rt21);
			case 2: pack(rt22, rt23);
			case 3: pack(rt31, rt32);
			case 4: rt33;
			case 5: trX;
			case 6: trY;
			case 7: trZ;
			case 8: pack(l11, l12);
			case 9: pack(l13, l21);
			case 10: pack(l22, l23);
			case 11: pack(l31, l32);
			case 12: l33;
			case 13: rbk;
			case 14: gbk;
			case 15: bbk;
			case 16: pack(lr1, lr2);
			case 17: pack(lr3, lg1);
			case 18: pack(lg2, lg3);
			case 19: pack(lb1, lb2);
			case 20: lb3;
			case 21: rfc;
			case 22: gfc;
			case 23: bfc;
			case 24: ofx;
			case 25: ofy;
			// Sign-extended on the way out, which is the hardware bug this reproduces.
			case 26: h;
			case 27: dqa;
			case 28: dqb;
			case 29: zsf3;
			case 30: zsf4;
			case 31: flagRead();
			case _: 0;
		}
	}

	public static inline function setCtrl(ctx:CpuState, reg:Int, value:Int):Void {
		switch (reg) {
			case 0: { rt11 = lowOf(value); rt12 = highOf(value); }
			case 1: { rt13 = lowOf(value); rt21 = highOf(value); }
			case 2: { rt22 = lowOf(value); rt23 = highOf(value); }
			case 3: { rt31 = lowOf(value); rt32 = highOf(value); }
			case 4: rt33 = sext16(value);
			case 5: trX = value;
			case 6: trY = value;
			case 7: trZ = value;
			case 8: { l11 = lowOf(value); l12 = highOf(value); }
			case 9: { l13 = lowOf(value); l21 = highOf(value); }
			case 10: { l22 = lowOf(value); l23 = highOf(value); }
			case 11: { l31 = lowOf(value); l32 = highOf(value); }
			case 12: l33 = sext16(value);
			case 13: rbk = value;
			case 14: gbk = value;
			case 15: bbk = value;
			case 16: { lr1 = lowOf(value); lr2 = highOf(value); }
			case 17: { lr3 = lowOf(value); lg1 = highOf(value); }
			case 18: { lg2 = lowOf(value); lg3 = highOf(value); }
			case 19: { lb1 = lowOf(value); lb2 = highOf(value); }
			case 20: lb3 = sext16(value);
			case 21: rfc = value;
			case 22: gfc = value;
			case 23: bfc = value;
			case 24: ofx = value;
			case 25: ofy = value;
			case 26: h = sext16(value);
			case 27: dqa = sext16(value);
			case 28: dqb = value;
			case 29: zsf3 = sext16(value);
			case 30: zsf4 = sext16(value);
			case 31: flag = value & 0x7FFFF000;
			case _: {}
		}
	}

	static inline function pack(lo:Int, hi:Int):Int {
		return (lo & 0xFFFF) | (hi << 16);
	}

	static inline function lowOf(v:Int):Int {
		return sext16(v);
	}

	static inline function highOf(v:Int):Int {
		return v >> 16;
	}

	static inline function sext16(v:Int):Int {
		return (v << 16) >> 16;
	}

	/** Bit 31 is computed, never stored: it is the OR of the bits the hardware calls errors. */
	static function flagRead():Int {
		return (flag & F_ERROR_MASK) != 0 ? flag | 0x80000000 : flag;
	}

	// ---- the division ------------------------------------------------------------------------------

	/**
		The reciprocal table the hardware's Newton-Raphson step starts from.

		257 entries, built once at init from the formula in the spec. Allocation at init is allowed
		and this is the only place the GTE does any; every other value it touches is a static Int.
	**/
	static var unrTable:RawBuf;

	static function buildUnrTable():Void {
		// Built unconditionally, not behind `if (unrTable != null)`.
		//
		// `Array<Int>` is not a nullable type, so that comparison is not a question both targets
		// answer the same way: JavaScript sees the field's initial `null` and builds the table,
		// while the C++ side folds the check away and returns immediately — leaving every
		// division to dereference nothing. It cost a segmentation fault that JavaScript could not
		// reproduce, which is exactly the divergence the two-target gate exists to catch. `init`
		// runs once, so there is nothing to guard against anyway.
		//
		// A flat buffer, not an `Array<Int>`: on C++ that is a `shared_ptr` to a `vector`, three
		// dependent loads for an entry on every perspective divide where this is two.
		unrTable = RawMem.alloc(257 << 2);
		for (i in 0...257) {
			final v = shim.IntMath.div(shim.IntMath.div(0x40000, i + 0x100) + 1, 2) - 0x101;
			MemA.set32(unrTable, i << 2, v < 0 ? 0 : v);
		}
	}

	/**
		`H / SZ3`, the way the hardware does it — approximately, and identically every time.

		A real divider would have cost transistors, so the GTE normalises the divisor, looks up a
		reciprocal, refines it with one Newton-Raphson step and multiplies. The result is not
		always the true quotient, and games are calibrated against the error, so reproducing the
		*algorithm* matters more than reproducing the arithmetic it approximates.

		A divisor at most half the dividend cannot be normalised into range, and the hardware
		answers 0x1FFFF with the overflow flag rather than a wrong number.

		Forced inline on C++: as a call it sat in the middle of every vertex of RTPT, and a call is
		a point after which the compiler must read the whole matrix again.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function unrDivide():Int {
		final divisor = sz3 & 0xFFFF;
		final dividend = h & 0xFFFF;
		if (divisor * 2 <= dividend) return divideOverflow();
		else {}

		final shift = countLeadingZeros16(divisor);
		var n = (dividend << shift) | 0;
		var d = (divisor << shift) & 0xFFFF;
		final u = MemA.get32(unrTable, ((d - 0x7FC0) >> 7) << 2) + 0x101;
		d = (0x2000080 - shim.IntMath.mul(d, u)) >> 8;
		d = (0x0000080 + shim.IntMath.mul(d, u)) >> 8;
		final q = I64.mulShr16Round(n, d);
		return q > 0x1FFFF ? 0x1FFFF : q;
	}

	static function divideOverflow():Int {
		flag |= (1 << F_DIVIDE);
		return 0x1FFFF;
	}

	/** Leading zeros of a byte, 8 for zero: the table countLeadingZeros16 reads. Flat, as
	    `unrTable` is. */
	static var clz8:RawBuf;

	static function buildClzTable():Void {
		clz8 = RawMem.alloc(256 << 2);
		for (i in 0...256) {
			var n = 8;
			var v = i;
			while (v != 0) {
				n--;
				v = v >> 1;
			}
			MemA.set32(clz8, i << 2, n);
		}
	}

	/**
		Leading zeros of a 16-bit value, 16 for zero — how far the divisor must shift left before
		its top bit is set, on every perspective divide.

		A table rather than `IntMath.clz32`: a count-leading-zeros instruction is what that
		becomes on most CPUs, but the SH-4 has none, and there it was a call into libgcc's
		`__clzsi2` from the middle of every RTPS, with the caller's registers saved around it.
		Two bytes, one lookup, the same answer everywhere.
	**/
	static inline function countLeadingZeros16(v:Int):Int {
		final x = v & 0xFFFF;
		final hi = x >>> 8;
		return hi != 0 ? MemA.get32(clz8, hi << 2) : 8 + MemA.get32(clz8, x << 2);
	}

	// ---- executing ------------------------------------------------------------------------------------

	/** Executes a COP2 command. `imm25` carries the operation and its sf/lm/MVMVA fields. */
	/**
		Direct entries for the recompiler. A GTE command word is a constant in the guest code,
		so the emitter decodes it at build time and calls the operation by name, skipping the
		decode and the dispatch chain `execute` walks for a word it first sees at run time —
		which the browser profile had at six percent of a frame on its own. Each entry does
		exactly what `execute` does for its opcode, the flag reset included. `execute` stays
		for words the emitter does not recognise and for the fixtures.
	**/
	public static function cmdRtps(sf:Int, lm:Bool):Void { enter(); rtps(sf, lm, 0, true); leave(); }
	public static function cmdRtpt(sf:Int, lm:Bool):Void { enter(); rtpt(sf, lm); leave(); }
	public static function cmdNclip():Void { enter(); nclip(); leave(); }
	public static function cmdAvsz3():Void { enter(); avsz3(); leave(); }
	public static function cmdAvsz4():Void { enter(); avsz4(); leave(); }
	public static function cmdMvmva(sf:Int, lm:Bool, imm25:Int):Void { enter(); mvmva(sf, lm, imm25); leave(); }
	public static function cmdSqr(sf:Int):Void { enter(); sqr(sf); leave(); }
	public static function cmdOp(sf:Int, lm:Bool):Void { enter(); crossProduct(sf, lm); leave(); }
	public static function cmdGpf(sf:Int, lm:Bool):Void { enter(); gpf(sf, lm); leave(); }
	public static function cmdGpl(sf:Int, lm:Bool):Void { enter(); gpl(sf, lm); leave(); }
	public static function cmdDpcs(sf:Int, lm:Bool):Void { enter(); dpcs(sf, lm); leave(); }
	public static function cmdDpct(sf:Int, lm:Bool):Void { enter(); dpct(sf, lm); leave(); }
	public static function cmdIntpl(sf:Int, lm:Bool):Void { enter(); intpl(sf, lm); leave(); }
	public static function cmdDcpl(sf:Int, lm:Bool):Void { enter(); dcpl(sf, lm); leave(); }
	public static function cmdNcs(sf:Int, lm:Bool):Void { enter(); ncs(sf, lm, 0); leave(); }
	public static function cmdNct(sf:Int, lm:Bool):Void { enter(); ncTriple(sf, lm, 0); leave(); }
	public static function cmdNcds(sf:Int, lm:Bool):Void { enter(); ncds(sf, lm, 0); leave(); }
	public static function cmdNcdt(sf:Int, lm:Bool):Void { enter(); ncTriple(sf, lm, 1); leave(); }
	public static function cmdNccs(sf:Int, lm:Bool):Void { enter(); nccs(sf, lm, 0); leave(); }
	public static function cmdNcct(sf:Int, lm:Bool):Void { enter(); ncTriple(sf, lm, 2); leave(); }
	public static function cmdCc(sf:Int, lm:Bool):Void { enter(); cc(sf, lm); leave(); }
	public static function cmdCdp(sf:Int, lm:Bool):Void { enter(); cdp(sf, lm); leave(); }

	public static function execute(ctx:CpuState, imm25:Int):Void {
		enter();
		final op = imm25 & 0x3F;
		final sf = (imm25 & 0x80000) != 0 ? 12 : 0;
		final lm = (imm25 & 0x400) != 0;
		if (op == 0x01) rtps(sf, lm, 0, true);
		else if (op == 0x30) rtpt(sf, lm);
		else if (op == 0x06) nclip();
		else if (op == 0x2D) avsz3();
		else if (op == 0x2E) avsz4();
		else if (op == 0x12) mvmva(sf, lm, imm25);
		else if (op == 0x28) sqr(sf);
		else if (op == 0x0C) crossProduct(sf, lm);
		else if (op == 0x3D) gpf(sf, lm);
		else if (op == 0x3E) gpl(sf, lm);
		else if (op == 0x10) dpcs(sf, lm);
		else if (op == 0x2A) dpct(sf, lm);
		else if (op == 0x11) intpl(sf, lm);
		else if (op == 0x29) dcpl(sf, lm);
		else if (op == 0x1E) ncs(sf, lm, 0);
		else if (op == 0x20) ncTriple(sf, lm, 0);
		else if (op == 0x13) ncds(sf, lm, 0);
		else if (op == 0x16) ncTriple(sf, lm, 1);
		else if (op == 0x1B) nccs(sf, lm, 0);
		else if (op == 0x3F) ncTriple(sf, lm, 2);
		else if (op == 0x1C) cc(sf, lm);
		else if (op == 0x14) cdp(sf, lm);
		else unimplementedOp(op);
		leave();
	}

	/**
		Every command starts with FLAG cleared, and is bracketed for a backend that shows where a
		frame goes (the Dreamcast's overlay). There are thousands a frame, so that backend samples
		rather than times them. One-way markers: nothing about the host comes back.
	**/
	static inline function enter():Void {
		Backend.profileMark(Backend.PROFILE_GTE, 1);
		flag = 0;
	}

	static inline function leave():Void {
		Backend.profileMark(Backend.PROFILE_GTE, 0);
	}

	static function unimplementedOp(op:Int):Void {
		Runtime.reportOnce(0x70000000 | op, "GTE operation 0x" + hex2(op) + " is not implemented");
	}

	static function hex2(v:Int):String {
		final d = "0123456789abcdef";
		return d.charAt((v >> 4) & 0xF) + d.charAt(v & 0xF);
	}

	// ---- the operations ---------------------------------------------------------------------------------

	/**
		Rotate, translate and perspective-transform one vertex.

		The workhorse: every visible polygon in every 3D PlayStation game passes through here. Three
		matrix rows produce a camera-space point, the third component becomes a depth value, and the
		perspective divide turns the first two into screen coordinates.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function rtps(sf:Int, lm:Bool, v:Int, last:Bool):Void {
		project(sf, lm, vecX(v), vecY(v), vecZ(v), last);
	}

	/**
		The same transform for all three vertices; only the last one sets the depth-cue outputs.

		On C++ `project` is forced inline here, which is where the time goes — RTPT is most of a
		frame's vertices. The three copies then share one read of the matrix and the translation,
		and the first two vertices' MAC and IR stores, which the third overwrites before anything
		reads them, are dropped by the compiler.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function rtpt(sf:Int, lm:Bool):Void {
		project(sf, lm, sext16(vxy0), vxy0 >> 16, vz0, false);
		project(sf, lm, sext16(vxy1), vxy1 >> 16, vz1, false);
		project(sf, lm, sext16(vxy2), vxy2 >> 16, vz2, true);
	}

	/**
		One vertex of RTPS/RTPT: MAC1-3 and IR1-3, SZ3 and SX2/SY2 pushed, MAC0, and with `last`
		the depth cue.

		Two exact 32-bit forms carry nearly every vertex a game sends; where the premise of one
		fails, the general form runs instead, out of line (`rowsWide`, `screenWide`).

		- **A matrix row is one sum.** The matrix and the vector are sixteen-bit signed, so each
		  product fits in 32 bits. With every vector component within +-2^14 a product is within
		  2^29 and a row's three within 2^31, so their plain sum is exact; with the translation
		  within +-2^30 no partial sum can reach 44 bits (see row44Checked), so no flag is lost.
		  MAC is then TR + (sum >> 12) at sf = 1 — TR << 12 is a multiple of 4096 — and the low
		  word of (TR << 12) + sum at sf = 0. Crash Bandicoot: Warped sends 2,044 of 687,068
		  vertices wider than that (vblanks 4700-5000), Crash Bash none of 2.5 million.
		- **SX2, SY2 and MAC0 are one multiply-add.** A quotient within 16 bits times a saturated IR
		  is within 2^31, and a sum that does not overflow 32 bits *is* MAC0, with no flag to
		  raise. The quotient is wider for 1.3 % (Crash 3) and 3.3 % (Crash Bash) of vertices.

		On the SH-4 the general forms were most of the transform: a row was a shift, a mask and a
		carry per product, a screen coordinate a 64-bit multiply, a carry chain, a five-way range
		check and a double-word shift.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function project(sf:Int, lm:Bool, vx:Int, vy:Int, vz:Int, last:Bool):Void {
		final tx = trX, ty = trY, tz = trZ;
		var mac3Shifted = 0;
		// Each `v + 0x4000` is within 0..0x7FFF exactly when v is within -0x4000..0x3FFF, each
		// `t + 0x40000000` is non-negative exactly when t is within -2^30..2^30-1: one test each.
		if ((((vx + 0x4000) | (vy + 0x4000) | (vz + 0x4000)) >>> 15) == 0
				&& (((tx + 0x40000000) | (ty + 0x40000000) | (tz + 0x40000000)) >= 0)) {
			final r1 = (IntMath.mul(rt11, vx) + IntMath.mul(rt12, vy) + IntMath.mul(rt13, vz)) | 0;
			final r2 = (IntMath.mul(rt21, vx) + IntMath.mul(rt22, vy) + IntMath.mul(rt23, vz)) | 0;
			final r3 = (IntMath.mul(rt31, vx) + IntMath.mul(rt32, vy) + IntMath.mul(rt33, vz)) | 0;
			// The depth value is always the >>12 form, whatever `sf` says — and IR3's saturation
			// flag is judged from *that*, not from the stored MAC3. Only visible at sf=0, and games
			// rely on it. psx-spx records the same quirk.
			mac3Shifted = tz + (r3 >> 12);
			if (sf == 0) {
				mac1 = ((tx << 12) + r1) | 0;
				mac2 = ((ty << 12) + r2) | 0;
				mac3 = ((tz << 12) + r3) | 0;
			} else {
				mac1 = tx + (r1 >> 12);
				mac2 = ty + (r2 >> 12);
				mac3 = mac3Shifted;
			}
		} else {
			mac3Shifted = rowsWide(sf, vx, vy, vz);
		}

		ir1 = saturateIr(mac1, lm, F_IR1);
		ir2 = saturateIr(mac2, lm, F_IR2);
		ir3 = saturateIr3(mac3, mac3Shifted, lm);

		pushSz(saturateSz3(mac3Shifted));

		final n = unrDivide();
		final px = IntMath.mul(ir1, n);
		final py = IntMath.mul(ir2, n);
		final sx = (ofx + px) | 0;
		final sy = (ofy + py) | 0;
		// A sum overflowed exactly when both addends share a sign the result does not.
		if (n <= 0xFFFF && (((ofx ^ sx) & (px ^ sx)) | ((ofy ^ sy) & (py ^ sy))) >= 0) {
			mac0 = sy;
			pushSxy(pack(saturateSxy(sx >> 16, F_SX2), saturateSxy(sy >> 16, F_SY2)));
		} else {
			screenWide(n);
		}

		if (last) depthCueing(n);
		else {}
	}

	/**
		MAC1-3 for a vertex outside project's premise, answering the >>12 form of MAC3: in 32 bits
		by rowShr12 while every translation is within 2^30, which holds any vector, and otherwise
		through the 44-bit accumulator with its flags. Out of line on C++: it is rare, and inlined
		it made each of RTPT's three vertices carry both forms.
	**/
	@:specifier("__attribute__((noinline))")
	static function rowsWide(sf:Int, vx:Int, vy:Int, vz:Int):Int {
		final tx = trX, ty = trY, tz = trZ;
		var mac3Shifted = 0;
		if (tx > -0x40000000 && tx < 0x40000000 && ty > -0x40000000 && ty < 0x40000000
				&& tz > -0x40000000 && tz < 0x40000000) {
			final a1 = IntMath.mul(rt11, vx), b1 = IntMath.mul(rt12, vy), c1 = IntMath.mul(rt13, vz);
			final a2 = IntMath.mul(rt21, vx), b2 = IntMath.mul(rt22, vy), c2 = IntMath.mul(rt23, vz);
			final a3 = IntMath.mul(rt31, vx), b3 = IntMath.mul(rt32, vy), c3 = IntMath.mul(rt33, vz);
			mac3Shifted = rowShr12(tz, a3, b3, c3);
			if (sf == 0) {
				mac1 = rowLow(tx, a1, b1, c1);
				mac2 = rowLow(ty, a2, b2, c2);
				mac3 = rowLow(tz, a3, b3, c3);
			} else {
				mac1 = rowShr12(tx, a1, b1, c1);
				mac2 = rowShr12(ty, a2, b2, c2);
				mac3 = mac3Shifted;
			}
		} else {
			// A translation this large can overflow the 44-bit accumulator. Every row takes the
			// checked path; for a row whose own translation is in range it gives the same answer.
			var m = row44Checked(tx, rt11, rt12, rt13, vx, vy, vz, F_MAC1_POS, F_MAC1_NEG);
			mac1 = shiftBySf(m, sf);
			m = row44Checked(ty, rt21, rt22, rt23, vx, vy, vz, F_MAC2_POS, F_MAC2_NEG);
			mac2 = shiftBySf(m, sf);
			m = row44Checked(tz, rt31, rt32, rt33, vx, vy, vz, F_MAC3_POS, F_MAC3_NEG);
			mac3Shifted = Acc.shr12(m);
			mac3 = shiftBySf(m, sf);
		}
		return mac3Shifted;
	}

	/** SX2/SY2 and MAC0 through the 64-bit accumulator, for what project's 32-bit form cannot hold. */
	@:specifier("__attribute__((noinline))")
	static function screenWide(n:Int):Void {
		var m = Acc.mac(Acc.of(ofx), ir1, n);
		mac0 = mac0From32(m);
		final sx = saturateSxy(Acc.shr16(m), F_SX2);
		m = Acc.mac(Acc.of(ofy), ir2, n);
		mac0 = mac0From32(m);
		final sy = saturateSxy(Acc.shr16(m), F_SY2);
		pushSxy(pack(sx, sy));
	}

	/**
		`((t << 12) + a + b + c) >> 12`, exactly, in 32 bits — a matrix row with sf = 1.

		Shifting `t << 12` out again leaves `t`, so the row is `t` plus the floor of the three
		products' sum over 4096. Each product splits into a floor part (`a >> 12`, arithmetic) and
		a remainder (`a & 0xFFF`, 0..4095), and the remainders' sum carries at most 2 into the
		result. With |t| < 2^30 and each product within 2^30, nothing here can overflow.
	**/
	static inline function rowShr12(t:Int, a:Int, b:Int, c:Int):Int {
		return t + (a >> 12) + (b >> 12) + (c >> 12) + (((a & 0xFFF) + (b & 0xFFF) + (c & 0xFFF)) >> 12);
	}

	/** The low 32 bits of the same sum: what a row stores with sf = 0. */
	static inline function rowLow(t:Int, a:Int, b:Int, c:Int):Int {
		return ((t << 12) + a + b + c) | 0;
	}

	/**
		`MAC0 = DQB + DQA * n`, `IR0 = MAC0 >> 12`: the fog factor a game multiplies its colours
		by, 0..0x1000 for none..all (docs/specs/runtime.md §5, psx-spx).

		The shift was missing, so IR0 saturated wherever MAC0 passed 0x1000. With Crash Bash's
		DQA/DQB (-4194, 0x1400000) a fifth of its RTPS/RTPT results differed — full far colour
		where the hardware gives about half — but that game never reads an IR0 the transform
		produced (it writes its own before every use; counted over 30,000 frames), so its digests
		did not move. A game that fogs with it would have drawn every distant vertex fully fogged.
	**/
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	static function depthCueing(n:Int):Void {
		// In 32 bits under project's premise for SX/SY: DQA is sixteen-bit signed. Inline on C++,
		// with the 64-bit form out of line: as one function it was too big to inline, and the
		// call cost more than the arithmetic.
		final p = IntMath.mul(dqa, n);
		final m = (dqb + p) | 0;
		if (n <= 0xFFFF && ((dqb ^ m) & (p ^ m)) >= 0) {
			mac0 = m;
			ir0 = saturateIr0(m >> 12);
		} else {
			depthCueWide(n);
		}
	}

	@:specifier("__attribute__((noinline))")
	static function depthCueWide(n:Int):Void {
		mac0 = mac0From32(Acc.mac(Acc.of(dqb), dqa, n));
		ir0 = saturateIr0(mac0 >> 12);
	}

	/**
		The signed area of the triangle in the screen FIFO — positive one way round, negative the
		other.

		A game calls it before drawing and skips the polygon when the sign says it is facing away,
		which is why a wrong sign here means half the world is missing.
	**/
	static function nclip():Void {
		final x0 = sxyX(sxy0), y0 = sxyY(sxy0);
		final x1 = sxyX(sxy1), y1 = sxyY(sxy1);
		final x2 = sxyX(sxy2), y2 = sxyY(sxy2);
		// With every coordinate within +-2^14 — RTPS clamps its own to +-0x400 — the six products
		// regroup as (x1-x0)(y2-y0) - (x2-x0)(y1-y0), whose factors stay under 2^15 and whose
		// result under 2^31: two 32-bit multiplies where the 64-bit form took six, and no flag
		// can arise. A game that writes wider coordinates into the queue gets the 64-bit form.
		if ((((x0 + 0x4000) | (y0 + 0x4000) | (x1 + 0x4000) | (y1 + 0x4000) | (x2 + 0x4000)
				| (y2 + 0x4000)) & -0x8000) == 0) {
			mac0 = IntMath.mul(x1 - x0, y2 - y0) - IntMath.mul(x2 - x0, y1 - y0);
		} else {
			nclipWide(x0, y0, x1, y1, x2, y2);
		}
	}

	static function nclipWide(x0:Int, y0:Int, x1:Int, y1:Int, x2:Int, y2:Int):Void {
		var m = Acc.mac(Acc.zero(), x0, y1);
		m = Acc.mac(m, x1, y2);
		m = Acc.mac(m, x2, y0);
		m = Acc.mac(m, -x0, y2);
		m = Acc.mac(m, -x1, y0);
		m = Acc.mac(m, -x2, y1);
		mac0 = mac0From32(m);
	}

	/** The average depth of three vertices, scaled — what a game sorts its ordering table by. */
	static function avsz3():Void {
		// ZSF times the sum of three depths fits in 32 bits for |ZSF3| <= 10922 (3 x 0xFFFF x
		// 10922 < 2^31); games use a few hundred. Then it is one multiply and no flag can arise.
		if (zsf3 >= -10922 && zsf3 <= 10922) {
			final m = IntMath.mul(zsf3, (sz1 & 0xFFFF) + (sz2 & 0xFFFF) + (sz3 & 0xFFFF));
			mac0 = m;
			otz = saturateSz3(m >> 12);
		} else {
			avsz3Wide();
		}
	}

	static function avsz3Wide():Void {
		// Four separate products, never ZSF times a sum: 32767 x 65535 only just fits in an Int,
		// and a sum of three depths times ZSF would not.
		var m = Acc.mac(Acc.zero(), zsf3, sz1 & 0xFFFF);
		m = Acc.mac(m, zsf3, sz2 & 0xFFFF);
		m = Acc.mac(m, zsf3, sz3 & 0xFFFF);
		mac0 = mac0From32(m);
		otz = saturateSz3(Acc.shr12(m));
	}

	static function avsz4():Void {
		// As avsz3, with four depths: |ZSF4| <= 8192 keeps the product under 2^31.
		if (zsf4 >= -8192 && zsf4 <= 8192) {
			final m = IntMath.mul(zsf4, (sz0 & 0xFFFF) + (sz1 & 0xFFFF) + (sz2 & 0xFFFF) + (sz3 & 0xFFFF));
			mac0 = m;
			otz = saturateSz3(m >> 12);
		} else {
			avsz4Wide();
		}
	}

	static function avsz4Wide():Void {
		var m = Acc.mac(Acc.zero(), zsf4, sz0 & 0xFFFF);
		m = Acc.mac(m, zsf4, sz1 & 0xFFFF);
		m = Acc.mac(m, zsf4, sz2 & 0xFFFF);
		m = Acc.mac(m, zsf4, sz3 & 0xFFFF);
		mac0 = mac0From32(m);
		otz = saturateSz3(Acc.shr12(m));
	}

	// ---- MVMVA and the arithmetic family ---------------------------------------------------------------

	/**
		Multiply a vector by a matrix and add a translation — the general form of every other
		transform the GTE does, with all three operands chosen by the instruction word.

		This is the one a 3D game cannot do without. `RTPS` covers the camera transform, but every
		*other* transform a game invents — a bone, a normal into world space, a light direction, a
		custom projection — is written as `MVMVA` with a matrix the game loaded itself. Leaving it
		out is why a build can draw its 2D interface perfectly and never put a single polygon of the
		world on screen: the sprites go through the GPU untransformed, and the world does not.

		Two hardware faults are part of the definition and both are reproduced. Selecting the far
		colour as the translation (`cv=2`) does not add it correctly — the first product of each row
		is lost, while FLAG is set as though the whole sum had happened — and selecting matrix 3
		reads a "matrix" assembled out of unrelated registers. Neither is useful, both are what the
		silicon does, and a game that stumbles into either has been calibrated against the result.
	**/
	static function mvmva(sf:Int, lm:Bool, imm25:Int):Void {
		final mx = (imm25 >> 17) & 3;
		final vs = (imm25 >> 15) & 3;
		final cv = (imm25 >> 13) & 3;
		// The matrix, the vector and the translation the instruction word names, chosen into
		// locals. They used to be copied through static scratch and read back lane by lane,
		// which cost about as much as the multiplies they fed.
		var m11 = 0, m12 = 0, m13 = 0, m21 = 0, m22 = 0, m23 = 0, m31 = 0, m32 = 0, m33 = 0;
		if (mx == 0) {
			m11 = rt11; m12 = rt12; m13 = rt13;
			m21 = rt21; m22 = rt22; m23 = rt23;
			m31 = rt31; m32 = rt32; m33 = rt33;
		} else if (mx == 1) {
			m11 = l11; m12 = l12; m13 = l13;
			m21 = l21; m22 = l22; m23 = l23;
			m31 = l31; m32 = l32; m33 = l33;
		} else if (mx == 2) {
			m11 = lr1; m12 = lr2; m13 = lr3;
			m21 = lg1; m22 = lg2; m23 = lg3;
			m31 = lb1; m32 = lb2; m33 = lb3;
		} else {
			// Not a matrix at all: three registers that happen to sit where one would be read
			// from, per psx-spx's "-R*10h, +R*10h, IR0, RT13 x3, RT22 x3". R is RGBC's red byte.
			final r = (rgbc & 0xFF) << 4;
			m11 = -r; m12 = r; m13 = ir0;
			m21 = rt13; m22 = rt13; m23 = rt13;
			m31 = rt22; m32 = rt22; m33 = rt22;
		}
		var vx = 0, vy = 0, vz = 0;
		if (vs == 3) {
			vx = ir1; vy = ir2; vz = ir3;
		} else {
			vx = vecX(vs); vy = vecY(vs); vz = vecZ(vs);
		}
		var tx = 0, ty = 0, tz = 0;
		if (cv == 0) {
			tx = trX; ty = trY; tz = trZ;
		} else if (cv == 1) {
			tx = rbk; ty = gbk; tz = bbk;
		} else if (cv == 2) {
			tx = rfc; ty = gfc; tz = bfc;
		} else {}
		if (cv == 2) mvmvaFarColor(sf, lm, m11, m12, m13, m21, m22, m23, m31, m32, m33, vx, vy, vz, tx, ty, tz);
		else mvmvaNormal(sf, lm, m11, m12, m13, m21, m22, m23, m31, m32, m33, vx, vy, vz, tx, ty, tz);
	}

	/**
		`(T*1000h + M*V) SAR (sf*12)` into MAC1-3, and IR from them — the light matrix, the colour
		matrix and MVMVA. Every operand of the products is sixteen-bit here (the matrices, V0-2,
		IR, and the registers MVMVA's garbage matrix borrows), so with every translation within
		2^30 the rows are exact in 32 bits, as in `project`; otherwise the checked 44-bit path.
	**/
	static function mvmvaNormal(sf:Int, lm:Bool, m11:Int, m12:Int, m13:Int, m21:Int, m22:Int,
			m23:Int, m31:Int, m32:Int, m33:Int, vx:Int, vy:Int, vz:Int, tx:Int, ty:Int, tz:Int):Void {
		if (tx > -0x40000000 && tx < 0x40000000 && ty > -0x40000000 && ty < 0x40000000
				&& tz > -0x40000000 && tz < 0x40000000) {
			final a1 = IntMath.mul(m11, vx), b1 = IntMath.mul(m12, vy), c1 = IntMath.mul(m13, vz);
			final a2 = IntMath.mul(m21, vx), b2 = IntMath.mul(m22, vy), c2 = IntMath.mul(m23, vz);
			final a3 = IntMath.mul(m31, vx), b3 = IntMath.mul(m32, vy), c3 = IntMath.mul(m33, vz);
			if (sf == 0) {
				mac1 = rowLow(tx, a1, b1, c1);
				mac2 = rowLow(ty, a2, b2, c2);
				mac3 = rowLow(tz, a3, b3, c3);
			} else {
				mac1 = rowShr12(tx, a1, b1, c1);
				mac2 = rowShr12(ty, a2, b2, c2);
				mac3 = rowShr12(tz, a3, b3, c3);
			}
			copyMacToIr(lm);
		} else {
			mvmvaWide(sf, lm, m11, m12, m13, m21, m22, m23, m31, m32, m33, vx, vy, vz, tx, ty, tz);
		}
	}

	static function mvmvaWide(sf:Int, lm:Bool, m11:Int, m12:Int, m13:Int, m21:Int, m22:Int,
			m23:Int, m31:Int, m32:Int, m33:Int, vx:Int, vy:Int, vz:Int, tx:Int, ty:Int, tz:Int):Void {
		var m = Acc.shl12(tx);
		m = step44(Acc.mac(m, m11, vx), F_MAC1_POS, F_MAC1_NEG);
		m = step44(Acc.mac(m, m12, vy), F_MAC1_POS, F_MAC1_NEG);
		m = step44(Acc.mac(m, m13, vz), F_MAC1_POS, F_MAC1_NEG);
		mac1 = shiftBySf(m, sf);

		m = Acc.shl12(ty);
		m = step44(Acc.mac(m, m21, vx), F_MAC2_POS, F_MAC2_NEG);
		m = step44(Acc.mac(m, m22, vy), F_MAC2_POS, F_MAC2_NEG);
		m = step44(Acc.mac(m, m23, vz), F_MAC2_POS, F_MAC2_NEG);
		mac2 = shiftBySf(m, sf);

		m = Acc.shl12(tz);
		m = step44(Acc.mac(m, m31, vx), F_MAC3_POS, F_MAC3_NEG);
		m = step44(Acc.mac(m, m32, vy), F_MAC3_POS, F_MAC3_NEG);
		m = step44(Acc.mac(m, m33, vz), F_MAC3_POS, F_MAC3_NEG);
		mac3 = shiftBySf(m, sf);

		copyMacToIr(lm);
	}

	/**
		`cv=2`, where the hardware loses the first product of every row.

		psx-spx: "the return values are reduced to the last two portions of the formula ...
		nevertheless, some bits in the FLAG register seem to be adjusted as if the full operation
		would have been executed". So each lane is computed twice — once with the translation and
		the first product, purely so its overflows reach FLAG, and once without either, for the
		value that is kept.
	**/
	static function mvmvaFarColor(sf:Int, lm:Bool, m11:Int, m12:Int, m13:Int, m21:Int, m22:Int,
			m23:Int, m31:Int, m32:Int, m33:Int, vx:Int, vy:Int, vz:Int, tx:Int, ty:Int, tz:Int):Void {
		mac1 = farColorLane(sf, tx, m11, m12, m13, vx, vy, vz, F_MAC1_POS, F_MAC1_NEG);
		mac2 = farColorLane(sf, ty, m21, m22, m23, vx, vy, vz, F_MAC2_POS, F_MAC2_NEG);
		mac3 = farColorLane(sf, tz, m31, m32, m33, vx, vy, vz, F_MAC3_POS, F_MAC3_NEG);
		copyMacToIr(lm);
	}

	static function farColorLane(sf:Int, t:Int, m1:Int, m2:Int, m3:Int, vx:Int, vy:Int, vz:Int,
			pos:Int, neg:Int):Int {
		// For the flags only.
		step44(Acc.mac(Acc.shl12(t), m1, vx), pos, neg);
		// For the value.
		var m = step44(Acc.mac(Acc.zero(), m2, vy), pos, neg);
		m = step44(Acc.mac(m, m3, vz), pos, neg);
		return shiftBySf(m, sf);
	}

	/** `[MAC] = [IR1²,IR2²,IR3²] SHR (sf*12)`. Always positive, so `lm` cannot bite. */
	static function sqr(sf:Int):Void {
		mac1 = shiftBySf(Acc.mac(Acc.zero(), ir1, ir1), sf);
		mac2 = shiftBySf(Acc.mac(Acc.zero(), ir2, ir2), sf);
		mac3 = shiftBySf(Acc.mac(Acc.zero(), ir3, ir3), sf);
		copyMacToIr(false);
	}

	/**
		The cross product of IR with the RT matrix's diagonal, which a game uses as a vector.

		Sony's documentation calls it the outer product, which psx-spx puts down to a translation of
		外積; the arithmetic is the ordinary cross product either way.
	**/
	static function crossProduct(sf:Int, lm:Bool):Void {
		final d1 = rt11, d2 = rt22, d3 = rt33;
		final a = ir1, b = ir2, c = ir3;
		mac1 = shiftBySf(step44(Acc.mac(Acc.mac(Acc.zero(), c, d2), -b, d3), F_MAC1_POS, F_MAC1_NEG), sf);
		mac2 = shiftBySf(step44(Acc.mac(Acc.mac(Acc.zero(), a, d3), -c, d1), F_MAC2_POS, F_MAC2_NEG), sf);
		mac3 = shiftBySf(step44(Acc.mac(Acc.mac(Acc.zero(), b, d1), -a, d2), F_MAC3_POS, F_MAC3_NEG), sf);
		copyMacToIr(lm);
	}

	/** `[MAC] = ([IR] * IR0) SAR (sf*12)`, then a colour. */
	static function gpf(sf:Int, lm:Bool):Void {
		interpolateBy(0, 0, 0, sf);
		finishColor(sf, lm);
	}

	/** The same with the current MAC as a base, shifted up first so the SAR undoes it. */
	static function gpl(sf:Int, lm:Bool):Void {
		interpolateBy(shlBySf(mac1, sf), shlBySf(mac2, sf), shlBySf(mac3, sf), sf);
		finishColor(sf, lm);
	}

	static function interpolateBy(b1:Int, b2:Int, b3:Int, sf:Int):Void {
		mac1 = shiftBySf(step44(Acc.mac(Acc.of(b1), ir1, ir0), F_MAC1_POS, F_MAC1_NEG), sf);
		mac2 = shiftBySf(step44(Acc.mac(Acc.of(b2), ir2, ir0), F_MAC2_POS, F_MAC2_NEG), sf);
		mac3 = shiftBySf(step44(Acc.mac(Acc.of(b3), ir3, ir0), F_MAC3_POS, F_MAC3_NEG), sf);
	}

	static inline function shlBySf(v:Int, sf:Int):Int {
		return sf == 0 ? v : (v << 12) | 0;
	}

	// ---- depth cueing, and the interpolations built out of it ------------------------------------------

	/**
		Fog: the vertex colour pulled towards the far colour by IR0.

		`DPCS` starts from the RGBC register, `DPCT` from the bottom of the colour FIFO three times
		over, `INTPL` from IR itself, and `DCPL` from the colour modulated by IR — after which all
		four run the same interpolation and push the same kind of colour. Which starting value is
		used is the whole difference between them.
	**/
	static function dpcs(sf:Int, lm:Bool):Void {
		startFromColor(rgbc);
		farColorInterpolate(sf, lm);
	}

	static function dpct(sf:Int, lm:Bool):Void {
		// Three times, each reading the *bottom* of the FIFO — which the push then moves along, so
		// the three entries are consumed in order and all three end up replaced.
		dpctOnce(sf, lm);
		dpctOnce(sf, lm);
		dpctOnce(sf, lm);
	}

	static function dpctOnce(sf:Int, lm:Bool):Void {
		startFromColor(rgb0);
		farColorInterpolate(sf, lm);
	}

	static function intpl(sf:Int, lm:Bool):Void {
		mac1 = Acc.low32(Acc.shl12(ir1));
		mac2 = Acc.low32(Acc.shl12(ir2));
		mac3 = Acc.low32(Acc.shl12(ir3));
		farColorInterpolate(sf, lm);
	}

	static function dcpl(sf:Int, lm:Bool):Void {
		mac1 = (shim.IntMath.mul(rgbc & 0xFF, ir1) << 4) | 0;
		mac2 = (shim.IntMath.mul((rgbc >> 8) & 0xFF, ir2) << 4) | 0;
		mac3 = (shim.IntMath.mul((rgbc >> 16) & 0xFF, ir3) << 4) | 0;
		farColorInterpolate(sf, lm);
	}

	// ---- the lighting family ---------------------------------------------------------------------

	/**
		Normal colour, and the six commands built on it.

		This is how a PlayStation lights a model, and there is no other way: a vertex normal goes
		through the light matrix to find how much each of three lights strikes it, that result goes
		through the colour matrix onto the background colour to become a light colour, and the
		light colour is then combined with the material — the polygon's own RGB — and optionally
		pulled towards the far colour by depth. Six commands, differing only in which of the last
		two steps they perform, and all of them ending in the colour FIFO the game reads back.

		Both matrix steps are MVMVA with its fields fixed, which psx-spx says outright, so they are
		the same code: the light matrix against a vertex, then the colour matrix against IR with
		the background colour as the translation.

		Absent, a lit model computes no colour at all and is drawn in whatever was left in the
		accumulators — black, most often, which on a dark scene is indistinguishable from a model
		that was never drawn.
	**/
	static function ncs(sf:Int, lm:Bool, v:Int):Void {
		lightNormal(sf, lm, v);
		lightColour(sf, lm);
		finishColor(sf, lm);
	}

	/** Normal colour, then the material, then depth-cued towards the far colour. */
	static function ncds(sf:Int, lm:Bool, v:Int):Void {
		lightNormal(sf, lm, v);
		lightColour(sf, lm);
		materialTimesIr();
		farColorInterpolate(sf, lm);
	}

	/** Normal colour, then the material, and no depth cue. */
	static function nccs(sf:Int, lm:Bool, v:Int):Void {
		lightNormal(sf, lm, v);
		lightColour(sf, lm);
		materialTimesIr();
		shiftMacBySf(sf);
		finishColor(sf, lm);
	}

	/** The same three, over all three vertex normals. `kind` picks which. */
	static function ncTriple(sf:Int, lm:Bool, kind:Int):Void {
		for (v in 0...3) {
			if (kind == 0) ncs(sf, lm, v);
			else if (kind == 1) ncds(sf, lm, v);
			else nccs(sf, lm, v);
		}
	}

	/** IR is already the normal's light: colour matrix, material, no depth cue. */
	static function cc(sf:Int, lm:Bool):Void {
		lightColour(sf, lm);
		materialTimesIr();
		shiftMacBySf(sf);
		finishColor(sf, lm);
	}

	/** The same, depth-cued. */
	static function cdp(sf:Int, lm:Bool):Void {
		lightColour(sf, lm);
		materialTimesIr();
		farColorInterpolate(sf, lm);
	}

	/** `(LLM * V) SAR (sf*12)` — MVMVA against the light matrix with no translation. */
	static function lightNormal(sf:Int, lm:Bool, v:Int):Void {
		final vx = v == 3 ? ir1 : vecX(v);
		final vy = v == 3 ? ir2 : vecY(v);
		final vz = v == 3 ? ir3 : vecZ(v);
		mvmvaNormal(sf, lm, l11, l12, l13, l21, l22, l23, l31, l32, l33, vx, vy, vz, 0, 0, 0);
	}

	/** `(BK*1000h + LCM * IR) SAR (sf*12)` — the colour matrix onto the background colour. */
	static function lightColour(sf:Int, lm:Bool):Void {
		mvmvaNormal(sf, lm, lr1, lr2, lr3, lg1, lg2, lg3, lb1, lb2, lb3, ir1, ir2, ir3, rbk, gbk, bbk);
	}

	/**
		`[MAC] = [R*IR1, G*IR2, B*IR3] SHL 4` — the light met by the material it falls on.

		No shift by `sf` here: the commands that depth-cue apply it after the far colour has been
		mixed in, and the ones that do not apply it themselves. Both products fit in 32 bits — a
		byte times a signed 16-bit accumulator, shifted four — so the accumulator is loaded whole.
	**/
	static function materialTimesIr():Void {
		mac1 = Acc.low32(step44(Acc.of((shim.IntMath.mul(rgbc & 0xFF, ir1) << 4) | 0), F_MAC1_POS, F_MAC1_NEG));
		mac2 = Acc.low32(step44(Acc.of((shim.IntMath.mul((rgbc >> 8) & 0xFF, ir2) << 4) | 0), F_MAC2_POS, F_MAC2_NEG));
		mac3 = Acc.low32(step44(Acc.of((shim.IntMath.mul((rgbc >> 16) & 0xFF, ir3) << 4) | 0), F_MAC3_POS, F_MAC3_NEG));
	}

	static function shiftMacBySf(sf:Int):Void {
		mac1 = shiftBySf(Acc.of(mac1), sf);
		mac2 = shiftBySf(Acc.of(mac2), sf);
		mac3 = shiftBySf(Acc.of(mac3), sf);
	}

	/** `[MAC] = [R,G,B] SHL 16`, the starting point DPCS and DPCT share. */
	static function startFromColor(source:Int):Void {
		mac1 = ((source & 0xFF) << 16) | 0;
		mac2 = (((source >> 8) & 0xFF) << 16) | 0;
		mac3 = (((source >> 16) & 0xFF) << 16) | 0;
	}

	/**
		`MAC = MAC + (FC - MAC) * IR0`, which psx-spx spells out in two steps.

		The intermediate `(FC - MAC) SAR (sf*12)` lands in IR saturated *as if `lm` were zero*,
		whatever `lm` actually is; only the final write back to IR obeys it. Getting that wrong
		clamps every negative difference to zero and fog stops darkening anything.
	**/
	static function farColorInterpolate(sf:Int, lm:Bool):Void {
		final base1 = mac1, base2 = mac2, base3 = mac3;
		// With the far colour within 2^18 and MAC within 2^30 — a colour in 12.4 or 8.16, which
		// is what reaches here — FC*1000h - MAC and MAC + IR*IR0 (IR and IR0 sixteen-bit) both
		// stay under 2^31: exact in 32 bits, and no 44-bit flag can arise.
		if (rfc > -0x40000 && rfc < 0x40000 && gfc > -0x40000 && gfc < 0x40000
				&& bfc > -0x40000 && bfc < 0x40000
				&& base1 > -0x40000000 && base1 < 0x40000000 && base2 > -0x40000000
				&& base2 < 0x40000000 && base3 > -0x40000000 && base3 < 0x40000000) {
			final d1 = (rfc << 12) - base1, d2 = (gfc << 12) - base2, d3 = (bfc << 12) - base3;
			ir1 = saturateIr(sf == 0 ? d1 : d1 >> 12, false, F_IR1);
			ir2 = saturateIr(sf == 0 ? d2 : d2 >> 12, false, F_IR2);
			ir3 = saturateIr(sf == 0 ? d3 : d3 >> 12, false, F_IR3);
			final e1 = base1 + IntMath.mul(ir1, ir0);
			final e2 = base2 + IntMath.mul(ir2, ir0);
			final e3 = base3 + IntMath.mul(ir3, ir0);
			mac1 = sf == 0 ? e1 : e1 >> 12;
			mac2 = sf == 0 ? e2 : e2 >> 12;
			mac3 = sf == 0 ? e3 : e3 >> 12;
			finishColor(sf, lm);
		} else {
			farColorWide(sf, lm, base1, base2, base3);
		}
	}

	static function farColorWide(sf:Int, lm:Bool, base1:Int, base2:Int, base3:Int):Void {
		ir1 = saturateIr(shiftBySf(step44(Acc.add(Acc.shl12(rfc), -base1), F_MAC1_POS, F_MAC1_NEG), sf), false, F_IR1);
		ir2 = saturateIr(shiftBySf(step44(Acc.add(Acc.shl12(gfc), -base2), F_MAC2_POS, F_MAC2_NEG), sf), false, F_IR2);
		ir3 = saturateIr(shiftBySf(step44(Acc.add(Acc.shl12(bfc), -base3), F_MAC3_POS, F_MAC3_NEG), sf), false, F_IR3);

		interpolateBy(base1, base2, base3, sf);
		finishColor(sf, lm);
	}

	/** Every colour operation ends the same way: a FIFO entry, and IR holding what made it. */
	static function finishColor(sf:Int, lm:Bool):Void {
		pushColor(saturateColor(mac1 >> 4, F_COLOR_R),
			saturateColor(mac2 >> 4, F_COLOR_G),
			saturateColor(mac3 >> 4, F_COLOR_B));
		copyMacToIr(lm);
	}

	static function copyMacToIr(lm:Bool):Void {
		ir1 = saturateIr(mac1, lm, F_IR1);
		ir2 = saturateIr(mac2, lm, F_IR2);
		ir3 = saturateIr(mac3, lm, F_IR3);
	}

	static function saturateColor(v:Int, bit:Int):Int {
		if (v < 0) { flag |= (1 << bit); return 0; }
		else {}
		if (v > 0xFF) { flag |= (1 << bit); return 0xFF; }
		else {}
		return v;
	}

	/** The colour FIFO, three deep, keeping RGBC's code byte with each entry as the hardware does. */
	static function pushColor(r:Int, g:Int, b:Int):Void {
		rgb0 = rgb1;
		rgb1 = rgb2;
		rgb2 = r | (g << 8) | (b << 16) | (rgbc & 0xFF000000);
	}

	// ---- the pieces the operations are made of --------------------------------------------------------

	/**
		One accumulation step: check the 44-bit range, flag it, then wrap as the hardware does.
		The accumulator is a value (`shim.Acc`) passed in and handed back, so a chain of steps
		stays in a local — a register, on both targets — rather than in a static field.
	**/
	static inline function step44(m:Acc, posBit:Int, negBit:Int):Acc {
		// In range, the wrap is the identity, so only an overflow pays for it: on a 32-bit CPU
		// the wrap is a pair of 64-bit shifts, and this runs nine times a vertex.
		final over = Acc.check44(m);
		return over == 0 ? m : overflow44(m, over, posBit, negBit);
	}

	/**
		`(tr << 12) + r1*x + r2*y + r3*z`, each partial sum checked against 44 bits and wrapped as
		the hardware does. Only for a translation of 2^30 or more: the matrix and the vector are
		sixteen-bit signed, so each product is within 2^30, and with |tr| < 2^30 the translation is
		within 2^42 and no partial sum can reach 2^43 — nothing to flag or wrap, which is why
		`project` does those rows in 32 bits.
	**/
	static function row44Checked(tr:Int, r1:Int, r2:Int, r3:Int, x:Int, y:Int, z:Int,
			posBit:Int, negBit:Int):Acc {
		var m = Acc.shl12(tr);
		m = step44(Acc.mac(m, r1, x), posBit, negBit);
		m = step44(Acc.mac(m, r2, y), posBit, negBit);
		m = step44(Acc.mac(m, r3, z), posBit, negBit);
		return m;
	}

	static function overflow44(m:Acc, over:Int, posBit:Int, negBit:Int):Acc {
		if (over > 0) flag |= (1 << posBit);
		else flag |= (1 << negBit);
		return Acc.wrap44(m);
	}

	static inline function shiftBySf(m:Acc, sf:Int):Int {
		return sf == 0 ? Acc.low32(m) : Acc.shr12(m);
	}

	/** MAC0 is 32 bits, so its flags are a range check rather than a truncation. */
	static inline function mac0From32(m:Acc):Int {
		final over = Acc.check32(m);
		if (over > 0) flag |= (1 << F_MAC0_POS);
		else if (over < 0) flag |= (1 << F_MAC0_NEG);
		else {}
		return Acc.low32(m);
	}

	static function saturateIr(v:Int, lm:Bool, bit:Int):Int {
		final lo = lm ? 0 : -0x8000;
		if (v < lo) { flag |= (1 << bit); return lo; }
		else {}
		if (v > 0x7FFF) { flag |= (1 << bit); return 0x7FFF; }
		else {}
		return v;
	}

	/**
		IR3 saturates on the stored MAC3 but *flags* on the shifted one.

		Identical whenever `sf` is 12, which is almost always — and observably different when it is
		not, which is the case games were calibrated against.
	**/
	static function saturateIr3(v:Int, shifted:Int, lm:Bool):Int {
		final lo = lm ? 0 : -0x8000;
		if (shifted < -0x8000 || shifted > 0x7FFF) flag |= (1 << F_IR3);
		else {}
		if (v < lo) return lo;
		else {}
		if (v > 0x7FFF) return 0x7FFF;
		else {}
		return v;
	}

	static function saturateIr0(v:Int):Int {
		if (v < 0) { flag |= (1 << F_IR0); return 0; }
		else {}
		if (v > 0x1000) { flag |= (1 << F_IR0); return 0x1000; }
		else {}
		return v;
	}

	static function saturateSz3(v:Int):Int {
		if (v < 0) { flag |= (1 << F_SZ3); return 0; }
		else {}
		if (v > 0xFFFF) { flag |= (1 << F_SZ3); return 0xFFFF; }
		else {}
		return v;
	}

	static function saturateSxy(v:Int, bit:Int):Int {
		if (v < -0x400) { flag |= (1 << bit); return -0x400; }
		else {}
		if (v > 0x3FF) { flag |= (1 << bit); return 0x3FF; }
		else {}
		return v;
	}

	static function pushSz(v:Int):Void {
		sz0 = sz1;
		sz1 = sz2;
		sz2 = sz3;
		sz3 = v & 0xFFFF;
	}

	static inline function vecX(v:Int):Int {
		return v == 0 ? sext16(vxy0) : (v == 1 ? sext16(vxy1) : sext16(vxy2));
	}

	static inline function vecY(v:Int):Int {
		return v == 0 ? (vxy0 >> 16) : (v == 1 ? (vxy1 >> 16) : (vxy2 >> 16));
	}

	static inline function vecZ(v:Int):Int {
		return v == 0 ? vz0 : (v == 1 ? vz1 : vz2);
	}

	static inline function sxyX(v:Int):Int {
		return sext16(v);
	}

	static inline function sxyY(v:Int):Int {
		return v >> 16;
	}
}
