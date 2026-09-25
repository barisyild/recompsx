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

	// ---- MVMVA and the arithmetic family ---------------------------------------------------------------

	// The operands MVMVA picks out of its instruction word, copied here rather than branched on
	// three times per lane. Nine matrix elements, three vector components, three translation ones.
	static var mm11 = 0; static var mm12 = 0; static var mm13 = 0;
	static var mm21 = 0; static var mm22 = 0; static var mm23 = 0;
	static var mm31 = 0; static var mm32 = 0; static var mm33 = 0;
	static var mvX = 0; static var mvY = 0; static var mvZ = 0;
	static var mtX = 0; static var mtY = 0; static var mtZ = 0;

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
		selectMatrix((imm25 >> 17) & 3);
		selectVector((imm25 >> 15) & 3);
		final cv = (imm25 >> 13) & 3;
		selectTranslation(cv);
		if (cv == 2) mvmvaFarColor(sf, lm);
		else mvmvaNormal(sf, lm);
	}

	static function mvmvaNormal(sf:Int, lm:Bool):Void {
		I64.setShl12(mtX);
		I64.addProduct16(mm11, mvX); step44(F_MAC1_POS, F_MAC1_NEG);
		I64.addProduct16(mm12, mvY); step44(F_MAC1_POS, F_MAC1_NEG);
		I64.addProduct16(mm13, mvZ); step44(F_MAC1_POS, F_MAC1_NEG);
		mac1 = shiftBySf(sf);

		I64.setShl12(mtY);
		I64.addProduct16(mm21, mvX); step44(F_MAC2_POS, F_MAC2_NEG);
		I64.addProduct16(mm22, mvY); step44(F_MAC2_POS, F_MAC2_NEG);
		I64.addProduct16(mm23, mvZ); step44(F_MAC2_POS, F_MAC2_NEG);
		mac2 = shiftBySf(sf);

		I64.setShl12(mtZ);
		I64.addProduct16(mm31, mvX); step44(F_MAC3_POS, F_MAC3_NEG);
		I64.addProduct16(mm32, mvY); step44(F_MAC3_POS, F_MAC3_NEG);
		I64.addProduct16(mm33, mvZ); step44(F_MAC3_POS, F_MAC3_NEG);
		mac3 = shiftBySf(sf);

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
	static function mvmvaFarColor(sf:Int, lm:Bool):Void {
		mac1 = farColorLane(sf, mtX, mm11, mm12, mm13, F_MAC1_POS, F_MAC1_NEG);
		mac2 = farColorLane(sf, mtY, mm21, mm22, mm23, F_MAC2_POS, F_MAC2_NEG);
		mac3 = farColorLane(sf, mtZ, mm31, mm32, mm33, F_MAC3_POS, F_MAC3_NEG);
		copyMacToIr(lm);
	}

	static function farColorLane(sf:Int, t:Int, m1:Int, m2:Int, m3:Int, pos:Int, neg:Int):Int {
		// For the flags only.
		I64.setShl12(t);
		I64.addProduct16(m1, mvX); step44(pos, neg);
		// For the value.
		I64.setZero();
		I64.addProduct16(m2, mvY); step44(pos, neg);
		I64.addProduct16(m3, mvZ); step44(pos, neg);
		return shiftBySf(sf);
	}

	static function selectMatrix(mx:Int):Void {
		if (mx == 0) {
			mm11 = rt11; mm12 = rt12; mm13 = rt13;
			mm21 = rt21; mm22 = rt22; mm23 = rt23;
			mm31 = rt31; mm32 = rt32; mm33 = rt33;
		} else if (mx == 1) {
			mm11 = l11; mm12 = l12; mm13 = l13;
			mm21 = l21; mm22 = l22; mm23 = l23;
			mm31 = l31; mm32 = l32; mm33 = l33;
		} else if (mx == 2) {
			mm11 = lr1; mm12 = lr2; mm13 = lr3;
			mm21 = lg1; mm22 = lg2; mm23 = lg3;
			mm31 = lb1; mm32 = lb2; mm33 = lb3;
		} else {
			// Not a matrix at all: three registers that happen to sit where one would be read
			// from, per psx-spx's "-R*10h, +R*10h, IR0, RT13 x3, RT22 x3". R is RGBC's red byte.
			final r = (rgbc & 0xFF) << 4;
			mm11 = -r; mm12 = r; mm13 = ir0;
			mm21 = rt13; mm22 = rt13; mm23 = rt13;
			mm31 = rt22; mm32 = rt22; mm33 = rt22;
		}
	}

	static function selectVector(v:Int):Void {
		if (v == 3) {
			mvX = ir1; mvY = ir2; mvZ = ir3;
		} else {
			mvX = vecX(v); mvY = vecY(v); mvZ = vecZ(v);
		}
	}

	static function selectTranslation(cv:Int):Void {
		if (cv == 0) {
			mtX = trX; mtY = trY; mtZ = trZ;
		} else if (cv == 1) {
			mtX = rbk; mtY = gbk; mtZ = bbk;
		} else if (cv == 2) {
			mtX = rfc; mtY = gfc; mtZ = bfc;
		} else {
			mtX = 0; mtY = 0; mtZ = 0;
		}
	}

	/** `[MAC] = [IR1²,IR2²,IR3²] SHR (sf*12)`. Always positive, so `lm` cannot bite. */
	static function sqr(sf:Int):Void {
		I64.setZero(); I64.addProduct16(ir1, ir1); mac1 = shiftBySf(sf);
		I64.setZero(); I64.addProduct16(ir2, ir2); mac2 = shiftBySf(sf);
		I64.setZero(); I64.addProduct16(ir3, ir3); mac3 = shiftBySf(sf);
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
		I64.setZero();
		I64.addProduct16(c, d2); I64.addProduct16(-b, d3);
		step44(F_MAC1_POS, F_MAC1_NEG); mac1 = shiftBySf(sf);
		I64.setZero();
		I64.addProduct16(a, d3); I64.addProduct16(-c, d1);
		step44(F_MAC2_POS, F_MAC2_NEG); mac2 = shiftBySf(sf);
		I64.setZero();
		I64.addProduct16(b, d1); I64.addProduct16(-a, d2);
		step44(F_MAC3_POS, F_MAC3_NEG); mac3 = shiftBySf(sf);
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
		I64.set(b1); I64.addProduct16(ir1, ir0);
		step44(F_MAC1_POS, F_MAC1_NEG); mac1 = shiftBySf(sf);
		I64.set(b2); I64.addProduct16(ir2, ir0);
		step44(F_MAC2_POS, F_MAC2_NEG); mac2 = shiftBySf(sf);
		I64.set(b3); I64.addProduct16(ir3, ir0);
		step44(F_MAC3_POS, F_MAC3_NEG); mac3 = shiftBySf(sf);
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
		I64.setShl12(ir1); mac1 = I64.low32();
		I64.setShl12(ir2); mac2 = I64.low32();
		I64.setShl12(ir3); mac3 = I64.low32();
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
		selectMatrix(1);
		selectVector(v);
		selectTranslation(3);
		mvmvaNormal(sf, lm);
	}

	/** `(BK*1000h + LCM * IR) SAR (sf*12)` — the colour matrix onto the background colour. */
	static function lightColour(sf:Int, lm:Bool):Void {
		selectMatrix(2);
		selectVector(3);
		selectTranslation(1);
		mvmvaNormal(sf, lm);
	}

	/**
		`[MAC] = [R*IR1, G*IR2, B*IR3] SHL 4` — the light met by the material it falls on.

		No shift by `sf` here: the commands that depth-cue apply it after the far colour has been
		mixed in, and the ones that do not apply it themselves. Both products fit in 32 bits — a
		byte times a signed 16-bit accumulator, shifted four — so the accumulator is loaded whole.
	**/
	static function materialTimesIr():Void {
		I64.set((shim.IntMath.mul(rgbc & 0xFF, ir1) << 4) | 0);
		step44(F_MAC1_POS, F_MAC1_NEG);
		mac1 = I64.low32();
		I64.set((shim.IntMath.mul((rgbc >> 8) & 0xFF, ir2) << 4) | 0);
		step44(F_MAC2_POS, F_MAC2_NEG);
		mac2 = I64.low32();
		I64.set((shim.IntMath.mul((rgbc >> 16) & 0xFF, ir3) << 4) | 0);
		step44(F_MAC3_POS, F_MAC3_NEG);
		mac3 = I64.low32();
	}

	static function shiftMacBySf(sf:Int):Void {
		I64.set(mac1); mac1 = shiftBySf(sf);
		I64.set(mac2); mac2 = shiftBySf(sf);
		I64.set(mac3); mac3 = shiftBySf(sf);
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

		I64.setShl12(rfc); I64.addSmall(-base1);
		step44(F_MAC1_POS, F_MAC1_NEG);
		ir1 = saturateIr(shiftBySf(sf), false, F_IR1);
		I64.setShl12(gfc); I64.addSmall(-base2);
		step44(F_MAC2_POS, F_MAC2_NEG);
		ir2 = saturateIr(shiftBySf(sf), false, F_IR2);
		I64.setShl12(bfc); I64.addSmall(-base3);
		step44(F_MAC3_POS, F_MAC3_NEG);
		ir3 = saturateIr(shiftBySf(sf), false, F_IR3);

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

	/** One accumulation step: check the 44-bit range, flag it, then wrap as the hardware does. */
	static inline function step44(posBit:Int, negBit:Int):Void {
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
	static inline function mac0From32():Int {
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
