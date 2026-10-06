package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.mips.Op;

/**
	The register allocation of Sh4Emitter (ADR-0048): a guest register's values as *webs* — the
	definitions that reach a common use, joined, and every use they reach — each given an SH-4
	register or left in CpuState, where the C++ form keeps every guest register.

	A web is one value's life in one guest register: `t8` holding a field's bits in one block and a
	shift count in the next is two webs, which can sit in two SH-4 registers or share one. Every
	way out of the function (`jr $ra`) and every due pump at a loop header must find each guest
	register the function writes in CpuState (ADR-0029: the state they see is the machine's), so
	both count as a use of the web that reaches them in each such register: a web with an SH-4
	register is stored there, one left in CpuState was stored at each of its writes. The entry
	counts as a definition of every register, its value CpuState's: a web holding it is loaded at
	the entry when it has an SH-4 register and anything uses it.

	The SH-4 registers go by weight — each use and definition counting eight times per loop level —
	to the webs that interfere with no web already given the register, r7 first (free in a function
	that calls nothing), then r8-r14 (a save and a restore at each call).

	Instructions are taken in the order Sh4Emitter emits them: a block's body, then its delay slot
	and transfer — the slot first unless it writes a register the branch tests (`slotFirst`), when
	the test is made before it, or the transfer is a switch's `jr`, whose target is read first.
**/
class Sh4Webs {
	/** Per block, the instructions in emission order. */
	public final seq:Array<Array<InstructionIR>> = [];
	/** Global site of an instruction (its position across `seq`), by identity. */
	public final siteOf:Map<InstructionIR, Int> = new Map();
	/** Web of a use or a definition: key `site * 64 + register * 2 + (def ? 1 : 0)`. */
	final webAt:Map<Int, Int> = [];
	/** The SH-4 register of each web, or null (CpuState). */
	public final color:Array<Null<String>> = [];
	public final hasEntryDef:Array<Bool> = [];
	public final hasRealDef:Array<Bool> = [];
	/** Webs stored to CpuState at their definition, as a web without an SH-4 register is: those
	    reaching a way out or a pump with one definition, outside every loop, so that their SH-4
	    register is free after their last use instead of held to the way out. */
	public final writeThrough:Array<Bool> = [];
	/** Webs with an SH-4 register live at the entry: loaded there, with the guest register each holds. */
	public final entryLoads:Array<{web:Int, reg:Int}> = [];
	/** Per block (by index): at its way out, the webs to store, with their registers. */
	public final exitStores:Map<Int, Array<{web:Int, reg:Int}>> = [];
	/** Per pump block: the webs to store before the pump, and those to load again after it. */
	public final pumpStores:Map<Int, Array<{web:Int, reg:Int}>> = [];
	public final pumpLoads:Map<Int, Array<{web:Int, reg:Int}>> = [];
	/** Callee-saved SH-4 registers given to webs, in push order. */
	public final saved:Array<String> = [];
	public var webCount(default, null) = 0;

	final ir:FunctionIR;
	final written:Int;

	/**
		`ir` the function, `written` the guest registers it writes (bit per register), `pool` the SH-4
		registers webs may have, in order of preference.
	**/
	public function new(ir:FunctionIR, written:Int, pool:Array<String>, checkedReturns:Map<Int, Bool>) {
		this.ir = ir;
		this.written = written;
		final n = ir.blocks.length;
		final index:Map<Int, Int> = [];
		for (k in 0...n) index.set(ir.blocks[k].addr, k);
		// Emission order and sites.
		var site = 0;
		final siteBlock:Array<Int> = [];
		final siteInstr:Array<InstructionIR> = [];
		for (k in 0...n) {
			final b = ir.blocks[k];
			final o = b.body.copy();
			if (b.transfer != null) {
				final t = b.transfer;
				final s = b.delaySlot;
				final cond = switch (t.decoded.op) { case BEQ | BNE | BLEZ | BGTZ | BLTZ | BGEZ: true; case _: false; };
				// A switch's `jr` reads its target before the slot runs, as the C++ form does.
				final table = t.decoded.op == Op.JR && t.decoded.rs != 31;
				if (s != null && !s.decoded.isNop) {
					if (table || (cond && ((s.writes:Int) & (t.reads:Int)) != 0)) {
						o.push(t);
						o.push(s);
					} else {
						o.push(s);
						o.push(t);
					}
				} else o.push(t);
			} else {}
			seq.push(o);
			for (x in o) {
				siteOf.set(x, site);
				siteBlock.push(k);
				siteInstr.push(x);
				site++;
			}
		}
		final sites = site;
		// Definitions: one per (site, register written), then one entry definition per register.
		final defSite:Array<Int> = [];
		final defReg:Array<Int> = [];
		final defsOfReg:Array<Array<Int>> = [for (_ in 0...32) []];
		for (s in 0...sites) {
			final w:Int = siteInstr[s].writes;
			for (r in 1...32) if ((w & (1 << r)) != 0) {
				defsOfReg[r].push(defSite.length);
				defSite.push(s);
				defReg.push(r);
			} else {}
		}
		final entryDef = [for (_ in 0...32) -1];
		for (r in 1...32) {
			entryDef[r] = defSite.length;
			defsOfReg[r].push(defSite.length);
			defSite.push(-1);
			defReg.push(r);
		}
		final nd = defSite.length;
		final defAt:Map<Int, Int> = [];   // site * 32 + r -> def
		for (d in 0...nd) if (defSite[d] >= 0) defAt.set(defSite[d] * 32 + defReg[d], d);
		else {}
		// Reaching definitions, per register as a set of defs at each block's entry.
		final words = (nd + 31) >> 5;
		final inSet = [for (_ in 0...n) [for (_ in 0...words) 0]];
		final outSet = [for (_ in 0...n) [for (_ in 0...words) 0]];
		function setBit(a:Array<Int>, d:Int) a[d >> 5] |= 1 << (d & 31);
		function hasBit(a:Array<Int>, d:Int):Bool return (a[d >> 5] & (1 << (d & 31))) != 0;
		final entryBlock = index.get(ir.blocks[0].addr);
		// gen/kill: the last def of each register in the block survives.
		final lastDef = [for (_ in 0...n) [for (_ in 0...32) -1]];
		for (k in 0...n) for (x in seq[k]) {
			final s = siteOf.get(x);
			final w:Int = x.writes;
			for (r in 1...32) if ((w & (1 << r)) != 0) lastDef[k][r] = defAt.get(s * 32 + r);
			else {}
		}
		for (r in 1...32) setBit(inSet[entryBlock], entryDef[r]);
		var changed = true;
		while (changed) {
			changed = false;
			for (k in 0...n) {
				final b = ir.blocks[k];
				// IN = union of predecessors' OUT (the entry block keeps its entry defs too).
				final inn = k == entryBlock ? [for (w in 0...words) inSet[k][w]] : [for (_ in 0...words) 0];
				for (p in b.predecessors) {
					final j = index.get(p);
					if (j == null) continue;
					for (w in 0...words) inn[w] |= outSet[j][w];
				}
				// OUT = gen + (IN - kill)
				final out = inn.copy();
				for (r in 1...32) if (lastDef[k][r] >= 0) {
					for (d in defsOfReg[r]) out[d >> 5] &= ~(1 << (d & 31));
					setBit(out, lastDef[k][r]);
				} else {}
				var diff = false;
				for (w in 0...words) if (inn[w] != inSet[k][w] || out[w] != outSet[k][w]) diff = true;
				else {}
				if (diff) {
					inSet[k] = inn;
					outSet[k] = out;
					changed = true;
				} else {}
			}
		}
		// Union-find over defs: the defs reaching one use are one web.
		final parent = [for (d in 0...nd) d];
		function find(d:Int):Int {
			var x = d;
			while (parent[x] != x) {
				parent[x] = parent[parent[x]];
				x = parent[x];
			}
			return x;
		}
		function union(a:Int, b:Int):Void {
			final x = find(a);
			final y = find(b);
			if (x != y) parent[x] = y;
			else {}
		}
		// Walk each block with the current reaching def per register: a set at the block's entry
		// (`IN`), one def after a definition in the block.
		final useDefs:Map<Int, Int> = [];   // site * 64 + r * 2 -> a representative def
		// Sync points: per exit block and per pump block, the representative def of each written
		// register reaching them.
		final exitDefs:Map<Int, Array<{reg:Int, def:Int}>> = [];
		final pumpDefs:Map<Int, Array<{reg:Int, def:Int}>> = [];
		for (k in 0...n) {
			final cur:Array<Int> = [for (_ in 0...32) -1];   // -1: the IN set's defs
			function reaching(r:Int):Int {
				if (cur[r] >= 0) return cur[r];
				// Join every def of r in IN.
				var rep = -1;
				for (d in defsOfReg[r]) if (hasBit(inSet[k], d)) {
					if (rep < 0) rep = d;
					else union(rep, d);
				} else {}
				if (rep < 0) rep = entryDef[r];   // unreachable block: nothing reaches; the entry's
				else {}
				return rep;
			}
			if (ir.blocks[k].pump) {
				final list = [];
				for (r in 1...32) if ((written & (1 << r)) != 0) list.push({reg: r, def: reaching(r)});
				else {}
				pumpDefs.set(k, list);
			} else {}
			for (x in seq[k]) {
				final s = siteOf.get(x);
				final rd:Int = readsOf(x, checkedReturns);
				for (r in 1...32) if ((rd & (1 << r)) != 0) useDefs.set(s * 64 + r * 2, reaching(r));
				else {}
				final w:Int = x.writes;
				for (r in 1...32) if ((w & (1 << r)) != 0) cur[r] = defAt.get(s * 32 + r);
				else {}
			}
			final t = ir.blocks[k].transfer;
			if (t != null && t.decoded.op == Op.JR) {
				final list = [];
				for (r in 1...32) if ((written & (1 << r)) != 0) list.push({reg: r, def: reaching(r)});
				else {}
				exitDefs.set(k, list);
			} else {}
		}
		// Webs: the roots, numbered.
		final webOfRoot:Map<Int, Int> = [];
		function webOfDef(d:Int):Int {
			final root = find(d);
			var w = webOfRoot.get(root);
			if (w == null) {
				w = webCount++;
				webOfRoot.set(root, w);
				color.push(null);
				hasEntryDef.push(false);
				hasRealDef.push(false);
				writeThrough.push(false);
			} else {}
			return w;
		}
		for (d in 0...nd) {
			final w = webOfDef(d);
			if (defSite[d] < 0) hasEntryDef[w] = true;
			else hasRealDef[w] = true;
		}
		// Only webs something uses or a sync point stores matter; an entry def nothing reads is
		// CpuState's value and stays there.
		for (key => d in useDefs) webAt.set(key, webOfDef(d));
		for (d in 0...nd) if (defSite[d] >= 0) webAt.set(defSite[d] * 64 + defReg[d] * 2 + 1, webOfDef(d));
		else {}
		// Weights: eight per loop level, to 64.
		final depth = loopDepth(index);
		final weight = [for (_ in 0...webCount) 0];
		for (key => w in webAt) {
			final s = key >> 6;
			final k = siteBlock[s];
			final r = (key >> 1) & 31;
			// What leaving the web in CpuState costs at this site: a load or a store, two
			// instructions for a field past mov.l @(disp,Rn)'s 60 bytes.
			final far = Sh4Emitter.FIELD_OFFSET.get(recomp.mips.Instr.regName(r)) > 60 ? 2 : 1;
			weight[w] += (depth[k] == 0 ? 1 : (depth[k] == 1 ? 8 : 64)) * far;
		}
		final syncWebs = new Map<Int, Bool>();
		for (k => list in exitDefs) for (e in list) syncWebs.set(webOfDef(e.def), true);
		for (k => list in pumpDefs) for (e in list) syncWebs.set(webOfDef(e.def), true);
		// A sync web whose definitions are all outside loops is stored where it is defined: each path
		// stores it once either way, and its register is not held to the way out.
		// One definition only: a web of several can run them one after another on a path (each a
		// value the next replaces, joined by a use some path reaches from either), each a store.
		final loopDef = [for (_ in 0...webCount) false];
		final realDefs = [for (_ in 0...webCount) 0];
		for (d in 0...nd) if (defSite[d] >= 0) {
			realDefs[webOfDef(d)]++;
			if (depth[siteBlock[defSite[d]]] > 0) loopDef[webOfDef(d)] = true;
			else {}
		} else {}
		for (w in syncWebs.keys()) if (realDefs[w] == 1 && !loopDef[w]) writeThrough[w] = true;
		else {}
		// Liveness of webs, backward, with the sync points as uses: an exit's at its block's end, a
		// pump's at its block's start.
		final wwords = (webCount + 31) >> 5;
		final liveIn = [for (_ in 0...n) [for (_ in 0...wwords) 0]];
		final liveOut = [for (_ in 0...n) [for (_ in 0...wwords) 0]];
		final interfere:Array<Map<Int, Bool>> = [for (_ in 0...webCount) new Map()];
		function addEdge(a:Int, b:Int):Void {
			if (a == b) return;
			interfere[a].set(b, true);
			interfere[b].set(a, true);
		}
		function walk(k:Int, record:Bool):Array<Int> {
			final live = liveOut[k].copy();
			if (exitDefs.exists(k)) for (e in exitDefs.get(k)) {
				final w = webOfDef(e.def);
				if (!writeThrough[w]) live[w >> 5] |= 1 << (w & 31);
				else {}
			} else {}
			var i = seq[k].length - 1;
			while (i >= 0) {
				final x = seq[k][i];
				final s = siteOf.get(x);
				final wr:Int = x.writes;
				for (r in 1...32) if ((wr & (1 << r)) != 0) {
					final w = webAt.get(s * 64 + r * 2 + 1);
					if (record) for (j in 0...webCount) if ((live[j >> 5] & (1 << (j & 31))) != 0) addEdge(w, j);
					else {}
					live[w >> 5] &= ~(1 << (w & 31));
				} else {}
				final rd:Int = readsOf(x, checkedReturns);
				for (r in 1...32) if ((rd & (1 << r)) != 0) {
					final w = webAt.get(s * 64 + r * 2);
					live[w >> 5] |= 1 << (w & 31);
				} else {}
				i--;
			}
			if (pumpDefs.exists(k)) for (e in pumpDefs.get(k)) {
				final w = webOfDef(e.def);
				if (!writeThrough[w]) live[w >> 5] |= 1 << (w & 31);
				else {}
			} else {}
			return live;
		}
		changed = true;
		while (changed) {
			changed = false;
			var k = n - 1;
			while (k >= 0) {
				final out = [for (_ in 0...wwords) 0];
				for (to in ir.blocks[k].successors) {
					final j = index.get(to);
					if (j != null) for (w in 0...wwords) out[w] |= liveIn[j][w];
					else {}
				}
				liveOut[k] = out;
				final inn = walk(k, false);
				var diff = false;
				for (w in 0...wwords) if (inn[w] != liveIn[k][w]) diff = true;
				else {}
				if (diff) {
					liveIn[k] = inn;
					changed = true;
				} else {}
				k--;
			}
		}
		for (k in 0...n) {
			walk(k, true);
			// Everything live at a block's entry interferes there too (a join, a pump's reload).
			final at = [for (j in 0...webCount) if ((liveIn[k][j >> 5] & (1 << (j & 31))) != 0) j];
			for (a in at) for (b in at) addEdge(a, b);
		}
		// Hints: an SH-4 operation writes its first operand, so a web defined from another that ends at
		// that instruction sits best in the same register (no move).
		final hints:Array<Array<Int>> = [for (_ in 0...webCount) []];
		for (k in 0...n) for (x in seq[k]) {
			final i = x.decoded;
			final s0 = siteOf.get(x);
			final src = switch (i.op) {
				case ADDU | ADD | SUBU | SUB | AND | OR | XOR | NOR | SLLV | SRLV | SRAV: i.op == Op.SLLV || i.op == Op.SRLV || i.op == Op.SRAV ? i.rt : i.rs;
				case ADDIU | ADDI | ANDI | ORI | XORI: i.rs;
				case SLL | SRL | SRA: i.rt;
				case _: 0;
			};
			final dst = switch (i.op) {
				case ADDIU | ADDI | ANDI | ORI | XORI: i.rt;
				case ADDU | ADD | SUBU | SUB | AND | OR | XOR | NOR | SLLV | SRLV | SRAV | SLL | SRL | SRA: i.rd;
				case _: 0;
			};
			if (src == 0 || dst == 0) continue;
			final a = webAt.get(s0 * 64 + src * 2);
			final b = webAt.get(s0 * 64 + dst * 2 + 1);
			if (a == null || b == null || a == b || interfere[a].exists(b)) continue;
			hints[a].push(b);
			hints[b].push(a);
		}
		// Colours, heaviest first.
		// Weight over degree: a web long enough to meet many others gives way to the several it
		// would keep out of a register (Chaitin's spill choice, as the greedy order).
		final degree = [for (w in 0...webCount) [for (_ in interfere[w].keys()) 0].length];
		final prio = [for (w in 0...webCount) weight[w] / (degree[w] + 1.0)];
		final order = [for (w in 0...webCount) if (weight[w] > 0) w];
		order.sort((a, b) -> prio[b] > prio[a] ? 1 : (prio[b] < prio[a] ? -1 : a - b));
		function freeFor(w:Int, reg:String):Bool {
			for (o in interfere[w].keys()) if (color[o] == reg) return false;
			else {}
			return true;
		}
		for (w in order) {
			// A partner's register first, when it is free here.
			for (h in hints[w]) if (color[h] != null && freeFor(w, color[h])) {
				color[w] = color[h];
				break;
			} else {}
			if (color[w] != null) continue;
			for (reg in pool) {
				var free = true;
				for (o in interfere[w].keys()) if (color[o] == reg) {
					free = false;
					break;
				} else {}
				if (free) {
					color[w] = reg;
					break;
				} else {}
			}
		}
		for (reg in pool) {
			if (Std.parseInt(reg.substr(1)) < 8) continue;
			for (w in 0...webCount) if (color[w] == reg) {
				saved.push(reg);
				break;
			} else {}
		}
		// The entry's loads, the sync points' stores and loads.
		final entryLive = liveIn[entryBlock];
		for (w in 0...webCount) if (color[w] != null && (entryLive[w >> 5] & (1 << (w & 31))) != 0 && hasEntryDef[w]) {
			entryLoads.push({web: w, reg: regOfWeb(w, defReg, parent, nd, find)});
		} else {}
		for (k => list in exitDefs) {
			final st = [];
			for (e in list) {
				final w = webOfDef(e.def);
				if (color[w] != null && hasRealDef[w] && !writeThrough[w]) st.push({web: w, reg: e.reg});
				else {}
			}
			exitStores.set(k, st);
		}
		for (k => list in pumpDefs) {
			final st = [];
			final ld = [];
			for (e in list) {
				final w = webOfDef(e.def);
				if (color[w] != null && hasRealDef[w] && !writeThrough[w]) st.push({web: w, reg: e.reg});
				else {}
			}
			// After the pump: every web with a register live at the block's entry, read again.
			for (w in 0...webCount) if (color[w] != null && (liveIn[k][w >> 5] & (1 << (w & 31))) != 0)
				ld.push({web: w, reg: regOfWeb(w, defReg, parent, nd, find)});
			else {}
			pumpStores.set(k, st);
			pumpLoads.set(k, ld);
		}
		final _ = syncWebs;
	}

	/** What an instruction reads as Sh4Emitter writes it: a return's `$ra` only when the return is
	    checked (ADR-0027) — otherwise it goes back to its host caller, reading nothing. */
	static function readsOf(x:InstructionIR, checkedReturns:Map<Int, Bool>):Int {
		final i = x.decoded;
		if (i.op == Op.JR && i.rs == 31 && !checkedReturns.exists(i.addr)) return (x.reads:Int) & ~(1 << 31);
		return x.reads;
	}

	/** The guest register a web holds (every def of a web is of one register). */
	function regOfWeb(w:Int, defReg:Array<Int>, parent:Array<Int>, nd:Int, find:Int->Int):Int {
		for (key => x in webAt) if (x == w) return (key >> 1) & 31;
		else {}
		throw 'Sh4Webs: web $w with no site';
	}

	/** The web of guest register `r` used (`def` false) or defined at `site`. */
	public function web(site:Int, r:Int, def:Bool):Int {
		final w = webAt.get(site * 64 + r * 2 + (def ? 1 : 0));
		if (w == null) throw 'Sh4Webs: no web for r$r at site $site (${def ? "def" : "use"})';
		return w;
	}

	/** Loop depth of each block: each back edge's natural loop one level deeper. */
	function loopDepth(index:Map<Int, Int>):Array<Int> {
		final n = ir.blocks.length;
		final depth = [for (_ in 0...n) 0];
		for (k in 0...n) for (to in ir.blocks[k].successors) {
			final h = index.get(to);
			if (h == null || ir.blocks[h].addr > ir.blocks[k].addr) continue;
			final inLoop = [for (_ in 0...n) false];
			inLoop[h] = true;
			final stack = [k];
			while (stack.length > 0) {
				final x = stack.pop();
				if (inLoop[x]) continue;
				inLoop[x] = true;
				for (p in ir.blocks[x].predecessors) {
					final j = index.get(p);
					if (j != null && !inLoop[j]) stack.push(j);
					else {}
				}
			}
			for (x in 0...n) if (inLoop[x]) depth[x]++;
			else {}
		}
		return depth;
	}
}
