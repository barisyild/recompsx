package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.ir.FunctionIR;
import recomp.codegen.RegionPlan.Region;
import recomp.mips.Disasm;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.codegen.PatternMatcher.FusedKind;
import recomp.codegen.IdleLoopPlan;

/**
	Turns analysed MIPS into Haxe.

	Registers become scalar Haxe locals, giving the Haxe analyzer ordinary values to propagate
	and eliminate. CpuState is synchronised at calls, returns and scheduler safe points. Linear
	CFGs become sequences, natural loops with one exit become native `while` loops, and
	single-entry regions inside other CFGs become sequences and choices. Remaining control flow
	uses a region/block dispatcher. Every guest block stays addressable without duplicating its
	body (ADR-0007/0008).

	Inside a native loop a transfer may only fall through, `continue`, `break` or return: Haxe
	has no labelled jumps, so nothing inside one may reach the dispatcher. A jump past the next
	part of a sequence, and a `break` out of a loop, record their target in `resume`, the same
	local that routes an interior entry; every sequence part is guarded by it and every block
	resets it, which is what lets forward jumps and multi-exit loops stay structured.

	Every arithmetic result that can overflow is written `| 0`, which JS needs and C++ folds
	away (ADR-0004). Eliminated instructions still contribute to the guest cycle count.

	The subtle part is the delay slot. On MIPS the instruction after a branch executes *before*
	the branch takes effect, so it cannot simply be emitted in program order. The rule here is to
	evaluate the branch condition into a temporary first, then emit the slot instruction, then
	transfer — which preserves the semantics even when the slot writes a register the condition
	read. For a `jal` the same ordering applies to the link register.

	`optimize=false` keeps context fields and the block dispatcher as a differential reference.
	`structureRegions=false` isolates the scalar-register/simple-loop baseline.
**/
class Emitter {
	final image:Image;
	final discovery:Discovery;
	final optimize:Bool;
	final structureRegions:Bool;
	var registers:Null<RegisterPlan>;
	var ir:FunctionIR;
	var functionAddr:Int;
	/** Program substitutes a pinned handle after body deduplication; fixtures use addresses. */
	public var continuationToken:Null<String> = null;
	var continuation:Int;
	// A native loop consumes transfers to this block instead of re-entering the dispatcher.
	var nativeLoop:Null<Int>;
	var linearNext:Null<Int>;
	// A structured choice consumes its header's branch after latching it before the slot.
	var capturedBranch:Null<Int>;
	// The innermost native loop being emitted: a transfer to its header is a `continue`, one
	// to anything outside its members a recorded `break`. Null outside a Loop region.
	var loopHead:Null<Int>;
	var loopMembers:Null<Map<Int, Bool>>;
	// The enclosing sequences, innermost last: which part is being emitted, so a transfer to a
	// later part of any of them can be a recorded forward jump. `loopFrame` is how many of them
	// lie outside the innermost native loop and are therefore reached only by a `break`.
	final frames:Array<SequenceFrame> = [];
	var loopFrame:Int = 0;
	// Region emission declares `resume`; block emission then resets it at every block start.
	var inRegions:Bool = false;
	// Loops proved idle (IdleLoopPlan), by header address: the header emits the skip prologue.
	var idlePlans:Map<Int, IdleLoopPlan> = [];
	// While the idle prologue evaluates a dry turn, the registers it writes are these locals.
	var shadow:Null<Map<Int, String>> = null;

	/**
		The class a call to this address should go to, or null to dispatch it by address.

		Set by `Program`, because the answer depends on the whole program and not on the function
		being emitted. Two things make an address undecidable at emission time: it may be inside an
		overlay window, where what is resident is a run-time fact; or it may be code this build
		never found, where the runtime's table is the only thing that could know.

		Returning a class name means "this target is always this code" — the executable outside
		every window, or an overlay's own window seen from inside that overlay, where the caller
		running at all proves the callee is resident.
	**/
	public var staticTargetOf:Int -> String = _ -> null;

	public function new(image:Image, discovery:Discovery, optimize:Bool = true, structureRegions:Bool = true) {
		this.image = image;
		this.discovery = discovery;
		this.optimize = optimize;
		this.structureRegions = structureRegions;
	}

	/**
		Stable block entry indices, shared by the dispatch tables and both output shapes.

		Public because the dispatch table needs the same numbering: an address that lands *inside*
		a function has to become a case index, and the only way for that to be right is for the
		table and the switch to be built from one definition of the order rather than two that
		happen to agree.
	**/
	public static function blockOrder(fn:Func):Array<Int> return FunctionIR.blockOrder(fn);

	public function emitFunction(fn:Func):String {
		final buf = new StringBuf();
		final blockAddrs = blockOrder(fn);
		ir = new FunctionIR(fn, image);
		functionAddr = fn.entry;
		registers = optimize ? new RegisterPlan(ir) : null;
		nativeLoop = null;
		linearNext = null;
		capturedBranch = null;
		loopHead = null;
		loopMembers = null;
		loopFrame = 0;
		inRegions = false;
		while (frames.length > 0) frames.pop();
		idlePlans = [];
		shadow = null;

		// Dense indices in address order: stable across regenerations, and the case labels read
		// in the same order as the original listing.
		final indexOf:Map<Int, Int> = [];
		for (i in 0...blockAddrs.length) indexOf.set(blockAddrs[i], i);

		final pumpAt = loopHeaders(fn, blockAddrs);

		buf.add('\t/**\n');
		buf.add('\t\t${fn.name} — ${Vaddr.hex(fn.entry)}..${Vaddr.hex(fn.endAddr - 1)}, '
			+ '${blockAddrs.length} block${blockAddrs.length == 1 ? "" : "s"}, '
			+ '${fn.instructionCount()} instructions.\n');
		if (fn.confidence == recomp.analysis.Confidence.Swept) {
			buf.add('\t\tFound by the prologue sweep rather than by a call, so nothing in the\n');
			buf.add('\t\tprogram is known to reach it statically.\n');
		}
		buf.add('\t**/\n');
		buf.add('\tpublic static function ${fn.name}(ctx:CpuState, entry:Int = 0):Void {\n');
		buf.add('\t\t#if recompsx_cooperative\n');
		buf.add('\t\tvar entryPump = true;\n');
		buf.add('\t\tif (core.Cooperative.resumeEntry >= 0) {\n');
		buf.add('\t\t\tentry = core.Cooperative.resumeEntry; entryPump = core.Cooperative.resumePump;\n');
		buf.add('\t\t\tcore.Cooperative.resumeEntry = -1;\n\t\t} else {}\n');
		buf.add('\t\tif (entryPump) {\n');
		emitCheckpoint(buf, '\t\t\t', 'entry', true);
		buf.add(PUMP_ENTRY);
		buf.add('\t\t} else {}\n\t\t#else\n');
		buf.add(PUMP_ENTRY);
		buf.add('\t\t#end\n');
		if (registers != null) registers.declare(buf, '\t\t');

		// Even a one-block CFG needs a loop if it has an edge to itself.
		final flat = blockAddrs.length == 1 && fn.blocks.get(blockAddrs[0]).successors.length == 0;
		final linear = optimize && linearChain(fn, blockAddrs);
		if (optimize && structureRegions && !flat && !linear) {
			final regions = new RegionPlan(ir);
			if (regions.sequences > 0 || regions.choices > 0 || regions.loops > 0) {
				emitRegions(buf, fn, regions, indexOf);
				buf.add('\t}\n');
				return buf.toString();
			}
		}
		final dispatch = !flat && !linear;
		if (linear && !flat) buf.add('\t\tif (entry < 0 || entry >= ${blockAddrs.length}) return;\n');
		if (dispatch) {
			buf.add('\t\tvar bb = entry;\n');
			buf.add('\t\twhile (true) switch (bb) {\n');
		}

		for (i in 0...blockAddrs.length) {
			final addr = blockAddrs[i];
			final guarded = linear && i + 1 < blockAddrs.length;
			final indent = dispatch ? "\t\t\t\t" : (guarded ? "\t\t\t" : "\t\t");
			linearNext = guarded ? blockAddrs[i + 1] : null;
			if (dispatch) buf.add('\t\t\tcase $i: // ${Vaddr.hex(addr)}\n');
			else if (guarded) buf.add('\t\tif (entry <= $i) { // ${Vaddr.hex(addr)}\n');
			final loopExit = optimize ? selfLoopExit(fn, addr) : null;
			if (loopExit != null) {
				nativeLoop = addr;
				buf.add(indent + 'while (true) {\n');
				emitPump(buf, indent + '\t', i);
				emitBlock(buf, fn, addr, indexOf, indent + '\t');
				buf.add(indent + '}\n');
				nativeLoop = null;
				emitGoto(buf, indent, loopExit, indexOf, addr);
			} else {
				if (pumpAt.exists(addr)) emitPump(buf, indent, i);
				emitBlock(buf, fn, addr, indexOf, indent);
			}
			if (guarded) buf.add('\t\t} else {}\n');
		}

		if (dispatch) {
			buf.add('\t\t\tdefault: return;   // unreachable; keeps the switch total\n');
			buf.add('\t\t}\n');
		}
		buf.add('\t}\n');
		return buf.toString();
	}

	function emitRegions(buf:StringBuf, fn:Func, plan:RegionPlan, indexOf:Map<Int, Int>):Void {
		inRegions = true;
		final dispatch = plan.roots.length != 1 || plan.roots[0].successors.length != 0;
		buf.add('\t\t// Regions: ${plan.roots.length}; ${plan.sequences} sequence / ${plan.choices} choice / ${plan.loops} loop reductions.\n');
		if (dispatch) {
			buf.add('\t\tvar bb = entry;\n\t\twhile (true) switch (bb) {\n');
		} else {
			buf.add('\t\tif (entry < 0 || entry >= ${ir.blocks.length}) return;\n');
		}
		for (root in plan.roots) {
			final ind = dispatch ? '\t\t\t\t' : '\t\t';
			if (dispatch) buf.add('\t\t\tcase ${root.members.join(" | ")}:\n');
			buf.add(ind + 'var resume = ${dispatch ? "bb" : "entry"};\n');
			emitRegion(buf, fn, root, indexOf, ind, null);
			// The end of a root is reached only with a recorded target in another root: the
			// guards inside skipped everything after a jump out of a loop or past the tail.
			if (dispatch) buf.add(ind + 'bb = resume; continue;\n');
		}
		if (dispatch) buf.add('\t\t\tdefault: return;\n\t\t}\n');
	}

	/**
		`resume` is local entry routing, not a guest block dispatcher. -1 means ordinary flow;
		otherwise it names the block the guards are steering towards: the interior entry on the
		way in, or the target of a forward jump or a loop exit recorded on the way. Every part of
		a sequence is guarded by it and every block resets it on arrival, so the steering costs a
		compare a part and nothing once a block has run — the host compiler folds the compares
		that follow a reset. Each block, its cycles and its safe point are emitted once.
	**/
	function emitRegion(buf:StringBuf, fn:Func, region:Region, indexOf:Map<Int, Int>,
			ind:String, follow:Null<Int>):Void {
		switch (region.body) {
			case Block(block):
				linearNext = follow;
				final loopExit = block.selfLoopExit();
				if (loopExit != null) {
					planIdle([block.resumeId], block.resumeId);
					nativeLoop = block.addr;
					buf.add(ind + 'while (true) {\n');
					emitPump(buf, ind + '\t', block.resumeId);
					emitBlock(buf, fn, block.addr, indexOf, ind + '\t');
					buf.add(ind + '}\n');
					nativeLoop = null;
					emitGoto(buf, ind, loopExit, indexOf, block.addr);
				} else {
					if (block.pump) emitPump(buf, ind, block.resumeId);
					emitBlock(buf, fn, block.addr, indexOf, ind);
				}
			case Sequence(parts):
				final frame = new SequenceFrame([for (part in parts) part.entry]);
				frames.push(frame);
				for (i in 0...parts.length) {
					frame.index = i;
					final last = i + 1 == parts.length;
					buf.add(ind + 'if (resume < 0 || ${containsEntry(parts[i])}) {\n');
					emitRegion(buf, fn, parts[i], indexOf, ind + '\t', last ? follow : parts[i + 1].entry);
					buf.add(ind + '} else {}\n');
				}
				frames.pop();
			case Choice(head, taken, notTaken, join):
				final branch = head.selector;
				final name = 'take_${branch.resumeId}';
				buf.add(ind + 'var $name = false;\n');
				buf.add(ind + 'if (resume < 0 || ${containsEntry(head)}) {\n');
				final previous = capturedBranch;
				capturedBranch = branch.addr;
				emitRegion(buf, fn, head, indexOf, ind + '\t', null);
				capturedBranch = previous;
				buf.add(ind + '} else {}\n');
				buf.add(ind + 'if (resume < 0 ? $name : ${containsEntry(taken)}) {\n');
				if (taken != null) emitRegion(buf, fn, taken, indexOf, ind + '\t', join);
				buf.add(ind + '} else {\n');
				if (notTaken != null) emitRegion(buf, fn, notTaken, indexOf, ind + '\t', join);
				buf.add(ind + '}\n');
				linearNext = follow;
				if (join != null) emitGoto(buf, ind, join, indexOf, head.entry);
			case Loop(body, exits):
				final outerHead = loopHead, outerMembers = loopMembers, outerFrame = loopFrame;
				loopHead = body.entry;
				loopMembers = [for (id in body.members) id => true];
				loopFrame = frames.length;
				final headId = ir.byAddress.get(body.entry).resumeId;
				planIdle(body.members, headId);
				buf.add(ind + 'while (true) {\n');
				emitRegion(buf, fn, body, indexOf, ind + '\t', null);
				// Reached with a recorded target only: one outside the loop leaves it, and the
				// guards after the loop steer to it; the loop's own header is the next pass.
				buf.add(ind + '\tif (resume >= 0 && resume != $headId) break; else {}\n');
				buf.add(ind + '}\n');
				loopHead = outerHead;
				loopMembers = outerMembers;
				loopFrame = outerFrame;
				linearNext = follow;
		}
	}

	/** Consecutive stable IDs become ranges, keeping resume guards small without a host table. */
	static function containsEntry(region:Null<Region>):String {
		if (region == null) return 'false';
		final tests = [];
		var i = 0;
		while (i < region.members.length) {
			final first = region.members[i];
			var last = first;
			i++;
			while (i < region.members.length && region.members[i] == last + 1) last = region.members[i++];
			tests.push(first == last ? 'resume == $first' : '(resume >= $first && resume <= $last)');
		}
		return '(' + tests.join(' || ') + ')';
	}

	/**
		A sequence, optionally containing single-block loops, needs no block dispatcher. Initial
		entry guards skip the prefix on a resume; ordinary edges become Haxe fallthrough. Each
		block is emitted once, including call-return sites. No code-size trade for a second body.
	**/
	function linearChain(fn:Func, order:Array<Int>):Bool {
		for (i in 0...order.length) {
			final at = order[i];
			final successors = fn.blocks.get(at).successors;
			if (i + 1 == order.length) return successors.length == 0;
			final next = order[i + 1];
			if (successors.indexOf(next) < 0) return false;
			final terminal = ir.byAddress.get(at).transfer;
			if (terminal != null) {
				final transfer = terminal.decoded;
				switch (transfer.op) {
					// Even a one-target recovered table needs its computed-target check.
					case JR | JALR if (transfer.isRegisterJump && transfer.rs != 31): return false;
					case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
						if (transfer.target != next && selfLoopExit(fn, at) != next) return false;
					case _:
				}
			}
			for (to in successors) {
				if (to != next && (to != at || selfLoopExit(fn, at) != next)) return false;
			}
		}
		return false;
	}

	/** A conditional single-block loop, with one distinct exit. Other CFGs keep the dispatcher. */
	function selfLoopExit(fn:Func, addr:Int):Null<Int> return ir.byAddress.get(addr).selfLoopExit();

	function publish(buf:StringBuf, ind:String):Void {
		if (registers != null) registers.publish(buf, ind);
	}

	function reload(buf:StringBuf, ind:String):Void {
		if (registers != null) registers.reload(buf, ind);
	}

	function reloadContinuation(buf:StringBuf, ind:String, entry:Int):Void {
		if (registers != null && entry >= 0 && entry < ir.blocks.length)
			registers.reloadContinuation(buf, ind, ir.blocks[entry].addr);
	}

	function emitReturn(buf:StringBuf, ind:String):Void {
		publish(buf, ind);
		buf.add(ind + 'return;\n');
	}

	function emitCheckpoint(buf:StringBuf, ind:String, entry:String, entryPump:Bool):Void {
		buf.add(ind + '#if recompsx_cooperative\n');
		buf.add(ind + 'if (core.Cooperative.wantsYield(ctx)) {\n');
		if (!entryPump) publish(buf, ind + '\t');
		buf.add(ind + '\tcore.Cooperative.suspend(ctx, ${continuationId()}, $entry, $entryPump);\n');
		buf.add(ind + '\treturn;\n' + ind + '} else {}\n' + ind + '#end\n');
	}

	function emitPump(buf:StringBuf, ind:String, entry:Int):Void {
		emitCheckpoint(buf, ind, Std.string(entry), false);
		buf.add('${ind}if (((ctx.cycles - ctx.nextEvent) | 0) >= 0) {\n');
		publish(buf, ind + '\t');
		buf.add(ind + '\tRuntime.pump(ctx);\n');
		// A nonlocal jump has already restored CpuState: never publish stale locals over it.
		buf.add(ind + '\t' + UNWIND_LINE + '\n');
		if (registers != null) registers.reloadBlock(buf, ind + '\t', ir.blocks[entry].addr);
		buf.add(ind + '} else {}\n');
	}

	/**
		The function-entry pump check, before register locals have been loaded.

		`| 0` is not decoration. The comparison is a subtraction so that it stays correct when the
		cycle counter passes 2^31, and that only works if the subtraction wraps — which C++ does
		and JavaScript does not (ADR-0004). Without it a deadline just past the wrap reads as long
		overdue on one target and correctly future on the other, and the two builds diverge.

		The due path also checks for halt/nonlocal unwind. Keep its explicit `else {}`: reflaxe.CPP
		used to delete multi-statement `if` bodies without one (upstream defect 8), and generated
		code should not depend on that fix being present.
	**/
	// Memory-mapped clocks read the bound CpuState directly.
	// Direct callers have already checked every operation that can unwind. Runtime.call guards
	// external entries. At a function entry only a due pump can introduce a new token, so keep
	// its check on that path instead of paying a second branch on every ordinary function call.
	static inline final PUMP_ENTRY =
		"\t\tif (((ctx.cycles - ctx.nextEvent) | 0) >= 0) {\n"
		+ "\t\t\tRuntime.pump(ctx);\n\t\t\tif (ctx.unwindToken != 0) return;\n\t\t} else {}\n";

	/**
		What makes `longjmp` able to leave.

		A non-local jump has to abandon every frame between where it was called and where it
		lands, and in a recompiled program those are host stack frames that only return normally.
		So `longjmp` restores the emulated registers, sets the token, and this line — after every
		call — carries the return all the way out. The top of the runtime then dispatches afresh
		to the saved address, with `sp` and `ra` already correct.

		A single return needs no `else` workaround for upstream defect 8.
	**/
	static inline final UNWIND_LINE = "if (ctx.unwindToken != 0) return;";

	/**
		Blocks that a back-edge returns to — the loop headers.

		The pump goes here rather than at each back-edge *source*, which is the same guarantee for
		less code: every path that re-enters a loop passes through its header, including the ones
		that are easy to miss when writing them out one at a time (a recovered switch table's
		edges, a conditional whose two arms are emitted as a ternary). One check per loop instead
		of one per branch, and no way to leave a path uncovered.

		Forward progress follows: any loop in the original program has a back-edge, so any loop in
		the generated program pumps, and an idle `b .` spin still lets time advance.
	**/
	function loopHeaders(fn:Func, blockAddrs:Array<Int>):Map<Int, Bool> {
		final headers:Map<Int, Bool> = [];
		for (block in ir.blocks) if (block.pump) headers.set(block.addr, true);
		return headers;
	}

	// ---- one block ------------------------------------------------------------------------------

	function emitBlock(buf:StringBuf, fn:Func, blockAddr:Int, indexOf:Map<Int, Int>,
			ind:String):Void {
		final block = ir.byAddress.get(blockAddr);
		// Arriving here ends whatever `resume` was steering towards.
		if (inRegions) buf.add(ind + 'resume = -1;\n');
		final idle = idlePlans.get(blockAddr);
		if (idle != null) emitIdlePrologue(buf, ind, idle);
		final stackPlan = optimize ? StackMemoryForwarding.plan(block.body) : null;
		var i = 0;
		while (i < block.body.length) {
			if (stackPlan != null) {
				switch (stackPlan[i]) {
					case ForwardLoad(source):
						final line = assign(block.body[i].decoded.rt, reg(source), false);
						if (line != "") buf.add(ind + line + '\n');
						i++;
						continue;
					case DropStore:
						i++;
						continue;
					case null:
				}
			}
			final fused = optimize ? PatternMatcher.match(block.body, i) : null;
			if (fused == null) {
				emitSimple(buf, ind, block.body[i].decoded, false, block.addr, i);
				i++;
			} else {
				emitFused(buf, ind, block.body[i].decoded, block.body[i + 1].decoded, fused.kind);
				i += fused.length;
			}
		}
		if (block.transfer != null) {
			emitTransfer(buf, fn, block.transfer.decoded,
				block.delaySlot == null ? null : block.delaySlot.decoded,
				blockAddr, indexOf, ind, block.cycles, block.instructions.length, block.resumeId);
		} else {
			emitCharges(buf, ind, block.cycles, block.instructions.length);
			if (block.successors.length == 1) emitGoto(buf, ind, block.successors[0], indexOf, blockAddr);
			else emitReturn(buf, ind);
		}
	}

	/** Emit a selected pair as one Haxe expression or one runtime helper call. */
	function emitFused(buf:StringBuf, ind:String, first:Instr, second:Instr,
			kind:FusedKind):Void {
		final text = switch (kind) {
			case ConstantOr:
				assign(first.rt, hex((first.immU << 16) | second.immU), false);
			case ConstantAdd:
				assign(first.rt, hex(((first.immU << 16) + second.immS) | 0), false);
			case MultLo:
				fusedResult(second.rd, 'Ops.multLo(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.mult(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case MultHi:
				fusedResult(second.rd, 'Ops.multHi(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.mult(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case MultuLo:
				fusedResult(second.rd, 'Ops.multuLo(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.multu(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case MultuHi:
				fusedResult(second.rd, 'Ops.multuHi(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.multu(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case DivLo:
				fusedResult(second.rd, 'Ops.divLo(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.div(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case DivHi:
				fusedResult(second.rd, 'Ops.divHi(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.div(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case DivuLo:
				fusedResult(second.rd, 'Ops.divuLo(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.divu(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
			case DivuHi:
				fusedResult(second.rd, 'Ops.divuHi(ctx, ${reg(first.rs)}, ${reg(first.rt)})',
					'Ops.divu(ctx, ${reg(first.rs)}, ${reg(first.rt)})');
		};
		if (text != "") buf.add(ind + text + '\n');
	}

	/** A discarded MFLO/MFHI still leaves the multiply/divide result in HI:LO. */
	function fusedResult(dest:Int, result:String, sideEffect:String):String
		return dest == 0 ? '$sideEffect;' : assign(dest, result, false);

	/** Records the skip prologue for a loop that proves idle; only an optimized build takes it. */
	function planIdle(members:Array<Int>, headerId:Int):Void {
		if (!optimize) return;
		final plan = IdleLoopPlan.analyze(ir, members, headerId);
		if (plan != null) idlePlans.set(ir.blocks[headerId].addr, plan);
	}

	/**
		The idle-loop prologue, at the head of a turn, after the pump.

		First a dry turn: the loop's instructions are evaluated once into shadow locals — loads
		guarded to plain memory and away from the counter slot, the slot's store left out, each
		invariant branch checked to be going round again. If all of that holds, how many turns
		can run before the next event and before the counter's branch leaves is computed, and
		all but the last of them are taken at once: the cycles are charged, the slot is advanced,
		and the turn below runs as the last one, leaving every register as the loop itself
		would. Exact by construction: IdleLoopPlan says what a turn is, core.IdleLoop counts.
	**/
	function emitIdlePrologue(buf:StringBuf, ind:String, plan:IdleLoopPlan):Void {
		final in1 = ind + '\t', in2 = ind + '\t\t', in3 = ind + '\t\t\t';
		buf.add(ind + '// Idle loop: all but the last of the turns before the next event are taken by\n');
		buf.add(ind + '// arithmetic (exact; core.IdleLoop), and the last one runs below.\n');
		buf.add(ind + '{\n');
		buf.add(in1 + 'var idleOk = true;\n');
		final names:Map<Int, String> = [];
		for (r in plan.written) {
			final name = 'idle_' + Instr.regName(r);
			names.set(r, name);
			buf.add(in1 + 'var $name = 0;\n');
		}
		final slot = plan.slot;
		if (slot != null) {
			buf.add(in1 + 'final idleSlot = ${addrExpr(slot.load)};\n');
			buf.add(in1 + 'var idleTop = 0;\n');
		}
		shadow = names;
		var loads = 0;
		for (entry in plan.list) {
			final i = entry.decoded;
			if (i.isNop) continue;
			switch (i.op) {
				case LW if (plan.isReload(i)):
					buf.add(in1 + '${reg(i.rt)} = idleStored;\n');
				case LB | LBU | LH | LHU | LW:
					final addr = 'idleAddr$loads';
					final diff = 'idleDiff$loads';
					loads++;
					final width = switch (i.op) { case LW: 4; case LH | LHU: 2; case _: 1; };
					final read = switch (i.op) {
						case LW: 'read32'; case LH: 'read16s'; case LHU: 'read16u';
						case LB: 'read8s'; case _: 'read8u';
					};
					buf.add(in1 + 'final $addr = ${addrExpr(i)};\n');
					if (plan.isSlotLoad(i)) {
						buf.add(in1 + 'if (Memory.isPlainMemory($addr)) { ${reg(i.rt)} = Memory.read32($addr); idleTop = ${reg(i.rt)}; } else { idleOk = false; }\n');
					} else if (slot != null) {
						buf.add(in1 + 'final $diff = ($addr - idleSlot) | 0;\n');
						buf.add(in1 + 'if (Memory.isPlainMemory($addr) && ($diff <= -$width || $diff >= 4)) ${reg(i.rt)} = Memory.$read($addr); else idleOk = false;\n');
					} else {
						buf.add(in1 + 'if (Memory.isPlainMemory($addr)) ${reg(i.rt)} = Memory.$read($addr); else idleOk = false;\n');
					}
				case SW:
					if (slot != null) buf.add(in1 + 'final idleStored = ${reg(i.rt)};\n');
				case J:
				case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
					final exit = plan.invariantExit(i.addr);
					if (exit != null) buf.add(in1 + 'if ((${condition(i)}) != ${exit.continueWhen}) idleOk = false; else {}\n');
				case _:
					final line = simple(i);
					if (line != "") buf.add(in1 + line + '\n');
			}
		}
		shadow = null;
		buf.add(in1 + 'if (idleOk) {\n');
		buf.add(in2 + 'var idleTurns = core.IdleLoop.untilEvent(ctx.cycles, ctx.nextEvent, ${plan.cycles});\n');
		final exit = plan.counterExit;
		if (slot != null && exit != null) {
			final other = reg(exit.other);
			if (exit.exitOnEqual) buf.add(in2 + 'final idleExit = core.IdleLoop.untilEqual(idleTop, ${slot.delta}, $other);\n');
			else buf.add(in2 + 'final idleExit = ((idleTop + ${slot.delta}) | 0) == $other ? 2 : 1;\n');
			buf.add(in2 + 'if (idleExit - 1 < idleTurns) idleTurns = idleExit - 1; else {}\n');
		}
		buf.add(in2 + 'if (idleTurns >= 2) {\n');
		buf.add(in3 + 'final idleSkip = idleTurns - 1;\n');
		buf.add(in3 + 'ctx.cycles = (ctx.cycles + shim.IntMath.mul(${plan.cycles}, idleSkip)) | 0;\n');
		if (slot != null) buf.add(in3 + 'Memory.write32(idleSlot, (idleTop + shim.IntMath.mul(${slot.delta}, idleSkip)) | 0);\n');
		buf.add(in3 + '#if recompsx_insns\n');
		buf.add(in3 + 'Runtime.insns = (Runtime.insns + shim.IntMath.mul(${plan.instructions}, idleSkip)) | 0;\n');
		buf.add(in3 + 'Runtime.blocks = (Runtime.blocks + shim.IntMath.mul(${plan.turn.length}, idleSkip)) | 0;\n');
		buf.add(in3 + '#end\n');
		buf.add(in3 + 'core.IdleLoop.note(idleSkip);\n');
		buf.add(in2 + '} else {}\n');
		buf.add(in1 + '} else {}\n');
		buf.add(ind + '}\n');
	}

	/** Charge every original instruction, including eliminated instructions and delay slots. */
	static function emitCharges(buf:StringBuf, ind:String, cycles:Int, insns:Int):Void {
		if (cycles > 0) buf.add('${ind}ctx.cycles = (ctx.cycles + $cycles) | 0;\n');
		buf.add('${ind}#if recompsx_insns\n');
		buf.add('${ind}Runtime.insns = (Runtime.insns + $insns) | 0;\n');
		buf.add('${ind}Runtime.blocks = (Runtime.blocks + 1) | 0;\n');
		buf.add('${ind}#end\n');
	}

	function emitTransfer(buf:StringBuf, fn:Func, instr:Instr, slot:Null<Instr>, blockAddr:Int,
			indexOf:Map<Int, Int>, ind:String, cycles:Int, insns:Int, tempCounter:Int):Void {
		final retAddr = instr.addr + 8;
		continuation = indexOf.exists(retAddr) ? indexOf.get(retAddr) : -1;
		inline function emitSlot():Void {
			if (slot == null) return;
			emitSimple(buf, ind, slot, true);
		}

		inline function bump():Void {
			emitCharges(buf, ind, cycles, insns);
		}

		switch (instr.op) {
			case JR | JALR if (instr.isRegisterJump && instr.rs == 31):
				emitSlot();
				bump();
				emitReturn(buf, ind);

			case JR | JALR if (instr.isRegisterJump):
				final table = discovery.tables.get(instr.addr);
				final constant = discovery.constantJumps.get(instr.addr);
				if (table != null) {
					final t = 'target_${tempCounter}';
					buf.add('${ind}final $t = ${reg(instr.rs)};\n');
					emitSlot();
					bump();
					buf.add('${ind}switch ($t) {\n');
					// A switch may send several indices to the same arm, which shows up here as a
					// repeated case label. Emit each target once.
					final emitted:Map<Int, Bool> = [];
					for (target in table.targets) {
						if (indexOf.exists(target) && !emitted.exists(target)) {
							emitted.set(target, true);
							// Inside a region the arm records a forward target or continues the
							// loop; a `break` here would leave the switch, not the loop, on C++,
							// and RegionPlan never places a table where one would be needed.
							final kind = jumpKind(target, indexOf);
							if (kind == JUMP_BREAK) throw 'table target ${hex(target)} outside its loop at ${hex(instr.addr)}';
							buf.add('$ind\tcase ${hex(target)}: ' + (kind == JUMP_FALL ? '{}' : jumpText(kind, target, indexOf)) + '\n');
						}
					}
					buf.add('$ind\tdefault:\n');
					publish(buf, ind + '\t\t');
					buf.add('$ind\t\tctx.pc = $t; Runtime.call(ctx, $t); return;\n');
					buf.add('$ind}\n');
				} else if (constant != null && isKernelVector(constant.target)) {
					emitSlot();
					bump();
					publish(buf, ind);
					buf.add('${ind}ctx.pc = ${hex(instr.addr)};\n');
					buf.add('${ind}Kernel.call(ctx, ${hex(constant.target)}, ctx.t1);'
						+ '   // BIOS ${vectorName(constant.target)}('
						+ (constant.fnNumber >= 0 ? hex16(constant.fnNumber) : "?") + ')\n');
					buf.add('${ind}return;\n');
				} else {
					final t = 'target_${tempCounter}';
					buf.add('${ind}final $t = ${reg(instr.rs)};\n');
					emitSlot();
					bump();
					publish(buf, ind);
					buf.add('${ind}ctx.pc = $t;\n');
					buf.add('${ind}Runtime.call(ctx, $t);   // computed jump, dispatched by address\n');
					buf.add('${ind}return;\n');
				}

			case JAL:
				// The link is written before the slot runs, which matters when the slot reads $ra.
				buf.add('${ind}${reg(31)} = ${hex(retAddr)};\n');
				emitSlot();
				bump();
				emitCall(buf, ind, instr.target);
				emitFallThrough(buf, fn, ind, indexOf, retAddr);

			case JALR:
				final t = 'target_${tempCounter}';
				// The target is latched before the link is written, so `jalr $ra, $ra` works.
				buf.add('${ind}final $t = ${reg(instr.rs)};\n');
				if (instr.rd != 0) buf.add('${ind}${reg(instr.rd)} = ${hex(retAddr)};\n');
				emitSlot();
				bump();
				publish(buf, ind);
				buf.add('${ind}ctx.pc = $t;\n');
				buf.add('${ind}Runtime.call(ctx, $t);\n');
				emitCallUnwind(buf, ind, continuation);
				reloadContinuation(buf, ind, continuation);
				emitFallThrough(buf, fn, ind, indexOf, retAddr);

			case J:
				final target = instr.target;
				emitSlot();
				bump();
				if (indexOf.exists(target)) {
					emitGoto(buf, ind, target, indexOf, instr.addr);
				} else {
					emitCall(buf, ind, target, false);        // a tail call
					buf.add('${ind}return;\n');
				}

			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ | BLTZAL | BGEZAL:
				final captured = capturedBranch == blockAddr;
				final cond = captured ? 'take_${tempCounter}' : 'branch_${tempCounter}';
				// The condition is evaluated before the slot, because the slot may overwrite one
				// of the registers it reads. This is the single most common way to get delay
				// slots wrong.
				buf.add('${ind}${captured ? "" : "final "}$cond = ${condition(instr)};\n');
				if (instr.op == Op.BLTZAL || instr.op == Op.BGEZAL) {
					// The link happens whether or not the branch is taken.
					buf.add('${ind}${reg(31)} = ${hex(retAddr)};   // linked even when not taken\n');
				}
				emitSlot();
				bump();

				final taken = instr.target;
				final notTaken = instr.addr + 8;
				final takenIdx = indexOf.exists(taken) ? indexOf.get(taken) : -1;
				final notTakenIdx = indexOf.exists(notTaken) ? indexOf.get(notTaken) : -1;

				if (captured) {
					// The enclosing Choice owns both arms. Slot and cycles already ran.
				} else if (instr.op == Op.BLTZAL || instr.op == Op.BGEZAL) {
					buf.add('${ind}if ($cond) {\n');
					emitCall(buf, ind + '\t', taken);
					buf.add('${ind}} else {}\n');
					emitFallThrough(buf, fn, ind, indexOf, retAddr);
				} else if (nativeLoop != null && taken == nativeLoop) {
					buf.add('${ind}if (!$cond) break;\n');
				} else {
					final takenKind = jumpKind(taken, indexOf);
					final notTakenKind = jumpKind(notTaken, indexOf);
					if (takenKind == JUMP_FALL && notTakenKind == JUMP_FALL) {
						// Both outcomes are the following block; the slot and cycles already ran.
					} else if (takenKind == JUMP_DISPATCH && notTakenKind == JUMP_DISPATCH) {
						buf.add('${ind}bb = $cond ? $takenIdx : $notTakenIdx; continue;\n');
					} else if (takenKind == JUMP_RETURN && notTakenKind == JUMP_RETURN) {
						emitReturn(buf, ind);
					} else if (takenKind == JUMP_FALL) {
						buf.add('${ind}if (!$cond) ' + arm(notTakenKind, notTaken, indexOf, ind) + ' else {}\n');
					} else if (notTakenKind == JUMP_FALL) {
						buf.add('${ind}if ($cond) ' + arm(takenKind, taken, indexOf, ind) + ' else {}\n');
					} else {
						buf.add('${ind}if ($cond) ' + arm(takenKind, taken, indexOf, ind)
							+ ' else ' + arm(notTakenKind, notTaken, indexOf, ind) + '\n');
					}
				}

			case _:
				buf.add('$ind// unhandled transfer: ${Disasm.text(instr)}\n');
				emitReturn(buf, ind);
		}
	}

	function emitCall(buf:StringBuf, ind:String, target:Int, resumes:Bool = true):Void {
		final t = Vaddr.canonRam(target);
		final cls = staticTargetOf(t);
		publish(buf, ind);
		if (cls != null) {
			buf.add('$ind$cls.${Discovery.defaultName(t)}(ctx);\n');
		} else {
			// The kernel, code this build never found, or a window whose occupant is decided at
			// run time. All three are the same instruction here: ask by address.
			buf.add('${ind}ctx.pc = ${hex(t)};\n');
			buf.add('${ind}Runtime.call(ctx, ${hex(t)});\n');
		}
		emitCallUnwind(buf, ind, resumes ? continuation : -1);
		if (resumes) reloadContinuation(buf, ind, continuation);
	}

	function emitCallUnwind(buf:StringBuf, ind:String, entry:Int):Void {
		buf.add(ind + '#if recompsx_cooperative\n');
		buf.add(ind + 'if (core.Cooperative.afterCall(ctx, ${continuationId()}, $entry)) return;\n');
		buf.add(ind + '#else\n' + ind + UNWIND_LINE + '\n' + ind + '#end\n');
	}

	function continuationId():String return continuationToken == null ? hex(functionAddr) : continuationToken;

	function emitFallThrough(buf:StringBuf, fn:Func, ind:String, indexOf:Map<Int, Int>,
			addr:Int):Void {
		emitJump(buf, ind, addr, indexOf);
	}

	function emitGoto(buf:StringBuf, ind:String, target:Int, indexOf:Map<Int, Int>,
			fallback:Int):Void {
		emitJump(buf, ind, target, indexOf);
	}

	// ---- transfers -------------------------------------------------------------------------------

	static inline final JUMP_FALL = 0;       // control falls into the target: nothing to emit
	static inline final JUMP_CONTINUE = 1;   // the enclosing native loop's header
	static inline final JUMP_BREAK = 2;      // out of the enclosing native loop, target recorded
	static inline final JUMP_FORWARD = 3;    // a later part of an enclosing sequence, recorded
	static inline final JUMP_DISPATCH = 4;   // another case of the block dispatcher
	static inline final JUMP_RETURN = 5;     // outside the function: publish and return

	/**
		How control reaches `target` from here. The order is the nesting: the block that follows
		in a sequence needs no statement; the innermost native loop owns its header and, by a
		recorded `break`, everything outside its members; a later part of an enclosing sequence
		is reached by recording it and letting the guards skip; anything else still in the
		function goes through the dispatcher — which no native loop may contain — and anything
		outside it leaves.
	**/
	function jumpKind(target:Int, indexOf:Map<Int, Int>):Int {
		if (linearNext != null && target == linearNext) return JUMP_FALL;
		if (loopHead != null && target == loopHead) return JUMP_CONTINUE;
		if (loopHead != null && !loopMembers.exists(idOf(target))) return JUMP_BREAK;
		var frame = frames.length - 1;
		while (frame >= loopFrame) {
			final at = frames[frame].entries.indexOf(target);
			if (at > frames[frame].index) return JUMP_FORWARD;
			if (at >= 0) throw 'backward transfer to ${hex(target)} inside a sequence at ${hex(functionAddr)}';
			frame--;
		}
		if (loopHead != null) throw 'unstructured transfer to ${hex(target)} inside a native loop at ${hex(functionAddr)}';
		return indexOf.exists(target) ? JUMP_DISPATCH : JUMP_RETURN;
	}

	inline function idOf(target:Int):Int return ir.byAddress.get(target).resumeId;

	/** The one-line statement for a jump that is not a fall-through or a return. */
	function jumpText(kind:Int, target:Int, indexOf:Map<Int, Int>):String {
		return switch (kind) {
			case JUMP_CONTINUE: 'resume = -1; continue;';
			case JUMP_BREAK: 'resume = ${idOf(target)}; break;';
			case JUMP_FORWARD: 'resume = ${idOf(target)};';
			case _: 'bb = ${indexOf.get(target)}; continue;';
		};
	}

	function emitJump(buf:StringBuf, ind:String, target:Int, indexOf:Map<Int, Int>):Void {
		final kind = jumpKind(target, indexOf);
		if (kind == JUMP_FALL) return;
		if (kind == JUMP_RETURN) emitReturn(buf, ind);
		else buf.add(ind + jumpText(kind, target, indexOf) + '\n');
	}

	/** One arm of a branch as a braced block: a one-liner inline, a return on its own lines. */
	function arm(kind:Int, target:Int, indexOf:Map<Int, Int>, ind:String):String {
		if (kind != JUMP_RETURN) return '{ ' + jumpText(kind, target, indexOf) + ' }';
		final lines = new StringBuf();
		lines.add('{\n');
		emitReturn(lines, ind + '\t');
		lines.add(ind + '}');
		return lines.toString();
	}

	// ---- instructions without a delay slot -------------------------------------------------------

	function emitSimple(buf:StringBuf, ind:String, i:Instr, slot:Bool = false,
			afterBlock:Null<Int> = null, afterIndex:Int = -1):Void {
		final barrier = i.op == Op.SYSCALL || i.op == Op.BREAK;
		if (barrier) publish(buf, ind);
		final line = simple(i, afterBlock, afterIndex);
		if (line != "") buf.add(ind + line + (slot ? '   // delay slot' : '') + '\n');
		if (barrier) {
			buf.add(ind + UNWIND_LINE + '\n');
			if (registers != null && afterBlock != null)
				registers.reloadAfter(buf, ind, afterBlock, afterIndex);
			else reload(buf, ind);
		}
	}

	/** The Haxe statement for one non-branching instruction, or "" for a nop. */
	function simple(i:Instr, afterBlock:Null<Int> = null, afterIndex:Int = -1):String {
		if (i.isNop) return "";

		final rd = i.rd, rt = i.rt, rs = i.rs;
		return switch (i.op) {
			// Arithmetic wraps. `| 0` is what makes JavaScript agree with the hardware; C++
			// folds it away. See ADR-0004.
			// Folded where a source is $zero or the immediate is 0. These are not micro-
			// optimisations — the compiler would fold them anyway — but the generated code is
			// read by people during bring-up, and `ctx.v0 = 4` says what `(0 + 4) | 0` hides.
			case ADDI:
				if (rs == 0) assign(rt, Std.string(i.immS), false)
				else if (i.immS == 0) assign(rt, reg(rs), false)
				else assign(rt, '${reg(rs)} + ${i.immS}', true);
			case ADDIU:
				if (rs == 0) pureAssign(rt, Std.string(i.immS), false, afterBlock, afterIndex)
				else if (i.immS == 0) pureAssign(rt, reg(rs), false, afterBlock, afterIndex)
				else pureAssign(rt, '${reg(rs)} + ${i.immS}', true, afterBlock, afterIndex);
			case ADD | ADDU:
				if (rs == 0) pureAssign(rd, reg(rt), false, afterBlock, afterIndex)
				else if (rt == 0) pureAssign(rd, reg(rs), false, afterBlock, afterIndex)
				else if (i.op == Op.ADD) assign(rd, '${reg(rs)} + ${reg(rt)}', true)
				else pureAssign(rd, '${reg(rs)} + ${reg(rt)}', true, afterBlock, afterIndex);
			case SUB | SUBU:
				if (rt == 0 && i.op == Op.SUB) assign(rd, reg(rs), false)
				else if (rt == 0) pureAssign(rd, reg(rs), false, afterBlock, afterIndex)
				else if (i.op == Op.SUB) assign(rd, '${reg(rs)} - ${reg(rt)}', true)
				else pureAssign(rd, '${reg(rs)} - ${reg(rt)}', true, afterBlock, afterIndex);

			case AND:  pureAssign(rd, '${reg(rs)} & ${reg(rt)}', false, afterBlock, afterIndex);
			case OR:
				// `or rd, rs, $zero` is the canonical register move.
				if (rt == 0) pureAssign(rd, reg(rs), false, afterBlock, afterIndex)
				else if (rs == 0) pureAssign(rd, reg(rt), false, afterBlock, afterIndex)
				else pureAssign(rd, '${reg(rs)} | ${reg(rt)}', false, afterBlock, afterIndex);
			case XOR:  pureAssign(rd, '${reg(rs)} ^ ${reg(rt)}', false, afterBlock, afterIndex);
			case NOR:  pureAssign(rd, '~(${reg(rs)} | ${reg(rt)})', false, afterBlock, afterIndex);

			case ANDI: pureAssign(rt, '${reg(rs)} & ${hex16(i.immU)}', false, afterBlock, afterIndex);
			case ORI:  pureAssign(rt, '${reg(rs)} | ${hex16(i.immU)}', false, afterBlock, afterIndex);
			case XORI: pureAssign(rt, '${reg(rs)} ^ ${hex16(i.immU)}', false, afterBlock, afterIndex);
			case LUI:  pureAssign(rt, hex(i.immU << 16), false, afterBlock, afterIndex);

			case SLT:   pureAssign(rd, '${reg(rs)} < ${reg(rt)} ? 1 : 0', false, afterBlock, afterIndex);
			case SLTI:  pureAssign(rt, '${reg(rs)} < ${i.immS} ? 1 : 0', false, afterBlock, afterIndex);
			// Unsigned comparison on a signed type: flip both sign bits and compare.
			case SLTU:  pureAssign(rd, '(${reg(rs)} ^ 0x80000000) < (${reg(rt)} ^ 0x80000000) ? 1 : 0', false, afterBlock, afterIndex);
			case SLTIU: pureAssign(rt, '(${reg(rs)} ^ 0x80000000) < ${hex(i.immS ^ 0x80000000)} ? 1 : 0', false, afterBlock, afterIndex);

			case SLL:  pureAssign(rd, '${reg(rt)} << ${i.shamt}', false, afterBlock, afterIndex);
			case SRL:  pureAssign(rd, '${reg(rt)} >>> ${i.shamt}', false, afterBlock, afterIndex);
			case SRA:  pureAssign(rd, '${reg(rt)} >> ${i.shamt}', false, afterBlock, afterIndex);
			case SLLV: pureAssign(rd, '${reg(rt)} << (${reg(rs)} & 31)', false, afterBlock, afterIndex);
			case SRLV: pureAssign(rd, '${reg(rt)} >>> (${reg(rs)} & 31)', false, afterBlock, afterIndex);
			case SRAV: pureAssign(rd, '${reg(rt)} >> (${reg(rs)} & 31)', false, afterBlock, afterIndex);

			case MULT:  'Ops.mult(ctx, ${reg(rs)}, ${reg(rt)});';
			case MULTU: 'Ops.multu(ctx, ${reg(rs)}, ${reg(rt)});';
			case DIV:   'Ops.div(ctx, ${reg(rs)}, ${reg(rt)});';
			case DIVU:  'Ops.divu(ctx, ${reg(rs)}, ${reg(rt)});';
			case MFHI:  pureAssign(rd, 'ctx.hi', false, afterBlock, afterIndex);
			case MFLO:  pureAssign(rd, 'ctx.lo', false, afterBlock, afterIndex);
			case MTHI:  'ctx.hi = ${reg(rs)};';
			case MTLO:  'ctx.lo = ${reg(rs)};';

			// A load into $zero still performs the read: half the address space is hardware.
			case LB:  load(rt, 'Memory.read8s(${addrExpr(i)})');
			case LBU: load(rt, 'Memory.read8u(${addrExpr(i)})');
			case LH:  load(rt, 'Memory.read16s(${addrExpr(i)})');
			case LHU: load(rt, 'Memory.read16u(${addrExpr(i)})');
			case LW:  load(rt, 'Memory.read32(${addrExpr(i)})');
			case LWL: load(rt, 'Memory.lwl(${addrExpr(i)}, ${reg(rt)})');
			case LWR: load(rt, 'Memory.lwr(${addrExpr(i)}, ${reg(rt)})');

			case SB: 'Memory.write8(${addrExpr(i)}, ${reg(rt)});';
			case SH: 'Memory.write16(${addrExpr(i)}, ${reg(rt)});';
			case SW: 'Memory.write32(${addrExpr(i)}, ${reg(rt)});';
			case SWL: 'Memory.swl(${addrExpr(i)}, ${reg(rt)});';
			case SWR: 'Memory.swr(${addrExpr(i)}, ${reg(rt)});';

			case SYSCALL: 'ctx.pc = ${hex(i.addr)}; Kernel.syscall(ctx, ${i.code});';
			case BREAK:   'ctx.pc = ${hex(i.addr)}; Kernel.brk(ctx, ${i.code});';

			case MFC0: assign(rt, 'Runtime.mfc0(ctx, ${i.rd})', false);
			case MTC0: 'Runtime.mtc0(ctx, ${i.rd}, ${reg(rt)});';
			case RFE:  'Runtime.rfe(ctx);';

			case MFC2: assign(rt, 'Gte.getData(ctx, ${i.rd})', false);
			case MTC2: 'Gte.setData(ctx, ${i.rd}, ${reg(rt)});';
			case CFC2: assign(rt, 'Gte.getCtrl(ctx, ${i.rd})', false);
			case CTC2: 'Gte.setCtrl(ctx, ${i.rd}, ${reg(rt)});';
			case LWC2: 'Gte.setData(ctx, ${i.rt}, Memory.read32(${addrExpr(i)}));';
			case SWC2: 'Memory.write32(${addrExpr(i)}, Gte.getData(ctx, ${i.rt}));';
			case COP2CMD: gteCommand(i.code);

			case _: '// unhandled: ${Disasm.text(i)}';
		}
	}

	/**
		A GTE command word is a constant, so its operation is called by name with the fields the
		runtime's `execute` would have decoded from it; `execute` itself is kept for any word the
		table below does not know, so an unknown operation still reports itself at run time.
	**/
	static function gteCommand(code:Int):String {
		final sf = (code & 0x80000) != 0 ? 12 : 0;
		final lm = (code & 0x400) != 0 ? "true" : "false";
		final args = '$sf, $lm';
		return switch (code & 0x3F) {
			case 0x01: 'Gte.cmdRtps($args);';
			case 0x30: 'Gte.cmdRtpt($args);';
			case 0x06: 'Gte.cmdNclip();';
			case 0x2D: 'Gte.cmdAvsz3();';
			case 0x2E: 'Gte.cmdAvsz4();';
			case 0x12: 'Gte.cmdMvmva($args, ${hex(code)});';
			case 0x28: 'Gte.cmdSqr($sf);';
			case 0x0C: 'Gte.cmdOp($args);';
			case 0x3D: 'Gte.cmdGpf($args);';
			case 0x3E: 'Gte.cmdGpl($args);';
			case 0x10: 'Gte.cmdDpcs($args);';
			case 0x2A: 'Gte.cmdDpct($args);';
			case 0x11: 'Gte.cmdIntpl($args);';
			case 0x29: 'Gte.cmdDcpl($args);';
			case 0x1E: 'Gte.cmdNcs($args);';
			case 0x20: 'Gte.cmdNct($args);';
			case 0x13: 'Gte.cmdNcds($args);';
			case 0x16: 'Gte.cmdNcdt($args);';
			case 0x1B: 'Gte.cmdNccs($args);';
			case 0x3F: 'Gte.cmdNcct($args);';
			case 0x1C: 'Gte.cmdCc($args);';
			case 0x14: 'Gte.cmdCdp($args);';
			case _: 'Gte.execute(ctx, ${hex(code)});';
		};
	}

	/** `rs + offset`, with the offset folded away when it is zero. */
	function addrExpr(i:Instr):String {
		if (i.rs == 0) return hex(i.immS);
		if (i.immS == 0) return reg(i.rs);
		return '(${reg(i.rs)} + ${i.immS}) | 0';
	}

	/** An assignment, dropped entirely when the destination is $zero. */
	function assign(dest:Int, expr:String, wraps:Bool):String {
		if (dest == 0) return "";
		if (!wraps && expr == reg(dest)) return "";
		return '${reg(dest)} = ' + (wraps ? '($expr) | 0;' : '$expr;');
	}

	/** Drop a pure GPR write when CFG liveness proves no later guest observation. */
	function pureAssign(dest:Int, expr:String, wraps:Bool, block:Null<Int>, index:Int):String {
		if (dest != 0 && registers != null && block != null && registers.canDropPureWrite(block)
			&& !registers.liveAfter(block, index, dest)) return "";
		return assign(dest, expr, wraps);
	}

	/** A load whose result is discarded still has to happen: the address may be a register. */
	function load(dest:Int, expr:String):String {
		return dest == 0 ? '$expr;   // result discarded; the read may have side effects'
			: '${reg(dest)} = $expr;';
	}

	function condition(i:Instr):String {
		return switch (i.op) {
			case BEQ:  '${reg(i.rs)} == ${reg(i.rt)}';
			case BNE:  '${reg(i.rs)} != ${reg(i.rt)}';
			case BLEZ: '${reg(i.rs)} <= 0';
			case BGTZ: '${reg(i.rs)} > 0';
			case BLTZ | BLTZAL: '${reg(i.rs)} < 0';
			case BGEZ | BGEZAL: '${reg(i.rs)} >= 0';
			case _: 'false';
		}
	}

	// ---- naming -----------------------------------------------------------------------------------

	/** `$zero` is a literal, not a field: it is the most-read register and costs nothing. A
	    register the idle prologue shadows is its shadow local while the dry turn is emitted. */
	inline function reg(n:Int):String
		return n == 0 ? "0" : (shadow != null && shadow.exists(n) ? shadow.get(n)
			: (registers != null && registers.used.indexOf(n) >= 0 ? "" : "ctx.") + Instr.regName(n));

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}

	static function hex16(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 12;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}

	static inline function isKernelVector(a:Int):Bool
		return a == 0xA0 || a == 0xB0 || a == 0xC0;

	static function vectorName(a:Int):String
		return a == 0xA0 ? "A0" : (a == 0xB0 ? "B0" : "C0");
}

/** One enclosing sequence during emission: its part entries, and which part is being emitted. */
private class SequenceFrame {
	public final entries:Array<Int>;
	public var index:Int = 0;
	public function new(entries:Array<Int>) this.entries = entries;
}
