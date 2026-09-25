package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;
import recomp.ir.FunctionIR.InstructionIR;
import recomp.ir.RegisterMask;
import recomp.mips.Instr;
import recomp.mips.Op;

/** The counter slot: `lw r, off($sp)` … `addiu r, r, ±1` … `sw r, off($sp)`, once a turn. */
typedef IdleSlot = {register:Int, offset:Int, delta:Int, load:Instr};

/** The one branch that reads the counter: the loop is left when it is equal, or when it is not. */
typedef IdleCounterExit = {other:Int, exitOnEqual:Bool};

/** A branch on invariants only; the loop goes on when its condition equals `continueWhen`. */
typedef IdleInvariantExit = {branch:Instr, continueWhen:Bool};

/**
	Proof that a loop is idle, and the facts the prologue needs.

	A turn of an idle loop changes nothing the machine can see except a counter in a stack slot
	and the cycle count; everything it reads is either a register it does not write, a register
	it wrote earlier in the same turn, or memory — and memory it reads cannot change between two
	pumps, because the machine is single-threaded and its devices act only through the scheduler,
	which acts only in `Runtime.pump`. With that, how many turns run before the next pump is a
	function of the cycle counter, and how many before the counter's branch leaves is a function
	of the slot; the emitter takes all but the last of them by arithmetic (`core.IdleLoop`).

	What is required, and why each requirement is there:
	- One pump per turn, at the header: a second pump point would be a state change mid-turn.
	- A single cycle of blocks, each with one successor inside the loop: a turn is one path.
	- Only plain arithmetic, loads, one stack-slot store and branches: nothing else is pure.
	- No register read before it is written in the turn unless the loop never writes it: a
	  loop-carried register would need reconstructing; the counter goes through memory instead.
	- The counter register is read, while it holds the count, only by its own `addiu`, its store
	  and one `beq`/`bne` against an invariant: any other reader would make a branch depend on
	  the count without the prologue knowing.
	- Every load's address is checked for plain memory at run time (a polled address is a
	  register's value) and, when there is a slot, for not overlapping it: the prologue reads
	  memory as it is now, and the slot is the one word the skipped turns would have changed.
	Loops that fail any of this are simply emitted as before: the analysis never changes what
	the loop does, only whether its turns are counted or run.
**/
class IdleLoopPlan {
	public final header:BlockIR;
	/** The members in the order a turn visits them, the header first. */
	public final turn:Array<BlockIR>;
	/** Every instruction of a turn, in order. */
	public final list:Array<InstructionIR>;
	/** Cycles charged per turn, and instructions executed per turn. */
	public final cycles:Int;
	public final instructions:Int;
	/** Registers the turn writes, ascending; the prologue shadows them. */
	public final written:Array<Int>;
	public final slot:Null<IdleSlot>;
	public final counterExit:Null<IdleCounterExit>;
	final invariantExits:Map<Int, IdleInvariantExit>;
	/** Reloads of the slot after its store, by address: in the dry turn they yield the stored count. */
	final reloads:Map<Int, Bool>;

	function new(header:BlockIR, turn:Array<BlockIR>, list:Array<InstructionIR>, cycles:Int,
			instructions:Int, written:Array<Int>, slot:Null<IdleSlot>,
			counterExit:Null<IdleCounterExit>, invariantExits:Map<Int, IdleInvariantExit>,
			reloads:Map<Int, Bool>) {
		this.header = header;
		this.turn = turn;
		this.list = list;
		this.cycles = cycles;
		this.instructions = instructions;
		this.written = written;
		this.slot = slot;
		this.counterExit = counterExit;
		this.invariantExits = invariantExits;
		this.reloads = reloads;
	}

	/** Whether this load is a reload of the slot after its store. */
	public function isReload(i:Instr):Bool return reloads.exists(i.addr);

	/** The invariant exit at a branch's address, if that branch is one. */
	public function invariantExit(addr:Int):Null<IdleInvariantExit> return invariantExits.get(addr);

	/** Whether this is the slot's own load. */
	public function isSlotLoad(i:Instr):Bool return slot != null && slot.load == i;

	/** The plan for a loop whose members are the given resume IDs, or null when it is not idle. */
	public static function analyze(ir:FunctionIR, members:Array<Int>, headerId:Int):Null<IdleLoopPlan> {
		final members_:Map<Int, Bool> = [];
		for (id in members) members_.set(ir.blocks[id].addr, true);
		final header = ir.blocks[headerId];
		if (!header.pump) return null;
		for (id in members) if (id != headerId && ir.blocks[id].pump) return null;

		// The turn's blocks are the members that reach the header again without leaving the
		// region. A region may also own a block reached only from the loop that returns or
		// leaves — that is an exit, not part of a turn.
		final inside:Map<Int, Bool> = [header.addr => true];
		final work = [header.addr];
		while (work.length > 0) {
			final at = work.pop();
			for (from in ir.byAddress.get(at).predecessors) {
				if (members_.exists(from) && !inside.exists(from)) {
					inside.set(from, true);
					work.push(from);
				}
			}
		}
		var onTurn = 0;
		for (_ in inside) onTurn++;

		// One path around: from the header, each block of the turn has exactly one successor
		// on the turn.
		final turn:Array<BlockIR> = [];
		var block = header;
		while (true) {
			turn.push(block);
			var next:Null<BlockIR> = null;
			var count = 0;
			for (to in block.successors) if (inside.exists(to)) {
				next = ir.byAddress.get(to);
				count++;
			}
			if (count != 1 || next == null) return null;
			if (next == header) break;
			if (turn.indexOf(next) >= 0) return null;
			block = next;
		}
		if (turn.length != onTurn) return null;

		final list:Array<InstructionIR> = [];
		var cycles = 0;
		var instructions = 0;
		for (b in turn) {
			for (i in b.instructions) list.push(i);
			cycles += b.cycles;
			instructions += b.instructions.length;
		}
		if (cycles <= 0) return null;

		var written:RegisterMask = 0;
		for (i in list) {
			if (!allowed(i.decoded)) return null;
			written = ((written : Int) | (i.writes : Int));
		}
		if (written.has(29) || written.has(30)) return null;

		// Nothing is read before the turn writes it, unless the loop never writes it at all.
		var defined:RegisterMask = 0;
		for (i in list) {
			for (r in 1...32) if (i.reads.has(r) && written.has(r) && !defined.has(r)) return null;
			defined = ((defined : Int) | (i.writes : Int));
		}

		// The counter slot, if there is a store at all.
		var slot:Null<IdleSlot> = null;
		final reloads:Map<Int, Bool> = [];
		// Where a register holds the count: from the addiu, and from each reload, to the next
		// write of that register.
		final holds:Array<{register:Int, from:Int, to:Int}> = [];
		var storeAt = -1;
		var stores = 0;
		for (n in 0...list.length) if (list[n].decoded.op == Op.SW) { stores++; storeAt = n; }
		if (stores > 1) return null;
		if (stores == 1) {
			final store = list[storeAt].decoded;
			final r = store.rt;
			if (r == 0) return null;
			var a = storeAt - 1;
			while (a >= 0 && !list[a].writes.has(r)) a--;
			if (a < 0) return null;
			final add = list[a].decoded;
			if (add.op != Op.ADDIU || add.rs != r || add.rt != r || (add.immS != 1 && add.immS != -1)) return null;
			var l = a - 1;
			while (l >= 0 && !list[l].writes.has(r)) l--;
			if (l < 0) return null;
			final load = list[l].decoded;
			if (load.op != Op.LW || load.rs != 29 || load.immS != store.immS) return null;
			slot = {register: r, offset: store.immS, delta: add.immS, load: load};
			holds.push({register: r, from: a, to: nextWrite(list, a, r)});
			// The only other stack loads allowed are reloads of the slot after its store — the
			// compiler's own store-then-reload, which libetc's wait has — and they yield the
			// count again, so the register they fill holds it too. Any other stack load would
			// read a slot the prologue does not model.
			for (n in 0...list.length) {
				final d = list[n].decoded;
				if (n == l || !isLoad(d.op) || d.rs != 29) continue;
				if (n < storeAt || d.op != Op.LW || d.immS != store.immS || d.rt == 0) return null;
				reloads.set(d.addr, true);
				holds.push({register: d.rt, from: n, to: nextWrite(list, n, d.rt)});
			}
		}

		// Branches: the counter's exit, and the invariant ones.
		var counterExit:Null<IdleCounterExit> = null;
		final invariantExits:Map<Int, IdleInvariantExit> = [];
		var counterBranchAt = -1;
		for (n in 0...list.length) {
			final i = list[n].decoded;
			if (!isConditional(i.op)) continue;
			final takenIn = inside.exists(i.target);
			final fallIn = inside.exists(i.addr + 8);
			if (takenIn == fallIn) return null;
			final counted = holdingAt(holds, n, list[n].reads);
			if (counted >= 0) {
				if (counterExit != null) return null;
				if (i.op != Op.BEQ && i.op != Op.BNE) return null;
				final other = i.rs == counted ? i.rt : i.rs;
				if (other == counted || holdsAt(holds, n, other)) return null;
				if (other != 0 && written.has(other)) return null;
				final exitOnTaken = !takenIn;
				counterExit = {other: other, exitOnEqual: (i.op == Op.BEQ) == exitOnTaken};
				counterBranchAt = n;
			} else {
				invariantExits.set(i.addr, {branch: i, continueWhen: takenIn});
			}
		}

		// While a register holds the count, only the store and the counter branch may read it:
		// any other reader would make a branch depend on the count without the prologue knowing.
		for (h in holds) for (n in (h.from + 1)...h.to) {
			if (n == storeAt || n == counterBranchAt) continue;
			if (list[n].reads.has(h.register)) return null;
		}

		final writtenList = [for (r in 1...32) if (written.has(r)) r];
		return new IdleLoopPlan(header, turn, list, cycles, instructions, writtenList, slot,
			counterExit, invariantExits, reloads);
	}

	/** The index of the next write of `r` after instruction `n`, or the list's end. */
	static function nextWrite(list:Array<InstructionIR>, n:Int, r:Int):Int {
		for (m in (n + 1)...list.length) if (list[m].writes.has(r)) return m;
		return list.length;
	}

	/** The register among `reads` that holds the count at instruction `n`, or -1. */
	static function holdingAt(holds:Array<{register:Int, from:Int, to:Int}>, n:Int,
			reads:RegisterMask):Int {
		for (h in holds) if (n > h.from && n < h.to && reads.has(h.register)) return h.register;
		return -1;
	}

	static function holdsAt(holds:Array<{register:Int, from:Int, to:Int}>, n:Int, r:Int):Bool {
		for (h in holds) if (h.register == r && n > h.from && n < h.to) return true;
		return false;
	}

	static function isLoad(op:Op):Bool return switch (op) {
		case LB | LBU | LH | LHU | LW: true;
		case _: false;
	};

	static function isConditional(op:Op):Bool return switch (op) {
		case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ: true;
		case _: false;
	};

	/** The instructions a turn may contain: pure arithmetic, loads, the slot's store, branches. */
	static function allowed(i:Instr):Bool return switch (i.op) {
		case ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU
			| SLL | SRL | SRA | SLLV | SRLV | SRAV
			| ADDI | ADDIU | ANDI | ORI | XORI | SLTI | SLTIU | LUI: true;
		case LB | LBU | LH | LHU | LW: i.rt != 0;
		case SW: i.rs == 29;
		case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ | J: true;
		case _: false;
	};
}
