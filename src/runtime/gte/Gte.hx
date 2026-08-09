package gte;

import core.CpuState;
import core.Runtime;
import shim.I64;

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
	}

	// ---- data register access ----------------------------------------------------------------------

	public static function getData(ctx:CpuState, reg:Int):Int {
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

	public static function setData(ctx:CpuState, reg:Int, value:Int):Void {
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

	public static function getCtrl(ctx:CpuState, reg:Int):Int {
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

	public static function setCtrl(ctx:CpuState, reg:Int, value:Int):Void {
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
	static var unrTable:Array<Int>;

	static function buildUnrTable():Void {
		// Built unconditionally, not behind `if (unrTable != null)`.
		//
		// `Array<Int>` is not a nullable type, so that comparison is not a question both targets
		// answer the same way: JavaScript sees the field's initial `null` and builds the table,
		// while the C++ side folds the check away and returns immediately — leaving every
		// division to dereference nothing. It cost a segmentation fault that JavaScript could not
		// reproduce, which is exactly the divergence the two-target gate exists to catch. `init`
		// runs once, so there is nothing to guard against anyway.
		unrTable = [for (_ in 0...257) 0];
		for (i in 0...257) {
			final v = shim.IntMath.div(shim.IntMath.div(0x40000, i + 0x100) + 1, 2) - 0x101;
			unrTable[i] = v < 0 ? 0 : v;
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
	**/
	static function unrDivide():Int {
		final divisor = sz3 & 0xFFFF;
		final dividend = h & 0xFFFF;
		if (divisor * 2 <= dividend) return divideOverflow();
		else {}

		final shift = countLeadingZeros16(divisor);
		var n = (dividend << shift) | 0;
		var d = (divisor << shift) & 0xFFFF;
		final u = unrTable[((d - 0x7FC0) >> 7)] + 0x101;
		d = (0x2000080 - shim.IntMath.mul(d, u)) >> 8;
		d = (0x0000080 + shim.IntMath.mul(d, u)) >> 8;
		final q = I64.mulShr16Round(n, d);
		return q > 0x1FFFF ? 0x1FFFF : q;
	}

	static function divideOverflow():Int {
		flag |= (1 << F_DIVIDE);
		return 0x1FFFF;
	}

	/** How far a 16-bit value must shift left before its top bit is set. */
	static function countLeadingZeros16(v:Int):Int {
		var n = 0;
		var x = v & 0xFFFF;
		while (n < 16 && (x & 0x8000) == 0) {
			n++;
			x = (x << 1) & 0xFFFF;
		}
		return n;
	}

	// ---- executing ------------------------------------------------------------------------------------

	/** Executes a COP2 command. `imm25` carries the operation and its sf/lm/MVMVA fields. */
	public static function execute(ctx:CpuState, imm25:Int):Void {
		flag = 0;
		final op = imm25 & 0x3F;
		final sf = (imm25 & 0x80000) != 0 ? 12 : 0;
		final lm = (imm25 & 0x400) != 0;
		if (op == 0x01) rtps(sf, lm, 0, true);
		else if (op == 0x30) rtpt(sf, lm);
		else if (op == 0x06) nclip();
		else if (op == 0x2D) avsz3();
		else if (op == 0x2E) avsz4();
		else unimplementedOp(op);
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
	static function rtps(sf:Int, lm:Bool, v:Int, last:Bool):Void {
		final vx = vecX(v), vy = vecY(v), vz = vecZ(v);

		I64.setShl12(trX);
		I64.addProduct16(rt11, vx); step44(F_MAC1_POS, F_MAC1_NEG);
		I64.addProduct16(rt12, vy); step44(F_MAC1_POS, F_MAC1_NEG);
		I64.addProduct16(rt13, vz); step44(F_MAC1_POS, F_MAC1_NEG);
		mac1 = shiftBySf(sf);

		I64.setShl12(trY);
		I64.addProduct16(rt21, vx); step44(F_MAC2_POS, F_MAC2_NEG);
		I64.addProduct16(rt22, vy); step44(F_MAC2_POS, F_MAC2_NEG);
		I64.addProduct16(rt23, vz); step44(F_MAC2_POS, F_MAC2_NEG);
		mac2 = shiftBySf(sf);

		I64.setShl12(trZ);
		I64.addProduct16(rt31, vx); step44(F_MAC3_POS, F_MAC3_NEG);
		I64.addProduct16(rt32, vy); step44(F_MAC3_POS, F_MAC3_NEG);
		I64.addProduct16(rt33, vz); step44(F_MAC3_POS, F_MAC3_NEG);
		// The depth value is always the >>12 form, whatever `sf` says — and IR3's saturation flag
		// is judged from *that*, not from the stored MAC3. Only visible at sf=0, and games rely on
		// it. psx-spx records the same quirk.
		final mac3Shifted = I64.shr12();
		mac3 = shiftBySf(sf);

		ir1 = saturateIr(mac1, lm, F_IR1);
		ir2 = saturateIr(mac2, lm, F_IR2);
		ir3 = saturateIr3(mac3, mac3Shifted, lm);

		pushSz(saturateSz3(mac3Shifted));

		final n = unrDivide();

		I64.set(ofx);
		I64.addProductWide(ir1, n);
		mac0 = mac0From32();
		final sx = saturateSxy(I64.shr16(), F_SX2);

		I64.set(ofy);
		I64.addProductWide(ir2, n);
		mac0 = mac0From32();
		final sy = saturateSxy(I64.shr16(), F_SY2);

		pushSxy(pack(sx, sy));

		if (last) depthCueing(n);
		else {}
	}

	/** The same transform for all three vertices; only the last one sets the depth-cue outputs. */
	static function rtpt(sf:Int, lm:Bool):Void {
		rtps(sf, lm, 0, false);
		rtps(sf, lm, 1, false);
		rtps(sf, lm, 2, true);
	}

	/** `IR0 = DQB + DQA * n`, the fog factor a game multiplies its colours by. */
	static function depthCueing(n:Int):Void {
		I64.set(dqb);
		I64.addProductWide(dqa, n);
		mac0 = mac0From32();
		ir0 = saturateIr0(mac0);
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
		I64.setZero();
		I64.addProduct16(x0, y1);
		I64.addProduct16(x1, y2);
		I64.addProduct16(x2, y0);
		I64.addProduct16(-x0, y2);
		I64.addProduct16(-x1, y0);
		I64.addProduct16(-x2, y1);
		mac0 = mac0From32();
	}

	/** The average depth of three vertices, scaled — what a game sorts its ordering table by. */
	static function avsz3():Void {
		I64.setZero();
		// Four separate products, never ZSF times a sum: 32767 x 65535 only just fits in an Int,
		// and a sum of three depths times ZSF would not.
		I64.addProduct16(zsf3, sz1 & 0xFFFF);
		I64.addProduct16(zsf3, sz2 & 0xFFFF);
		I64.addProduct16(zsf3, sz3 & 0xFFFF);
		mac0 = mac0From32();
		otz = saturateSz3(I64.shr12());
	}

	static function avsz4():Void {
		I64.setZero();
		I64.addProduct16(zsf4, sz0 & 0xFFFF);
		I64.addProduct16(zsf4, sz1 & 0xFFFF);
		I64.addProduct16(zsf4, sz2 & 0xFFFF);
		I64.addProduct16(zsf4, sz3 & 0xFFFF);
		mac0 = mac0From32();
		otz = saturateSz3(I64.shr12());
	}

	// ---- the pieces the operations are made of --------------------------------------------------------

	/** One accumulation step: check the 44-bit range, flag it, then wrap as the hardware does. */
	static function step44(posBit:Int, negBit:Int):Void {
		final over = I64.check44();
		if (over > 0) flag |= (1 << posBit);
		else if (over < 0) flag |= (1 << negBit);
		else {}
		I64.wrap44();
	}

	static inline function shiftBySf(sf:Int):Int {
		return sf == 0 ? I64.low32() : I64.shr12();
	}

	/** MAC0 is 32 bits, so its flags are a range check rather than a truncation. */
	static function mac0From32():Int {
		final over = I64.check32();
		if (over > 0) flag |= (1 << F_MAC0_POS);
		else if (over < 0) flag |= (1 << F_MAC0_NEG);
		else {}
		return I64.low32();
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
