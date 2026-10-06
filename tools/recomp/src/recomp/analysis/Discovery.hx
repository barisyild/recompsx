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

	/** Addresses the executable calls whose bytes there are not code (addSeed): overlay windows. */
	public final notCode:Array<Int> = [];

	/** Switch tables recovered from computed jumps, keyed by the address of the `jr`. */
	public final tables:Map<Int, JumpTable> = [];

	/** Computed jumps that turned out to have a constant target, keyed by the `jr` address.
	    Mostly BIOS calls; see JumpKind.Constant. */
	public final constantJumps:Map<Int, {target:Int, fnNumber:Int}> = [];

	/**
		`jr $ra` sites where $ra holds an address the function set itself: jumps, not returns.
		Per function (keyed by entry, then by the `jr`), because the same `jr` reached from another
		entry — or through dead code after a call that never returns — can mean a real return.
		See `findRaJumps`.
	**/
	public final raJumps:Map<Int, Map<Int, Int>> = [];

	/** The address a `jr $ra` in `fn` jumps to, or null where it returns. */
	public function raJumpOf(fnEntry:Int, jrAddr:Int):Null<Int> {
		final m = raJumps.get(fnEntry);
		return m == null ? null : m.get(jrAddr);
	}

	final pending:Array<Seed> = [];
	final seen:Map<Int, Bool> = [];
	/** Every seed ever accepted. A pass that learns something new about a computed jump replays
	    all of them, which reproduces the same functions plus whatever the new knowledge reveals. */
	final allSeeds:Array<Seed> = [];

	/**
		The stretch of addresses this pass is responsible for, and how sure it is about them.

		A base pass owns the whole image and is strict: the bytes are a linked program, so an
		instruction that cannot exist means the analysis took a wrong turn, and stopping is better
		than emitting a program with a hole in it.

		An overlay pass owns only its window and is lenient. Two things change. It does not trace
		outside the window — the base is analysed once, by the base pass, and re-tracing it here
		would emit every base function a second time under an overlay's name. And inside the
		window it cannot be strict: overlay code sits directly against the artwork it was loaded
		with, no linker map says where one ends, so a wrong guess about a boundary is expected and
		must cost one dropped function rather than the whole build.
	**/
	public final scopeLo:Int;
	public final scopeHi:Int;
	public final lenient:Bool;

	public function new(image:Image, ?scopeLo:Int, ?scopeHi:Int, ?lenient:Bool = false) {
		this.image = image;
		this.scopeLo = scopeLo == null ? image.baseAddr : Vaddr.canonRam(scopeLo);
		this.scopeHi = scopeHi == null ? image.endAddr() : Vaddr.canonRam(scopeHi);
		this.lenient = lenient;
	}

	/** Whether an address is this pass's to discover. */
	public inline function inScope(addr:Int):Bool {
		final a = Vaddr.canonRam(addr);
		return a >= scopeLo && a < scopeHi;
	}

	/**
		A computed jump the config explains: `jumpTableHints` in game.json.

		Installed before the first closure, so the arms are traced as blocks of the function that
		jumps to them — exactly what a recovered switch becomes — and the matcher never looks at
		this `jr` again. The emitter's switch still keeps a dispatch-by-address default, so a
		target the hint left out reports itself at run time instead of running the wrong arm.

		A hint is a person asserting something, so it is checked hard: the address must hold a
		`jr` through a register other than `$ra`, and every target must be a word in this image.
		`tableBase` 0 with explicit `targets` is hand-written arithmetic with no table behind it.
	**/
	public function addTableHint(jrAddr:Int, tableBase:Int, count:Int, listed:Array<Int>):Void {
		final at = Vaddr.canonRam(jrAddr);
		if (!image.containsWord(at) || !inScope(at)) return;
		final jr = Decoder.decode(at, image.readWord(at));
		if (jr.op != Op.JR || jr.rs == 31) {
			throw new AnalysisError('jumpTableHint at ${Vaddr.hex(at)} names ${Disasm.text(jr)}, '
				+ 'not a jr through a register');
		}
		final targets = listed != null ? [for (t in listed) Vaddr.canonRam(t)]
			: [for (i in 0...count) Vaddr.canonRam(image.readWord(Vaddr.canonRam(tableBase) + i * 4))];
		for (t in targets) {
			if ((t & 3) != 0 || !image.containsWord(t)) {
				throw new AnalysisError('jumpTableHint at ${Vaddr.hex(at)}: target ${Vaddr.hex(t)} '
					+ 'is not a code address in ${image.name}');
			}
		}
		final base = listed != null ? 0 : Vaddr.canonRam(tableBase);
		tables.set(at, new JumpTable(at, base, jr.rs, TableConfidence.Hinted, targets));
	}

	public function addSeed(addr:Int, name:String, confidence:Confidence):Void {
		final a = Vaddr.canonRam(addr);
		if (seen.exists(a)) return;
		if (!image.containsWord(a)) {
			// Calls out of the image are normal: kernel vectors, and code in another overlay.
			return;
		}
		if (!inScope(a)) {
			// Someone else's to find. An overlay calling into the executable is the ordinary case,
			// and the emitter resolves it against the base pass's functions.
			return;
		}
		if ((a & 3) != 0) {
			throw new AnalysisError('function address ${Vaddr.hex(a)} is not word-aligned');
		}
		seen.set(a, true);
		// A call into the executable's own bytes that are not code from their first instruction:
		// an overlay window inside the image, whose code is loaded from the disc at run time — the
		// executable holds only the window's first contents there (Tekken 3 calls into 0x800d....
		// from a switch, and its image runs on to 0x80131000). Not traced; the call goes by address
		// at run time, where a miss names the address and what the disc put there, which is how an
		// overlay is found for game.json. A hint is a person's assertion and stays a hard error
		// (traceFunction); a lenient pass reads its seeds in its own way. A window not loaded yet is
		// zeros, which decode as `nop`: eight of them at an entry is no function either (Tekken 3's
		// 0x800b0cec.. holds 32 KB of them).
		if (confidence == Confidence.Called && !lenient && (!plausibleEntry(a) || zeroWords(a, 8))) {
			notCode.push(a);
			warnings.push('${Vaddr.hex(a)} is called but is not code in the executable — an overlay '
				+ 'window? Called by address at run time.');
			return;
		}
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
		settleJumps(recoverTables);

		if (sweepGaps) {
			sweepForPrologues();
			closure();
			// The sweep reaches code the closure could not, and that code contains computed jumps
			// of its own — so the jump analysis has to run again over what it found. Skipping this
			// leaves BIOS calls in swept functions looking like unresolved dispatch.
			settleJumps(recoverTables);
		}

		markCheckedReturns();
		if (cutShared) {
			cutAtEntries();
			// Again, over the functions as they now are: a hand-over's own check (checkedHops).
			markCheckedReturns();
		} else {}
		claimTables();
		markPadding();
	}

	/**
		Whether functions hand over at other functions' entries instead of carrying their code
		(`cutAtEntries`): `--cut-shared`. Off by default: exact, and smaller (Crash 3's image
		-376 KB, Crash Bash's -194 KB), but slower where the copies ran — each copy carried only the
		paths its own entry takes, so the hot code was hardly smaller, and the hand-overs' calls and
		entries cost instruction fills (docs/perf/dreamcast-ledger.md E-077).
	**/
	public var cutShared = false;
	/**
		The entries a function may hand over to: the emitted code calls the one handed to by its
		class, so not an address whose occupant is decided at run time — the executable's own code
		inside an overlay window (Main.analyseBase).
	**/
	public var cutTarget:Int -> Bool = _ -> true;

	/**
		One copy of code that several functions reach by branches.

		The multi-entry policy keeps every entry and gives each function every block it can reach,
		so code that several entries run into is emitted once per entry. Compiled code rarely does
		that; hand-written code does it on purpose: Crash Bandicoot: Warped's renderer hops between
		routines through `jr`, and each routine branches back into a shared loop — five functions
		carried their own copy of it, and the game's emitted guest code was 1.54 times its own. Here
		every function is traced again, stopping where it reaches another function's entry by a
		branch, by running into it or as a call's continuation, and handing over to that function
		there (`Func.hops`): a direct tail call in the emitted code, entered past its pump and
		checkpoint, so time is charged and events are taken where the inline copy took them.

		It is kept only where that is the same program. A hand-over is a host call, so functions on
		a cycle of hand-overs and tail calls keep their copies (a loop between two entries would
		otherwise recurse). So does a function whose own `$ra` analysis reached into code it would
		now hand over: a `jr $ra` there jumped to an address the function had built (`raJumps`).
	**/
	function cutAtEntries():Void {
		final cut:Map<Int, Bool> = [];
		for (k in functions.keys()) if (cutTarget(Vaddr.canonRam(k))) cut.set(Vaddr.canonRam(k), true); else {}
		final entries = [for (k in functions.keys()) k];
		entries.sort((a, b) -> (a ^ 0x80000000) < (b ^ 0x80000000) ? -1 : ((a ^ 0x80000000) > (b ^ 0x80000000) ? 1 : 0));
		final calls = indirectCalls.length;
		final traced:Map<Int, Func> = [];
		for (e in entries) {
			final old = functions.get(e);
			final fn = traceFunction({addr: old.entry, name: old.name, confidence: old.confidence}, cut);
			if (!fn.abandoned && fn.hops.keys().hasNext() && sameReturns(old, fn)) traced.set(e, fn);
			else {}
		}
		// The second tracing must not count each indirect call twice in the coverage report.
		indirectCalls.resize(calls);
		final cycle = handOverCycles(traced);
		for (e in cycle.keys()) traced.remove(e);
		// Where the generated code takes events must not move: keep only the hand-overs whose code
		// pumps where the copy did, until that holds for every one kept (keeping a copy can only
		// change the functions that hand over to it).
		var changed = true;
		while (changed) {
			changed = false;
			for (e in entries) {
				final fn = traced.get(e);
				if (fn == null || samePumps(functions.get(e), fn, traced)) continue;
				else {}
				traced.remove(e);
				changed = true;
			}
		}
		for (e => fn in traced) {
			final old = functions.get(e);
			final pumped = pumpPoints(old);
			// Entering a function past its pump, unless the copy pumped at that entry's block — and
			// that block does not pump of its own (a loop's head), which would be a second time.
			for (h in fn.hops.keys()) {
				final target = traced.exists(h) ? traced.get(h) : functions.get(h);
				if (pumped.exists(h) && !pumpPoints(target).exists(h)) fn.pumpedHops.set(h, true);
				else {}
			}
		}
		for (e => fn in traced) functions.set(e, fn);
	}

	/**
		Where generated code pumps (FunctionIR): every block an edge reaches from a block at the
		same address or above, by canonical address.
	**/
	static function pumpPoints(fn:Func):Map<Int, Bool> {
		final out:Map<Int, Bool> = [];
		for (b in fn.blocks) for (to in b.successors) if (to <= b.addr) out.set(Vaddr.canonRam(to), true); else {}
		return out;
	}

	/**
		Whether `whole`'s code pumps where it did once `cutFn` and the functions it reaches by
		hand-overs run it (each in the form it will have: `traced`, or as it is): every pump point
		any of them has on that code is one of `whole`'s, and every one of `whole`'s is a pump
		point of each of them whose code holds it — or the entry of a function handed over to, which
		pumps on the way in exactly when the copy that hands over pumped there (`Func.pumpedHops`;
		each hand-over on the way must agree with `whole`). A block of the copy pumps for every edge
		to it, so one an edge from code that stays behind made a pump point cannot be handed over:
		then the copy is kept.
	**/
	function samePumps(whole:Func, cutFn:Func, traced:Map<Int, Func>):Bool {
		final before = pumpPoints(whole);
		final runners:Array<Func> = [cutFn];
		final seen:Map<Int, Bool> = [Vaddr.canonRam(cutFn.entry) => true];
		var i = 0;
		while (i < runners.length) {
			final from = runners[i++];
			// The function handing over pumps on the way in where its own copy pumped.
			final fromCopy = pumpPoints(functions.get(Vaddr.canonRam(from.entry)) != null
				? functions.get(Vaddr.canonRam(from.entry)) : from);
			for (h in from.hops.keys()) {
				if (fromCopy.exists(h) != before.exists(h)) return false;
				else {}
				if (seen.exists(h)) continue;
				else {}
				seen.set(h, true);
				final next = traced.exists(h) ? traced.get(h) : functions.get(h);
				if (next == null) return false;
				else {}
				runners.push(next);
			}
		}
		for (r in runners) {
			final theirs = pumpPoints(r);
			for (p in theirs.keys()) if (covers(whole, p) && !before.exists(p)) return false;
			for (p in before.keys()) {
				if (!covers(r, p) || theirs.exists(p) || p == Vaddr.canonRam(r.entry)) continue;
				else {}
				return false;
			}
		}
		return true;
	}

	/**
		Whether `cutFn` (traced with hand-overs) returns as `whole` (traced with the code) does: no
		`jr $ra` that jumps to an address `whole` built (`raJumps`), and no `jr` through the copy of
		`$ra` its entry block made (`registerReturns`), is left in the code handed over.
		Return checks need nothing here: a hand-over passes the entry's `$ra` on (Runtime.hopRa),
		so the function handed to checks against the value the inline code checked against, and
		where `$ra` may be foreign at the hand-over the caller checks its return (`checkedHops`).
	**/
	function sameReturns(whole:Func, cutFn:Func):Bool {
		final built = raJumps.get(whole.entry);
		if (built != null) for (at in built.keys()) if (!covers(cutFn, at)) return false;
		// A `jr` through the copy of `$ra` the entry block made is a return only in the function
		// whose entry made it (findRegisterReturns).
		for (at in whole.registerReturns.keys()) if (!covers(cutFn, at)) return false;
		return true;
	}

	static function covers(fn:Func, at:Int):Bool {
		for (b in fn.blocks) if ((at ^ 0x80000000) >= (b.addr ^ 0x80000000) && (at ^ 0x80000000) < (b.endAddr() ^ 0x80000000)) return true;
		return false;
	}

	/**
		Entries on a cycle of hand-overs and direct tail calls (Tarjan's strongly connected
		components), which keep their copies: each such transfer is a host call.
	**/
	function handOverCycles(traced:Map<Int, Func>):Map<Int, Bool> {
		final edges:Map<Int, Array<Int>> = [];
		for (e => fn in functions) {
			final f = traced.exists(e) ? traced.get(e) : fn;
			final out = [for (t in f.hops.keys()) t];
			for (c in f.tailCalls) if (c.target != 0) out.push(Vaddr.canonRam(c.target)); else {}
			edges.set(Vaddr.canonRam(e), out);
		}
		final index:Map<Int, Int> = [];
		final low:Map<Int, Int> = [];
		final onStack:Map<Int, Bool> = [];
		final stack:Array<Int> = [];
		final result:Map<Int, Bool> = [];
		var next = 0;
		function connect(v:Int):Void {
			index.set(v, next); low.set(v, next); next++;
			stack.push(v); onStack.set(v, true);
			for (w in edges.get(v)) {
				if (!edges.exists(w)) continue;
				else {}
				if (!index.exists(w)) {
					connect(w);
					if (low.get(w) < low.get(v)) low.set(v, low.get(w)); else {}
				} else if (onStack.exists(w) && index.get(w) < low.get(v)) low.set(v, index.get(w));
				else {}
			}
			if (low.get(v) == index.get(v)) {
				final members = [];
				while (true) {
					final w = stack.pop();
					onStack.remove(w);
					members.push(w);
					if (w == v) break;
					else {}
				}
				if (members.length > 1 || edges.get(v).indexOf(v) >= 0) for (m in members) result.set(m, true);
				else {}
			} else {}
		}
		final keys = [for (k in edges.keys()) k];
		keys.sort((a, b) -> (a ^ 0x80000000) < (b ^ 0x80000000) ? -1 : ((a ^ 0x80000000) > (b ^ 0x80000000) ? 1 : 0));
		for (k in keys) if (!index.exists(k)) connect(k); else {}
		// `traced` and `functions` share keys as found; a cycle names canonical entries.
		final out:Map<Int, Bool> = [];
		for (e in traced.keys()) if (result.exists(Vaddr.canonRam(e))) out.set(e, true); else {}
		return out;
	}

	/**
		Explains computed jumps until nothing new is learned.

		Each round can only improve on the last: a recovered table opens code that may contain
		more computed jumps, and a jump recognised as a BIOS call removes a false dead end. The
		round count is capped because the loop is driven by a heuristic and a pathological image
		should not be able to spin it.
	**/
	function settleJumps(recoverTables:Bool):Void {
		var rounds = 0;
		while (rounds < 4 && (recoverTables ? findTables() : 0) + findRaJumps() > 0) {
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
			// A function the tracer gave up on is not a function. Keeping it would emit a body
			// built out of whatever the data happened to decode to, which runs, and does something.
			if (fn.abandoned) rejected++;
			else functions.set(fn.entry, fn);
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
		`jr $ra` that is not a return.

		`jr $ra` returns because $ra holds the caller's address — unless the function put something
		else there. Hand-written code does: Crash Bandicoot: Warped's run-merge routine saves every
		register to the scratchpad, loads $ra with its own loop head, and ends each unrolled copy
		with `jr $ra` back into the loop; only the final `jr $ra`, after reloading $ra, returns.
		Taken as returns, the first copy left the routine mid-loop with $sp and $gp holding data.

		So $ra is followed through each function: the value it enters with (a return), a constant
		the function builds explicitly (`lui`/`addiu`/`ori`), or unknown. A load
		(`lw $ra`) is the epilogue restoring what the prologue saved, and counts as the entry value.
		Where every path reaches a `jr $ra` with one constant, that `jr` jumps there. Unknown keeps
		the old reading — a return — so nothing that worked before can change.
	**/
	function findRaJumps():Int {
		var found = 0;
		for (fn in functions) {
			final kind:Map<Int, Int> = [fn.entry => RA_ENTRY];
			final value:Map<Int, Int> = [fn.entry => 0];
			final work = [fn.entry];
			var guard = 0;
			while (work.length > 0 && guard++ < 100000) {
				final a = work.pop();
				final b = fn.blocks.get(a);
				if (b == null) continue;
				else {}
				var k = kind.get(a);
				var v = value.get(a);
				for (i in 0...b.length) {
					final at = a + i * 4;
					final ins = Decoder.decode(at, image.readWord(at));
					if (ins.op == Op.JR && ins.rs == 31 && k == RA_CONST && raJumpOf(fn.entry, at) == null
							&& image.containsWord(Vaddr.canonRam(v))) {
						if (!raJumps.exists(fn.entry)) raJumps.set(fn.entry, []);
						else {}
						raJumps.get(fn.entry).set(at, Vaddr.canonRam(v));
						found++;
					} else {}
					// The effect on $ra, in the same order the machine applies it.
					if (ins.op == Op.LUI && ins.rt == 31) { k = RA_CONST; v = ins.immU << 16; }
					else if ((ins.op == Op.ADDIU || ins.op == Op.ADDI) && ins.rt == 31) {
						if (ins.rs == 0) { k = RA_CONST; v = ins.immS; }
						else if (ins.rs == 31 && k == RA_CONST) v = (v + ins.immS) | 0;
						else k = RA_TOP;
					}
					else if (ins.op == Op.ORI && ins.rt == 31) {
						if (ins.rs == 0) { k = RA_CONST; v = ins.immU; }
						else if (ins.rs == 31 && k == RA_CONST) v = v | ins.immU;
						else k = RA_TOP;
					}
					else if (ins.op == Op.LW && ins.rt == 31) { k = RA_ENTRY; v = 0; }
					// A call's link is deliberately unknown, not a constant: a `jr $ra` after a
					// call with no restore is either a bug or dead code after a call that never
					// returns, and the old reading (a return) is the safe one for both.
					else if (new recomp.ir.FunctionIR.InstructionIR(ins).writes.has(31)
							|| ins.op == Op.JAL || ins.op == Op.BLTZAL || ins.op == Op.BGEZAL
							|| (ins.op == Op.JALR && ins.rd == 31)) k = RA_TOP;
					else {}
				}
				for (succ in b.successors) {
					if (!kind.exists(succ)) {
						kind.set(succ, k); value.set(succ, v); work.push(succ);
					} else {
						final ok = kind.get(succ);
						final merged = ok == k && (k != RA_CONST || value.get(succ) == v) ? ok : RA_TOP;
						if (merged != ok) { kind.set(succ, merged); work.push(succ); }
						else {}
					}
				}
			}
		}
		return found;
	}

	static inline final RA_ENTRY = 0;
	static inline final RA_CONST = 1;
	static inline final RA_TOP = 2;

	/**
		Returns whose `$ra` may not be the address the function was called with (ADR-0027).

		`jr $ra` is emitted as a return — back to the host caller, which is where the address the
		function was called with points. That is the same thing only while `$ra` still holds that
		address. A load puts back whatever the memory holds: the prologue's own save, normally, but
		hand-written code also loads a return address another function saved. Crash Bandicoot:
		Warped's bounding-box test (0x8003def4) saves its `$ra` in the scratchpad and calls a
		helper per corner; the helper, on finding a corner on screen, loads that saved address and
		jumps to it — out of both functions at once, with "visible" in $t8. As a return it went
		back into the test, which tried the next corner and ended "not visible" every time: every
		object that uses the test was culled.

		So `$ra` is followed once more, telling a restore of the function's own stack slot
		(`lw $ra, N($sp)` where it also has `sw $ra, N($sp)`) apart from any other load. A return
		that such a load can reach is checked at run time against the address the function was
		entered with. Other writes of `$ra` keep the old reading (`findRaJumps`).
	**/
	function markCheckedReturns():Void {
		for (fn in functions) {
			fn.checkedReturns.clear();
			fn.checkedHops.clear();
			final ownSlots:Map<Int, Bool> = [];
			for (b in fn.blocks) {
				for (i in 0...b.length) {
					final at = b.addr + i * 4;
					final ins = Decoder.decode(at, image.readWord(at));
					if (ins.op == Op.SW && ins.rt == 31 && ins.rs == 29) ownSlots.set(ins.immS, true);
					else {}
				}
			}
			// Per block: whether $ra may hold something a load other than the own restore put there.
			final foreign:Map<Int, Bool> = [fn.entry => false];
			final work = [fn.entry];
			var guard = 0;
			while (work.length > 0 && guard++ < 100000) {
				final a = work.pop();
				final b = fn.blocks.get(a);
				if (b == null) continue;
				else {}
				var f = foreign.get(a);
				for (i in 0...b.length) {
					final at = a + i * 4;
					final ins = Decoder.decode(at, image.readWord(at));
					if (f && (ins.op == Op.JR || ins.op == Op.JALR) && ins.isRegisterJump && ins.rs == 31
							&& raJumpOf(fn.entry, at) == null) {
						fn.checkedReturns.set(at, true);
					} else {}
					if (ins.op == Op.LW && ins.rt == 31) f = !(ins.rs == 29 && ownSlots.exists(ins.immS));
					else if (new recomp.ir.FunctionIR.InstructionIR(ins).writes.has(31)
							|| ins.op == Op.JAL || ins.op == Op.BLTZAL || ins.op == Op.BGEZAL
							|| (ins.op == Op.JALR && ins.rd == 31)) f = false;
					else {}
				}
				// A hand-over where `$ra` may be foreign: the callee's return goes where `$ra` points,
				// as this function's own `jr $ra` would have gone from the code it carried.
				if (f && b.exits && fn.hops.keys().hasNext()) fn.checkedHops.set(a, true);
				else {}
				for (succ in b.successors) {
					final known = foreign.get(succ);
					if (known == null || (f && !known)) {
						foreign.set(succ, f || known == true);
						work.push(succ);
					} else {}
				}
			}
		}
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
			// A hint with explicit targets has no table in memory to claim.
			if (t.base != 0) image.claimRange(t.base, t.base + t.sizeBytes(), Kind.DataInText, 0);
			else {}
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
	function traceFunction(seed:Seed, ?cut:Map<Int, Bool>):Func {
		final fn = new Func(seed.addr, seed.name, seed.confidence);
		// With `cut` (cutAtEntries): another function's entry reached by a branch, by running into
		// it or as a call's continuation is handed over to (`fn.hops`), not traced into.
		inline function hopsTo(target:Int):Bool {
			final t = Vaddr.canonRam(target);
			return cut != null && t != Vaddr.canonRam(fn.entry) && cut.exists(t) && image.containsWord(target);
		}
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
				if (instr.op == Op.INVALID) {
					if (!strict()) return abandon(fn, instr.addr, "does not decode");
					throw new AnalysisError(invalidInstructionMessage(fn, instr));
				}

				reachable.set(addr, true);
				if (addr + 4 > maxEnd) maxEnd = addr + 4;

				if (!instr.op.hasDelaySlot) {
					addr += 4;
					if (hopsTo(addr)) {
						fn.hops.set(Vaddr.canonRam(addr), true);
						break;
					} else {}
					continue;
				}

				// The delay slot belongs to this transfer and executes before it takes effect.
				final slotAddr = addr + 4;
				if (image.containsWord(slotAddr)) {
					final slot = Decoder.decode(slotAddr, image.readWord(slotAddr));
					if (slot.op.hasDelaySlot) {
						if (!strict()) {
							return abandon(fn, slot.addr, "is a branch in another branch's delay slot");
						}
						throw new AnalysisError(delaySlotBranchMessage(fn, instr, slot));
					}
					if (slot.op == Op.INVALID) {
						if (!strict()) return abandon(fn, slot.addr, "does not decode");
						throw new AnalysisError(invalidInstructionMessage(fn, slot));
					}
					reachable.set(slotAddr, true);
					if (slotAddr + 4 > maxEnd) maxEnd = slotAddr + 4;
				}
				final afterSlot = slotAddr + 4;

				running = false;
				switch (instr.op) {
					case JR | JALR if (instr.isRegisterJump):
						if (instr.rs == 31 && raJumpOf(fn.entry, instr.addr) != null) {
							// $ra holds an address this function set: a jump (findRaJumps).
							final t:Int = raJumpOf(fn.entry, instr.addr);
							if (inScope(t)) follow(leaders, queue, t);
							else {
								fn.tailCalls.push(new CallSite(instr.addr, t, false));
								addSeed(t, defaultName(t), Confidence.Called);
							}
						} else if (instr.rs == 31) {
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

					case JALR if (instr.rs == 31):
						// A jump through $ra returns, whatever it links. Code handing its caller a
						// continuation does exactly this — `jalr $s5, $ra` leaves with the address
						// after it in $s5 (Crash Bandicoot: Warped's native GOOL code). Treated as a
						// call, the words after it — the next bytecode — were traced as code.

					case JALR:
						fn.calls.push(new CallSite(instr.addr, 0, true));
						if (cut == null) indirectCalls.push(new CallSite(instr.addr, 0, true));
						else {}
						// A call's continuation is never handed over to: it must be a block here, where a
						// cooperative slice suspended in the callee resumes this function.
						follow(leaders, queue, afterSlot);

					case JAL:
						fn.calls.push(new CallSite(instr.addr, instr.target, false));
						addSeed(instr.target, defaultName(instr.target), Confidence.Called);
						// A call's continuation is never handed over to: it must be a block here, where a
						// cooperative slice suspended in the callee resumes this function.
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
						if (hopsTo(instr.target)) fn.hops.set(Vaddr.canonRam(instr.target), true);
						else follow(leaders, queue, instr.target);   // taken
						if (hopsTo(afterSlot)) fn.hops.set(Vaddr.canonRam(afterSlot), true);
						else follow(leaders, queue, afterSlot);      // not taken

					case BLTZAL | BGEZAL:
						// A conditional call: the link register is written whether or not the
						// branch is taken, which the emitter has to reproduce. For control flow
						// it behaves like a branch that falls through.
						fn.calls.push(new CallSite(instr.addr, instr.target, false));
						addSeed(instr.target, defaultName(instr.target), Confidence.Called);
						// A call's continuation is never handed over to: it must be a block here, where a
						// cooperative slice suspended in the callee resumes this function.
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
					block.exits = !instr.op.fallsThrough || instr.isRegisterJump;
					recordSuccessors(fn.entry, block, instr, addr + 8, leaders);
					// A hand-over leaves the function, like a tail call (a branch's arms only).
					if (fn.hops.exists(Vaddr.canonRam(addr + 8)) && instr.op != Op.J && instr.op.fallsThrough
							&& instr.op != Op.JAL && instr.op != Op.JALR && instr.op != Op.BLTZAL
							&& instr.op != Op.BGEZAL) block.exits = true;
					else {}
					if (instr.op != Op.J && !instr.isRegisterJump && fn.hops.exists(Vaddr.canonRam(instr.target))
							&& instr.op != Op.JAL && instr.op != Op.BLTZAL && instr.op != Op.BGEZAL) block.exits = true;
					else {}
					break;
				}

				addr += 4;
				if (leaders.exists(addr)) {
					// Falls through into the next block.
					block.successors.push(addr);
					break;
				}
				if (!reachable.exists(addr) && fn.hops.exists(Vaddr.canonRam(addr))) {
					// Runs into another function's entry: handed over there.
					block.exits = true;
					break;
				}
			}
		}

		fn.endAddr = maxEnd;
		findRegisterReturns(fn);
		return fn;
	}

	/**
		Returns through a register other than `$ra`.

		A routine that calls something itself must put its return address somewhere a `jal` will
		not overwrite. Compilers use the stack; hand-written code often uses a scratch register —
		`addu $at, $ra, $zero` on entry, `jr $at` on the way out (Crash Bandicoot: Warped's GOOL
		operand helpers). Left as a computed jump, that `jr` dispatched to the caller's return
		address as a fresh entry into the caller, which then ran on inside a nested call while the
		original invocation resumed later with state the nested one had already unwound.

		The rule is deliberately narrow, so that it can only ever describe a return: the copy is
		made in the entry block before any call and before anything writes `$ra`, and no other
		instruction anywhere in the function writes that register. Then every `jr` through it
		jumps to the address the function was called from — which is what `jr $ra` does, and is
		emitted the same way. A callee that clobbered the register would break the original on
		hardware too.
	**/
	function findRegisterReturns(fn:Func):Void {
		if (fn.unresolvedJumps.length == 0) return;
		final entry = fn.blocks.get(fn.entry);
		if (entry == null) return;
		final copies:Array<Int> = [];
		for (i in 0...entry.length) {
			final a = fn.entry + i * 4;
			final instr = Decoder.decode(a, image.readWord(a));
			final ir = new recomp.ir.FunctionIR.InstructionIR(instr);
			if (ir.writes.has(31) || instr.op.hasDelaySlot) break;
			if ((instr.op == Op.ADDU || instr.op == Op.OR) && instr.rd != 0 && instr.rd != 31
					&& ((instr.rs == 31 && instr.rt == 0) || (instr.rs == 0 && instr.rt == 31)))
				copies.push(instr.rd);
			else {}
		}
		if (copies.length == 0) return;
		for (reg in copies) {
			var writers = 0;
			for (b in fn.blocks) {
				for (i in 0...b.length) {
					final a = b.addr + i * 4;
					if (new recomp.ir.FunctionIR.InstructionIR(Decoder.decode(a, image.readWord(a))).writes.has(reg))
						writers++;
					else {}
				}
			}
			if (writers != 1) continue;
			for (jr in fn.unresolvedJumps.copy()) {
				final instr = Decoder.decode(jr, image.readWord(jr));
				if (instr.op == Op.JR && instr.rs == reg) {
					fn.unresolvedJumps.remove(jr);
					fn.registerReturns.set(jr, true);
				} else {}
			}
		}
	}

	/** Records where control can go from a block ending in `instr`. */
	function recordSuccessors(fnEntry:Int, block:Block, instr:Instr, afterSlot:Int,
			leaders:Map<Int, Bool>):Void {
		switch (instr.op) {
			case JR | JALR if (instr.isRegisterJump && instr.rs == 31 && raJumpOf(fnEntry, instr.addr) != null):
				final t:Int = raJumpOf(fnEntry, instr.addr);
				if (leaders.exists(t)) block.successors.push(t);
				else {}
				block.exits = block.successors.length == 0;
			case JR | JALR if (instr.isRegisterJump):
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
			case JALR if (instr.rs == 31):
				block.exits = true;   // a return that links; see traceFunction
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
			// Only this pass's stretch. An overlay pass sweeping the executable would rediscover
			// the whole base program under overlay names; a base pass sweeping an overlay window
			// would find functions in bytes that are not resident while it runs.
			var a = run.addr < scopeLo ? scopeLo : run.addr;
			var end = run.addr + run.words * 4;
			if (end > scopeHi) end = scopeHi;
			if (a + 8 > end) continue;

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
		Could a function begin here at all?

		For seeds that are guesses. A hint in `game.json` is a person asserting something and is
		worth a hard error when it is wrong. A seed recovered from a runtime miss is not: a game
		reaches those by jumping through pointers, and a pointer sometimes holds rubbish — feeding
		that back would have the tool trace artwork until two branches share a delay slot, and
		refuse to build a program because of one wild jump the game itself never took twice.

		So a lenient pass reads a seed before it believes it. Anything that cannot decode, and
		anything with a branch in a delay slot, is not code: no compiler emits either, which is the
		same test the tracer applies — just applied early, and answered with "no" instead of a stop.

		The reading stops where the function does. After a jump that does not come back — `jr`,
		or `j` — and its delay slot, the next word belongs to whatever the linker put there, and in
		an overlay window that is as likely to be a table as another function. Reading on used to
		reject short functions for their neighbours: Crash Bash's third mini-game registers its
		callbacks in a 26-instruction initialiser followed by data, the hint was refused, and the
		game's call to it was skipped at run time, leaving the previous game's callbacks in place.
	**/
	public function plausibleEntry(addr:Int):Bool {
		if (!image.containsWord(addr)) return false;
		var previousHadSlot = false;
		var leaving = false;
		for (i in 0...32) {
			final a = addr + i * 4;
			if (!image.containsWord(a)) return i > 0;
			final instr = Decoder.decode(a, image.readWord(a));
			if (instr.op == Op.INVALID) return false;
			if (previousHadSlot && instr.op.hasDelaySlot) return false;
			// This is the delay slot of a jump that leaves: it decoded, so the function is whole.
			if (leaving) return true;
			previousHadSlot = instr.op.hasDelaySlot;
			// A jump through $ra leaves too, whatever it links (see traceFunction).
			leaving = instr.op == Op.JR || instr.op == Op.J || (instr.op == Op.JALR && instr.rs == 31);
		}
		return true;
	}

	/** Whether the `n` words from `addr` are all in the image and all zero. */
	function zeroWords(addr:Int, n:Int):Bool {
		for (i in 0...n) {
			final w = addr + i * 4;
			if (!image.containsWord(w) || image.readWord(w) != 0) return false;
			else {}
		}
		return true;
	}

	/**
		Whether being wrong here is the tool's fault.

		In the executable it is: every function is reached by something, and an impossible
		instruction means a wrong turn worth stopping for. In an overlay window it is not — those
		bytes are code and assets side by side, and the boundary between them is exactly what
		nothing has told us.
	**/
	inline function strict():Bool {
		return !lenient;
	}

	/** Gives up on one function, recording why, and keeps the rest of the program. */
	function abandon(fn:Func, at:Int, why:String):Func {
		fn.abandoned = true;
		fn.warnings.push('abandoned at ${Vaddr.hex(at)}: it ${why}, so this is data');
		return fn;
	}

	/** Functions dropped because a window turned out to hold data there. */
	public var rejected(default, null) = 0;

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
