package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;
import recomp.codegen.RegionPlan.Region;
import recomp.mips.Op;

/** Promote GPR values across a bounded pure acyclic region. Existing Haxe branches assign
    the merge variables, preserving the original public-entry routing and path accounting.
    All captures precede execution and all written values are published at each region exit.
**/
class ValueCfg {
	public final used:Array<Int>;
	public final written:Array<Int>;
	public final members:Map<Int, Bool>;
	public final continuation:Null<Int>;
	public final returnSites:Array<Int>;
	function new(used:Int, written:Int, members:Map<Int, Bool>, continuation:Null<Int>, returnSites:Array<Int>) {
		this.used = [for (r in 1...32) if ((used & (1 << r)) != 0) r];
		this.written = [for (r in 1...32) if ((written & (1 << r)) != 0) r];
		this.members = members; this.continuation = continuation; this.returnSites = returnSites;
	}
	public static function analyze(ir:FunctionIR, region:Region):Null<ValueCfg> {
		if (region.members.length < 2 || region.members.length > 16 || region.computed) return null;
		final inside:Map<Int, Bool> = []; final pending:Map<Int, Int> = [];
		var insns = 0; var cycles = 0; var written = 0; var continuation:Null<Int> = null;
		final returnSites:Array<Int> = [];
		for (id in region.members) inside.set(ir.blocks[id].addr, true);
		for (id in region.members) {
			final b = ir.blocks[id];
			insns += b.instructions.length; cycles += b.cycles;
			if (b.pump || insns > 32 || cycles > 1023) return null;
			var incoming = 0;
			for (a in b.predecessors) if (inside.exists(a)) incoming++;
			pending.set(b.addr, incoming);
			final t = b.transfer;
			if (t == null) { if (b.successors.length != 1) return null; }
			else {
				if (b.delaySlot == null) return null;
				final i = t.decoded;
				if (b.conditional()) {
					if (b.successors.indexOf(i.target) < 0 || b.successors.indexOf(i.addr + 8) < 0
							|| b.successors.length > 2) return null;
				} else if (i.op == Op.J) {
					if (b.successors.length != 1 || b.successors[0] != i.target) return null;
				} else if (i.op == Op.JR && i.rs == 31 && b.successors.length == 0) returnSites.push(i.addr);
				else return null;
			}
			for (x in b.body) { if ((x.effects : Int) != 0 || x.writes.has(31)) return null; written |= x.writes; }
			if (b.delaySlot != null) {
				if ((b.delaySlot.effects : Int) != 0 || b.delaySlot.writes.has(31)) return null;
				written |= b.delaySlot.writes;
			}
			for (a in b.successors) if (!inside.exists(a)) {
				if (continuation != null && continuation != a) return null;
				continuation = a;
			}
		}
		final order:Array<BlockIR> = [];
		while (order.length < region.members.length) {
			var next:Null<BlockIR> = null;
			for (id in region.members) if (pending.get(ir.blocks[id].addr) == 0) { next = ir.blocks[id]; break; }
			if (next == null) return null;
			pending.set(next.addr, -1); order.push(next);
			for (a in next.successors) if (inside.exists(a)) pending.set(a, pending.get(a) - 1);
		}
		var used = written;
		for (b in order) {
			for (x in b.body) used |= x.reads;
			if (b.delaySlot != null) used |= b.delaySlot.reads;
			if (b.conditional()) used |= b.transfer.reads;
		}
		return new ValueCfg(used, written, inside, continuation, returnSites);
	}
}
