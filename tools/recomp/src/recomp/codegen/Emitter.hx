package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.ir.Effect;
import recomp.ir.FunctionIR;
import recomp.codegen.RegionPlan.Region;
import recomp.mips.Disasm;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.codegen.PatternMatcher.FusedKind;
import recomp.codegen.IdleLoopPlan;

/**
	Turns analysed MIPS into Haxe.

	Guest registers are CpuState's fields, read and written in place, so the state a call, a
	return, a pump or a trap sees is always the machine's own, and nothing is copied at those
	boundaries (ADR-0029, which replaced ADR-0007's scalar locals). A looping leaf — no guest
	call, trap or unknown instruction — keeps them in locals instead, where no copy can go stale.
	A bounded leaf uses scalar parameters/results, with checked spans for plain-memory effects.
	Its wrapper and guarded direct callers preserve all entry work and accounting (ADR-0044).
	Pure intervals and opt-in bounded acyclic regions inside other functions use local values, with
	all changed registers published before the next observation. Linear CFGs become sequences, natural loops with one
	exit become native `while` loops, and
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

	`optimize=false` keeps the block dispatcher, and no fusion, forwarding or idle skip, as a
	differential reference. `structureRegions=false` isolates the simple-loop baseline.
**/
class Emitter {
	final image:Image;
	final discovery:Discovery;
	final optimize:Bool;
	final structureRegions:Bool;
	final scalarFunctions:Bool;
	final valueRegions:Bool;
	final valueCfg:Bool;
	var valueScope:Null<ValueCfg> = null;
	var valuePrefix = "";
	var suppressValueCfg = false;
	var ir:FunctionIR;
	var functionAddr:Int;
	/** Program substitutes a pinned handle after body deduplication; fixtures use addresses. */
	public var continuationToken:Null<String> = null;
	var continuation:Int;
	// The guest address a call being emitted returns to: what a return elsewhere is matched
	// against when it passes this frame (ADR-0027).
	var callReturnAddr:Int = 0;
	// The function has returns checked against the `$ra` it was entered with, kept in `entryRa`.
	var entryRaLocal = false;
	/** Whether another function hands over to the one being emitted (Discovery.cutAtEntries); after
	    `emitFunction`, the one it emitted. */
	public var hopTarget(default, null) = false;
	var hopTargets:Null<Map<Int, Bool>> = null;
	/** The function being emitted. */
	var curFn:Null<Func> = null;
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
	// In a function with a block dispatcher (`while (true) switch (bb)`): each block index's case,
	// by the first index that case lists — its label on C++ (dispatchJump). Null without one.
	var dispatchCase:Null<Map<Int, Int>> = null;
	// Loops proved idle (IdleLoopPlan), by header address: the header emits the skip prologue.
	var idlePlans:Map<Int, IdleLoopPlan> = [];

	/** Whether the function emitted last skips the idle turns of a loop (Sh4Emitter declines it). */
	public function emittedIdleLoop():Bool return idlePlans.keys().hasNext();
	// A leaf's registers, held in locals (null: every register is a CpuState field), and which of
	// them it writes, which is what it publishes.
	var leafUsed:Null<Array<Int>> = null;
	var leafWritten:Array<Int> = [];
	// While the idle prologue evaluates a dry turn, the registers it writes are these locals.
	var shadow:Null<Map<Int, String>> = null;
	// The span (Memory.span) the load or store being emitted belongs to: its local (a shim.Span) and
	// the instruction's offset. Null: the access decodes its own address, as always.
	var span:Null<SpanAccess> = null;
	var spanCount = 0;
	// The loads and stores whose base holds a port (PortBases), by address: on fastmem they decode
	// their address as every other target does instead of trapping (Memory's `pt`/`pf`).
	var portAccesses:Map<Int, Bool> = [];
	// Function spans (planFunctionSpans): a base register's span for the whole function, by
	// register, set wherever the register's value may have changed. Null: none.
	var fspans:Null<Map<Int, FunctionSpan>> = null;
	var scalarBorrows:Map<Int, ScalarBorrow> = [];
	// Where each function span must be taken again (planFspanLiveness), and the block being emitted.
	var fspanLive:Null<FspanLive> = null;
	var curBlock = -1;
	// The function's cycle count is its local `cyc` (an optimized build), written to CpuState
	// where anything else can read it and read back where anything else may have moved it.
	var cycLocal = false;

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

	/**
		What a call by address is emitted as: `(ctx, target)`, runs the target and the tail jumps
		it leaves. A program has `FnTable.run`, which keeps its answers and skips the runtime's
		dispatcher on a hit; a fixture compiled without a program keeps `Runtime.call`.
	**/
	public var dynamicCall = "Runtime.call";

	/**
		What a call through a register (JALR) is emitted as when the program keeps an answer per
		call site: `(ctx, target, site)`, `site` the place's own number. Null: `dynamicCall`.
		Each site is written as `SITE_TOKEN` + its ordinal in the function + `__`, which `Program`
		numbers program-wide after it has compared the bodies for duplicates, so two identical
		functions still compare identical (a duplicate's sites are its owner's).
	**/
	public var dynamicSite:Null<String> = null;
	public static inline final SITE_TOKEN = "__RECOMPSX_SITE_";
	var siteOrdinal = 0;

	/**
		What a call to a function may write, transitively, as a register mask (bit n for $n):
		`Program`'s summaries of the functions a direct call reaches; every register (ALL_REGS)
		for anything they cannot see. Read by the function spans' liveness: a span on a register
		the callee never writes need not be taken again after the call.
	**/
	public var writesOf:Int -> Int = _ -> ALL_REGS;
	public static inline final ALL_REGS = 0xFFFFFFFE;
	/** Proven scalar body for an always-resident direct callee; Program resolves universes. */
	public var scalarTargetOf:Int -> Null<ScalarPlan>;
	final scalarPlans:Map<Int, Null<ScalarPlan>> = [];
	public var projectedTargetOf:(Int, Int, String) -> Null<ScalarPlan>;
	/** Program-wide pure helper sharing; standalone emitters retain self-contained output. */
	public var scalarPool:Null<ScalarPool> = null;
	var callLive:Map<Int, Int> = [];
	var projections:Array<{plan:ScalarPlan, owner:String, borrowed:Bool}> = [];

	/**
		Function entries a mod hooks (ADR-0033), set by `Program` from the manifests `gen --mods`
		was given. Null — the build without mods — emits exactly what it always has.
	**/
	public var hooks(default, set):Null<Map<Int, Bool>> = null;
	function set_hooks(value:Null<Map<Int, Bool>>):Null<Map<Int, Bool>> {
		scalarPlans.clear(); return hooks = value;
	}

	/** Which hooked entries were emitted, so `gen` can refuse a hook that matched nothing. */
	public final hooked:Map<Int, Bool> = [];

	public function new(image:Image, discovery:Discovery, optimize:Bool = true, structureRegions:Bool = true,
			scalarFunctions:Bool = true, valueRegions:Bool = true, valueCfg:Bool = false) {
		this.image = image;
		this.discovery = discovery;
		this.optimize = optimize;
		this.structureRegions = structureRegions;
		this.scalarFunctions = scalarFunctions;
		this.valueRegions = valueRegions;
		this.valueCfg = valueCfg;
		scalarTargetOf = a -> {
			final fn = discovery.functions.get(a);
			return fn == null ? null : scalarPlan(fn);
		};
		projectedTargetOf = (a, required, suffix) -> {
			final fn = discovery.functions.get(a);
			return fn == null ? null : scalarProjection(fn, required, suffix);
		};
	}

	public function scalarProjection(fn:Func, required:Int, suffix:String):Null<ScalarPlan> {
		if (!optimize || !scalarFunctions || relocatable || (hooks != null && hooks.exists(fn.entry))) return null;
		final plan = ScalarPlan.analyze(fn, image, required, suffix);
		return plan != null && plan.omitted != 0 ? plan : null;
	}

	function finishFunction(buf:StringBuf):String {
		for (projection in projections) {
			final text = projection.plan.emitHelper()
				+ (projection.borrowed ? ScalarEntry.borrowedAdapter(projection.plan, null, projection.owner)
					: ScalarEntry.projectedAdapter(projection.plan, projection.owner));
			buf.add(text);
			lastProjections.push({helper: projection.plan.helperName(), text: text,
				adapter: projection.borrowed ? projection.plan.borrowedName() : projection.plan.projectedName()});
		}
		return buf.toString();
	}

	/** The memory projections the last `emitFunction` appended to its text, in that order:
	    `Program` shares equal ones within a class (ProjectionShare). */
	public var lastProjections(default, null):Array<ProjectionShare.ProjectionText> = [];

	/** Call sites may use proved helpers: direct scalar calls, borrowed-span adapters and
	    caller-specific projections. Off (`--no-scalar-calls`), every call goes to the callee's
	    CpuState entry, which keeps its own helper; for measuring where helpers cost or pay. */
	public var scalarCalls = true;

	public function scalarPlan(fn:Func):Null<ScalarPlan> {
		if (!optimize || !scalarFunctions || relocatable || (hooks != null && hooks.exists(fn.entry))) return null;
		if (!scalarPlans.exists(fn.entry)) {
			// A recursive edge sees no proved signature. It cannot consume an unfinished plan.
			scalarPlans.set(fn.entry, null);
			scalarPlans.set(fn.entry, ScalarPlan.analyze(fn, image, ALL_REGS, '', a -> {
				final target = Vaddr.canonRam(a); final owner = staticTargetOf(target);
				if (owner == null) return null;
				final plan = scalarTargetOf(target);
				return plan == null ? null : new ScalarCall(plan, owner);
			}));
		}
		return scalarPlans.get(fn.entry);
	}
	public function clearScalarPlans():Void scalarPlans.clear();

	/**
		Stable block entry indices, shared by the dispatch tables and both output shapes.

		Public because the dispatch table needs the same numbering: an address that lands *inside*
		a function has to become a case index, and the only way for that to be right is for the
		table and the switch to be built from one definition of the order rather than two that
		happen to agree.
	**/
	public static function blockOrder(fn:Func):Array<Int> return FunctionIR.blockOrder(fn);

	/**
		Relocatable code (ADR-0025): the function is compiled once and runs wherever the game put
		it. Its entry address arrives in `core.Reloc.base` and is kept in the local `rbase`; the
		only values the instructions compute from their own address — link registers, and the pc
		published for a trap or a kernel call — are emitted as `rbase` plus an offset from the
		entry. Everything else about such code is already position independent: branches are
		relative, and its calls go to the executable at fixed addresses.
	**/
	public var relocatable = false;

	/** An instruction address as the emitted code must compute it. */
	function pcExpr(a:Int):String {
		return relocatable ? '((rbase + ${hex((a - functionAddr) | 0)}) | 0)' : hex(a);
	}

	/** An address for a comment: absolute, or an offset from the entry for relocatable code. */
	function addrNote(a:Int):String {
		return relocatable ? 'entry+' + hex((a - functionAddr) | 0) : Vaddr.hex(a);
	}

	public function emitFunction(fn:Func):String {
		final buf = new StringBuf();
		final blockAddrs = blockOrder(fn);
		ir = new FunctionIR(fn, image);
		portAccesses = optimize ? PortBases.analyze(ir, image, x -> x.decoded.op == Op.JAL ? callWrites(x.decoded.target) : ALL_REGS) : [];
		projections = [];
		lastProjections = [];
		callLive = optimize && scalarFunctions && scalarCalls && !relocatable
			? new recomp.analysis.BoundaryLiveness(fn, ir).afterCall : [];
		leafUsed = optimize ? leafRegisters(ir) : null;
		functionAddr = fn.entry;
		curFn = fn;
		siteOrdinal = 0;
		// A hand-over passes the entry's `$ra` on (Runtime.hopRa), for the callee's checks.
		entryRaLocal = fn.checkedReturns.keys().hasNext() || fn.hops.keys().hasNext();
		hopTarget = isHopTarget(fn.entry);
		nativeLoop = null;
		linearNext = null;
		capturedBranch = null;
		loopHead = null;
		loopMembers = null;
		loopFrame = 0;
		inRegions = false;
		dispatchCase = null;
		while (frames.length > 0) frames.pop();
		idlePlans = [];
		shadow = null;
		span = null;
		spanCount = 0;
		fspans = null;
		scalarBorrows = [];
		fspanLive = null;
		curBlock = -1;
		cycLocal = optimize;

		// Dense indices in address order: stable across regenerations, and the case labels read
		// in the same order as the original listing.
		final indexOf:Map<Int, Int> = [];
		for (i in 0...blockAddrs.length) indexOf.set(blockAddrs[i], i);

		final pumpAt = loopHeaders(fn, blockAddrs);

		buf.add('\t/**\n');
		buf.add('\t\t${fn.name} — ' + (relocatable ? 'relocatable, ${fn.endAddr - fn.entry} bytes from its entry'
			: '${Vaddr.hex(fn.entry)}..${Vaddr.hex(fn.endAddr - 1)}') + ', '
			+ '${blockAddrs.length} block${blockAddrs.length == 1 ? "" : "s"}, '
			+ '${fn.instructionCount()} instructions.\n');
		if (fn.confidence == recomp.analysis.Confidence.Swept) {
			buf.add('\t\tFound by the prologue sweep rather than by a call, so nothing in the\n');
			buf.add('\t\tprogram is known to reach it statically.\n');
		}
		buf.add('\t**/\n');
		// `core.Ctx`: the CpuState, `__restrict` on C++ (E-041).
		buf.add('\tpublic static function ${fn.name}(ctx:core.Ctx, entry:Int = 0):Void {\n');
		// First, before anything can call out and let another relocatable function set it.
		if (relocatable) buf.add('\t\tfinal rbase = core.Reloc.base;\n');
		// The address this call returns to, before anything can overwrite `$ra` (ADR-0027).
		if (entryRaLocal) buf.add(hopTarget ? '\t\tvar entryRa = entry <= $HOP ? core.Runtime.hopRa : ctx.ra;\n'
			: '\t\tvar entryRa = ctx.ra;\n');
		if (hopTarget) {
			// A hand-over (Discovery.cutAtEntries) enters the first block: past the checkpoint and the
			// pump where the code it replaces ran on into here inline, with them where that code
			// pumped at this block ($HOP_PUMP); never through a mod's hook.
			buf.add('\t\tfinal hopped = entry <= $HOP;\n');
			buf.add('\t\tfinal pumping = entry != $HOP;\n');
			buf.add('\t\tif (hopped) entry = 0; else {}\n');
		} else {}
		buf.add('\t\t#if recompsx_cooperative\n');
		buf.add('\t\tvar entryPump = true;\n');
		buf.add('\t\tif (core.Cooperative.resumeEntry >= 0) {\n');
		buf.add('\t\t\tentry = core.Cooperative.resumeEntry; entryPump = core.Cooperative.resumePump;\n');
		if (entryRaLocal) buf.add('\t\t\tentryRa = core.Cooperative.resumeRa;\n');
		buf.add('\t\t\tcore.Cooperative.resumeEntry = -1;\n\t\t} else {}\n');
		buf.add(hopTarget ? '\t\tif (entryPump && pumping) {\n' : '\t\tif (entryPump) {\n');
		emitCheckpoint(buf, '\t\t\t', 'entry', true);
		buf.add(hopTarget ? PUMP_ENTRY_HOP : PUMP_ENTRY);
		buf.add('\t\t} else {}\n\t\t#else\n');
		buf.add(hopTarget ? PUMP_ENTRY_HOP : PUMP_ENTRY);
		buf.add('\t\t#end\n');
		if (hooks != null && !relocatable && hooks.exists(fn.entry)) emitModEntry(buf, fn.entry);
		final scalar = scalarPlan(fn);
		if (scalar != null) {
			// Keep the original entry checkpoint and pump, including resumption; only the
			// computation has a recovered signature. There are no internal safe points.
			final guarded = scalar.memory != null || scalar.accounting != null;
			var ind = '\t\t';
			if (scalar.accounting != null) {
				buf.add(ind + 'if (entry == 0' + (scalar.horizon == 0 ? '' : ' && (' + ScalarEntry.callWindow(scalar.horizon) + ')') + ') {\n');
				ind += '\t';
			}
			if (scalar.memory != null) { buf.add(scalar.memory.guard(ind)); ind += '\t'; }
			buf.add(scalar.apply(ind));
			cycLocal = false;
			emitScalarCharges(buf, ind, scalar);
			if (!guarded) {
				buf.add('\t}\n');
				buf.add(scalar.emitHelper() + ScalarEntry.borrowedAdapter(scalar));
				return finishFunction(buf);
			} else {
				buf.add(ind + 'return;\n');
				if (scalar.memory != null) { ind = ind.substr(1); buf.add(ind + '} else {}\n'); }
				if (scalar.accounting != null) { ind = ind.substr(1); buf.add(ind + '} else {}\n'); }
				// Interior CFG entries and failed memory guards keep the original body.
				cycLocal = optimize;
			}
		}
		if (cycLocal) buf.add('\t\tvar cyc = ctx.cycles;\n');
		if (leafUsed != null) for (r in leafUsed) buf.add('\t\tvar ${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
		fspans = optimize ? planFunctionSpans(ir) : null;
		scalarBorrows = planScalarBorrows();
		fspanLive = fspans != null ? planFspanLiveness() : null;
		if (fspans != null) for (r in 1...32) {
			final f = fspans.get(r);
			// Taken here when the entry block needs it; otherwise only for a resume, which may
			// enter at a block that does — a call enters at 0 and takes it where it is needed.
			if (f == null) {}
			else if ((fspanLive.top & (1 << r)) != 0) buf.add('\t\tvar ${f.v} = Memory.span(${reg(r)}, ${f.lo}, ${f.hi});\n');
			else buf.add('\t\tvar ${f.v} = entry == 0 ? Memory.spanNone() : Memory.span(${reg(r)}, ${f.lo}, ${f.hi});\n');
		}

		// Even a one-block CFG needs a loop if it has an edge to itself.
		final flat = blockAddrs.length == 1 && fn.blocks.get(blockAddrs[0]).successors.length == 0;
		final linear = optimize && linearChain(fn, blockAddrs);
		if (optimize && structureRegions && !flat && !linear) {
			final regions = new RegionPlan(ir);
			if (regions.sequences > 0 || regions.choices > 0 || regions.loops > 0) {
				emitRegions(buf, fn, regions, indexOf);
				buf.add('\t}\n');
				if (scalar != null) buf.add(scalar.emitHelper() + ScalarEntry.borrowedAdapter(scalar));
				return finishFunction(buf);
			}
		}
		final dispatch = !flat && !linear;
		if (linear && !flat) buf.add('\t\tif (entry < 0 || entry >= ${blockAddrs.length}) return;\n');
		if (dispatch) {
			dispatchCase = [for (i in 0...blockAddrs.length) i => i];
			buf.add('\t\tvar bb = entry;\n');
			buf.add('\t\twhile (true) switch (bb) {\n');
		}

		for (i in 0...blockAddrs.length) {
			final addr = blockAddrs[i];
			final guarded = linear && i + 1 < blockAddrs.length;
			final indent = dispatch ? "\t\t\t\t" : (guarded ? "\t\t\t" : "\t\t");
			linearNext = guarded ? blockAddrs[i + 1] : null;
			if (dispatch) buf.add('\t\t\tcase $i: // ${addrNote(addr)}\n' + caseLabel('\t\t\t\t', i));
			else if (guarded) buf.add('\t\tif (entry <= $i) { // ${addrNote(addr)}\n');
			final loopExit = optimize ? selfLoopExit(fn, addr) : null;
			if (loopExit != null) {
				// A loop of one block in a linear chain is planned as the regions' are.
				final id = ir.byAddress.get(addr).resumeId;
				planIdle([id], id);
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
		if (scalar != null) buf.add(scalar.emitHelper() + ScalarEntry.borrowedAdapter(scalar));
		return finishFunction(buf);
	}

	function emitRegions(buf:StringBuf, fn:Func, plan:RegionPlan, indexOf:Map<Int, Int>):Void {
		inRegions = true;
		final dispatch = plan.roots.length != 1 || plan.roots[0].successors.length != 0;
		buf.add('\t\t// Regions: ${plan.roots.length}; ${plan.sequences} sequence / ${plan.choices} choice / ${plan.loops} loop reductions.\n');
		if (dispatch) {
			dispatchCase = [];
			for (root in plan.roots) for (m in root.members) dispatchCase.set(m, root.members[0]);
			buf.add('\t\tvar bb = entry;\n\t\twhile (true) switch (bb) {\n');
		} else {
			buf.add('\t\tif (entry < 0 || entry >= ${ir.blocks.length}) return;\n');
		}
		for (root in plan.roots) {
			final ind = dispatch ? '\t\t\t\t' : '\t\t';
			if (dispatch) buf.add('\t\t\tcase ${root.members.join(" | ")}:\n' + caseLabel(ind, root.members[0]));
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
		if (optimize && valueRegions && valueCfg && !suppressValueCfg && valueScope == null
				&& leafUsed == null && capturedBranch == null && scalarPlan(fn) == null) {
			final values = ValueCfg.analyze(ir, region);
			if (values != null && emitValueCfg(buf, fn, region, values, indexOf, ind, follow)) return;
		}
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
					buf.add(ind + 'if (shim.MemA.likely(resume < 0) || ${containsEntry(parts[i])}) {\n');
					emitRegion(buf, fn, parts[i], indexOf, ind + '\t', last ? follow : parts[i + 1].entry);
					buf.add(ind + '} else {}\n');
				}
				frames.pop();
			case Choice(head, taken, notTaken, join):
				final branch = head.selector;
				final name = 'take_${branch.resumeId}';
				buf.add(ind + 'var $name = false;\n');
				buf.add(ind + 'if (shim.MemA.likely(resume < 0) || ${containsEntry(head)}) {\n');
				final previous = capturedBranch;
				capturedBranch = branch.addr;
				emitRegion(buf, fn, head, indexOf, ind + '\t', null);
				capturedBranch = previous;
				buf.add(ind + '} else {}\n');
				buf.add(ind + 'if (shim.MemA.likely(resume < 0) ? $name : ${containsEntry(taken)}) {\n');
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
				buf.add(ind + '\tif (shim.MemA.unlikely(resume >= 0) && resume != $headId) break; else {}\n');
				buf.add(ind + '}\n');
				loopHead = outerHead;
				loopMembers = outerMembers;
				loopFrame = outerFrame;
				linearNext = follow;
		}
	}

	/** Local merge values for every public entry of a pure acyclic region. */
	function emitValueCfg(buf:StringBuf, fn:Func, region:Region, plan:ValueCfg,
			indexOf:Map<Int, Int>, ind:String, follow:Null<Int>):Bool {
		for (pc in plan.returnSites)
			if (fn.checkedReturns.exists(pc) || discovery.raJumpOf(fn.entry, pc) != null) return false;
		// The proof excludes effects, loops and calls: trial emission cannot add projections,
		// span variables or loop plans. Restore the block and transfer routing cursors below.
		final oldBlock = curBlock; final oldNext = linearNext;
		final oldContinuation = continuation; final oldReturn = callReturnAddr;
		suppressValueCfg = true;
		final original = new StringBuf(); emitRegion(original, fn, region, indexOf, ind, follow);
		curBlock = oldBlock; linearNext = oldNext;
		valueScope = plan; valuePrefix = 'vc_${ir.byAddress.get(region.entry).resumeId}_';
		final candidate = new StringBuf();
		candidate.add(ind + '// Value CFG: ' + region.members.length + ' blocks, public entries retained.\n');
		for (r in plan.used) candidate.add('${ind}var ${reg(r)} = ctx.${Instr.regName(r)};\n');
		emitRegion(candidate, fn, region, indexOf, ind, follow);
		if (plan.continuation != null) publishValues(candidate, ind);
		valueScope = null; valuePrefix = ""; suppressValueCfg = false;
		curBlock = oldBlock; linearNext = oldNext;
		continuation = oldContinuation; callReturnAddr = oldReturn;
		final text = candidate.toString();
		if (text.split('ctx.').length >= original.toString().split('ctx.').length) return false;
		buf.add(text);
		return true;
	}

	/** No emulated effect may run while this scope is active; publish at every actual escape. */
	function publishValues(buf:StringBuf, ind:String):Void {
		if (valueScope != null) for (r in valueScope.written)
			buf.add('${ind}ctx.${Instr.regName(r)} = ${reg(r)};\n');
	}
	function leavesValues(target:Int):Bool return valueScope != null && !valueScope.members.exists(target);

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

	/**
		Which registers a leaf keeps in locals, or null when the function is not one.

		A leaf makes no guest call, no trap and nothing unknown, so the only things that run while
		its locals are live are the runtime's helpers, which touch no general register, and due
		pumps, whose callbacks give the interrupted registers back as they found them: its copies
		cannot go stale, which is what made locals unsound elsewhere (ADR-0029). They are declared
		at entry (every entry, interior ones too), published at every way out — return, tail
		transfer, due pump, suspension — and read again after a due pump. On the SH-4 a leaf's
		loop keeps its values in machine registers across the stores and helper calls that make a
		CpuState field a load again.
	**/
	function leafRegisters(ir:FunctionIR):Null<Array<Int>> {
		var used:recomp.ir.RegisterMask = 0;
		var written:recomp.ir.RegisterMask = 0;
		var loops = false;
		for (block in ir.blocks) {
			for (i in block.instructions) {
				if (i.effects.has(Effect.CALL) || i.effects.has(Effect.TRAP) || i.effects.has(Effect.UNKNOWN))
					return null;
				used |= i.reads | i.writes;
				written |= i.writes;
			}
			for (s in block.successors) if (s <= block.addr) loops = true;
		}
		final regs = [for (r in 1...32) if (used.has(r)) r];
		if (!loops || regs.length > LEAF_LOCALS_MAX) return null;
		leafWritten = [for (r in 1...32) if (written.has(r)) r];
		return regs;
	}

	/**
		Locals only pay in a loop, and only while they fit. Measured on the Dreamcast, leaf by
		leaf, fields against locals: the loops of Crash Bash's two hottest leaves (16 and 17
		registers, GTE commands in the loop) ran 11 % and 13 % faster with locals, one of 22
		registers the same; Crash Bandicoot: Warped's loopless leaves (17 and 20 registers) and a
		29-register loop 5-35 % slower — a loopless leaf copies its registers in and out on every
		call, and past the host's registers the locals spill to the stack anyway.
	**/
	static inline final LEAF_LOCALS_MAX = 20;

	/** A leaf's written registers back to CpuState, before anything outside it can look. */
	function publish(buf:StringBuf, ind:String):Void {
		if (cycLocal) buf.add('${ind}ctx.cycles = cyc;\n');
		publishValues(buf, ind);
		if (leafUsed != null) for (r in leafWritten) buf.add('${ind}ctx.${Instr.regName(r)} = ${Instr.regName(r)};\n');
	}

	/** A leaf's locals read again, after a due pump. */
	function reloadLeaf(buf:StringBuf, ind:String):Void {
		if (cycLocal) buf.add('${ind}cyc = ctx.cycles;\n');
		if (leafUsed != null) for (r in leafUsed) buf.add('${ind}${Instr.regName(r)} = ctx.${Instr.regName(r)};\n');
	}

	function emitReturn(buf:StringBuf, ind:String):Void {
		publish(buf, ind);
		buf.add(ind + 'return;\n');
	}

	/**
		A hand-over to another function's entry (Discovery.cutAtEntries): a direct tail call that
		enters past its pump and checkpoint, with this function's entry `$ra` for its return checks.
		A token it leaves is this function's caller's to act on, as it was when the code ran inline;
		a plain return goes where `$ra` points, checked as this function's own return would be
		(`Func.checkedHops`).
	**/
	function emitHop(buf:StringBuf, ind:String, target:Int):Void {
		final t = Vaddr.canonRam(target);
		final cls = staticTargetOf(t);
		publish(buf, ind);
		if (cls == null) {
			// An address whose occupant is decided at run time (Main.analyseBase keeps these out):
			// by address, as any call there is.
			buf.add('${ind}ctx.pc = ${hex(t)};\n');
			buf.add('${ind}$dynamicCall(ctx, ${hex(t)});   // runs on into another function\n');
		} else {
			buf.add('${ind}core.Runtime.hopRa = entryRa;\n');
			buf.add('${ind}$cls.${Discovery.defaultName(t)}(ctx, ${curFn.pumpedHops.exists(t) ? HOP_PUMP : HOP});   // runs on into another function\n');
		}
		buf.add('${ind}if (ctx.unwindToken != 0) return;\n');
		if (curFn.checkedHops.exists(curBlock)) {
			buf.add('${ind}if (ctx.ra != entryRa) Runtime.returnTo(ctx, ctx.ra);   // a return elsewhere\n');
			buf.add('${ind}else {}\n');
		} else {}
		buf.add('${ind}return;\n');
	}

	function isHopTarget(entry:Int):Bool {
		if (hopTargets == null) {
			hopTargets = [];
			for (f in discovery.functions) for (h in f.hops.keys()) hopTargets.set(h, true);
		} else {}
		return hopTargets.exists(Vaddr.canonRam(entry));
	}

	/**
		A return whose `$ra` may not be the one the function was entered with (ADR-0027): if it is
		not, control goes to that address, not to the host caller — `Runtime.returnTo` leaves the
		target, and each caller's after-call check carries it out to the frame that continues
		there. `target` is the expression holding the address the `jr` jumps to.
	**/
	function emitReturnCheck(buf:StringBuf, ind:String, fn:Func, instr:Instr, target:String):Void {
		if (!fn.checkedReturns.exists(instr.addr)) return;
		buf.add('${ind}if ($target != entryRa) Runtime.returnTo(ctx, $target);   // a return elsewhere\n');
		buf.add('${ind}else {}\n');
	}

	function emitCheckpoint(buf:StringBuf, ind:String, entry:String, entryPump:Bool):Void {
		buf.add(ind + '#if recompsx_cooperative\n');
		// The yield budget is counted in cycles: it reads the clock. At the entry it is current.
		if (cycLocal && !entryPump) buf.add(ind + 'ctx.cycles = cyc;\n');
		buf.add(ind + 'if (core.Cooperative.wantsYield(ctx)) {\n');
		if (!entryPump) publish(buf, ind + '\t');
		final ra = entryRaLocal ? ', entryRa' : '';
		buf.add(ind + (relocatable
			? '\tcore.Cooperative.suspendAt(ctx, ${continuationId()}, $entry, $entryPump, rbase$ra);\n'
			: '\tcore.Cooperative.suspend(ctx, ${continuationId()}, $entry, $entryPump$ra);\n'));
		buf.add(ind + '\treturn;\n' + ind + '} else {}\n' + ind + '#end\n');
	}

	/**
		A mod's hook at a function's entry (ADR-0033). After the entry pump, so the machine is where
		an ordinary call finds it; before a leaf copies registers into locals, so the hook reads the
		arguments from CpuState and anything it writes there is what the body starts from. Only a
		call enters: a frame resumed at a later block has been through here already, and so has a
		cooperative resume anywhere but the entry's own checkpoint (`entryPump`), which suspends
		before this line and so runs it on resuming.
	**/
	function emitModEntry(buf:StringBuf, addr:Int):Void {
		hooked.set(addr, true);
		final notHop = hopTarget ? '!hopped && ' : '';
		buf.add('\t\t#if recompsx_cooperative\n');
		buf.add('\t\tif (entry == 0 && ${notHop}entryPump && mod.ModHost.enter(ctx, ${hex(addr)})) return;   // a mod\'s hook\n');
		buf.add('\t\t#else\n');
		buf.add('\t\tif (entry == 0 && ${notHop}mod.ModHost.enter(ctx, ${hex(addr)})) return;   // a mod\'s hook\n');
		buf.add('\t\t#end\n');
	}

	function emitPump(buf:StringBuf, ind:String, entry:Int):Void {
		emitCheckpoint(buf, ind, Std.string(entry), false);
		buf.add('${ind}if (shim.MemA.unlikely(((${cycExpr()} - core.Runtime.deadline(ctx)) | 0) >= 0)) {\n');
		publish(buf, ind + '\t');
		buf.add(ind + '\tRuntime.pump(ctx);\n');
		// A nonlocal jump has already restored CpuState: never publish a leaf's locals over it.
		buf.add(ind + '\t' + unwindLine(NO_CONTINUATION) + '\n');
		reloadLeaf(buf, ind + '\t');
		resetAllFunctionSpans(buf, ind + '\t');
		buf.add(ind + '} else {}\n');
	}

	/**
		The function-entry pump check.

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
		"\t\tif (shim.MemA.unlikely(((ctx.cycles - core.Runtime.deadline(ctx)) | 0) >= 0)) {\n"
		+ "\t\t\tRuntime.pump(ctx);\n\t\t\tif (ctx.unwindToken != 0) return;\n\t\t} else {}\n";

	/** PUMP_ENTRY for a function another one hands over to: not for the hand-over itself. */
	static inline final PUMP_ENTRY_HOP =
		"\t\tif (shim.MemA.unlikely(((ctx.cycles - core.Runtime.deadline(ctx)) | 0) >= 0) && pumping) {\n"
		+ "\t\t\tRuntime.pump(ctx);\n\t\t\tif (ctx.unwindToken != 0) return;\n\t\t} else {}\n";

	/** The `entry` a hand-over calls with (Discovery.cutAtEntries): the first block, past the pump. */
	static inline final HOP = -2;
	/** The same, through the checkpoint and the pump (`Func.pumpedHops`). */
	static inline final HOP_PUMP = -3;

	/**
		What makes `longjmp` able to leave.

		A non-local jump has to abandon every frame between where it was called and where it
		lands, and in a recompiled program those are host stack frames that only return normally.
		So `longjmp` restores the emulated registers, sets the token, and this line — after every
		call — carries the return all the way out. The top of the runtime then dispatches afresh
		to the saved address, with `sp` and `ra` already correct.

		A single return needs no `else` workaround for upstream defect 8.
	**/
	// `unwinding` runs a tail jump the callee left (ADR-0026) before deciding, and stops a return
	// to elsewhere at the frame that continues at `cont` (ADR-0027); the common case, no token at
	// all, is the same single compare as before.
	static function unwindLine(cont:String):String {
		return 'if (shim.MemA.unlikely(ctx.unwindToken != 0) && Runtime.unwinding(ctx, $cont)) return;';
	}

	/** Where no call returns: after a pump or a trap. No return to elsewhere stops there. */
	static inline final NO_CONTINUATION = "-1";

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
		curBlock = blockAddr;
		// Arriving here ends whatever `resume` was steering towards.
		if (inRegions) buf.add(ind + 'resume = -1;\n');
		// A span the entry left to the block that needs it on every path on (deferEntryTakes).
		if (fspanLive != null && fspanLive.entry.exists(blockAddr)) takeFunctionSpans(buf, ind, fspanLive.entry.get(blockAddr));
		else {}
		final idle = idlePlans.get(blockAddr);
		if (idle != null) emitIdlePrologue(buf, ind, idle);
		final stackPlan = optimize ? StackMemoryForwarding.plan(block.body) : null;
		final spans = optimize ? planSpans(block.body, stackPlan) : null;
		var i = 0;
		while (i < block.body.length) {
			final region = optimize && valueRegions && leafUsed == null
				? valueRegion(block.body, i, block.resumeId, ind) : null;
			if (region != null) {
				buf.add(region.text);
				for (at in i...region.end) {
					resetFunctionSpans(buf, ind, at);
					if (fspanLive != null) {
						final steps = fspanLive.step.get(curBlock);
						stepFunctionSpans(buf, ind, steps != null && steps.exists(at) ? steps.get(at) : 0, block.body[at].decoded);
					}
				}
				i = region.end; continue;
			}
			if (stackPlan != null) {
				switch (stackPlan[i]) {
					case ForwardLoad(source):
						final line = assign(block.body[i].decoded.rt, reg(source), false);
						if (line != "") buf.add(ind + line + '\n');
						resetFunctionSpans(buf, ind, i);
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
				if (spans != null) {
					final open = spans.open.get(i);
					if (open != null) buf.add(ind + open + '\n');
					span = spans.at.get(i);
				}
				if (span == null) span = functionSpanOf(block.body[i].decoded);
				emitSimple(buf, ind, block.body[i].decoded, false, block.addr, i);
				span = null;
				resetFunctionSpans(buf, ind, i);
				if (fspanLive != null) {
					final st = fspanLive.step.get(curBlock);
					stepFunctionSpans(buf, ind, st == null || !st.exists(i) ? 0 : st.get(i), block.body[i].decoded);
				} else {}
				i++;
			} else {
				emitFused(buf, ind, block.body[i].decoded, block.body[i + 1].decoded, fused.kind);
				for (k in 0...fused.length) resetFunctionSpans(buf, ind, i + k);
				i += fused.length;
			}
		}
		if (block.transfer != null) {
			emitTransfer(buf, fn, block.transfer.decoded,
				block.delaySlot == null ? null : block.delaySlot.decoded,
				blockAddr, indexOf, ind, block.cycles, block.instructions.length, block.resumeId);
		} else {
			emitCharges(buf, ind, block.cycles, block.instructions.length);
			final next = blockAddr + block.instructions.length * 4;
			if (block.successors.length == 1) emitGoto(buf, ind, block.successors[0], indexOf, blockAddr);
			// Runs on into another function's entry (Discovery.cutAtEntries).
			else if (fn.hops.exists(Vaddr.canonRam(next))) emitHop(buf, ind, next);
			else emitReturn(buf, ind);
		}
	}

	/** Never replace field syntax alone: require fewer architectural field accesses than the
	    existing fused emitter. A span refresh is also a boundary, preserving its exact inputs. */
	function valueRegion(body:Array<recomp.ir.FunctionIR.InstructionIR>, start:Int, blockId:Int, ind:String):Null<{end:Int, text:String}> {
		// Most body positions are effects or isolated arithmetic. Avoid constructing a graph
		// for those, and bound span lookahead by the same interval limit as the value lift.
		if (start + 1 >= body.length || (body[start].effects : Int) != 0 || body[start].writes.has(31)
				|| (body[start + 1].effects : Int) != 0 || body[start + 1].writes.has(31)) return null;
		var limit = start + 32 < body.length ? start + 32 : body.length;
		if (fspanLive != null) {
			final writes = fspanLive.write.get(curBlock); final steps = fspanLive.step.get(curBlock);
			for (i in start...limit) if ((writes != null && writes.exists(i) && writes.get(i) != 0)
					|| (steps != null && steps.exists(i) && steps.get(i) != 0)) { limit = i + 1; break; }
		}
		final region = ValueRegion.analyze(body, start, limit);
		if (region == null) return null;
		final original = new StringBuf(); var i = start;
		while (i < region.end) {
			final fused = PatternMatcher.match(body, i);
			if (fused != null && i + fused.length <= region.end) {
				emitFused(original, ind, body[i].decoded, body[i + 1].decoded, fused.kind); i += fused.length;
			} else { emitSimple(original, ind, body[i].decoded); i++; }
		}
		final text = region.emit(ind, 'vr_${blockId}_${start}_', reg);
		final storage = valueScope == null ? 'ctx.' : valuePrefix;
		return text.split(storage).length < original.toString().split(storage).length ? {end:region.end, text:text} : null;
	}

	/**
		The runs of loads and stores in a block that go through one base register with no write
		to it between them: each run of two or more is checked once (`Memory.span`, before its
		first access) and its accesses index the arena by the result. A run ends at a write to its
		base — a load into its own base register ends it after that load, which used the old value
		— and every run ends at a trap, an unknown instruction or a coprocessor-0 write, after
		which nothing is assumed. Accesses the stack forwarding removed are in no run, and a delay
		slot is emitted elsewhere and is in none either. The unaligned ones (lwl and the rest)
		keep their own path.
	**/
	function planSpans(body:Array<recomp.ir.FunctionIR.InstructionIR>,
			stackPlan:Null<Array<Null<StackMemoryForwarding.StackMemoryDecision>>>):Null<SpanPlan> {
		final open:Map<Int, Array<Int>> = [];
		final runs:Array<{base:Int, members:Array<Int>}> = [];
		function close(r:Int):Void {
			final m = open.get(r);
			if (m != null) {
				if (m.length >= 2) runs.push({base: r, members: m});
				else {}
				open.remove(r);
			} else {}
		}
		function closeAll():Void {
			for (r in [for (k in open.keys()) k]) close(r);
		}
		for (idx in 0...body.length) {
			final ins = body[idx];
			final d = ins.decoded;
			if (d.op == Op.SYSCALL || d.op == Op.BREAK || d.op == Op.INVALID || d.op == Op.MTC0 || d.op == Op.RFE) {
				closeAll();
				continue;
			} else {}
			final elided = stackPlan != null && stackPlan[idx] != null;
			if (!elided && spanWidth(d.op) > 0 && d.rs != 0 && (fspans == null || !fspans.exists(d.rs))) {
				final m = open.get(d.rs);
				if (m == null) open.set(d.rs, [idx]);
				else m.push(idx);
			} else {}
			for (r in 1...32) if (ins.writes.has(r)) close(r);
		}
		closeAll();
		if (runs.length == 0) return null;
		final plan:SpanPlan = {open: [], at: []};
		for (run in runs) {
			var lo = 0x7FFFFFFF, hi = -0x7FFFFFFF;
			for (k in run.members) {
				final d = body[k].decoded;
				if (d.immS < lo) lo = d.immS;
				else {}
				final last = d.immS + spanWidth(d.op) - 1;
				if (last > hi) hi = last;
				else {}
			}
			final v = 'span_$spanCount';
			spanCount++;
			plan.open.set(run.members[0], 'final $v = Memory.span(${reg(run.base)}, $lo, $hi);');
			for (k in run.members) plan.at.set(k, {v: v, off: body[k].decoded.immS});
		}
		return plan;
	}

	/**
		Function spans: a base register the function reads memory through often and sets seldom
		gets one span for the whole function — checked once wherever its value may have changed,
		and every load and store through it, in any block and in delay slots, indexes the arena
		by it. Those places: the entry, after each instruction writing the register, and after
		anything outside the function that could have — a call, a pump that ran, a trap. Nothing
		about calling conventions is assumed: a callee that changes the register is seen, since
		the span is taken again from its value after every call.

		For a register never written here that is only the entry and the calls, which is what
		makes a pointer a caller hands down (Crash Bandicoot: Warped keeps the scratchpad's
		address in v1 through its hot object loop) cost one check instead of one per access —
		and the scratchpad's was the dearer check, after the RAM test had failed. `sp` is set
		at entry and exit. A register written as often as it is read through keeps the block
		spans: a check after every write would be no fewer checks. Link registers are left out
		(a transfer writes them before its delay slot runs), and so is any register whose
		offsets span more than the scratchpad, which could never pass there.
	**/
	function planFunctionSpans(ir:recomp.ir.FunctionIR):Null<Map<Int, FunctionSpan>> {
		final accesses = [for (_ in 0...32) 0];
		final writes = [for (_ in 0...32) 0];
		final lo = [for (_ in 0...32) 0x7FFFFFFF];
		final hi = [for (_ in 0...32) -0x7FFFFFFF];
		final linked = [for (_ in 0...32) false];
		for (block in ir.blocks) for (ins in block.instructions) {
			final d = ins.decoded;
			final w = spanWidth(d.op);
			if (w > 0 && d.rs != 0) {
				accesses[d.rs]++;
				if (d.immS < lo[d.rs]) lo[d.rs] = d.immS;
				else {}
				if (d.immS + w - 1 > hi[d.rs]) hi[d.rs] = d.immS + w - 1;
				else {}
			} else {}
			for (r in 1...32) {
				if (ins.writes.has(r)) {
					// A step (`addiu r, r, imm`) counts as a write here, though the span follows
					// it (stepFunctionSpans) instead of being taken again: counted as nothing, a
					// pointer stepped more often than it is read through got a span too, and
					// Crash 3's generated code ran 0.15 ms a frame slower with those 455 spans
					// (docs/perf/dreamcast-ledger.md, E-035).
					writes[r]++;
					if (d.op.hasDelaySlot) linked[r] = true;
					else {}
				} else {}
			}
		}
		var plan:Null<Map<Int, FunctionSpan>> = null;
		for (r in 1...32) {
			if (accesses[r] >= 2 && !linked[r] && writes[r] * 2 <= accesses[r] && hi[r] - lo[r] < 1024) {
				if (plan == null) plan = [];
				else {}
				plan.set(r, {v: 'fspan_${Instr.regName(r)}', lo: lo[r], hi: hi[r]});
			} else {}
		}
		return plan;
	}

	/** Reuse spans already worthwhile for this caller. Do not widen ranges or add new
	    spans merely to specialize a call. Residency/hooks use the ordinary direct-call proof. */
	function planScalarBorrows():Map<Int, ScalarBorrow> {
		final plans:Map<Int, ScalarBorrow> = [];
		if (!optimize || !scalarCalls || relocatable || fspans == null) return plans;
		for (b in ir.blocks) {
			if (b.transfer == null || b.transfer.decoded.op != Op.JAL) continue;
			final target = Vaddr.canonRam(b.transfer.decoded.target);
			if (staticTargetOf(target) == null) continue;
			final scalar = scalarTargetOf(target);
			if (scalar == null || scalar.memory == null) continue;
			final borrowed = ScalarBorrow.analyze(scalar.memory, fspans, recomp.analysis.CallAliases.beforeCall(b));
			if (borrowed != null) plans.set(b.addr, borrowed);
		}
		return plans;
	}

	/** The function span a load or store goes through, or null. */
	function functionSpanOf(i:Instr):Null<SpanAccess> {
		if (fspans == null || spanWidth(i.op) == 0 || i.rs == 0) return null;
		final f = fspans.get(i.rs);
		return f == null ? null : {v: f.v, off: i.immS};
	}

	/** After instruction `index` of the current block (a write, a forwarded load, a trap): the
	    function spans it changed that a later access still needs, taken again. */
	function resetFunctionSpans(buf:StringBuf, ind:String, index:Int):Void {
		if (fspans == null) return;
		final m = fspanLive.write.get(curBlock);
		takeFunctionSpans(buf, ind, m == null || !m.exists(index) ? 0 : m.get(index));
	}

	/** Every function span taken again: after a pump that ran, where it is rare enough not to ask. */
	function resetAllFunctionSpans(buf:StringBuf, ind:String):Void {
		takeFunctionSpans(buf, ind, -1);
	}

	/** `addiu r, r, imm`: a register stepped by a constant, which its function span follows. */
	static inline function isStep(d:Instr, r:Int):Bool return d.op == Op.ADDIU && d.rs == r && d.rt == r && r != 0;

	/** After a step of a span register (`d`, just emitted): the span moved by the same amount
	    while it stays inside its region (Memory.spanStep). One that was not a span stays none
	    (the accesses take the slow path, which is always right): a pointer outside RAM and the
	    scratchpad is not stepped into them, and a full check here cost code at every step. */
	function stepFunctionSpans(buf:StringBuf, ind:String, mask:Int, d:Instr):Void {
		if (fspans == null || mask == 0) return;
		for (r in 1...32) {
			final f = fspans.get(r);
			if (f != null && (mask & (1 << r)) != 0)
				buf.add('${ind}${f.v} = Memory.spanOk(${f.v}) ? Memory.spanStep(${f.v}, ${d.immS}, ${f.lo}, ${f.hi}) : Memory.spanNone();\n');
			else {}
		}
	}

	/** The function spans of the registers in `mask`, from their values now. */
	function takeFunctionSpans(buf:StringBuf, ind:String, mask:Int):Void {
		if (fspans == null || mask == 0) return;
		for (r in 1...32) {
			final f = fspans.get(r);
			if (f != null && (mask & (1 << r)) != 0) buf.add('${ind}${f.v} = Memory.span(${reg(r)}, ${f.lo}, ${f.hi});\n');
			else {}
		}
	}

	/**
		Where each function span has to be taken again, so that none is taken for nothing: a
		backward liveness over the blocks, of "an access through this register may come before
		its value changes again". Taking one costs a dozen instructions, and taking every one
		after every call was 13 % of Crash 3's generated code for 1.9 accesses a span. The value
		changes at a write to the register, a call (anything may have happened), a trap; the
		span is taken again after one of those only if some path reaches an access through the
		register first. A pump that ran still takes every span (resetAllFunctionSpans), being rare.
		The events follow the order emitBlock emits: stack forwarding, fused pairs, the body,
		the delay slot, the transfer. A conditional call (bltzal, bgezal) changes nothing on the
		path that does not call, so it is no kill here, only a place to take them again.
	**/
	function planFspanLiveness():FspanLive {
		var regs = 0;
		for (r in fspans.keys()) regs |= 1 << r;
		inline function bitOf(r:Int):Int return (1 << r) & regs;
		// Per block, its events: [kind, arg, at] — kind 0 a use of arg's span, 1 a write of the
		// registers in mask arg, 2 everything changed, 3 a conditional call; at is the body
		// index, -1 the delay slot, -2 the transfer.
		final events:Map<Int, Array<Array<Int>>> = [];
		for (block in ir.blocks) {
			final ev:Array<Array<Int>> = [];
			final stackPlan = StackMemoryForwarding.plan(block.body);
			var i = 0;
			while (i < block.body.length) {
				if (stackPlan != null && stackPlan[i] != null) {
					switch (stackPlan[i]) {
						case ForwardLoad(_):
							final w = (block.body[i].writes : Int) & regs;
							if (w != 0) ev.push([1, w, i]);
							else {}
						case _:
					}
					i++;
					continue;
				} else {}
				final fused = PatternMatcher.match(block.body, i);
				if (fused != null) {
					for (k in 0...fused.length) {
						final w = (block.body[i + k].writes : Int) & regs;
						if (w != 0) ev.push([1, w, i + k]);
						else {}
					}
					i += fused.length;
					continue;
				} else {}
				final d = block.body[i].decoded;
				if (d.op == Op.SYSCALL || d.op == Op.BREAK) ev.push([2, 0, i]);
				else {
					if (spanWidth(d.op) > 0 && d.rs != 0 && bitOf(d.rs) != 0) ev.push([0, d.rs, i]);
					else {}
					final w = (block.body[i].writes : Int) & regs;
					if (w != 0 && isStep(d, d.rt)) ev.push([5, d.rt, i]);
					else if (w != 0) ev.push([1, w, i]);
					else {}
				}
				i++;
			}
			if (block.delaySlot != null) {
				final d = block.delaySlot.decoded;
				if (spanWidth(d.op) > 0 && d.rs != 0 && bitOf(d.rs) != 0) ev.push([0, d.rs, -1]);
				else {}
				final w = (block.delaySlot.writes : Int) & regs;
				if (w != 0 && isStep(d, d.rt)) ev.push([5, d.rt, -1]);
				else if (w != 0) ev.push([1, w, -1]);
				else {}
			} else {}
			if (block.transfer != null) {
				final d = block.transfer.decoded;
				final link = (block.transfer.writes : Int);
				// The callee consumes the current pointer, after the slot and before its own
				// writes. Keeping this use live also refreshes a last-use span changed by the
				// body, delay slot or an earlier call, even without a later caller load.
				final borrowed = scalarBorrows.get(block.addr);
				if (borrowed != null) for (r in 1...32)
					if ((borrowed.registers & (1 << r)) != 0) ev.push([0, r, -2]);
				if (d.op == Op.BLTZAL || d.op == Op.BGEZAL) ev.push([3, 0, -2]);
				else if (d.op == Op.JAL) ev.push([4, (callWrites(d.target) | link) & regs, -2]);
				else if (d.op == Op.JALR) {
					// Through a register: only a guessed target (jalrGuess) has a summary, and its
					// guard's other arm takes every span the call left live (`callLive`).
					final guess = jalrGuess(block.transfer.decoded);
					if (guess != null) ev.push([4, (writesOf(Vaddr.canonRam(guess)) | link) & regs, -2]);
					else ev.push([2, 0, -2]);
				} else {}
			} else {}
			events.set(block.addr, ev);
		}
		// Backward to a fixed point: what each block needs taken on entry.
		final needIn:Map<Int, Int> = [];
		for (block in ir.blocks) needIn.set(block.addr, 0);
		var changed = true;
		while (changed) {
			changed = false;
			var k = ir.blocks.length - 1;
			while (k >= 0) {
				final block = ir.blocks[k];
				var live = 0;
				for (s in block.successors) live |= needIn.exists(s) ? needIn.get(s) : 0;
				final ev = events.get(block.addr);
				var e = ev.length - 1;
				while (e >= 0) {
					final x = ev[e];
					if (x[0] == 0) live |= 1 << x[1];
					else if (x[0] == 1 || x[0] == 4) live &= ~x[1];
					else if (x[0] == 2) live = 0;
					else {}
					e--;
				}
				if (live != needIn.get(block.addr)) {
					needIn.set(block.addr, live);
					changed = true;
				} else {}
				k--;
			}
		}
		// The same pass once more, now recording what to take after each event.
		final plan:FspanLive = {top: needIn.get(ir.blocks[0].addr), write: [], slot: [], call: [], callLive: [],
			step: [], slotStep: [], entry: []};
		for (block in ir.blocks) {
			var live = 0;
			for (s in block.successors) live |= needIn.exists(s) ? needIn.get(s) : 0;
			final ev = events.get(block.addr);
			final writes:Map<Int, Int> = [];
			final steps:Map<Int, Int> = [];
			var e = ev.length - 1;
			while (e >= 0) {
				final x = ev[e];
				if (x[0] == 5) {
					// A step keeps the span valid if it was: moved where it is live after.
					if ((live & (1 << x[1])) != 0) {
						if (x[2] == -1) plan.slotStep.set(block.addr, 1 << x[1]);
						else steps.set(x[2], 1 << x[1]);
					} else {}
				} else if (x[0] == 0) live |= 1 << x[1];
				else if (x[0] == 1) {
					if (x[2] == -1) plan.slot.set(block.addr, live & x[1]);
					else writes.set(x[2], (writes.exists(x[2]) ? writes.get(x[2]) : 0) | (live & x[1]));
					live &= ~x[1];
				} else if (x[0] == 2) {
					if (x[2] == -2) plan.call.set(block.addr, live);
					else writes.set(x[2], live);
					live = 0;
				} else if (x[0] == 4) {
					// A call that writes only x[1]: those spans are taken again, the rest kept.
					plan.call.set(block.addr, live & x[1]);
					plan.callLive.set(block.addr, live);
					live &= ~x[1];
				} else plan.call.set(block.addr, live);
				e--;
			}
			plan.write.set(block.addr, writes);
			plan.step.set(block.addr, steps);
		}
		deferEntryTakes(plan, events, regs);
		return plan;
	}

	/**
		A span live at the entry but not needed on every path from it is taken where it is, not at
		the entry: at the start of each block from which every path reaches an access through the
		register before its value can change, on the paths that arrive there without it. Crash
		Bandicoot: Warped took ~1,800 entry spans a gameplay frame that no access used (a quarter of
		its function spans; most on the renderer's scratchpad pointer, ~20 instructions each): a
		decoder returning a cached value at its second block, say, while every other path decodes
		through the span. A call still enters at 0 with the span none, as for a span the entry block
		does not need; a resume still takes it at the entry. An access with no span decodes on its
		own, so a take left out costs only speed: what is exact is that a span is never taken from
		a value its register no longer holds, and each take here is at a block start no write, call
		or trap separates from the accesses it serves.

		Where such a block is also reached with the span already taken — a loop that took it on
		its first turn, a branch that took it after a write — taking it there again would cost
		that path a second take, so the span is taken at the entry as before.
	**/
	function deferEntryTakes(plan:FspanLive, events:Map<Int, Array<Array<Int>>>, regs:Int):Void {
		final entryAddr = ir.blocks[0].addr;
		// Backward, to a fixed point: the spans every path from a block's start uses before a write
		// to the register, a call that may write it, a trap or a way out.
		final antIn:Map<Int, Int> = [];
		for (block in ir.blocks) antIn.set(block.addr, regs);
		var changed = true;
		while (changed) {
			changed = false;
			var k = ir.blocks.length - 1;
			while (k >= 0) {
				final block = ir.blocks[k];
				var ant = block.successors.length == 0 ? 0 : regs;
				for (s in block.successors) ant &= antIn.exists(s) ? antIn.get(s) : 0;
				final ev = events.get(block.addr);
				var e = ev.length - 1;
				while (e >= 0) {
					final x = ev[e];
					if (x[0] == 0) ant |= 1 << x[1];
					else if (x[0] == 1 || x[0] == 4) ant &= ~x[1];
					else if (x[0] == 2 || x[0] == 3) ant = 0;
					else {}
					e--;
				}
				if (ant != antIn.get(block.addr)) {
					antIn.set(block.addr, ant);
					changed = true;
				} else {}
				k--;
			}
		}
		var active = plan.top & ~antIn.get(entryAddr);
		final entry:Map<Int, Int> = [];
		while (active != 0) {
			// Forward, to a fixed point: which spans arrive at each block not yet taken (`pend`) and
			// which already taken (`taken`); a span in both arrives each way by different paths.
			final pendIn:Map<Int, Int> = [], takenIn:Map<Int, Int> = [];
			final pendOut:Map<Int, Int> = [], takenOut:Map<Int, Int> = [];
			for (block in ir.blocks) {
				pendIn.set(block.addr, 0); takenIn.set(block.addr, 0);
				pendOut.set(block.addr, 0); takenOut.set(block.addr, 0);
			}
			var bad = 0;
			changed = true;
			while (changed) {
				changed = false;
				bad = 0;
				for (block in ir.blocks) {
					var p = block.addr == entryAddr ? active : 0;
					var t = 0;
					for (pr in block.predecessors) {
						p |= pendOut.exists(pr) ? pendOut.get(pr) : 0;
						t |= takenOut.exists(pr) ? takenOut.get(pr) : 0;
					}
					pendIn.set(block.addr, p);
					takenIn.set(block.addr, t);
					final ant = antIn.get(block.addr);
					bad |= p & t & ant;
					var pend = p & ~ant;
					var taken = t | (p & ant);
					final writes = plan.write.get(block.addr);
					for (x in events.get(block.addr)) {
						final kind = x[0];
						if (kind == 0) bad |= pend & (1 << x[1]);
						else if (kind == 1) {
							final again = x[2] == -1 ? (plan.slot.exists(block.addr) ? plan.slot.get(block.addr) : 0)
								: (writes != null && writes.exists(x[2]) ? writes.get(x[2]) : 0);
							pend &= ~x[1];
							taken = (taken & ~x[1]) | (again & x[1]);
						} else if (kind == 2) {
							final again = x[2] == -2 ? (plan.call.exists(block.addr) ? plan.call.get(block.addr) : 0)
								: (writes != null && writes.exists(x[2]) ? writes.get(x[2]) : 0);
							pend = 0;
							taken = again;
						} else if (kind == 3) {
							final again = plan.call.exists(block.addr) ? plan.call.get(block.addr) : 0;
							pend &= ~again;
							taken |= again;
						} else if (kind == 4) {
							final again = plan.call.exists(block.addr) ? plan.call.get(block.addr) : 0;
							pend &= ~x[1];
							taken = (taken & ~x[1]) | (again & x[1]);
							// A guessed jalr's other arm takes every span the call left live.
							if (block.transfer != null && block.transfer.decoded.op == Op.JALR)
								taken |= plan.callLive.exists(block.addr) ? plan.callLive.get(block.addr) : 0;
							else {}
						} else {}
					}
					pend &= active;
					taken &= active;
					if (pend != pendOut.get(block.addr) || taken != takenOut.get(block.addr)) {
						pendOut.set(block.addr, pend);
						takenOut.set(block.addr, taken);
						changed = true;
					} else {}
				}
			}
			if (bad == 0) {
				for (block in ir.blocks) {
					final m = pendIn.get(block.addr) & antIn.get(block.addr) & active;
					if (m != 0) entry.set(block.addr, m);
					else {}
				}
				break;
			} else active &= ~bad;
		}
		plan.top &= ~active;
		plan.entry = entry;
	}

	/** What a `jal` to `target` may write: the summary of the function it calls directly, or
	    every register for a call by address (emitCall's same test). */
	function callWrites(target:Int):Int {
		final t = Vaddr.canonRam(target);
		return staticTargetOf(t) != null ? writesOf(t) : ALL_REGS;
	}

	/**
		The function a `jalr` through a register most likely calls: the one constant the running
		function builds in that register (`lui` then `ori`/`addiu` into it), when it names a function
		this universe calls directly. A guess, and emitted as one: the call is guarded by the
		compare (emitTransfer), so a register that holds anything else still goes by address.
		Crash Bandicoot: Warped's model loop calls its vertex decoder this way at every vertex.
	**/
	function jalrGuess(i:Instr):Null<Int> {
		if (!optimize || i.rs == 0 || i.rs == 31) return null;
		final r = i.rs;
		var guess:Null<Int> = null;
		var hi:Null<Int> = null;
		for (block in ir.blocks) {
			for (x in block.instructions) {
				final d = x.decoded;
				if (d.op == Op.LUI && d.rt == r) hi = d.immU << 16;
				else if (hi != null && d.rt == r && d.rs == r && (d.op == Op.ORI || d.op == Op.ADDIU)) {
					final k = d.op == Op.ORI ? (hi | d.immU) : ((hi + d.immS) | 0);
					if (guess != null && guess != k) return null;
					else guess = k;
					hi = null;
				} else if (((x.writes : Int) & (1 << r)) != 0) hi = null;
				else {}
			}
		}
		// The constant as the code builds it, which is what the register will hold; a caller
		// canonicalises it to look the function up.
		return (guess != null && staticTargetOf(Vaddr.canonRam(guess)) != null) ? guess : null;
	}

	/** The bytes a load or store a span can take moves, or 0 for one it cannot. */
	static function spanWidth(op:Op):Int {
		return switch (op) {
			case LB | LBU | SB: 1;
			case LH | LHU | SH: 2;
			case LW | SW | LWC2 | SWC2: 4;
			case _: 0;
		};
	}

	/** A load: the timed form (`Memory.read32t(a, ctx, cyc)`) when the clock is in `cyc`, which
	    writes it to CpuState before a port can read it. */
	function memRead(name:String, addr:String):String
		return cycLocal ? 'Memory.${name}t($addr, ctx, cyc)' : 'Memory.$name($addr)';

	/** A store, likewise, as a statement. */
	function memWrite(name:String, addr:String, value:String):String
		return cycLocal ? 'Memory.${name}t($addr, $value, ctx, cyc);' : 'Memory.$name($addr, $value);';

	/** `stmt` after the clock is written to CpuState: for the unaligned accesses, which have no
	    timed form and are rare. */
	function clockFirst(stmt:String):String
		return (!cycLocal || stmt == "") ? stmt : 'ctx.cycles = cyc; $stmt';

	/** `span + offset`, the index of the access being emitted in its span. */

	/** A load (`name`: `read32` and the rest): through its span when it has one — the arena where
	    the span holds, the whole decode out of line (`Memory.read32f`) where it does not — and
	    otherwise the access itself, inline.

	    The span's test is marked likely (`shim.MemA.likely`, GCC's `__builtin_expect`), as are a
	    resume guard's `resume < 0` and a guessed call's compare, and a due pump and a pending
	    token unlikely: GCC then lays the slow paths out after a function's hot code rather than
	    between its blocks. Unmarked, Crash 3's 21 KB f_8003fc50 kept two hot stretches 8 KB
	    apart, which the SH-4's 8 KB instruction cache cannot hold at once, and no placement of
	    the function can separate (docs/perf/dreamcast-ledger.md, E-037). */
	function spanLoad(fast:String, name:String, i:Instr):String {
		final b = byBase(i);
		final k = portAccesses.exists(i.addr) ? 'p' : 'b';
		final slow = b == null ? 'Memory.${name}f(${busAddr(i)}, ctx, cyc)' : 'Memory.${name}${k}f($b, ctx, cyc)';
		return span == null ? ((b == null || !cycLocal) ? memRead(name, busAddr(i)) : 'Memory.${name}${k}t($b, ctx, cyc)')
			: '(shim.MemA.likely(Memory.spanOk(${span.v})) ? Memory.$fast(${span.v}, ${span.off}) : $slow)';
	}

	/** A store, likewise, as a statement. */
	function spanStore(fast:String, name:String, i:Instr, value:String):String {
		final b = byBase(i);
		final k = portAccesses.exists(i.addr) ? 'p' : 'b';
		final slow = b == null ? 'Memory.${name}f(${busAddr(i)}, $value, ctx, cyc);' : 'Memory.${name}${k}f($b, $value, ctx, cyc);';
		return span == null ? ((b == null || !cycLocal) ? memWrite(name, busAddr(i), value) : 'Memory.${name}${k}t($b, $value, ctx, cyc);')
			: 'if (shim.MemA.likely(Memory.spanOk(${span.v}))) Memory.$fast(${span.v}, ${span.off}, $value); else $slow';
	}

	/** An access through a register as `base, offset` (Memory's `*bt` and `*bf` forms: the bus
	    address `(base + offset) & 0x1FFFFFFF` everywhere but fastmem, where they let the C++
	    compiler share the base's P0 address among its accesses, ADR-0049); null for one at a
	    constant address, which keeps the bus address. */
	function byBase(i:Instr):Null<String>
		return i.rs == 0 ? null : '${reg(i.rs)}, ${i.immS}';

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
			case UnalignedLoad:
				final r = first.op == Op.LWR ? first : second;
				final l = first.op == Op.LWL ? first : second;
				assign(first.rt, 'Memory.lwu(${busAddr(r)}, ${busAddr(l)}, ${reg(first.rt)}, '
					+ '${first.op == Op.LWR}, ctx, ${cycLocal ? "cyc" : "ctx.cycles"})', false);
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
						buf.add(in1 + 'if (Memory.isIdleReadable($addr) && ($diff <= -$width || $diff >= 4)) ${reg(i.rt)} = Memory.$read($addr); else idleOk = false;\n');
					} else {
						buf.add(in1 + 'if (Memory.isIdleReadable($addr)) ${reg(i.rt)} = Memory.$read($addr); else idleOk = false;\n');
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
		buf.add(in2 + 'var idleTurns = core.IdleLoop.untilEvent(${cycExpr()}, core.Runtime.deadline(ctx), ${plan.cycles});\n');
		final exit = plan.counterExit;
		if (slot != null && exit != null) {
			final other = reg(exit.other);
			if (exit.exitOnEqual) buf.add(in2 + 'final idleExit = core.IdleLoop.untilEqual(idleTop, ${slot.delta}, $other);\n');
			else buf.add(in2 + 'final idleExit = ((idleTop + ${slot.delta}) | 0) == $other ? 2 : 1;\n');
			buf.add(in2 + 'if (idleExit - 1 < idleTurns) idleTurns = idleExit - 1; else {}\n');
		}
		buf.add(in2 + 'if (idleTurns >= 2) {\n');
		buf.add(in3 + 'final idleSkip = idleTurns - 1;\n');
		buf.add(in3 + '${cycExpr()} = (${cycExpr()} + shim.IntMath.mul(${plan.cycles}, idleSkip)) | 0;\n');
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
	function emitScalarCharges(buf:StringBuf, ind:String, scalar:ScalarPlan):Void {
		buf.add(ScalarEntry.charges(scalar, ind, cycExpr()));
	}

	/** Charge every original instruction, including eliminated instructions and delay slots. */
	function emitCharges(buf:StringBuf, ind:String, cycles:Int, insns:Int):Void {
		if (cycles > 0) buf.add('${ind}${cycExpr()} = (${cycExpr()} + $cycles) | 0;\n');
		buf.add('${ind}#if recompsx_insns\n');
		buf.add('${ind}Runtime.insns = (Runtime.insns + $insns) | 0;\n');
		buf.add('${ind}Runtime.blocks = (Runtime.blocks + 1) | 0;\n');
		buf.add('${ind}#end\n');
	}

	function emitTransfer(buf:StringBuf, fn:Func, instr:Instr, slot:Null<Instr>, blockAddr:Int,
			indexOf:Map<Int, Int>, ind:String, cycles:Int, insns:Int, tempCounter:Int):Void {
		final retAddr = instr.addr + 8;
		continuation = indexOf.exists(retAddr) ? indexOf.get(retAddr) : -1;
		callReturnAddr = retAddr;
		inline function emitSlot():Void {
			if (slot == null) return;
			span = functionSpanOf(slot);
			emitSimple(buf, ind, slot, true);
			span = null;
			if (fspanLive != null) {
				takeFunctionSpans(buf, ind, fspanLive.slot.exists(curBlock) ? fspanLive.slot.get(curBlock) : 0);
				stepFunctionSpans(buf, ind, fspanLive.slotStep.exists(curBlock) ? fspanLive.slotStep.get(curBlock) : 0, slot);
			} else {}
		}

		inline function bump():Void {
			emitCharges(buf, ind, cycles, insns);
		}

		switch (instr.op) {
			case JR | JALR if (instr.isRegisterJump && instr.rs == 31
					&& discovery.raJumpOf(fn.entry, instr.addr) != null):
				// $ra holds an address this function set: a jump (Discovery.findRaJumps).
				final target:Int = discovery.raJumpOf(fn.entry, instr.addr);
				emitSlot();
				bump();
				if (indexOf.exists(target)) emitGoto(buf, ind, target, indexOf, instr.addr);
				else {
					emitCall(buf, ind, target, false);
					buf.add('${ind}return;\n');
				}

			case JR | JALR if (instr.isRegisterJump && instr.rs == 31):
				emitSlot();
				bump();
				emitReturnCheck(buf, ind, fn, instr, reg(31));
				emitReturn(buf, ind);

			case JALR if (instr.rs == 31):
				// A return that also links: the caller's continuation goes into rd, then control
				// goes back to the caller (Discovery: a jump through $ra returns).
				final checked = fn.checkedReturns.exists(instr.addr);
				final t = 'target_${tempCounter}';
				if (checked) buf.add('${ind}final $t = ${reg(31)};\n');
				buf.add('${ind}${reg(instr.rd)} = ${pcExpr(retAddr)};\n');
				emitSlot();
				bump();
				if (checked) emitReturnCheck(buf, ind, fn, instr, t);
				emitReturn(buf, ind);

			case JR if (fn.registerReturns.exists(instr.addr)):
				// A return through a copy of $ra (Discovery.findRegisterReturns).
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
					buf.add('$ind\t\tctx.pc = $t; ${tailCall(t)}; return;\n');
					buf.add('$ind}\n');
				} else if (constant != null && isKernelVector(constant.target)) {
					emitSlot();
					bump();
					publish(buf, ind);
					buf.add('${ind}ctx.pc = ${pcExpr(instr.addr)};\n');
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
					buf.add('${ind}${tailCall(t)};   // computed jump: the caller runs it (ADR-0026)\n');
					buf.add('${ind}return;\n');
				}

			case JAL:
				// The link is written before the slot runs, which matters when the slot reads $ra.
				buf.add('${ind}${reg(31)} = ${pcExpr(retAddr)};\n');
				emitSlot();
				bump();
				emitCall(buf, ind, instr.target);
				emitFallThrough(buf, fn, ind, indexOf, retAddr);

			case JALR:
				final t = 'target_${tempCounter}';
				// The target is latched before the link is written, so `jalr $ra, $ra` works.
				buf.add('${ind}final $t = ${reg(instr.rs)};\n');
				if (instr.rd != 0) buf.add('${ind}${reg(instr.rd)} = ${pcExpr(retAddr)};\n');
				emitSlot();
				bump();
				if (cycLocal) buf.add('${ind}ctx.cycles = cyc;\n');
				buf.add('${ind}ctx.pc = $t;\n');
				final guess = jalrGuess(instr);
				if (guess != null) {
					// The guessed function called directly when the register holds it, and after it
					// only the spans it may have changed taken again; anything else by address, and
					// every span the call left live.
					buf.add('${ind}if (shim.MemA.likely($t == ${hex(guess)})) {\n');
					final g = Vaddr.canonRam(guess);
					buf.add('${ind}\t${staticTargetOf(g)}.${Discovery.defaultName(g)}(ctx);\n');
					emitCallUnwind(buf, ind + '\t', continuation, pcExpr(retAddr));
					buf.add('${ind}} else {\n');
					buf.add('${ind}\t${siteCall(t)};\n');
					emitCallUnwind(buf, ind + '\t', continuation, pcExpr(retAddr), true);
					buf.add('${ind}}\n');
				} else {
					buf.add('${ind}${siteCall(t)};\n');
					emitCallUnwind(buf, ind, continuation, pcExpr(retAddr));
				}
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
					buf.add('${ind}${reg(31)} = ${pcExpr(retAddr)};   // linked even when not taken\n');
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
						publishValues(buf, ind);
						if (dispatchCase != null && dispatchCase.exists(takenIdx) && dispatchCase.exists(notTakenIdx)) {
							buf.add('$ind$GOTO_IF\n');
							buf.add('${ind}if ($cond) { ' + cxxJump(takenIdx) + ' } else { ' + cxxJump(notTakenIdx) + ' }\n');
							buf.add('$ind#else\n');
							buf.add('${ind}bb = $cond ? $takenIdx : $notTakenIdx; continue;\n');
							buf.add('$ind#end\n');
						} else buf.add('${ind}bb = $cond ? $takenIdx : $notTakenIdx; continue;\n');
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
		// Only a tail call reaches here from a leaf, and it leaves: publish, never reload.
		publish(buf, ind);
		if (cls != null) {
			var scalar = optimize && scalarCalls ? scalarTargetOf(t) : null;
			var projected = false;
			var borrowed = resumes ? scalarBorrows.get(curBlock) : null;
			final transfer = ir.byAddress.get(curBlock).transfer;
			if (resumes && !relocatable && transfer != null
					&& transfer.decoded.op == Op.JAL && callLive.exists(transfer.decoded.addr)) {
				final suffix = '_from_${StringTools.hex(functionAddr, 8)}_${StringTools.hex(transfer.decoded.addr, 8)}';
				final projection = projectedTargetOf(t, callLive.get(transfer.decoded.addr), suffix);
				// Borrow liveness/arguments were planned from the complete callee. A memory
				// projection may only reuse them with exactly the same access/alias preflight.
				if (projection != null) {
					if (borrowed != null && (projection.memory == null || scalar == null || scalar.memory == null
							|| projection.memory.guard('') != scalar.memory.guard(''))) borrowed = null;
					scalar = projection;
					projected = true;
					// Memory and GTE projections stay with their caller: only pure ones are pooled.
					if (scalarPool == null || scalar.memory != null || scalar.coprocessor) projections.push({plan:scalar, owner:cls, borrowed:borrowed != null});
				}
			}
			// Borrowed adapters reuse caller coverage; fresh adapters build all access guards.
			// Both own publication and fall back to the complete original entry.
			if (projected && scalar.memory != null && borrowed == null) buf.add('$ind${scalar.projectedName()}(ctx);\n');
			else if (scalar == null || (scalar.memory != null && borrowed == null)) buf.add('$ind$cls.${Discovery.defaultName(t)}(ctx);\n');
			else if (borrowed != null) buf.add(ind + (projected ? '' : cls + '.') + '${scalar.borrowedName()}(ctx, ' + borrowed.args.join(', ') + ');\n');
			else emitScalarCall(buf, ind, cls, scalar, projected);
		} else if (!resumes) {
			// A tail call by address: a jump, left for the caller to run (ADR-0026).
			buf.add('${ind}ctx.pc = ${hex(t)};\n');
			buf.add('${ind}${tailCall(hex(t))};\n');
			return;
		} else {
			// The kernel, code this build never found, or a window whose occupant is decided at
			// run time. All three are the same instruction here: ask by address — a site of its own,
			// as a JALR is (a window's occupant changes, and its answer with it).
			buf.add('${ind}ctx.pc = ${hex(t)};\n');
			buf.add('${ind}${siteCall(hex(t))};\n');
		}
		// A tail call's callee returns to our caller: this frame is no one's continuation.
		emitCallUnwind(buf, ind, resumes ? continuation : -1,
			resumes ? pcExpr(callReturnAddr) : NO_CONTINUATION);
	}

	/** The slow arm owns all observable entry work. Do not call wantsYield here: its
	    stress counter must advance exactly once, in the callee's original checkpoint. */
	function emitScalarCall(buf:StringBuf, ind:String, cls:String, scalar:ScalarPlan, projected:Bool = false):Void {
		buf.add(ScalarEntry.slowGuard(ind, projected, scalar.horizon == 0 ? null : ScalarEntry.callWindow(scalar.horizon)));
		buf.add('${ind}\t$cls.${scalar.name}(ctx);\n');
		buf.add('${ind}} else {\n');
		final shared = projected && scalarPool != null && !scalar.coprocessor ? scalarPool.intern(scalar) : null;
		buf.add(scalar.apply(ind + '\t', projected ? null : cls, shared));
		final local = cycLocal;
		cycLocal = false;
		emitScalarCharges(buf, ind + '\t', scalar);
		cycLocal = local;
		buf.add('${ind}}\n');
	}

	/** After a call: `entry` is the block it resumes at, `cont` the guest address it returns to;
	    `anything` for a call that may have written any register (a guessed call's other arm). */
	function emitCallUnwind(buf:StringBuf, ind:String, entry:Int, cont:String, anything:Bool = false):Void {
		final ra = entryRaLocal ? ', entryRa' : '';
		buf.add(ind + '#if recompsx_cooperative\n');
		buf.add(ind + (relocatable
			? 'if (core.Cooperative.afterCallAt(ctx, ${continuationId()}, $entry, rbase, $cont$ra)) return;\n'
			: 'if (core.Cooperative.afterCall(ctx, ${continuationId()}, $entry, $cont$ra)) return;\n'));
		buf.add(ind + '#else\n' + ind + callUnwindLine(cont) + '\n' + ind + '#end\n');
		// After the unwind check: `unwinding` may have run a tail jump the callee left.
		if (cycLocal) buf.add(ind + 'cyc = ctx.cycles;\n');
		if (fspanLive != null) {
			final m = anything && fspanLive.callLive.exists(curBlock) ? fspanLive.callLive.get(curBlock)
				: (fspanLive.call.exists(curBlock) ? fspanLive.call.get(curBlock) : -1);
			takeFunctionSpans(buf, ind, m);
		} else {}
	}

	/** The running function's cycle count: its local in an optimized build (`cycLocal`). */
	function cycExpr():String return cycLocal ? 'cyc' : 'ctx.cycles';

	/** `stmt` with the cycle count written to CpuState before it and read back after it: for a
	    statement that reaches the runtime, which may read the clock and may move it. */
	function aroundRuntime(stmt:String):String
		return (!cycLocal || stmt == "") ? stmt : 'ctx.cycles = cyc; $stmt cyc = ctx.cycles;';

	function continuationId():String return continuationToken == null ? hex(functionAddr) : continuationToken;

	/** A call by address followed by the ordinary unwind check (emitCallUnwind, which runs the tail
	    jumps the callee leaves): through `dynamicSite` with this site's token when the program
	    numbers sites. A hand-over (emitHop) keeps `dynamicCall`, whose loop runs them itself. */
	function siteCall(t:String):String {
		if (dynamicSite == null) return '$dynamicCall(ctx, $t)';
		else return '$dynamicSite(ctx, $t, $SITE_TOKEN${siteOrdinal++}__)';
	}

	/** A jump the caller runs (ADR-0026): `Runtime.tail`, or with a site of its own when the program
	    numbers sites — a computed jump goes to one function nearly every time (Crash 3's renderer,
	    983 a present, one target a site), which a site's answer holds where the program's one last
	    answer missed 19 in 20. */
	function tailCall(t:String):String {
		if (dynamicSite == null) return 'Runtime.tail(ctx, $t)';
		else {}
		final site = '$SITE_TOKEN${siteOrdinal++}__';
		// On C++ the site's answer is a tail call (GCC's musttail: this frame replaced, so a chain of
		// jumps runs at one host depth, as ADR-0026 asks): a JIT's block linking, through the site's
		// pointer. Anything else leaves the jump to the caller, as before, and the caller's `run`
		// keeps the site's answer for the next time. The cooperative build keeps its continuations.
		return '#if (cxx && !recompsx_cooperative) untyped __cpp__("RECOMPSX_TAIL(({1}), ({0}))", $t, $site); #end '
			+ 'FnTable.tailAt(ctx, $t, $site)';
	}

	/** The check after a call: `unwindLine`, through the program's own `FnTable.unwound` when it has
	    one, which runs a tail jump the callee left without the runtime's Runtime.call and its bound
	    runner on the way. */
	function callUnwindLine(cont:String):String {
		if (dynamicSite == null) return unwindLine(cont);
		else return 'if (shim.MemA.unlikely(ctx.unwindToken != 0) && FnTable.unwound(ctx, $cont)) return;';
	}

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
	static inline final JUMP_HOP = 6;        // another function's entry: hand over (cutAtEntries)

	/**
		How control reaches `target` from here. The order is the nesting: the block that follows
		in a sequence needs no statement; the innermost native loop owns its header and, by a
		recorded `break`, everything outside its members; a later part of an enclosing sequence
		is reached by recording it and letting the guards skip; anything else still in the
		function goes through the dispatcher — which no native loop may contain — and anything
		outside it leaves.
	**/
	function jumpKind(target:Int, indexOf:Map<Int, Int>):Int {
		// Another function's entry is no block here, whatever encloses the jump: it leaves.
		if (!indexOf.exists(target) && curFn != null && curFn.hops.exists(Vaddr.canonRam(target))) return JUMP_HOP;
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
			case _: dispatchJump(indexOf.get(target));
		};
	}

	function emitJump(buf:StringBuf, ind:String, target:Int, indexOf:Map<Int, Int>):Void {
		final kind = jumpKind(target, indexOf);
		if (kind == JUMP_FALL) return;
		if (kind == JUMP_RETURN) emitReturn(buf, ind);
		else if (kind == JUMP_HOP) emitHop(buf, ind, target);
		else {
			if (kind == JUMP_DISPATCH || (kind != JUMP_FORWARD && leavesValues(target))) publishValues(buf, ind);
			buf.add(ind + jumpText(kind, target, indexOf) + '\n');
		}
	}

	/** Code only reflaxe.CPP's output may hold: a label, a `goto` (dispatchJump). */
	static inline final GOTO_IF = '#if (cxx && !recompsx_cooperative)';

	/** The label at the head of a dispatcher's case on C++, which dispatchJump's `goto` reaches. */
	function caseLabel(ind:String, first:Int):String
		return '$ind$GOTO_IF untyped __cpp__("rx_bb_$first:;"); #end\n';

	/**
		A jump to block `idx` through the dispatcher: `bb` set, then on C++ a `goto` to the label of
		the case that holds it, and elsewhere `continue`, back to the switch; the case's `resume = bb`
		steers to the block either way. The switch was a bound check, a table load and a `braf` a
		jump on the SH-4, its table in the code and read through the operand cache (ADR-0050).
	**/
	function dispatchJump(idx:Int):String {
		return dispatchCase == null || !dispatchCase.exists(idx) ? 'bb = $idx; continue;'
			: 'bb = $idx; $GOTO_IF untyped __cpp__("goto rx_bb_${dispatchCase.get(idx)};"); #else continue; #end';
	}

	/** dispatchJump's C++ form alone, for code already inside GOTO_IF. */
	function cxxJump(idx:Int):String
		return 'bb = $idx; untyped __cpp__("goto rx_bb_${dispatchCase.get(idx)};");';

	/** One arm of a branch as a braced block: a one-liner inline, a return on its own lines. */
	function arm(kind:Int, target:Int, indexOf:Map<Int, Int>, ind:String):String {
		if (kind != JUMP_RETURN && kind != JUMP_HOP && (valueScope == null || kind != JUMP_DISPATCH)
				&& (kind == JUMP_FORWARD || !leavesValues(target)))
			return '{ ' + jumpText(kind, target, indexOf) + ' }';
		final lines = new StringBuf();
		lines.add('{\n');
		if (kind == JUMP_RETURN) emitReturn(lines, ind + '\t');
		else if (kind == JUMP_HOP) emitHop(lines, ind + '\t', target);
		else { publishValues(lines, ind + '\t'); lines.add(ind + '\t' + jumpText(kind, target, indexOf) + '\n'); }
		lines.add(ind + '}');
		return lines.toString();
	}

	// ---- instructions without a delay slot -------------------------------------------------------

	function emitSimple(buf:StringBuf, ind:String, i:Instr, slot:Bool = false,
			afterBlock:Null<Int> = null, afterIndex:Int = -1):Void {
		final barrier = i.op == Op.SYSCALL || i.op == Op.BREAK;
		final line = simple(i, afterBlock, afterIndex);
		if (line != "") buf.add(ind + line + (slot ? '   // delay slot' : '') + '\n');
		if (barrier) buf.add(ind + unwindLine(NO_CONTINUATION) + '\n');
		if (barrier && cycLocal) buf.add(ind + 'cyc = ctx.cycles;\n');
		// A trap in the body is an event of the liveness plan (resetFunctionSpans, by its index,
		// after this returns); one in a delay slot takes every span.
		if (barrier && slot) resetAllFunctionSpans(buf, ind);
		else {}
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
			// A logical right shift by zero is the value unchanged, and on JavaScript `x >>> 0` is
			// not: it is the unsigned reading, a number above 2^31 that no Int can hold. Such a
			// value compares unequal to the same bits held signed (BEQ is `==`), which C++ never
			// sees, and stored once into a CpuState field it turned the field into a boxed double
			// for good — every later read in unoptimised code, and every trip through a call in
			// optimised code, allocated. The same for SRLV, whose amount is only known at run time.
			case SRL:  pureAssign(rd, i.shamt == 0 ? reg(rt) : '${reg(rt)} >>> ${i.shamt}', false, afterBlock, afterIndex);
			case SRA:  pureAssign(rd, '${reg(rt)} >> ${i.shamt}', false, afterBlock, afterIndex);
			case SLLV: pureAssign(rd, '${reg(rt)} << (${reg(rs)} & 31)', false, afterBlock, afterIndex);
			case SRLV: pureAssign(rd, '${reg(rt)} >>> (${reg(rs)} & 31)', true, afterBlock, afterIndex);
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
			case LB:  load(rt, spanLoad('spanRead8s', 'read8s', i));
			case LBU: load(rt, spanLoad('spanRead8u', 'read8u', i));
			case LH:  load(rt, spanLoad('spanRead16s', 'read16s', i));
			case LHU: load(rt, spanLoad('spanRead16u', 'read16u', i));
			case LW:  load(rt, spanLoad('spanRead32', 'read32', i));
			case LWL: clockFirst(load(rt, 'Memory.lwl(${busAddr(i)}, ${reg(rt)})'));
			case LWR: clockFirst(load(rt, 'Memory.lwr(${busAddr(i)}, ${reg(rt)})'));

			case SB: spanStore('spanWrite8', 'write8', i, reg(rt));
			case SH: spanStore('spanWrite16', 'write16', i, reg(rt));
			case SW: spanStore('spanWrite32', 'write32', i, reg(rt));
			case SWL: clockFirst('Memory.swl(${busAddr(i)}, ${reg(rt)});');
			case SWR: clockFirst('Memory.swr(${busAddr(i)}, ${reg(rt)});');

			case SYSCALL: '${cycLocal ? "ctx.cycles = cyc; " : ""}ctx.pc = ${pcExpr(i.addr)}; Kernel.syscall(ctx, ${i.code});';
			case BREAK:   '${cycLocal ? "ctx.cycles = cyc; " : ""}ctx.pc = ${pcExpr(i.addr)}; Kernel.brk(ctx, ${i.code});';

			case MFC0: aroundRuntime(assign(rt, 'Runtime.mfc0(ctx, ${i.rd})', false));
			case MTC0: aroundRuntime('Runtime.mtc0(ctx, ${i.rd}, ${reg(rt)});');
			case RFE:  aroundRuntime('Runtime.rfe(ctx);');

			case MFC2: assign(rt, 'Gte.getData(ctx, ${i.rd})', false);
			case MTC2: 'Gte.setData(ctx, ${i.rd}, ${reg(rt)});';
			case CFC2: assign(rt, 'Gte.getCtrl(ctx, ${i.rd})', false);
			case CTC2: 'Gte.setCtrl(ctx, ${i.rd}, ${reg(rt)});';
			case LWC2: 'Gte.setData(ctx, ${i.rt}, ${spanLoad('spanRead32', 'read32', i)});';
			case SWC2: spanStore('spanWrite32', 'write32', i, 'Gte.getData(ctx, ${i.rt})');
			case COP2CMD: gteCommand(i.code, optimize, optimize);

			case _: '// unhandled: ${Disasm.text(i)}';
		}
	}

	/**
		A GTE command word is a constant, so its operation is called by name with the fields the
		runtime's `execute` would have decoded from it; `execute` itself is kept for any word the
		table below does not know, so an unknown operation still reports itself at run time.
	**/
	/* In an optimized build NCLIP, AVSZ3 and AVSZ4 run at the call site (`gte.GteQuick`, forced
	   inline on C++): each is shorter than the call it was. */
	/**
		A COP2 command by name. `quick`: NCLIP, AVSZ3 and AVSZ4 run inline (gte.GteQuick).
		`inlineRtps`: RTPS as well, wherever the code is optimized. Until the SH-4's RTPS core
		(ADR-0046) a looping leaf kept it a call: inline, the transform's own dozen values spilled
		the leaf's registers, and Crash Bash's hottest loop (a leaf, four RTPS) ran 0.2 ms a frame
		slower (E-031; E-051: still 0.08 slower with the matrix rows on the multiply-accumulate
		unit). With the core the inline transform is a call to it, its C form out of line
		(Gte.project32), so a leaf's registers fare as they did around `Gte.cmdRtps` and the
		wrapper's own call goes (E-088).
	**/
	static function gteCommand(code:Int, quick:Bool = false, inlineRtps:Bool = false):String {
		return gteCommandText(code, quick, inlineRtps);
	}

	/**
		A known COP2 command as a scalar helper issues it (ScalarGraph), without its `;`, or null for
		a word the table does not know, whose `execute` needs the CPU state. Inline as everywhere
		else (gteCommand): the quick ones and RTPS.
	**/
	public static function scalarGteCommand(code:Int):Null<String> {
		final text = gteCommandText(code, true, true);
		if (StringTools.startsWith(text, 'Gte.execute')) return null;
		return (StringTools.startsWith(text, 'Gte.') ? 'gte.' : '') + text.substr(0, text.length - 1);
	}

	static function gteCommandText(code:Int, quick:Bool, inlineRtps:Bool):String {
		final sf = (code & 0x80000) != 0 ? 12 : 0;
		final lm = (code & 0x400) != 0 ? "true" : "false";
		final args = '$sf, $lm';
		return switch (code & 0x3F) {
			case 0x01: inlineRtps ? 'gte.GteQuick.rtps($args);' : 'Gte.cmdRtps($args);';
			case 0x30: 'Gte.cmdRtpt($args);';
			case 0x06: quick ? 'gte.GteQuick.nclip();' : 'Gte.cmdNclip();';
			case 0x2D: quick ? 'gte.GteQuick.avsz3();' : 'Gte.cmdAvsz3();';
			case 0x2E: quick ? 'gte.GteQuick.avsz4();' : 'Gte.cmdAvsz4();';
			case 0x12: 'Gte.cmdMvmva($args, ${hex(code)});';
			case 0x28: 'Gte.cmdSqr($sf);';
			case 0x0C: 'Gte.cmdOp($args);';
			case 0x3D: 'Gte.cmdGpf($args);';
			case 0x3E: 'Gte.cmdGpl($args);';
			case 0x10: quick ? 'gte.GteQuick.dpcs($args);' : 'Gte.cmdDpcs($args);';
			case 0x2A: quick ? 'gte.GteQuick.dpct($args);' : 'Gte.cmdDpct($args);';
			case 0x11: quick ? 'gte.GteQuick.intpl($args);' : 'Gte.cmdIntpl($args);';
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

	/**
		The address a load or store hands the bus: the virtual one with its segment bits cleared,
		which every accessor does first anyway (`Memory.phys`), so the value it sees is the same.

		Done here as well for the JavaScript engines with 31-bit small integers — V8 in Chrome,
		Edge and Brave. A KSEG0 address (0x80000000 and up) is outside that range, so every one
		passed to an accessor the JIT did not inline was a heap-allocated number, the largest
		share of what the browser's collector cleared; a physical address is below 2^29 and is
		never boxed. On C++ the accessor's own mask makes this one redundant and it folds away.
	**/
	function busAddr(i:Instr):String {
		if (i.rs == 0) return hex(i.immS & 0x1FFFFFFF);
		if (i.immS == 0) return '${reg(i.rs)} & 0x1FFFFFFF';
		return '(${reg(i.rs)} + ${i.immS}) & 0x1FFFFFFF';
	}

	/** An assignment, dropped entirely when the destination is $zero. */
	function assign(dest:Int, expr:String, wraps:Bool):String {
		if (dest == 0) return "";
		if (!wraps && expr == reg(dest)) return "";
		return '${reg(dest)} = ' + (wraps ? '($expr) | 0;' : '$expr;');
	}

	/** A pure GPR write outside a selected value region. Keep it: a register is machine state,
	    and the next frame, pump or trap may read it (ADR-0029/0044). */
	function pureAssign(dest:Int, expr:String, wraps:Bool, block:Null<Int>, index:Int):String {
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
			: valueScope != null && valueScope.used.indexOf(n) >= 0 ? valuePrefix + Instr.regName(n)
			: (leafUsed != null && leafUsed.indexOf(n) >= 0 ? "" : "ctx.") + Instr.regName(n));

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

/** A load or store's place in its span (Emitter.planSpans): the span's local, its offset. */
typedef SpanAccess = {v:String, off:Int};

/** A block's spans: the line opening each, by the index of its first access, and every access's. */
typedef SpanPlan = {open:Map<Int, String>, at:Map<Int, SpanAccess>};

/** A function span (Emitter.planFunctionSpans): its local, and the offsets it covers. */
typedef FunctionSpan = {v:String, lo:Int, hi:Int};

/** Where function spans are taken (Emitter.planFspanLiveness), as register masks: at the entry,
    after a body instruction by block and index, after a block's delay slot, after its call, and
    at the start of a block (`entry`, Emitter.deferEntryTakes). */
typedef FspanLive = {top:Int, write:Map<Int, Map<Int, Int>>, slot:Map<Int, Int>, call:Map<Int, Int>,
	callLive:Map<Int, Int>, step:Map<Int, Map<Int, Int>>, slotStep:Map<Int, Int>, entry:Map<Int, Int>};
