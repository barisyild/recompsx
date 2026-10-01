package recomp.codegen;

import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.mips.Op;
import recomp.loader.PsxExe;
import recomp.codegen.Shards;
import recomp.codegen.Shards.Shard;
import recomp.codegen.Universe;
import recomp.codegen.Relocatable.RelocSet;
import recomp.codegen.Relocatable.RelocFunc;
import sys.FileSystem;
import sys.io.File;

/** One universe's dispatch rows: sorted addresses, and what each resolves to. */
typedef Rows = {addrs:Array<Int>, handle:Map<Int, Int>, block:Map<Int, Int>};

/**
	Writes a whole recompiled program: one file per shard, plus the dispatch table and the
	program's own facts.

	Everything emitted here is machine-written and is never edited by hand — a defect in the
	output is a defect in this tool, and the fix is to regenerate. The output is also
	deterministic: the same executable and the same tool version produce byte-identical files, so
	`git diff` on generated code shows what actually changed rather than what happened to move.
**/
class Program {
	final exe:PsxExe;

	/** Universe 0 is the executable; the rest are overlays, in config order. */
	final universes:Array<Universe>;

	/** Relocatable code (ADR-0025), after every universe in shard numbering. */
	final relocSets:Array<RelocSet>;

	/** Function bodies already emitted, keyed by their text, mapped to the class holding them. */
	final emitted:Map<String, String> = [];

	public var filesWritten(default, null) = 0;
	public var linesWritten(default, null) = 0;

	/** Function bodies a second universe did not need to emit because the first had them. */
	public var deduplicated(default, null) = 0;

	public function new(universes:Array<Universe>, exe:PsxExe, limit:Int = 0, optimize:Bool = true,
			structureRegions:Bool = true, ?relocSets:Array<RelocSet>) {
		this.universes = universes;
		this.exe = exe;
		this.relocSets = relocSets == null ? [] : relocSets;

		// Shard indices are program-wide: the base takes the first block and each overlay
		// continues from where the last stopped, so a handle names one shard in the whole program.
		var nextIndex = 0;
		for (u in universes) {
			u.shards = new Shards(u.discovery, limit, nextIndex, u.classPrefix());
			nextIndex += u.shards.shards.length;
		}
		for (r in this.relocSets) {
			r.shards = Shards.ofList([for (f in r.functions) f.func], nextIndex,
				"Rel_" + Universe.sanitizeId(r.config.id));
			nextIndex += r.shards.length;
			// Handles by position: the functions were cut into shards in list order.
			var at = 0;
			for (sh in r.shards) {
				for (slot in 0...sh.functions.length) r.functions[at++].handle = (sh.index << 20) | slot;
			}
		}
		if (nextIndex > MAX_SHARDS) {
			throw new recomp.analysis.AnalysisError('this program needs $nextIndex shards; a '
				+ 'handle has room for $MAX_SHARDS (ADR-0002: the top eleven bits of an Int)');
		}

		for (u in universes) {
			u.emitter = new Emitter(u.image, u.discovery, optimize, structureRegions);
			u.emitter.staticTargetOf = a -> staticTargetFor(u, a);
			u.emitter.writesOf = a -> writesFor(u, a);
			u.emitter.dynamicCall = "FnTable.run";
		}
		for (r in this.relocSets) {
			for (unit in r.units) {
				unit.emitter = new Emitter(unit.image, unit.discovery, optimize, structureRegions);
				unit.emitter.relocatable = true;
				unit.emitter.dynamicCall = "FnTable.run";
				unit.emitter.staticTargetOf = a -> staticTargetFor(universes[0], a);
				unit.emitter.writesOf = a -> writesFor(universes[0], a);
			}
		}
		checkFingerprintsDistinct();
	}

	/** A handle packs the shard index into the bits above the slot; this is what fits. */
	static inline var MAX_SHARDS = 2047;

	/**
		Where a call from `from` to `addr` should go, or null to dispatch it by address.

		Three answers, and the middle one is the whole overlay design:

		- Inside the calling universe's own scope, if it found a function there: a direct call.
		  An overlay calling into itself is safe because the caller running proves the callee is
		  resident — they arrived on the disc together.
		- Inside *some other* universe's window: by address. From the executable, nothing knows
		  which overlay is loaded; from one overlay into another's window, the same. That is not a
		  limitation to work around, it is what the hardware does, and the runtime's table is where
		  the answer lives.
		- In the executable, outside every window: a direct call. The base is always resident.
	**/
	function staticTargetFor(from:Universe, addr:Int):String {
		final a = Vaddr.canonRam(addr);
		// An overlay's own functions first: the caller running proves they are resident. This
		// must not apply to the executable — the executable can have functions *inside* a window
		// (windows overlap its tail), and those are exactly the ones whose bytes may be gone.
		if (!from.isBase() && from.shards.has(a)) return from.shards.classOf(a);
		if (inSomeWindow(a)) return null;
		final base = universes[0];
		return base.shards.has(a) ? base.shards.classOf(a) : null;
	}

	/** The universe whose function a direct call from `from` to `a` runs (staticTargetFor's rule),
	    or null for a call by address. */
	function calleeUniverse(from:Universe, a:Int):Null<Universe> {
		if (!from.isBase() && from.shards.has(a)) return from;
		if (inSomeWindow(a)) return null;
		return universes[0].shards.has(a) ? universes[0] : null;
	}

	/**
		What a direct call from `from` to `addr` may write: a register mask, bit n for $n, of every
		register the function or anything it calls directly may write — Emitter.ALL_REGS for a call
		by address, and for a function that makes one itself, traps (syscall, break, an
		instruction that can raise an overflow), jumps somewhere it cannot follow (a register jump
		other than a return, a jump table's default, a BIOS vector) or carries a mod's hook, since
		the hook may change anything. What an interrupt taken inside does is not counted: the
		kernel gives the interrupted registers back as it found them (ADR-0029's premise for a
		leaf's locals). Computed once, for every universe together, on the first question.

		Used by the function spans' liveness (Emitter.planFspanLiveness): after a call, only the
		spans on registers the callee may write are taken again. Crash Bandicoot: Warped's model
		loop calls its vertex decoder at every vertex, and the decoder never writes the register
		the loop reads its model through.
	**/
	function writesFor(from:Universe, addr:Int):Int {
		final a = Vaddr.canonRam(addr);
		final u = calleeUniverse(from, a);
		if (u == null) return Emitter.ALL_REGS;
		else {}
		if (u.writes == null) computeWrites();
		else {}
		return u.writes.exists(a) ? u.writes.get(a) : Emitter.ALL_REGS;
	}

	function computeWrites():Void {
		final all = Emitter.ALL_REGS;
		// Per function: its own writes, and the (universe, address) of each function it calls.
		final own:Array<Map<Int, Int>> = [];
		final edges:Array<Map<Int, Array<{u:Int, a:Int}>>> = [];
		for (ui in 0...universes.length) {
			final u = universes[ui];
			u.writes = [];
			final ownU:Map<Int, Int> = [];
			final edgesU:Map<Int, Array<{u:Int, a:Int}>> = [];
			final hooked = u.emitter.hooks;
			for (entry in u.discovery.functions.keys()) {
				final fn = u.discovery.functions.get(entry);
				if (!u.shards.has(Vaddr.canonRam(entry))) continue;
				else {}
				var mask = 0;
				final calls:Array<{u:Int, a:Int}> = [];
				if (hooked != null && hooked.exists(fn.entry)) mask = all;
				else {}
				final ir = new recomp.ir.FunctionIR(fn, u.image);
				inline function callTo(t:Int):Void {
					final ta = Vaddr.canonRam(t);
					final cu = calleeUniverse(u, ta);
					if (cu == null) mask = all;
					else calls.push({u: universes.indexOf(cu), a: ta});
				}
				for (block in ir.blocks) {
					for (x in block.instructions) {
						mask |= (x.writes : Int);
						final op = x.decoded.op;
						if (op == Op.SYSCALL || op == Op.BREAK || x.effects.has(recomp.ir.Effect.TRAP)
								|| x.effects.has(recomp.ir.Effect.UNKNOWN)) mask = all;
						else {}
					}
					final tr = block.transfer;
					if (tr == null) continue;
					else {}
					final d = tr.decoded;
					if (d.op == Op.JAL || d.op == Op.BLTZAL || d.op == Op.BGEZAL) callTo(d.target);
					else if (d.op == Op.J) {
						if (!ir.byAddress.exists(d.target)) callTo(d.target);   // a tail call
						else {}
					} else if (d.isRegisterJump) {
						if (d.rs == 31) {
							final ra = d.op == Op.JR ? u.discovery.raJumpOf(fn.entry, d.addr) : null;
							if (ra != null && !ir.byAddress.exists(ra)) callTo(ra);
							else {}
						} else if (d.op == Op.JR && fn.registerReturns.exists(d.addr)) {}
						else mask = all;      // a call or jump through a register, a table's default
					} else {}
				}
				ownU.set(Vaddr.canonRam(fn.entry), mask);
				edgesU.set(Vaddr.canonRam(fn.entry), calls);
			}
			own.push(ownU);
			edges.push(edgesU);
		}
		// The least fixed point: a function writes what it writes and what its callees write.
		for (ui in 0...universes.length) for (k in own[ui].keys()) universes[ui].writes.set(k, own[ui].get(k));
		var changed = true;
		while (changed) {
			changed = false;
			for (ui in 0...universes.length) {
				final w = universes[ui].writes;
				for (k in edges[ui].keys()) {
					var m = w.get(k);
					if (m == all) continue;
					else {}
					for (c in edges[ui].get(k)) {
						final cw = universes[c.u].writes;
						m |= cw.exists(c.a) ? cw.get(c.a) : all;
					}
					if (m != w.get(k)) {
						w.set(k, m);
						changed = true;
					} else {}
				}
			}
		}
	}

	/**
		Mods' hooks (ADR-0033), handed to the emitters before anything is written: a hook scoped to
		an overlay goes to that overlay's universe, one scoped to "exe" to the executable's, and an
		unscoped one to every universe — the same address is a different function in each overlay
		that shares a window. Relocatable code takes none: it has no address until it runs.
	**/
	public function setHooks(hooks:Array<recomp.config.ModConfig.ModHook>):Void {
		for (h in hooks) {
			if (h.scope != null && !Lambda.exists(universes, u -> scopeOf(u) == h.scope)) {
				throw new recomp.loader.LoaderError('a mod hooks ${Vaddr.hex(h.addr)} in "${h.scope}", '
					+ 'which is neither "exe" nor an overlay of this game');
			}
		}
		for (u in universes) {
			final set:Map<Int, Bool> = [];
			for (h in hooks) if (h.scope == null || h.scope == scopeOf(u)) set.set(h.addr, true);
			u.emitter.hooks = set;
		}
	}

	/** After `writeTo`: the hooks no emitted function begins at — a wrong address, or code the
	    analysis never found (a function hint would find it). */
	public function unmatchedHooks(hooks:Array<recomp.config.ModConfig.ModHook>):Array<recomp.config.ModConfig.ModHook> {
		return [for (h in hooks) if (!Lambda.exists(universes, u -> (h.scope == null
			|| h.scope == scopeOf(u)) && u.emitter.hooked.exists(h.addr))) h];
	}

	static function scopeOf(u:Universe):String return u.isBase() ? "exe" : u.overlay.id;

	function inSomeWindow(addr:Int):Bool {
		for (u in universes) if (u.contains(addr)) return true;
		return false;
	}

	public function writeTo(dir:String):Void {
		ensureDir(dir);
		// Remove every previously generated file first. Shard names carry their split point, so
		// when a discovery change moves a split, the old file's name no longer matches anything —
		// and a directory that accumulates every layout it has ever had is a haunted one: twenty
		// files where eleven belong, and any tooling that globs `Fns_*.hx` reads functions from
		// builds that no longer exist. Generated output is machine-owned; nothing hand-edited
		// lives here to protect (golden rule 5).
		for (name in FileSystem.readDirectory(dir)) {
			if (StringTools.endsWith(name, ".hx")) FileSystem.deleteFile('$dir/$name');
		}
		for (u in universes) {
			for (s in u.shards.shards) write('$dir/${s.className}.hx', shardSource(u, s));
		}
		for (r in relocSets) {
			for (sh in r.shards) write('$dir/${sh.className}.hx', relocShardSource(r, sh));
		}
		write('$dir/FnTable.hx', fnTableSource());
		write('$dir/Overlays.hx', overlaysSource());
		write('$dir/RelocTable.hx', relocTableSource());
		write('$dir/GameInfo.hx', gameInfoSource());
	}

	// ---- one shard --------------------------------------------------------------------------

	function shardSource(u:Universe, shard:Shard):String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tFunctions ${Vaddr.hex(shard.functions[0].entry)}'
			+ '..${Vaddr.hex(shard.functions[shard.functions.length - 1].endAddr - 1)}'
			+ ' — ${shard.functions.length} of them');
		if (!u.isBase()) buf.add(', from overlay "${u.overlay.id}"');
		buf.add('.\n');
		buf.add('**/\n');
		buf.add('class ${shard.className} {\n');

		for (fn in shard.functions) {
			buf.add(bodyOf(u, shard, fn));
			buf.add("\n");
		}

		// The shard's own dispatcher. Every function is reachable from here, which is also what
		// keeps them alive through `-dce full` — `@:keep` is not honoured upstream.
		buf.add('\t/**\n');
		buf.add('\t\tCalls one of this shard\'s functions by slot.\n\n');
		buf.add('\t\tThis switch is the only reference to most of them, which is deliberate: it is\n');
		buf.add('\t\twhat makes them survive dead-code elimination, and it is how an address in\n');
		buf.add('\t\temulated memory turns into a call without any function value existing.\n');
		buf.add('\t**/\n');
		buf.add('\tpublic static function dispatch(slot:Int, entry:Int, ctx:CpuState):Void {\n');
		buf.add('\t\tRuntime.lastSlot = slot;\n');
		buf.add('\t\tswitch (slot) {\n');
		for (i in 0...shard.functions.length) {
			buf.add('\t\t\tcase $i: ${shard.className}.${shard.functions[i].name}(ctx, entry);\n');
		}
		buf.add('\t\t\tdefault: Runtime.badHandle(ctx, ${shard.index}, ${shard.index}, slot);\n');
		buf.add('\t\t}\n');
		buf.add('\t}\n');
		buf.add('}\n');
		return buf.toString();
	}

	/**
		A function's body, or a note saying where the identical one already is.

		Overlays are linked from the same libraries as each other and as the executable, so the
		same routine appears at the same address in several universes, byte for byte. Emitting it
		once matters most where it costs most — a console links every overlay into one binary — and
		it is free to detect: the emitted *text* is compared, not the bytes.

		Text rather than bytes because two identical byte sequences do not always compile to the
		same thing here. A call inside a window resolves to the calling universe's own class, so
		the same instructions in two overlays can name two different callees. Comparing what was
		actually written cannot get that wrong, and the cases it does merge are exactly the ones
		that are genuinely the same code — usually library routines that only call into the base.
	**/
	function bodyOf(u:Universe, shard:Shard, fn:Func):String {
		// Shared bodies retain the first owner's handle. Comparing before substitution preserves
		// deduplication; resuming the handle cannot accidentally choose a new resident overlay.
		final token = '__RECOMPSX_CONTINUATION_HANDLE__';
		u.emitter.continuationToken = token;
		final text = u.emitter.emitFunction(fn);
		final owner = emitted.get(text);
		if (owner != null) {
			deduplicated++;
			return '\t/** Identical to `${owner}.${fn.name}`; one body serves both. */\n'
				+ '\tpublic static function ${fn.name}(ctx:core.Ctx, entry:Int = 0):Void {\n'
				+ '\t\t${owner}.${fn.name}(ctx, entry);\n'
				+ '\t}\n';
		}
		emitted.set(text, shard.className);
		return StringTools.replace(text, token, Std.string(u.shards.handleOf(fn.entry)));
	}

	// ---- the dispatch table -------------------------------------------------------------------

	/**
		Every addressable block in one universe, as three parallel columns.

		The rows are what dispatch searches: an address, the handle of the function that owns it,
		and which of that function's blocks it is. Built the same way for the executable and for
		every overlay, because they answer the same question about different memory.
	**/
	function rowsOf(shards:Shards):Rows {
		final addrs = [];
		final handle:Map<Int, Int> = [];
		final block:Map<Int, Int> = [];
		for (s in shards.shards) {
			for (slot in 0...s.functions.length) {
				final fn = s.functions[slot];
				final h = (s.index << 20) | slot;
				final order = Emitter.blockOrder(fn);
				for (i in 0...order.length) {
					final a = order[i];
					// A block duplicated into two functions belongs to the one that starts at it if
					// either does; otherwise first-come, which is address order and so is stable.
					if (handle.exists(a) && a != fn.entry) continue;
					else {}
					if (!handle.exists(a)) addrs.push(a);
					else {}
					handle.set(a, h);
					block.set(a, i);
				}
			}
		}
		addrs.sort((a, b) -> a - b);
		return {addrs: addrs, handle: handle, block: block};
	}

	function fnTableSource():String {
		// Only the executable's own code. An overlay's blocks live in `Overlays`, because at any
		// moment at most one overlay answers for a window and a single flat table cannot say which.
		final rows = rowsOf(universes[0].shards);
		final addrs = rows.addrs;
		final handle = rows.handle;
		final block = rows.block;

		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tAddress to code, for every jump this tool could not resolve statically.\n\n');
		buf.add('\tThe table holds packed integer handles, not function references: reflaxe.CPP\n');
		buf.add('\tlowers a function value to a heap-allocated std::function and an array of them\n');
		buf.add('\tdoes not compile at all (ADR-0002). A handle is `(shard << 20) | slot`, costs\n');
		buf.add('\tone integer, and dispatches through generated switches the C++ compiler turns\n');
		buf.add('\tinto jump tables.\n\n');
		buf.add('\t**Every basic block is addressable, not only every function entry.** A recompiled\n');
		buf.add('\tprogram has to be able to resume in the middle of a function, because that is\n');
		buf.add('\twhere `longjmp` lands: `setjmp` saves the return address of its own call, so the\n');
		buf.add('\tjump target is by construction an instruction after a `jal`, never a prologue. The\n');
		buf.add('\tsame is true of a thread switch and of an exception hook returning. An entries-only\n');
		buf.add('\ttable answers "no function there" to all of them, and the jump silently does\n');
		buf.add('\tnothing — which is how a game gets stuck with no error at all.\n\n');
		buf.add('\tSo each row carries the block index as well, and the shard switch passes it as the\n');
		buf.add('\tfunction\'s `entry` argument. Entering at block 0 is an ordinary call; entering\n');
		buf.add('\tanywhere else is a resume, and the emitted state machine needs nothing extra to\n');
		buf.add('\tsupport it because every block already assigns its own locals.\n\n');
		buf.add('\tLookup is a binary search over a sorted address array rather than a flat table\n');
		buf.add('\tindexed by address: ${addrs.length} entries against 512K slots, which matters on a\n');
		buf.add('\tconsole with 32 MB of RAM and costs about ${bits(addrs.length)} comparisons here.\n\n');
		buf.add('\tThese rows are the executable\'s. Code the game loads from its disc lives in\n');
		buf.add('\t`Overlays`, whose windows shadow these addresses while they are resident.\n');
		buf.add('**/\n');
		// C++ only (`cxx`, reflaxe.CPP's define): the executable's functions as a native array of
		// pointers, in handle order, so a kept answer (`FAST`) can hold an index into it and a call
		// through a register goes straight to its function — not through this class's switch on
		// the shard and the shard's switch on the slot, which with their prologues were most of a
		// dynamic call. A function value in Haxe would be a heap-allocated std::function (ADR-0002);
		// this is a C array the compiler fills at link time. Other targets keep the switches.
		final exe = universes[0].shards.shards;
		final fnRefs = [for (sh in exe) for (f in sh.functions) '&${sh.className}::${f.name}'];
		// Last, the empty state of the CpuState's last answer (`run`): its address is odd, which no
		// table answers, and this asks the long way, as a miss does.
		buf.add('@:cppFileCode("typedef void (*RecompsxFn)(core::CpuState*, int);\\n'
			+ 'static void recompsx_unanswered(core::CpuState* ctx, int entry) { (void)entry; core::Runtime::callOnce(ctx, ctx->_callAt); }\\n'
			+ 'static const RecompsxFn recompsx_fns[] = {\\n');
		var col = 0;
		for (r in fnRefs) {
			buf.add(r + ',');
			col++;
			if (col % 4 == 0) buf.add('\\n');
			else {}
		}
		buf.add('&recompsx_unanswered,\\n};\\n")\n');
		buf.add('class FnTable {\n');
		buf.add('\t/** `recompsx_unanswered`\'s place in the native pointer array (C++): after every function. */\n');
		buf.add('\tstatic inline var NONE:Int = ${fnRefs.length};\n\n');
		// Where each executable shard starts in that array: flat = SHARD_BASE[shard] + slot.
		var maxShard = -1;
		for (sh in exe) if (sh.index > maxShard) maxShard = sh.index;
		final bases = [for (_ in 0...maxShard + 1) -1];
		var next = 0;
		for (sh in exe) {
			bases[sh.index] = next;
			next += sh.functions.length;
		}
		buf.add('\t/** Where each of the executable\'s shards starts in the native pointer array (C++). */\n');
		buf.add('\tstatic final SHARD_BASE:Array<Int> = [${bases.join(", ")}];\n\n');

		buf.add('\t/** Block addresses, ascending. */\n');
		buf.add('\tstatic final ADDRS:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> hex(a));
		buf.add('\t];\n\n');

		buf.add('\t/** Handles, in the same order. */\n');
		buf.add('\tstatic final HANDLES:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> Std.string(handle.get(a)));
		buf.add('\t];\n\n');

		buf.add('\t/** Which block of that function each address is — the `entry` argument. */\n');
		buf.add('\tstatic final BLOCKS:Array<Int> = [\n');
		emitIntArray(buf, addrs, a -> Std.string(block.get(a)));
		buf.add('\t];\n\n');

		buf.add('\tstatic final N:Int = ${addrs.length};\n\n');
		buf.add(flatTables());

		buf.add("	/** The row for an address, or -1 if this program has no code there. */
	public static function lookup(addr:Int):Int {
		if (!flatReady) buildFlat();
		final slot = (addr >>> 2) & 1023;
		final cached = shim.MemA.get32(CACHE_ROW, slot << 2);
		if (cached != 0 && shim.MemA.get32(CACHE_TAG, slot << 2) == addr) return cached - 2;
		var lo = 0;
		var hi = N - 1;
		var row = -1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = shim.MemA.get32(ADDRS_F, mid << 2);
			if (at == addr) { row = mid; break; }
			else if (at < addr) { lo = mid + 1; }
			else { hi = mid - 1; }
		}
		shim.MemA.set32(CACHE_TAG, slot << 2, addr);
		shim.MemA.set32(CACHE_ROW, slot << 2, row + 2);
		return row;
	}

	/** Routes a handle to the shard that owns it, entering at block `entry`. The count is a
	    diagnostic, kept where the instruction counts are (`recompsx_insns`): on the SH-4 it was
	    a literal-pool address, a load and a store on every dynamic call. */
	public static function dispatch(handle:Int, entry:Int, ctx:CpuState):Void {
		#if recompsx_insns
		Runtime.dispatches++;
		#end
		final slot = handle & 0xFFFFF;
		switch (handle >>> 20) {
");
		// Every shard in the program, overlays included: a handle is program-wide, and an overlay's
		// table hands its handles to this same switch.
		for (u in universes) {
			for (s in u.shards.shards) {
				buf.add('\t\t\tcase ${s.index}: ${s.className}.dispatch(slot, entry, ctx);\n');
			}
		}
		for (r in relocSets) {
			for (s in r.shards) {
				buf.add('\t\t\tcase ${s.index}: ${s.className}.dispatch(slot, entry, ctx);\n');
			}
		}
		buf.add("			default: Runtime.badHandle(ctx, -1, handle >>> 20, slot);
		}
	}

	/**
		A call through a register, from generated code: the loop `Runtime.call` runs, with this
		table's kept answers in front of it.

		Nearly every dynamic call is to fixed code outside every overlay window — a renderer
		hopping between its routines through pointers, an interpreter through its handlers — and
		for those `FAST` holds the handle and block from the first time. A hit is one compare and
		the dispatch switch. Anything else is asked the way `Runtime.call` asks
		(`Runtime.callOnce`), which lands in `call` below, and `call` keeps the answer. Tail jumps
		the callee leaves (ADR-0026) loop here at a fixed host depth, as they do in `Runtime.call`.

		Generated code calls this rather than `Runtime.call` because the runtime cannot name this
		table: it reaches it through the dispatcher it was handed, and on the way a call passed
		`Runtime.call`, its out-of-line body, the `std::function` and `call` — four frames, each
		saving registers its cold paths need. On a Dreamcast that was about 150 instructions for
		every dynamic call, 7% of a frame of Crash Bandicoot: Warped.

		Nothing to test before the lookup. The table is built by `init`, before any guest code
		runs. And no token can be pending: a generated caller has returned or cleared at every
		point that may raise one (after each call, pump and trap), and `Runtime.call`, the other way
		in (`bindRun`), tests before it gets here. Both tests were here too, a load and a branch
		each on every dynamic call — 2.8 % of Crash 3's generated code between them.
	**/
	public static function run(ctx:CpuState, addr:Int):Void {
		var target = addr;
		while (true) {
			#if cxx
			// The last answer first (CpuState._callAt): a compare in a line that is always in the
			// cache, where FAST's slot is wherever the address puts it.
			if (shim.MemA.likely(ctx._callAt == target)) FnPtr.call(ctx._callFn, ctx, ctx._callBlock);
			else runFast(ctx, target);
			#else
			final at = ((target >>> 2) & 1023) << 4;
			if (shim.MemA.get32(FAST, at) == target) dispatch(shim.MemA.get32(FAST, at + 4), shim.MemA.get32(FAST, at + 8), ctx);
			else Runtime.callOnce(ctx, target);
			#end
			if (ctx.unwindToken != Runtime.TAIL) return;
			else {}
			ctx.unwindToken = 0;
			target = ctx.tailTarget;
		}
	}

	#if cxx
	/** `run` when the address is not the last one: FAST's answer, kept in the CpuState as the last
	    one, or the long way. Out of line, so a call site `run` is inlined into carries the compare
	    and the call, not the table. */
	@:specifier(\"__attribute__((noinline))\")
	static function runFast(ctx:CpuState, target:Int):Void {
		final at = ((target >>> 2) & 1023) << 4;
		if (shim.MemA.get32(FAST, at) == target) {
			final fn = shim.MemA.get32(FAST, at + 12);
			final block = shim.MemA.get32(FAST, at + 8);
			ctx._callAt = target;
			ctx._callFn = fn;
			ctx._callBlock = block;
			FnPtr.call(fn, ctx, block);
		} else Runtime.callOnce(ctx, target);
	}
	#end

	/**
		Runs the code at an address. Used for everything the analysis left dynamic.

		A resident overlay is asked first, and wins — including when it has nothing there. Its
		window shadows these addresses for as long as the game has it loaded, which is what the
		memory itself does: the executable's bytes at a shadowed address are *gone*, so falling
		back to the executable's table would run code whose bytes the game overwrote. An address
		the resident overlay has no row for is data, or an entry the analysis has not been given
		yet, and either way the honest answer is a miss that names it.
	**/
	public static function call(addr:Int, ctx:CpuState):Bool {
		if (!flatReady) buildFlat();
		else {}
		final at = ((addr >>> 2) & 1023) << 4;
		if (shim.MemA.get32(FAST, at) == addr) {
			dispatch(shim.MemA.get32(FAST, at + 4), shim.MemA.get32(FAST, at + 8), ctx);
			return true;
		} else {}
		final ovl = kernel.OverlayMgr.residentAt(addr);
		if (ovl >= 0) {
			// The resident overlay shadows the executable here: no fallthrough.
			final row = Overlays.lookup(ovl, addr);
			if (row < 0) return false;
			dispatch(Overlays.handleAt(row), Overlays.blockAt(row), ctx);
			return true;
		} else {}
		final row = lookup(addr);
		// Nothing at a fixed address: it may be relocatable code the game put there (ADR-0025).
		if (row < 0) return RelocTable.call(addr, ctx);
		final handle = shim.MemA.get32(HANDLES_F, row << 2);
		final block = shim.MemA.get32(BLOCKS_F, row << 2);
		// Kept only where no window can take the address away; `clearFast` runs whenever the
		// windows change, so a window declared later is honoured too.
		if (kernel.OverlayMgr.windowOf(addr) < 0) keep(at, addr, handle, block);
		else {}
		dispatch(handle, block, ctx);
		return true;
	}

	/** A kept answer: the address, its handle and block, and (the spare word) the function's place
	    in the native pointer array, which `run` calls through on C++. Only the executable's rows
	    are kept, and every one of those has a place there. */
	static function keep(at:Int, addr:Int, handle:Int, block:Int):Void {
		shim.MemA.set32(FAST, at, addr);
		shim.MemA.set32(FAST, at + 4, handle);
		shim.MemA.set32(FAST, at + 8, block);
		shim.MemA.set32(FAST, at + 12, SHARD_BASE[handle >>> 20] + (handle & 0xFFFFF));
	}

	/** Whether an address is a function entry rather than a block inside one. Diagnostics only. */
	public static function isEntry(addr:Int):Bool {
		final row = lookup(addr);
		return row >= 0 && shim.MemA.get32(BLOCKS_F, row << 2) == 0;
	}
}

#if cxx
/** A call through `recompsx_fns`, the array FnTable's C++ file defines (its `@:cppFileCode`). */
private extern class FnPtr {
	@:nativeFunctionCode(\"(recompsx_fns[({arg0})](({arg1}), ({arg2})))\")
	public static function call(index:Int, ctx:CpuState, entry:Int):Void;
}
#end
");
		return buf.toString();
	}

	/**
		The tables the hot path actually reads, and the reason they are not the arrays above.

		reflaxe.CPP represents `Array<Int>` as `std::shared_ptr<std::deque<int>>`. Every element
		access is therefore a call into `_Deque_iterator::operator[]` through a node map, and
		`length` is iterator subtraction with two shifts — so an eleven-probe binary search costs
		about four hundred instructions and a fistful of dependent loads. PC sampling on a
		Dreamcast, 305,000 samples, put **19% of the entire frame** inside this one lookup: the
		single largest item in the profile, above the game's own hottest function.

		The same numbers in a flat buffer are one `mov.l` per probe. On top of that, `lookup` is
		a **pure function of an address over build-time-constant tables** — the executable's code
		cannot move — so a direct-mapped cache of the answers can never go stale and needs no
		invalidation of any kind. A hit is a compare and a load.

		The literal arrays stay because they are how the data arrives; they are walked once, at
		startup, and never touched again.
	**/
	static function flatTables():String {
		return "	static var ADDRS_F:shim.RawBuf;
	static var HANDLES_F:shim.RawBuf;
	static var BLOCKS_F:shim.RawBuf;
	static var CACHE_TAG:shim.RawBuf;
	static var CACHE_ROW:shim.RawBuf;
	/**
		`call`'s answers for fixed code outside every overlay window, direct-mapped on the address:
		address, handle, block and a spare word per slot, so a lookup touches one cache line. An
		empty slot holds an address that maps to a different slot, which no lookup can match.
	**/
	static var FAST:shim.RawBuf;
	static var flatReady:Bool = false;

	/** Forgets every kept answer. The windows changed: an address may now belong to one. */
	static function clearFast():Void {
		var i = 0;
		while (i < 1024) {
			shim.MemA.set32(FAST, i << 4, ((i + 1) & 1023) << 2);
			i++;
		}
		#if cxx
		// And the one the machine's CpuState keeps (`run`).
		forgetLast(mem.Memory.machine);
		#end
	}

	#if cxx
	/** The CpuState's last answer emptied: an odd address, which no table answers, and
	    `recompsx_unanswered`, which asks the long way if one is ever called there. */
	static function forgetLast(m:CpuState):Void {
		m._callAt = 1;
		m._callFn = NONE;
		m._callBlock = 0;
	}
	#end

	/** Initialize before guest execution; subsequent calls allocate nothing. */
	public static function init():Void {
		if (!flatReady) buildFlat();
		RelocTable.init();
	}

	/** Out of line on C++, so `run`'s frame is not the size of a startup loop's. */
	@:specifier(\"__attribute__((noinline))\")
	static function buildFlat():Void {
		ADDRS_F = shim.RawMem.alloc(N << 2);
		HANDLES_F = shim.RawMem.alloc(N << 2);
		BLOCKS_F = shim.RawMem.alloc(N << 2);
		var i = 0;
		while (i < N) {
			shim.MemA.set32(ADDRS_F, i << 2, ADDRS[i]);
			shim.MemA.set32(HANDLES_F, i << 2, HANDLES[i]);
			shim.MemA.set32(BLOCKS_F, i << 2, BLOCKS[i]);
			i++;
		}
		// Zero is an empty cache row; one encodes a miss and two encodes table row zero.
		// Every Int address, including -1, therefore has an unambiguous answer.
		CACHE_TAG = shim.RawMem.alloc(1024 << 2);
		CACHE_ROW = shim.RawMem.alloc(1024 << 2);
		FAST = shim.RawMem.alloc(1024 << 4);
		i = 0;
		while (i < 1024) {
			shim.MemA.set32(CACHE_ROW, i << 2, 0);
			i++;
		}
		clearFast();
		kernel.OverlayMgr.watchWindows(clearFast);
		flatReady = true;
	}

";
	}

	// ---- relocatable code (ADR-0025) -------------------------------------------------------------

	function relocShardSource(r:RelocSet, shard:Shard):String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tRelocatable functions from "${r.config.id}" — ${shard.functions.length} of them. They run\n');
		buf.add('\twherever the game put them: `core.Reloc.base` holds the entry address (ADR-0025).\n');
		buf.add('**/\n');
		buf.add('class ${shard.className} {\n');
		for (fn in shard.functions) {
			final rf = relocOf(r, fn);
			final token = '__RECOMPSX_CONTINUATION_HANDLE__';
			rf.unit.emitter.continuationToken = token;
			buf.add(StringTools.replace(rf.unit.emitter.emitFunction(fn), token, Std.string(rf.handle)));
			buf.add("\n");
		}
		buf.add('\tpublic static function dispatch(slot:Int, entry:Int, ctx:CpuState):Void {\n');
		buf.add('\t\tRuntime.lastSlot = slot;\n');
		buf.add('\t\tswitch (slot) {\n');
		for (i in 0...shard.functions.length) {
			buf.add('\t\t\tcase $i: ${shard.className}.${shard.functions[i].name}(ctx, entry);\n');
		}
		buf.add('\t\t\tdefault: Runtime.badHandle(ctx, ${shard.index}, ${shard.index}, slot);\n');
		buf.add('\t\t}\n');
		buf.add('\t}\n');
		buf.add('}\n');
		return buf.toString();
	}

	static function relocOf(r:RelocSet, fn:Func):RelocFunc {
		for (f in r.functions) if (f.func == fn) return f;
		throw 'relocatable function ${fn.name} not in its set';
	}

	/**
		How the runtime recognises relocatable code: by the words at the address it was sent to.

		One program-wide table, however many stanzas: a key is FNV-1a over the first `HASH_WORDS`
		words at the entry, and its value is a handle — or, where several functions share the key,
		a group whose rows say which words to read and what each function has there. The tool
		chose those words so that no two different functions on the disc read the same.
	**/
	function relocTableSource():String {
		final hashWords = relocSets.length == 0 ? 1 : relocSets[0].config.hashWords;
		for (r in relocSets) {
			if (r.config.hashWords != hashWords) {
				throw new recomp.analysis.AnalysisError('relocatable stanzas must share one hashWords');
			} else {}
		}
		// Keys across stanzas, sorted; a key two stanzas share would be ambiguous, and is refused.
		final keys:Array<Int> = [];
		final values:Array<Int> = [];
		final posStart:Array<Int> = [];
		final posEnd:Array<Int> = [];
		final positions:Array<Int> = [];
		final rowStart:Array<Int> = [];
		final rowEnd:Array<Int> = [];
		final wordStart:Array<Int> = [];
		final rowWords:Array<Int> = [];
		final rowMasks:Array<Int> = [];
		final rowHandles:Array<Int> = [];
		final pairs:Array<{key:Int, value:Int}> = [];
		// Key lengths across stanzas, longest first: the order the runtime tries them in.
		final lengthSet:Map<Int, Bool> = [];
		for (r in relocSets) for (n in r.lengthsLongestFirst()) lengthSet.set(n, true);
		final lengths = [for (n in lengthSet.keys()) n];
		lengths.sort((a, b) -> b - a);
		for (r in relocSets) {
			for (i in 0...r.keys.length) {
				final v = r.keyValues[i];
				if (v >= 0) { pairs.push({key: r.keys[i], value: r.functions[v].handle}); continue; }
				else {}
				final g = r.groups[-1 - v];
				final gi = posStart.length;
				posStart.push(positions.length);
				for (p in g.positions) positions.push(p);
				posEnd.push(positions.length);
				rowStart.push(rowHandles.length);
				wordStart.push(rowWords.length);
				for (row in 0...g.rowWords.length) {
					for (w in g.rowWords[row]) rowWords.push(w);
					rowMasks.push(g.rowMasks[row]);
					rowHandles.push(r.functions[g.rowFuncs[row]].handle);
				}
				rowEnd.push(rowHandles.length);
				pairs.push({key: r.keys[i], value: -1 - gi});
			}
		}
		pairs.sort((a, b) -> a.key < b.key ? -1 : (a.key > b.key ? 1 : 0));
		for (i in 0...pairs.length) {
			if (i > 0 && pairs[i].key == pairs[i - 1].key) {
				throw new recomp.analysis.AnalysisError('two relocatable stanzas share a key; give '
					+ 'them different hashWords or merge them');
			} else {}
			keys.push(pairs[i].key);
			values.push(pairs[i].value);
		}

		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tRelocatable code, recognised by content (ADR-0025): ${keys.length} keys, '
			+ '${posStart.length} of them shared by several functions.\n');
		buf.add('**/\n');
		buf.add('class RelocTable {\n');
		buf.add('\tpublic static inline var HASH_WORDS = $hashWords;\n');
		// Counts as constants and the lengths as a flat buffer: an Array is a deque on
		// reflaxe.CPP, whose `length` and `[]` cost a call each (see `flatTables`).
		buf.add('\tstatic inline var KEY_COUNT = ${keys.length};\n');
		buf.add('\tstatic inline var LENGTH_COUNT = ${lengths.length};\n\n');
		emitTable(buf, "LENGTHS", "Key lengths in words, longest first.", lengths, a -> Std.string(a));
		emitTable(buf, "KEYS", "FNV-1a over a function's first words, then their count, ascending.", keys, a -> hex(a));
		emitTable(buf, "VALUES", "A handle, or -1 - group for a key several functions share.", values, a -> Std.string(a));
		emitTable(buf, "POS_START", "Each group's first position.", posStart, a -> Std.string(a));
		emitTable(buf, "POS_END", "One past its last.", posEnd, a -> Std.string(a));
		emitTable(buf, "POSITIONS", "Word offsets from the entry that tell a group's functions apart.", positions, a -> Std.string(a));
		emitTable(buf, "ROW_START", "Each group's first row.", rowStart, a -> Std.string(a));
		emitTable(buf, "ROW_END", "One past its last.", rowEnd, a -> Std.string(a));
		emitTable(buf, "WORD_START", "Where each group's row words begin in ROW_WORDS.", wordStart, a -> Std.string(a));
		emitTable(buf, "ROW_WORDS", "Each row's words at its group's positions, row after row.", rowWords, a -> hex(a));
		emitTable(buf, "ROW_MASKS", "Which of a row's positions count: bit k for position k.", rowMasks, a -> hex(a));
		emitTable(buf, "ROW_HANDLES", "The function each row names.", rowHandles, a -> Std.string(a));
		buf.add(RELOC_RUNTIME);
		buf.add('}\n');
		return buf.toString();
	}

	static final RELOC_RUNTIME = "	static var KEYS_F:shim.RawBuf;
	static var VALUES_F:shim.RawBuf;
	static var LENGTHS_F:shim.RawBuf;
	/** FNV-1a state after each word at the address being looked up: entry n after n words. */
	static var STATES_F:shim.RawBuf;
	static var ready:Bool = false;

	/** Initialize before guest execution; subsequent calls allocate nothing. */
	public static function init():Void {
		if (ready) return;
		else {}
		final n = KEY_COUNT;
		KEYS_F = shim.RawMem.alloc((n + 1) << 2);
		VALUES_F = shim.RawMem.alloc((n + 1) << 2);
		STATES_F = shim.RawMem.alloc((HASH_WORDS + 1) << 2);
		LENGTHS_F = shim.RawMem.alloc((LENGTH_COUNT + 1) << 2);
		var i = 0;
		while (i < n) {
			shim.MemA.set32(KEYS_F, i << 2, KEYS[i]);
			shim.MemA.set32(VALUES_F, i << 2, VALUES[i]);
			i++;
		}
		i = 0;
		while (i < LENGTH_COUNT) {
			shim.MemA.set32(LENGTHS_F, i << 2, LENGTHS[i]);
			i++;
		}
		ready = true;
	}

	/** One FNV-1a byte — the same lines as the tool's `RelocSet.step`. */
	static inline function step(h:Int, byte:Int):Int {
		final x = (h ^ byte) | 0;
		return (x + ((x << 1) | 0) + ((x << 4) | 0) + ((x << 7) | 0) + ((x << 8) | 0)
			+ ((x << 24) | 0)) | 0;
	}

	/** FNV-1a over HASH_WORDS words at `addr`, keeping the state after each word in STATES_F. */
	static function hashPrefixes(addr:Int):Void {
		var h = 0x811C9DC5;
		var i = 0;
		while (i < HASH_WORDS) {
			final w = Memory.read32(addr + (i << 2));
			h = step(h, w & 0xFF);
			h = step(h, (w >>> 8) & 0xFF);
			h = step(h, (w >>> 16) & 0xFF);
			h = step(h, (w >>> 24) & 0xFF);
			i++;
			shim.MemA.set32(STATES_F, i << 2, h);
		}
	}

	/** The index of `key` in KEYS, or -1. */
	static function find(key:Int):Int {
		var lo = 0;
		var hi = KEY_COUNT - 1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = shim.MemA.get32(KEYS_F, mid << 2);
			if (at == key) return mid;
			else if (at < key) { lo = mid + 1; }
			else { hi = mid - 1; }
		}
		return -1;
	}

	/**
		Runs relocatable code at `addr`, if what is there is code this program knows. A function
		is keyed on its own first instructions only, so several lengths are tried, longest first:
		a longer match is the more specific one.
	**/
	public static function call(addr:Int, ctx:CpuState):Bool {
		if (KEY_COUNT == 0 || (addr & 3) != 0) return false;
		else {}
		if (!Memory.isPlainMemory(addr) || !Memory.isPlainMemory(addr + ((HASH_WORDS - 1) << 2))) return false;
		else {}
		if (!ready) init();
		else {}
		hashPrefixes(addr);
		var l = 0;
		while (l < LENGTH_COUNT) {
			final n = shim.MemA.get32(LENGTHS_F, l << 2);
			final at = find(step(shim.MemA.get32(STATES_F, n << 2), n));
			if (at >= 0) {
				final value = shim.MemA.get32(VALUES_F, at << 2);
				final handle = value >= 0 ? value : resolve(-1 - value, addr);
				if (handle >= 0) {
					core.Reloc.base = addr;
					core.Reloc.calls = (core.Reloc.calls + 1) | 0;
					FnTable.dispatch(handle, 0, ctx);
					return true;
				} else {}
			} else {}
			l++;
		}
		return false;
	}

	/**
		Which of a group's functions is at `addr`, by the words at the group's positions that each
		row's function occupies (ROW_MASKS); rows are most specific first.
	**/
	static function resolve(group:Int, addr:Int):Int {
		final p0 = POS_START[group];
		final n = POS_END[group] - p0;
		var row = ROW_START[group];
		final end = ROW_END[group];
		while (row < end) {
			final mask = ROW_MASKS[row];
			var ok = true;
			var k = 0;
			while (k < n) {
				if (((mask >> k) & 1) != 0) {
					final at = addr + (POSITIONS[p0 + k] << 2);
					final expected = ROW_WORDS[WORD_START[group] + (row - ROW_START[group]) * n + k];
					if (!Memory.isPlainMemory(at) || Memory.read32(at) != expected) { ok = false; break; }
					else {}
				} else {}
				k++;
			}
			if (ok) return ROW_HANDLES[row];
			else {}
			row++;
		}
		return -1;
	}
";

	// ---- the overlays --------------------------------------------------------------------------

	/**
		What the runtime needs to know about code the game loads from its disc.

		Two halves. The **descriptors** say which overlays exist, where each one goes and how to
		recognise it: a window, and a fingerprint over the first words of its bytes. The **rows**
		are the same address/handle/block columns `FnTable` has, one set per overlay, concatenated
		into single arrays with a start and end index per overlay.

		Concatenated rather than nested because `Array<Array<Int>>` is a shape nothing in this
		project has put through reflaxe.CPP, and a flat array of integers is the shape everything
		else already uses. A slice is two more integers and no new risk.

		This file knows nothing about *when* an overlay is resident — that is `OverlayMgr`'s, and
		it asks these questions. Emitted even when a game has no overlays, so that the runtime can
		be written once against a table that is sometimes empty.
	**/
	function overlaysSource():String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/**\n');
		buf.add('\tCode this game loads from its disc: where it goes, how to recognise it, and\n');
		buf.add('\twhich function answers for each address while it is there.\n\n');
		buf.add('\tAn overlay is bytes from the disc placed at a fixed address. PlayStation overlays\n');
		buf.add('\tare linked at their final address — nothing relocates them at load time — so an\n');
		buf.add('\toverlay is identified by exactly two things, its window and its contents, and both\n');
		buf.add('\tare here. The fingerprint is FNV-1a over the first words of the overlay, which is\n');
		buf.add('\tits own code and so differs between overlays built from the same libraries; the\n');
		buf.add('\ttool checks at generation time that no two collide.\n');
		buf.add('**/\n');
		buf.add('class Overlays {\n');

		final overlays = universes.slice(1);
		buf.add('\tpublic static inline var COUNT = ${overlays.length};\n\n');

		final allAddrs = [];
		final allHandles = [];
		final allBlocks = [];
		final starts = [];
		final ends = [];
		for (u in overlays) {
			final rows = rowsOf(u.shards);
			starts.push(allAddrs.length);
			for (a in rows.addrs) {
				allAddrs.push(a);
				allHandles.push(rows.handle.get(a));
				allBlocks.push(rows.block.get(a));
			}
			ends.push(allAddrs.length);
		}

		emitTable(buf, "LO", "Where each overlay's window begins.",
			[for (u in overlays) u.overlay.loadAddr], a -> hex(a));
		emitTable(buf, "HI", "One past where it ends.",
			[for (u in overlays) u.overlay.endAddr()], a -> hex(a));
		emitTable(buf, "FINGERPRINT", "FNV-1a over the overlay's first words.",
			[for (u in overlays) u.fingerprint()], a -> hex(a));
		emitTable(buf, "HASH_WORDS", "How many words that fingerprint covers.",
			[for (u in overlays) u.overlay.hashWords], a -> Std.string(a));
		emitTable(buf, "ROW_START", "First row of this overlay's slice of the columns below.",
			starts, a -> Std.string(a));
		emitTable(buf, "ROW_END", "One past its last row.", ends, a -> Std.string(a));
		emitTable(buf, "ADDRS", "Every addressable block, ascending within each overlay.",
			allAddrs, a -> hex(a));
		emitTable(buf, "HANDLES", "The function that owns each, program-wide.", allHandles,
			a -> Std.string(a));
		emitTable(buf, "BLOCKS", "Which block of that function it is.", allBlocks,
			a -> Std.string(a));

		buf.add("	/**
		The row for an address within one overlay, or -1 if that overlay has no code there.

		A binary search over that overlay's slice. An address inside a window is not necessarily
		code: a window holds whatever the game loaded into it, and the parts that are artwork have
		no rows.
	**/
	public static function lookup(overlay:Int, addr:Int):Int {
		if (overlay < 0 || overlay >= COUNT) return -1;
		if (!flatReady) buildFlat();
		// Two tags, because the answer depends on both arguments and a collision between two
		// overlays asking about the same address would otherwise return the wrong row.
		final slot = ((addr >>> 2) + overlay * 40503) & 1023;
		if (shim.MemA.get32(CACHE_ADDR, slot << 2) == addr
			&& shim.MemA.get32(CACHE_OVL, slot << 2) == overlay)
			return shim.MemA.get32(CACHE_ROW, slot << 2);
		var lo = shim.MemA.get32(ROW_START_F, overlay << 2);
		var hi = shim.MemA.get32(ROW_END_F, overlay << 2) - 1;
		var row = -1;
		while (lo <= hi) {
			final mid = (lo + hi) >> 1;
			final at = shim.MemA.get32(ADDRS_F, mid << 2);
			if (at == addr) { row = mid; break; }
			else if (at < addr) { lo = mid + 1; }
			else { hi = mid - 1; }
		}
		shim.MemA.set32(CACHE_ADDR, slot << 2, addr);
		shim.MemA.set32(CACHE_OVL, slot << 2, overlay);
		shim.MemA.set32(CACHE_ROW, slot << 2, row);
		return row;
	}

	/**
		The same flat tables FnTable keeps, and for the same measured reason — but this is the
		copy that gameplay actually runs through. A game's code lives in the overlays it streams
		from the disc, so `FnTable.call` reaches a resident overlay first and never touches the
		executable's table at all. Sampling a Dreamcast found 14% of the frame inside
		`std::_Deque_iterator::operator[]` **after** FnTable was flattened: template
		instantiations have vague linkage, so every caller in the program shares one copy of that
		function, and the callers left were these.
	**/
	static var ADDRS_F:shim.RawBuf;
	static var HANDLES_F:shim.RawBuf;
	static var BLOCKS_F:shim.RawBuf;
	static var ROW_START_F:shim.RawBuf;
	static var ROW_END_F:shim.RawBuf;
	static var CACHE_ADDR:shim.RawBuf;
	static var CACHE_OVL:shim.RawBuf;
	static var CACHE_ROW:shim.RawBuf;
	static var flatReady:Bool = false;

	/** Initialize before guest execution; subsequent calls allocate nothing. */
	public static function init():Void {
		if (!flatReady) buildFlat();
	}

	static function buildFlat():Void {
		final n = ADDRS.length;
		ADDRS_F = shim.RawMem.alloc(n << 2);
		HANDLES_F = shim.RawMem.alloc(n << 2);
		BLOCKS_F = shim.RawMem.alloc(n << 2);
		var i = 0;
		while (i < n) {
			shim.MemA.set32(ADDRS_F, i << 2, ADDRS[i]);
			shim.MemA.set32(HANDLES_F, i << 2, HANDLES[i]);
			shim.MemA.set32(BLOCKS_F, i << 2, BLOCKS[i]);
			i++;
		}
		ROW_START_F = shim.RawMem.alloc(COUNT << 2);
		ROW_END_F = shim.RawMem.alloc(COUNT << 2);
		i = 0;
		while (i < COUNT) {
			shim.MemA.set32(ROW_START_F, i << 2, ROW_START[i]);
			shim.MemA.set32(ROW_END_F, i << 2, ROW_END[i]);
			i++;
		}
		CACHE_ADDR = shim.RawMem.alloc(1024 << 2);
		CACHE_OVL = shim.RawMem.alloc(1024 << 2);
		CACHE_ROW = shim.RawMem.alloc(1024 << 2);
		i = 0;
		while (i < 1024) { shim.MemA.set32(CACHE_OVL, i << 2, -1); i++; }
		flatReady = true;
	}

	/** Whether an address falls inside an overlay's window, resident or not. */
	public static function inWindow(overlay:Int, addr:Int):Bool {
		return overlay >= 0 && overlay < COUNT && addr >= LO[overlay] && addr < HI[overlay];
	}

	public static function handleAt(row:Int):Int return shim.MemA.get32(HANDLES_F, row << 2);
	public static function blockAt(row:Int):Int return shim.MemA.get32(BLOCKS_F, row << 2);

	/**
		Tells the runtime which overlays exist. Called once, at boot, after `Runtime.boot`.

		Four numbers each, and no tables: the runtime decides *whether* an overlay is resident and
		this class knows *what is in it*, which is what keeps `kernel.OverlayMgr` compilable with
		no generated code present at all.
	**/
	public static function register():Void {
		for (i in 0...COUNT) {
			kernel.OverlayMgr.define(i, LO[i], HI[i], FINGERPRINT[i], HASH_WORDS[i]);
		}
	}

	/** The overlay's name, for diagnostics. A switch rather than a table of strings: this is a
	    cold path, and it keeps the generated tables to plain integers. */
	public static function name(overlay:Int):String {
		switch (overlay) {
");
		for (i in 0...overlays.length) {
			buf.add('\t\t\tcase $i: return "${overlays[i].overlay.id}";\n');
		}
		buf.add("			default: return \"?\";
		}
	}
}
");
		return buf.toString();
	}

	/** One named table, with its comment. Empty arrays still emit, so the runtime compiles. */
	function emitTable(buf:StringBuf, name:String, doc:String, values:Array<Int>,
			render:Int -> String):Void {
		buf.add('\t/** $doc */\n');
		buf.add('\tstatic final $name:Array<Int> = [\n');
		emitIntArray(buf, values, render);
		buf.add('\t];\n\n');
	}

	/**
		No two overlays may look alike where the runtime looks.

		Recognition is a fingerprint over the first words of an overlay's bytes, so two overlays
		that begin with the same prologue would be indistinguishable — and the runtime would
		activate whichever it checked first, dispatching an address to the wrong code. That is a
		failure with no symptom at the point of the mistake, so it is caught here instead, where
		the fix is one number in a config.
	**/
	function checkFingerprintsDistinct():Void {
		final overlays = universes.slice(1);
		for (u in overlays) {
			// The tool clamps its hash to the bytes it has; the runtime hashes the full
			// `hashWords`. An overlay shorter than its own fingerprint would therefore hash
			// differently in the two places and never be recognised — silently. Refusing here
			// turns a game that mysteriously never activates into one number in a config.
			if (u.overlay.length < u.overlay.hashWords * 4) {
				throw new recomp.analysis.AnalysisError('overlay "${u.overlay.id}" is '
					+ '${u.overlay.length} bytes but its fingerprint covers '
					+ '${u.overlay.hashWords * 4}. Lower hashWords to at most '
					+ '${Std.int(u.overlay.length / 4)}.');
			}
		}
		for (i in 0...overlays.length) {
			for (j in 0...i) {
				if (overlays[i].fingerprint() != overlays[j].fingerprint()) continue;
				throw new recomp.analysis.AnalysisError(
					'overlays "${overlays[i].overlay.id}" and "${overlays[j].overlay.id}" have the '
					+ 'same fingerprint over their first ${overlays[i].overlay.hashWords} words, so '
					+ 'the runtime could not tell them apart. Raise hashWords on one of them.');
			}
		}
	}

	/** Comparisons a binary search over `n` rows costs, for the doc comment. */
	static function bits(n:Int):Int {
		var b = 0;
		var v = 1;
		while (v < n) { v <<= 1; b++; }
		return b;
	}

	/** Ten per line: readable in a diff, and not so long that an editor struggles. */
	function emitIntArray(buf:StringBuf, values:Array<Int>, render:Int -> String):Void {
		var i = 0;
		while (i < values.length) {
			buf.add("\t\t");
			var n = 0;
			while (n < 10 && i < values.length) {
				buf.add(render(values[i]));
				if (i < values.length - 1) buf.add(", ");
				i++;
				n++;
			}
			buf.add("\n");
		}
	}

	// ---- what the loader needs -----------------------------------------------------------------

	/** The product code and the game's name, for GameInfo: its memory card's key (ADR-0037). */
	public function setGame(serial:String, title:String):Void {
		gameSerial = serial;
		gameTitle = title;
	}

	var gameSerial = "";
	var gameTitle = "";

	/** A Haxe string literal's inside: printable ASCII, quotes and backslashes escaped. */
	static function literal(s:String):String {
		final buf = new StringBuf();
		for (i in 0...s.length) {
			final c = s.charCodeAt(i);
			if (c == '"'.code || c == '\\'.code) buf.add("\\" + String.fromCharCode(c));
			else buf.add(c >= 0x20 && c < 0x7F ? String.fromCharCode(c) : "?");
		}
		return buf.toString();
	}

	function gameInfoSource():String {
		final buf = new StringBuf();
		buf.add(header());
		buf.add('/** What the executable declares about itself, so the runtime can start it. */\n');
		buf.add('class GameInfo {\n');
		buf.add('\t/** The product code the game\'s memory card is kept under, and its name (ADR-0037). */\n');
		buf.add('\tpublic static inline var SERIAL = "${literal(gameSerial)}";\n');
		buf.add('\tpublic static inline var TITLE = "${literal(gameTitle)}";\n');
		buf.add('\tpublic static inline var ENTRY_POINT = ${hex(exe.initialPc)};\n');
		buf.add('\tpublic static inline var INITIAL_GP  = ${hex(exe.initialGp)};\n');
		buf.add('\tpublic static inline var LOAD_ADDR   = ${hex(exe.loadAddr)};\n');
		buf.add('\tpublic static inline var LOAD_SIZE   = ${hex(exe.fileSize)};\n');
		buf.add('\tpublic static inline var INITIAL_SP  = ${hex(exe.initialSp())};\n');
		// The executable's own, not the whole program's: this is what the loader places in RAM,
		// and an overlay is not there until the game fetches it.
		buf.add('\tpublic static inline var FUNCTIONS   = ${universes[0].shards.totalFunctions()};\n');
		buf.add('\tpublic static inline var SHARDS      = ${universes[0].shards.shards.length};\n');
		buf.add('}\n');
		return buf.toString();
	}

	// ---- plumbing -------------------------------------------------------------------------------

	function header():String {
		// The executable's name, on every file. An overlay's shards say which overlay they came
		// from in their own class comment; the program as a whole came from one game.
		return "// Generated by recompsx from " + universes[0].image.name + ". Do not edit.\n"
			+ "//\n"
			+ "// A defect here is a defect in tools/recomp; fix the generator and regenerate.\n"
			+ "// Generation is deterministic: the same input and tool version give the same bytes.\n\n"
			+ "import core.CpuState;\n"
			+ "import core.Ops;\n"
			+ "import core.Runtime;\n"
			+ "import mem.Memory;\n"
			+ "import kernel.Kernel;\n"
			+ "import gte.Gte;\n\n";
	}

	function write(path:String, source:String):Void {
		File.saveContent(path, source);
		filesWritten++;
		var lines = 1;
		for (i in 0...source.length) if (source.charCodeAt(i) == 10) lines++;
		linesWritten += lines;
	}

	static function ensureDir(dir:String):Void {
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
	}

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
}
