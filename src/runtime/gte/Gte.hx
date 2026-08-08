package gte;

import core.CpuState;
import core.Runtime;

/**
	The Geometry Transformation Engine — coprocessor 2, and the reason PlayStation games have
	3D at all.

	It is a fixed-point vector unit: matrix transforms, perspective division, lighting and colour,
	all in integers. Every 3D game leans on it heavily, and its results have to be bit-exact
	because games feed them straight into geometry that is then depth-sorted — a value off by one
	changes which polygon is drawn in front.

	Unimplemented so far; see docs/specs/runtime.md §5 for the register file, the operation list
	with their exact semantics, and the UNR division algorithm. The acceptance gate is amidog's
	psxtest_gte, which checks values *and* flag bits for every operation.
**/
class Gte {
	/** Executes a COP2 command. `imm25` carries the operation and its sf/lm/MVMVA fields. */
	public static function execute(ctx:CpuState, imm25:Int):Void {
		Runtime.reportOnce(0x62000000 | (imm25 & 0x3F), "GTE operation " + (imm25 & 0x3F));
	}

	public static function getData(ctx:CpuState, reg:Int):Int {
		Runtime.reportOnce(0x63000000 | reg, "GTE data register " + reg + " read");
		return 0;
	}

	public static function setData(ctx:CpuState, reg:Int, value:Int):Void {
		Runtime.reportOnce(0x64000000 | reg, "GTE data register " + reg + " write");
	}

	public static function getCtrl(ctx:CpuState, reg:Int):Int {
		Runtime.reportOnce(0x65000000 | reg, "GTE control register " + reg + " read");
		return 0;
	}

	public static function setCtrl(ctx:CpuState, reg:Int, value:Int):Void {
		Runtime.reportOnce(0x66000000 | reg, "GTE control register " + reg + " write");
	}
}
