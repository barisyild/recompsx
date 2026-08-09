package recomp.analysis;

import recomp.Vaddr;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.analysis.AnalysisError;
import recomp.analysis.Confidence;
import recomp.analysis.Func;
import recomp.analysis.Func.Block;
import recomp.analysis.Func.CallSite;
import recomp.analysis.Image;
import recomp.analysis.Kind;
import recomp.analysis.JumpTable;
import recomp.analysis.TableConfidence;
import recomp.analysis.TableFinder;
import recomp.analysis.JumpKind;

/** A seed the caller supplies: an address believed to start a function. */
typedef Seed = {addr:Int, name:String, confidence:Confidence};

/**
	Finds the functions in an image.

	The algorithm is a worklist closure over calls: start from the entry point and any configured
	or symbolic seeds, trace each function's basic blocks, and every `jal` target found becomes a
	new seed. This reaches everything statically called from the entry point, which for compiled
	code is most of the program.

	What it does not reach is anything only ever called through a register — dispatch tables,
	callbacks handed to the kernel, virtual-ish jumps. Those are not a failure of the closure but
	a fact about the program, and the answer is not to guess: they are recorded, the runtime
	dispatches them by address, and the coverage report lists the gaps so a person can decide
	which ones deserve a hint in `game.json`.

	The one guess made here is the gap sweep: after the closure settles, unclaimed regions are
	scanned for something that looks like a function prologue. It is explicitly marked as a guess
	(`Confidence.Swept`) so the report can separate what is known from what is suspected.
**/
class Discovery {
	/** No real function is anywhere near this large; a trace that runs away has misread data as
	    code, and stopping with a diagnostic beats consuming the whole image. */
	static inline var MAX_FUNCTION_WORDS = 16384;   // 64 KB

	public final image:Image;
	public final functions:Map<Int, Func> = [];
	public final warnings:Array<String> = [];

	/** Call sites whose target could not be resolved statically, across the whole image. */
	public final indirectCalls:Array<CallSite> = [];

	/** Switch tables recovered from computed jumps, keyed by the address of the `jr`. */
	public final tables:Map<Int, JumpTable> = [];

	/** Computed jumps that turned out to have a constant target, keyed by the `jr` address.
	    Mostly BIOS calls; see JumpKind.Constant. */
	public final constantJumps:Map<Int, {target:Int, fnNumber:Int}> = [];

	final pending:Array<Seed> = [];
	final seen:Map<Int, Bool> = [];
	/** Every seed ever accepted. A pass that learns something new about a computed jump replays
	    all of them, which reproduces the same functions plus whatever the new knowledge reveals. */
	final allSeeds:Array<Seed> = [];

	public function new(image:Image) {
		this.image = image;
	}

	public function addSeed(addr:Int, name:String, confidence:Confidence):Void {
		final a = Vaddr.canonRam(addr);
		if (seen.exists(a)) return;
		if (!image.containsWord(a)) {
			// Calls out of the image are normal: kernel vectors, and code in another overlay.
			return;
		}
		if ((a & 3) != 0) {
			throw new AnalysisError('function address ${Vaddr.hex(a)} is not word-aligned');
		}
		seen.set(a, true);
		final seed = {addr: a, name: name, confidence: confidence};
		pending.push(seed);
		allSeeds.push(seed);
	}

	/**
		Discovers everything reachable.

		Three stages, each feeding the next. The call closure finds what is statically called. Jump
		tables are then recovered from the computed jumps that closure ran into — and because every
		recovered table opens a subtree of previously invisible code, the closure is run again from
		scratch with the tables known. Finally the prologue sweep guesses at whatever is still
		unclaimed.

		Re-running rather than patching is deliberate: a table turns a `jr` from "control leaves
		here" into "control goes to one of these", which changes block boundaries, so the second
		pass starts from a cleared classification instead of trying to unpick the first.
	**/
	public function run(?sweepGaps = true, ?recoverTables = true):Void {
		closure();
		if (recoverTables) settleJumps();

		if (sweepGaps) {
			sweepForPrologues();
			closure();
			// The sweep reaches code the closure could not, and that code contains computed jumps
			// of its own — so the jump analysis has to run again over what it found. Skipping this
			// leaves BIOS calls in swept functions looking like unresolved dispatch.
			if (recoverTables) settleJumps();
		}

		claimTables();
		markPadding();
	}

	/**
		Explains computed jumps until nothing new is learned.

		Each round can only improve on the last: a recovered table opens code that may contain
		more computed jumps, and a jump recognised as a BIOS call removes a false dead end. The
		round count is capped because the loop is driven by a heuristic and a pathological image
		should not be able to spin it.
	**/
	function settleJumps():Void {
		var rounds = 0;
		while (rounds < 4 && findTables() > 0) {
			restart();
			closure();
			rounds++;
		}
	}

	/**
		Starts discovery over with everything learned so far still known.

		A recovered table turns a `jr` from "control leaves here" into "control goes to one of
		these", which moves block boundaries — so the classification is cleared and every seed
		replayed, rather than trying to patch the previous result in place.
	**/
	function restart():Void {
		image.resetClassification();
		functions.clear();
		seen.clear();
		final snapshot = allSeeds.copy();
		allSeeds.resize(0);
		for (s in snapshot) addSeed(s.addr, s.name, s.confidence);
	}

	function closure():Void {
		while (pending.length > 0) {
			final seed = pending.shift();
			final fn = traceFunction(seed);
			functions.set(fn.entry, fn);
		}
	}

	/** Tries to explain every computed jump found so far. Returns how many are newly explained. */
	function findTables():Int {
		final finder = new TableFinder(image);
		final codeRange = codeBounds();
		var found = 0;
		for (fn in functions) {
			for (jrAddr in fn.unresolvedJumps) {
				if (tables.exists(jrAddr) || constantJumps.exists(jrAddr)) continue;
				switch (finder.analyze(jrAddr, codeRange.start, codeRange.end)) {
					case Table(t):
						tables.set(jrAddr, t);
						found++;
					case Constant(target, fnNumber):
						constantJumps.set(jrAddr, {target: target, fnNumber: fnNumber});
						found++;
					case Unresolved:
				}
			}
		}
		return found;
	}

	/**
		Where a switch arm may plausibly point.

		A PS-EXE holds code and data in one blob, so "inside the image" is far too weak a test —
		half the image is tables and strings, and any word in them would pass. The end of the code
		is taken as the highest address any function reached, which is knowable after the first
		closure and is a much sharper boundary.
	**/
	function codeBounds():{start:Int, end:Int} {
		var end = image.baseAddr;
		for (fn in functions) if (fn.endAddr > end) end = fn.endAddr;
		// Allow a margin: the last function's tail may extend past what has been traced.
		end += 0x1000;
		if (end > image.endAddr()) end = image.endAddr();
		return {start: image.baseAddr, end: end};
	}

	/** Marks recovered tables as data, so coverage does not count them as unreached code. */
	function claimTables():Void {
		for (t in tables) {
			image.claimRange(t.base, t.base + t.sizeBytes(), Kind.DataInText, 0);
		}
	}

	// ---- tracing one function ---------------------------------------------------------------

	/**
		Traces one function in two passes.

		The first pass follows control flow to find which instructions are reachable and which
		addresses are *leaders* — the start of a basic block, meaning the entry, every branch
		target, and every instruction that follows a control transfer. The second pass then cuts
		the instruction stream at those leaders.

		Two passes rather than one because a block's boundaries are not known while it is being
		walked: a backward branch later in the function can make an address in the middle of an
		already-traced run into a leader. Building blocks in one pass produces overlapping blocks
		that each contain the shared tail, which reads fine in a report and would emit the same
		instructions twice in generated code.
	**/
	function traceFunction(seed:Seed):Func {
		final fn = new Func(seed.addr, seed.name, seed.confidence);
		final leaders:Map<Int, Bool> = [seed.addr => true];
		final reachable:Map<Int, Bool> = [];
		final overlapReported:Map<Int, Bool> = [];
		var maxEnd = seed.addr;
		var words = 0;

		// ---- pass 1: reachability and leaders ----
		final queue = [seed.addr];
		while (queue.length > 0) {
			var addr = queue.shift();
			var running = true;
			while (running) {
				if (reachable.exists(addr)) break;
				if (!image.containsWord(addr)) {
					fn.warnings.push('ran past the end of the image at ${Vaddr.hex(addr)}');
					break;
				}
				words++;
				if (words > MAX_FUNCTION_WORDS) {
					fn.warnings.push('gave up after ${MAX_FUNCTION_WORDS} words — this is almost '
						+ 'certainly data being read as code');
					break;
				}

				final instr = Decoder.decode(addr, image.readWord(addr));
				if (instr.op == Op.INVALID) throw new AnalysisError(invalidInstructionMessage(fn, instr));

				reachable.set(addr, true);
				if (addr + 4 > maxEnd) maxEnd = addr + 4;

				if (!instr.op.hasDelaySlot) {
					addr += 4;
					continue;
				}

				// The delay slot belongs to this transfer and executes before it takes effect.
				final slotAddr = addr + 4;
				if (image.containsWord(slotAddr)) {
					final slot = Decoder.decode(slotAddr, image.readWord(slotAddr));
					if (slot.op.hasDelaySlot) throw new AnalysisError(delaySlotBranchMessage(fn, instr, slot));
					if (slot.op == Op.INVALID) throw new AnalysisError(invalidInstructionMessage(fn, slot));
					reachable.set(slotAddr, true);
					if (slotAddr + 4 > maxEnd) maxEnd = slotAddr + 4;
				}
				final afterSlot = slotAddr + 4;

				running = false;
				switch (instr.op) {
					case JR:
						if (instr.rs == 31) {
							// A return: control leaves the function.
						} else if (tables.exists(instr.addr)) {
							// A recovered switch. Every arm is ordinary control flow inside this
							// function, which is the whole point of recovering the table.
							for (t in tables.get(instr.addr).targets) follow(leaders, queue, t);
						} else if (constantJumps.exists(instr.addr)) {
							final c = constantJumps.get(instr.addr);
							if (isKernelVector(c.target)) {
								fn.kernelCalls.push({from: instr.addr, vector: c.target,
									fnNumber: c.fnNumber});
								// A BIOS call through `jr` does not return here — the kernel
								// returns to $ra, so control leaves this block exactly as a tail
								// call would.
							} else {
								fn.tailCalls.push(new CallSite(instr.addr, c.target, false));
								addSeed(c.target, defaultName(c.target), Confidence.Called);
							}
						} else {
							fn.unresolvedJumps.push(instr.addr);
						}

					case JALR:
						fn.calls.push(new CallSite(instr.addr, 0, true));
						indirectCalls.push(new CallSite(instr.addr, 0, true));
						follow(leaders, queue, afterSlot);

					case JAL:
						fn.calls.push(new CallSite(instr.addr, instr.target, false));
						addSeed(instr.target, defaultName(instr.target), Confidence.Called);
						follow(leaders, queue, afterSlot);

					case J:
						// Inside this function, or a tail call to another? A jump to something
						// already known to be a function entry is a tail call; anything else is
						// internal control flow, which is what compilers emit for long branches
						// and switch arms.
						if (isKnownEntry(instr.target) && instr.target != fn.entry) {
							fn.tailCalls.push(new CallSite(instr.addr, instr.target, false));
						} else if (image.containsWord(instr.target)) {
							follow(leaders, queue, instr.target);
						} else {
							fn.tailCalls.push(new CallSite(instr.addr, instr.target, false));
							addSeed(instr.target, defaultName(instr.target), Confidence.Called);
						}

					case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
						follow(leaders, queue, instr.target);   // taken
						follow(leaders, queue, afterSlot);      // not taken

					case BLTZAL | BGEZAL:
						// A conditional call: the link register is written whether or not the
						// branch is taken, which the emitter has to reproduce. For control flow
						// it behaves like a branch that falls through.
						fn.calls.push(new CallSite(instr.addr, instr.target, false));
						addSeed(instr.target, defaultName(instr.target), Confidence.Called);
						follow(leaders, queue, afterSlot);

					case _:
						fn.warnings.push('unexpected control transfer ${instr.op.mnemonic} at '
							+ Vaddr.hex(instr.addr));
				}
			}
		}

		// ---- pass 2: cut the reachable instructions at the leaders ----
		for (leaderAddr in leaders.keys()) {
			if (!reachable.exists(leaderAddr)) continue;   // a target we never actually reached
			final block = new Block(leaderAddr);
			fn.blocks.set(leaderAddr, block);

			var addr = leaderAddr;
			while (reachable.exists(addr)) {
				final instr = Decoder.decode(addr, image.readWord(addr));
				block.length++;
				final claimed = image.claim(addr, Kind.Code, fn.entry);
				if (claimed != 0 && claimed != fn.entry && !overlapReported.exists(claimed)) {
					// One warning per pair of functions, not one per shared word. Overlap is
					// expected — a second entry point into the middle of a function is normal —
					// and the policy is to keep both and duplicate the shared blocks.
					overlapReported.set(claimed, true);
					fn.warnings.push('overlaps ' + Vaddr.hex(claimed)
						+ ' from ${Vaddr.hex(addr)} — two entries into shared code');
				}

				if (instr.op.hasDelaySlot) {
					// The slot is part of this block, and the block ends after it.
					if (reachable.exists(addr + 4)) {
						block.length++;
						image.claim(addr + 4, Kind.Code, fn.entry);
					}
					block.exits = !instr.op.fallsThrough || instr.op == Op.JR;
					recordSuccessors(block, instr, addr + 8, leaders);
					break;
				}

				addr += 4;
				if (leaders.exists(addr)) {
					// Falls through into the next block.
					block.successors.push(addr);
					break;
				}
			}
		}

		fn.endAddr = maxEnd;
		return fn;
	}

	/** Records where control can go from a block ending in `instr`. */
	function recordSuccessors(block:Block, instr:Instr, afterSlot:Int, leaders:Map<Int, Bool>):Void {
		switch (instr.op) {
			case JR:
				if (instr.rs != 31 && tables.exists(instr.addr)) {
					for (t in tables.get(instr.addr).targets) {
						if (leaders.exists(t)) block.successors.push(t);
					}
					block.exits = block.successors.length == 0;
				} else {
					block.exits = true;
				}
			case J:
				if (leaders.exists(instr.target)) block.successors.push(instr.target);
				else block.exits = true;
			case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ:
				if (leaders.exists(instr.target)) block.successors.push(instr.target);
				if (leaders.exists(afterSlot)) block.successors.push(afterSlot);
			case JAL | JALR | BLTZAL | BGEZAL:
				if (leaders.exists(afterSlot)) block.successors.push(afterSlot);
			case _:
		}
	}

	/** Marks an address as a block leader and queues it for pass 1. */
	function follow(leaders:Map<Int, Bool>, queue:Array<Int>, target:Int):Void {
		if (!image.containsWord(target)) return;
		leaders.set(target, true);
		queue.push(target);
	}

	inline function isKnownEntry(addr:Int):Bool
		return seen.exists(Vaddr.canonRam(addr));

	/** The three BIOS entry points, at the very bottom of RAM. */
	static inline function isKernelVector(addr:Int):Bool
		return addr == 0xA0 || addr == 0xB0 || addr == 0xC0;

	// ---- gaps -------------------------------------------------------------------------------

	/** Zero words between functions are alignment filler, not missing code. */
	function markPadding():Void {
		for (run in image.unknownRuns(1)) {
			var a = run.addr;
			final end = run.addr + run.words * 4;
			while (a < end) {
				if (image.readWord(a) == 0) image.claim(a, Kind.Padding, 0);
				else break;
				a += 4;
			}
		}
	}

	/**
		Looks in unclaimed regions for something shaped like a function.

		The signature is the stack-frame setup every non-leaf function begins with: `addiu sp, sp,
		-N` with a negative immediate, optionally followed within a few instructions by `sw ra`.
		Leaf functions that touch no stack are missed, which is fine — they are only reachable by
		call, and if nothing calls them they are dead.

		Everything found here is a guess, recorded as such. The value is not that the guesses are
		right; it is that a gap which sweeps cleanly into functions is probably code the closure
		could not reach, while a gap that yields nothing is probably data.
	**/
	function sweepForPrologues():Void {
		for (run in image.unknownRuns(2)) {
			var a = run.addr;
			final end = run.addr + run.words * 4;

			// Leading zero words are the previous function's alignment fill, not the gap's code —
			// and they must not be mistaken for an entry's opening instructions.
			while (a + 8 <= end && image.readWord(a) == 0) a += 4;

			// The gap start is the one address here that is not a guess: if this gap holds code at
			// all, it starts at the start. Compilers schedule loads ahead of the stack adjustment,
			// so the prologue may sit a few instructions in — and the seed must be THIS address,
			// not the adjustment's. Seeding the adjustment emits a function that begins past its
			// own entry, which every caller through a pointer table then misses by a few bytes.
			// libcd's CD interrupt handler (lui, lw, then addiu sp) was lost to exactly this, and
			// with it every sector the bring-up game ever asked for.
			final lead = prologueIndex(a, end, 4);
			if (lead >= 0) {
				addSeed(a, defaultName(a), Confidence.Swept);
				// Resume past the adjustment, or the sliding scan below re-seeds it and produces
				// a second function starting inside the first.
				a += (lead + 2) * 4;
			}

			var atGapStart = lead < 0;
			while (a + 8 <= end) {
				// Alignment fill between two functions inside the same gap, exactly as at the gap's
				// own start. Stepping over it makes the address after it a boundary candidate.
				if (image.readWord(a) == 0 && !atGapStart) { a += 4; continue; }
				else {}

				// A wider window than the gap-start test uses. It can afford one: "the previous
				// function returned" is corroboration the frame-setup test never has, so the
				// prologue search is only there to tell code from the read-only data that also
				// tends to follow a function's last return. Eight instructions is past anything
				// GCC schedules ahead of a stack adjustment, and still far short of resembling data.
				if (afterReturn(a) && prologueIndex(a, end, 8) >= 0) {
					// Code that follows a return begins a function. That is not a heuristic in the
					// way the frame-setup test is: the previous function said it was done, and the
					// gap continues, so whatever is here is entered from somewhere else.
					//
					// It matters because it is the only test that tolerates a scheduled prologue.
					// GCC hoists loads above the stack adjustment, so a function can open with
					// `lui`/`lw` and reach `addiu sp` four instructions in — and a scan that insists
					// on the adjustment coming first cannot see such an entry anywhere except at a
					// gap's start. libcd is full of them, reached only through pointer tables.
					addSeed(a, defaultName(a), Confidence.Swept);
					a += 8;
				} else if (looksLikePrologue(a, end, atGapStart)) {
					addSeed(a, defaultName(a), Confidence.Swept);
					// Skip ahead: the trace will claim what belongs to it, and re-sweeping
					// inside a function we just queued would find its inner frames.
					a += 8;
				} else {
					a += 4;
				}
				atGapStart = false;
			}
		}
	}

	/**
		The index of an `addiu sp, sp, -N` within the first `k` instructions, every instruction
		before it being plain — no branch, no jump, nothing invalid, because that is not how a
		function opens. -1 when the window holds none.
	**/
	function prologueIndex(addr:Int, limit:Int, k:Int):Int {
		var i = 0;
		while (i < k && addr + (i + 1) * 4 <= limit) {
			final instr = Decoder.decode(addr + i * 4, image.readWord(addr + i * 4));
			if (instr.op == Op.ADDIU && instr.rt == 29 && instr.rs == 29 && instr.immS < 0
					&& (instr.immS & 7) == 0) return i;
			if (instr.op == Op.INVALID || instr.op.hasDelaySlot) return -1;
			i++;
		}
		return -1;
	}

	/**
		Does a function begin here?

		The signature is the frame setup every function with locals starts with: `addiu sp, sp, -N`
		with N a multiple of 8. On its own that is weak — the same instruction appears inside
		functions — so it needs corroboration, and there are two kinds.

		The strong one is position. A gap starts where the previous function's last claimed word
		ended, so a frame setup as the *first* instruction of a gap is a function boundary in the
		ordinary sense, and taking it is how the sweep recovers code that is only ever called
		through a pointer. In the interior of a gap the same instruction proves much less, so
		there it must be backed by a `sw ra, N(sp)` within a few instructions — the non-leaf
		prologue, which is unambiguous.
	**/
	/**
		Do the two instructions before `addr` end a function?

		`jr ra` plus its delay slot, which is how every MIPS function returns. Read two words back
		rather than one because the delay slot sits between the jump and here, and it can be any
		instruction at all — usually the stack being given back.

		This says nothing about whether a function *starts* at `addr`; it says the previous one
		stopped, which is the corroboration a scheduled prologue cannot supply for itself.
	**/
	function afterReturn(addr:Int):Bool {
		final at = addr - 8;
		if (!image.containsWord(at)) return false;
		else {}
		final jump = Decoder.decode(at, image.readWord(at));
		return jump.op == Op.JR && jump.rs == 31;
	}

	function looksLikePrologue(addr:Int, limit:Int, atGapStart:Bool):Bool {
		final first = Decoder.decode(addr, image.readWord(addr));
		if (first.op != Op.ADDIU || first.rt != 29 || first.rs != 29 || first.immS >= 0) return false;
		if ((first.immS & 7) != 0) return false;   // frames are 8-byte aligned

		if (atGapStart) return true;

		var a = addr + 4;
		var checked = 0;
		while (a < limit && checked < 6) {
			final i = Decoder.decode(a, image.readWord(a));
			if (i.op == Op.SW && i.rt == 31 && i.rs == 29) return true;
			if (i.op == Op.INVALID) return false;
			a += 4;
			checked++;
		}
		return false;
	}

	// ---- diagnostics -------------------------------------------------------------------------

	public static function defaultName(addr:Int):String
		return "f_" + StringTools.hex(Vaddr.canonRam(addr), 8).toLowerCase();

	function invalidInstructionMessage(fn:Func, at:Instr):String {
		return 'cannot decode ${Vaddr.hex(at.raw)} at ${Vaddr.hex(at.addr)}, while tracing '
			+ '${fn.name} (${Vaddr.hex(fn.entry)}):\n'
			+ contextAround(at.addr)
			+ '\n\nThis is almost always data being read as code. Either the function boundary is '
			+ 'wrong — remove or correct its hint in game.json — or a jump table sits here and '
			+ 'needs a jumpTableHint.';
	}

	function delaySlotBranchMessage(fn:Func, branch:Instr, slot:Instr):String {
		return 'a branch sits in the delay slot of another at ${Vaddr.hex(branch.addr)}, while '
			+ 'tracing ${fn.name}:\n'
			+ contextAround(branch.addr)
			+ '\n\nNo compiler emits this, so the region is data rather than code.';
	}

	/** The instructions around an address, for error messages. */
	function contextAround(addr:Int, radius:Int = 6):String {
		final instrs = [];
		var a = addr - radius * 4;
		if (a < image.baseAddr) a = image.baseAddr;
		var index = 0;
		var n = 0;
		while (a < addr + (radius + 1) * 4 && image.containsWord(a)) {
			if (a == addr) index = n;
			instrs.push(Decoder.decode(a, image.readWord(a)));
			a += 4;
			n++;
		}
		return Disasm.context(instrs, index, radius);
	}
}
