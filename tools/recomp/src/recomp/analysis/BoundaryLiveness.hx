package recomp.analysis;

import recomp.ir.Effect;
import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.InstructionIR;

/** Architectural observations, not an ABI's caller-saved convention. All GPRs are live at
	exits, pumps and runtime effects. A missing result is safe only if every path overwrites it
	before a read or observation. Calls observe state after their link write and delay slot.
**/
class BoundaryLiveness {
	public static inline final ALL = 0xFFFFFFFE;
	public final entry:Map<Int, Int> = [];
	public final afterCall:Map<Int, Int> = [];

	public function new(fn:Func, ir:FunctionIR) {
		for (b in ir.blocks) entry.set(b.addr, ALL);
		var changed = true;
		while (changed) {
			changed = false;
			for (b in ir.blocks) {
				var live = b.successors.length == 0 || fn.blocks.get(b.addr).exits ? ALL : 0;
				for (s in b.successors) live |= entry.get(s);
				final t = b.transfer;
				if (t != null) {
					if (t.effects.has(Effect.CALL)) afterCall.set(t.decoded.addr, live);
					// Every call and computed transfer is an observation. Even a known pure
					// callee has an entry checkpoint; its fast arm is guarded independently.
					if (t.effects.has(Effect.CALL) || t.decoded.isRegisterJump) live = ALL;
					if (b.delaySlot != null) live = before(b.delaySlot, live);
					live = before(t, live);
				}
				var n = b.body.length;
				while (n > 0) live = before(b.body[--n], live);
				if (b.pump || b.addr == fn.entry) live = ALL;
				if (live != entry.get(b.addr)) { entry.set(b.addr, live); changed = true; }
			}
		}
	}

	static function before(x:InstructionIR, live:Int):Int {
		if (((x.effects : Int) & ~(Effect.CONTROL : Int)) != 0) return ALL;
		return (x.reads : Int) | (live & ~(x.writes : Int));
	}
}
