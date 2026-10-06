package recomp.codegen;

/**
	A list scheduler for a straight run of SH-4 instructions, by the cache model's issue rules
	(scripts/dc-issue-sim.py, which scripts/dc-sched.py schedules the runtime's assembly by): two
	instructions issue together when neither is CO and their units differ, or both are MT; an
	instruction waits for its operands (a load 2 cycles, `sts macl` 3, a multiply 4). Sh4Asm hands it
	what lies between two labels or transfers.

	Dependencies: registers, T, MACH:MACL and PR; CpuState's words (an access through r4 at a known
	displacement is that word, through r0 any of them); a guest access (Sh4Asm.access) keeps its order
	among the others, and reads CpuState's clock, which a trap reads (the `mov.l r5,@(8,r4)` before
	it stays before it, the next one after it).
**/
class Sh4Sched {
	/** The order to write `texts` in: indices into it. `guest[i]` marks a guest access. `slot`: a
	    `bra` follows, which takes the last instruction into its delay slot when it may go there —
	    so one nothing after it depends on, that is no guest access or pool load, ends the run. */
	public static function schedule(texts:Array<String>, guest:Array<Bool>, slot = false):Array<Int> {
		final n = texts.length;
		if (n <= 1) return [for (i in 0...n) i];
		final items = [for (i in 0...n) parse(texts[i], guest[i])];
		final preds:Array<Map<Int, Int>> = [for (_ in 0...n) new Map()];
		function dep(a:Int, b:Int, d:Int):Void {
			final old = preds[b].get(a);
			if (old == null || old < d) preds[b].set(a, d);
			else {}
		}
		for (b in 0...n) {
			final B = items[b];
			for (a in 0...b) {
				final A = items[a];
				for (w in A.wr) {
					if (B.rd.indexOf(w) >= 0) dep(a, b, A.lat);
					else {}
					if (B.wr.indexOf(w) >= 0) dep(a, b, 1);
					else {}
				}
				for (r in A.rd) if (B.wr.indexOf(r) >= 0) dep(a, b, 0);
				else {}
				// CpuState's words.
				if (A.mem != null && B.mem != null && (A.store || B.store)
					&& (A.mem == B.mem || A.mem == "ctx*" || B.mem == "ctx*"))
					dep(a, b, A.store ? 1 : 0);
				else {}
				// Guest accesses keep their order; each reads the clock word.
				if (A.guest && B.guest) dep(a, b, 1);
				else {}
				if (A.store && (A.mem == "ctx8" || A.mem == "ctx*") && B.guest) dep(a, b, 1);
				else {}
				if (A.guest && B.store && (B.mem == "ctx8" || B.mem == "ctx*")) dep(a, b, 0);
				else {}
				// A trap's slow path may move the deadline (nextEvent): a read of it stays after.
				if (A.guest && !B.store && (B.mem == "ctx64" || B.mem == "ctx*")) dep(a, b, 1);
				else {}
				if (!A.store && (A.mem == "ctx64" || A.mem == "ctx*") && B.guest) dep(a, b, 0);
				else {}
			}
		}
		// Priority: the longest latency path to the end.
		final prio = [for (_ in 0...n) 0];
		var b = n - 1;
		while (b >= 0) {
			var best = 0;
			for (c in b + 1...n) {
				final d = preds[c].get(b);
				if (d != null && prio[c] + d > best) best = prio[c] + d;
				else {}
			}
			prio[b] = best + items[b].issue;
			b--;
		}
		final done:Array<Null<Int>> = [for (_ in 0...n) null];
		final order = [];
		final remaining = [for (i in 0...n) true];
		var left = n;
		var now = 0;
		function readyAt(i:Int):Null<Int> {
			var t = 0;
			for (a => d in preds[i]) {
				final da = done[a];
				if (da == null) return null;
				if (da + d > t) t = da + d;
				else {}
			}
			return t;
		}
		function pairs(u1:String, u2:String):Bool
			return !(u1 == "CO" || u2 == "CO" || (u1 == u2 && u1 != "MT"));
		while (left > 0) {
			// The leader: what can start soonest, the longest path first, then the earliest.
			var lead = -1;
			var leadStart = 0;
			for (i in 0...n) if (remaining[i]) {
				final t = readyAt(i);
				if (t == null) continue;
				final start = t > now ? t : now;
				if (lead < 0 || start < leadStart || (start == leadStart && (prio[i] > prio[lead] || (prio[i] == prio[lead] && i < lead)))) {
					lead = i;
					leadStart = start;
				} else {}
			}
			done[lead] = leadStart;
			order.push(lead);
			remaining[lead] = false;
			left--;
			now = leadStart + items[lead].issue;
			// Its partner, if one can issue with it.
			if (items[lead].unit != "CO") {
				var best = -1;
				for (j in 0...n) if (remaining[j]) {
					final t = readyAt(j);
					if (t == null || t > leadStart || !pairs(items[lead].unit, items[j].unit)) continue;
					if (best < 0 || prio[j] > prio[best] || (prio[j] == prio[best] && j < best)) best = j;
					else {}
				}
				if (best >= 0) {
					done[best] = leadStart;
					order.push(best);
					remaining[best] = false;
					left--;
				} else {}
			} else {}
		}
		if (slot) {
			// The last one nothing depends on that a slot takes (not a guest access, a pool load or a
			// CO instruction), moved to the end.
			final needed = [for (_ in 0...n) false];
			for (i in 0...n) for (a in preds[i].keys()) needed[a] = true;
			var k = order.length - 1;
			while (k >= 0) {
				final i = order[k];
				final it = items[i];
				if (!needed[i] && !it.guest && it.unit != "CO" && texts[i].indexOf('.L') < 0) {
					order.splice(k, 1);
					order.push(i);
					break;
				} else {}
				k--;
			}
		} else {}
		return order;
	}

	static function regsOf(s:String):Array<String> {
		final out = [];
		final re = ~/\br([0-9]+)\b/g;
		var t = s;
		while (re.match(t)) {
			out.push('r' + re.matched(1));
			t = re.matchedRight();
		}
		return out;
	}

	static function splitOps(ops:String):{src:String, dst:String} {
		var depth = 0;
		var cut = -1;
		for (i in 0...ops.length) {
			final ch = ops.charAt(i);
			if (ch == "(") depth++;
			else if (ch == ")") depth--;
			else if (ch == "," && depth == 0) cut = i;
			else {}
		}
		return cut >= 0 ? {src: ops.substr(0, cut), dst: ops.substr(cut + 1)} : {src: ops, dst: ""};
	}

	/** CpuState's word an operand names (`@(d,r4)` -> "ctx<d>", `@(r0,r4)` -> "ctx*"), else null. */
	static function ctxWord(operand:String):Null<String> {
		final o = StringTools.trim(operand);
		if (!StringTools.startsWith(o, "@(") || !StringTools.endsWith(o, ",r4)")) return null;
		final inner = o.substr(2, o.length - 6);
		return inner == "r0" ? "ctx*" : 'ctx$inner';
	}

	static function parse(text:String, guest:Bool):Item {
		final tab = text.indexOf("\t");
		final mn = tab < 0 ? text : text.substr(0, tab);
		final ops = tab < 0 ? "" : text.substr(tab + 1);
		final so = splitOps(ops);
		final src = so.src;
		final dst = so.dst;
		final it = new Item();
		it.guest = guest;
		switch (mn) {
			case "mov.l" | "mov.w" | "mov.b":
				it.unit = "LS";
				if (StringTools.startsWith(src, ".L")) {
					it.lat = 2;
					it.wr = regsOf(dst);
				} else if (StringTools.startsWith(src, "@")) {
					it.lat = 2;
					it.rd = regsOf(src);
					it.wr = regsOf(dst);
					if (StringTools.endsWith(src, "+")) it.wr.push(regsOf(src)[0]);
					else {}
					it.mem = ctxWord(src);
				} else {
					it.lat = 1;
					it.rd = regsOf(src).concat(regsOf(dst));
					if (StringTools.startsWith(dst, "@-")) it.wr.push(regsOf(dst)[0]);
					else {}
					it.store = true;
					it.mem = ctxWord(dst);
				}
			case "mov":
				if (StringTools.startsWith(src, "#")) {
					it.unit = "EX";
					it.wr = regsOf(dst);
				} else {
					it.unit = "MT";
					it.lat = 0;
					it.rd = regsOf(src);
					it.wr = regsOf(dst);
				}
			case "add" | "sub" | "and" | "or" | "xor" | "shad" | "shld" | "xtrct":
				it.unit = "EX";
				it.rd = StringTools.startsWith(src, "#") ? regsOf(dst) : regsOf(src).concat(regsOf(dst));
				it.wr = regsOf(dst);
			case "addv" | "subv":
				it.unit = "EX";
				it.rd = regsOf(src).concat(regsOf(dst));
				it.wr = regsOf(dst).concat(["T"]);
			case "addc" | "subc" | "negc":
				it.unit = "EX";
				it.rd = regsOf(src).concat(regsOf(dst)).concat(["T"]);
				it.wr = regsOf(dst).concat(["T"]);
			case "not" | "neg" | "exts.w" | "extu.w" | "exts.b" | "extu.b" | "swap.w" | "swap.b":
				it.unit = "EX";
				it.rd = regsOf(src);
				it.wr = regsOf(dst);
			case "shll" | "shlr" | "shal" | "shar" | "rotl" | "rotr" | "dt":
				it.unit = "EX";
				it.rd = regsOf(ops);
				it.wr = regsOf(ops).concat(["T"]);
			case "shll2" | "shll8" | "shll16" | "shlr2" | "shlr8" | "shlr16":
				it.unit = "EX";
				it.rd = regsOf(ops);
				it.wr = regsOf(ops);
			case "movt":
				it.unit = "EX";
				it.rd = ["T"];
				it.wr = regsOf(ops);
			case "tst" | "cmp/eq" | "cmp/hs" | "cmp/ge" | "cmp/hi" | "cmp/gt" | "cmp/pz" | "cmp/pl" | "cmp/str":
				it.unit = "MT";
				it.rd = regsOf(ops);
				it.wr = ["T"];
			case "clrt" | "sett":
				it.unit = "MT";
				it.wr = ["T"];
			case "dmuls.l" | "dmulu.l" | "mul.l" | "muls.w" | "mulu.w":
				it.unit = "CO";
				it.issue = 2;
				it.lat = 4;
				it.rd = regsOf(ops);
				it.wr = ["MAC"];
			case "sts":
				if (src.indexOf("mac") >= 0) {
					it.unit = "CO";
					it.lat = 3;
					it.rd = ["MAC"];
					it.wr = regsOf(dst);
				} else throw 'Sh4Sched: $text';
			case "sts.l" | "lds.l":
				// pr to and from the stack: kept where they are (they bracket a call).
				it.unit = "CO";
				it.issue = 2;
				it.rd = ["r15", "PR"];
				it.wr = ["r15", "PR"];
			case "nop":
				it.unit = "MT";
				it.lat = 0;
			case _:
				throw 'Sh4Sched: unknown instruction "$text"';
		}
		return it;
	}
}

private class Item {
	public var unit = "EX";
	public var issue = 1;
	public var lat = 1;
	public var rd:Array<String> = [];
	public var wr:Array<String> = [];
	public var store = false;
	public var mem:Null<String> = null;
	public var guest = false;

	public function new() {}
}
