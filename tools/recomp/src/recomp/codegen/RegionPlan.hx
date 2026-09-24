package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;

/** A tree owns each block once; its members are the original, stable resume IDs. */
enum RegionBody {
	Block(block:BlockIR);
	Sequence(parts:Array<Region>);
	Choice(head:Region, taken:Null<Region>, notTaken:Null<Region>, join:Null<Int>);
	/**
		A natural loop. `body` begins at the header; inside it every transfer to the header is a
		`continue`, and every transfer to one of `exits` records that target in `resume` and
		`break`s, so the guards after the loop route to it. Empty `exits` means every way out is
		a return.
	**/
	Loop(body:Region, exits:Array<Int>);
}

class Region {
	public final body:RegionBody;
	public final entry:Int;
	public final members:Array<Int>;
	public final successors:Array<Int>;
	/** The last ordinary branch, if the region still has an unstructured two-way exit. */
	public final selector:Null<BlockIR>;
	/** Can the emitter replace the final transfer with a known continuation? */
	public final follows:Bool;
	/** A computed transfer (recovered table or register jump) that keeps its own target checks. */
	public final computed:Bool;
	public final depth:Int;

	public function new(body:RegionBody, entry:Int, members:Array<Int>, successors:Array<Int>,
			selector:Null<BlockIR>, follows:Bool, depth:Int, computed:Bool = false) {
		this.body = body;
		this.entry = entry;
		this.members = members;
		this.successors = successors;
		this.selector = selector;
		this.follows = follows;
		this.depth = depth;
		this.computed = computed;
	}
}

/**
	Reduce single-entry regions, keeping arbitrary block resumes and irreducible CFGs intact.
	A choice consumes arms owned solely by its header and meeting at one continuation (or both
	leaving the function). A sequence is a forward run: consecutive regions in address order,
	entered only at the first, whose internal edges all point forward — the emitter renders a
	jump past the next part by recording the target in `resume` and letting the guards on the
	parts in between skip to it. A loop consumes a natural loop — a header that dominates its
	body — once its body reduces to one region with the back-edges and every exit edge cut away;
	each exit is a `break` that records its target the same way. Computed transfers retain their
	target checks. There are no game addresses or ABI guesses.

	Why loops matter: every `for` and `while` a C compiler emits is several blocks, and until
	loops were reduced each one kept its whole function in the block dispatcher — 632 of the
	1576 functions of the bring-up game — where the host compiler sees a `switch` in a `while`
	instead of a loop, keeps nothing in a register across it, and takes an indirect jump per
	block. Haxe has no labelled jumps, which is why every transfer inside a native loop must be
	a fall-through, a `continue`, a recorded `break`, or a return.
**/
class RegionPlan {
	public final roots:Array<Region> = [];
	public var sequences(default, null):Int = 0;
	public var choices(default, null):Int = 0;
	public var loops(default, null):Int = 0;
	final ir:FunctionIR;
	final owners:Map<Int, Region> = [];
	/** Where every path begins: the function's entry block, or a loop's header in a sub-plan. */
	final entryAddr:Int;
	static inline final MAX_DEPTH = 32;

	/**
		The whole function when `seed` is null. Otherwise a sub-plan over a loop's members with
		their back-edges and exits already cut, used to find out whether the body is one region.
	**/
	public function new(ir:FunctionIR, ?seed:Array<Region>, entry:Int = -1) {
		this.ir = ir;
		entryAddr = seed == null ? ir.blocks[0].addr : entry;
		if (seed == null) {
			for (block in ir.blocks) {
				final loopExit = block.selfLoopExit();
				final computed = block.transfer != null && block.transfer.decoded.isRegisterJump
					&& block.transfer.decoded.rs != 31;
				// A conditional edge outside the discovered function is a real exit. A lone known
				// successor must not make that branch look like an unconditional fallthrough.
				final follows = !computed && (!block.conditional() || loopExit != null
					|| block.transfer.decoded.target == block.transfer.decoded.addr + 8);
				final region = new Region(Block(block), block.addr, [block.resumeId],
					loopExit == null ? block.successors.copy() : [loopExit],
					block.conditional() && loopExit == null ? block : null, follows, 0, computed);
				roots.push(region);
				owners.set(block.addr, region);
			}
		} else {
			for (region in seed) {
				roots.push(region);
				for (id in region.members) owners.set(ir.blocks[id].addr, region);
			}
			roots.sort((a, b) -> a.entry - b.entry);
		}
		while (reduce()) {}
	}

	/** Recompute incoming region edges after each reduction; duplicate switch arms count once. */
	function predecessors():Map<Int, Array<Int>> {
		final incoming:Map<Int, Array<Int>> = [];
		for (root in roots) incoming.set(root.entry, []);
		for (root in roots) for (target in root.successors) {
			final owner = owners.get(target);
			final from = incoming.get(owner.entry);
			if (from.indexOf(root.entry) < 0) from.push(root.entry);
		}
		return incoming;
	}

	function onlyFrom(node:Region, head:Region, incoming:Map<Int, Array<Int>>):Bool {
		final from = incoming.get(node.entry);
		return node != head && from.length == 1 && from[0] == head.entry;
	}

	function reduce():Bool {
		final incoming = predecessors();
		// Choices first: preserving a header until its arms have merged keeps nesting shallow.
		for (head in roots) {
			final branch = head.selector;
			if (branch == null || head.successors.length != 2) continue;
			final takenAddr = branch.transfer.decoded.target;
			final otherAddr = branch.transfer.decoded.addr + 8;
			final taken = owners.get(takenAddr);
			final other = owners.get(otherAddr);
			if (taken == null || other == null || taken == other || taken == head || other == head
				|| taken.entry != takenAddr || other.entry != otherAddr) continue;
			if (onlyFrom(taken, head, incoming) && endsAt(taken, other.entry)) {
				if (choice(head, taken, null, other.entry)) return true;
			}
			if (onlyFrom(other, head, incoming) && endsAt(other, taken.entry)) {
				if (choice(head, null, other, taken.entry)) return true;
			}
			if (onlyFrom(taken, head, incoming) && onlyFrom(other, head, incoming)
				&& taken.follows && other.follows && taken.successors.length <= 1
				&& other.successors.length == taken.successors.length) {
				if (taken.successors.length == 0) {
					if (choice(head, taken, other, null)) return true;
				} else if (taken.successors[0] == other.successors[0]) {
					if (choice(head, taken, other, taken.successors[0])) return true;
				}
			}
		}
		if (reduceRun(incoming)) return true;
		// Loops last: their bodies are only reducible once the forward structure inside them is.
		return reduceLoop(incoming);
	}

	/**
		A forward run from each root: the root, then every other root all of whose predecessors
		already lie in the run, taken in address order until none qualifies. That is a
		single-entry slice of the graph in a topological order — the order the parts are
		emitted in, which need not be the address order, and is not when a compiler places a
		loop's condition after its body. A member with an edge back to the first region or to
		itself makes it a loop, and `reduceLoop`'s. Edges to a later part need no dispatcher —
		the emitter records the target in `resume` and the guarded parts in between are skipped
		— and edges out of the slice become the run's successors. A single conditional tail keeps
		its selector so a choice can still be built on it; a run that exits from several members
		has no one branch to latch.
	**/
	function reduceRun(incoming:Map<Int, Array<Int>>):Bool {
		for (start in 0...roots.length) {
			final nodes = [roots[start]];
			final inside:Map<Int, Bool> = [roots[start].entry => true];
			var grew = true;
			while (grew) {
				grew = false;
				for (candidate in roots) {
					if (inside.exists(candidate.entry)) continue;
					var entered = true;
					for (from in incoming.get(candidate.entry)) if (!inside.exists(from)) entered = false;
					if (!entered || incoming.get(candidate.entry).length == 0) continue;
					nodes.push(candidate);
					inside.set(candidate.entry, true);
					grew = true;
					break;
				}
			}
			if (nodes.length < 2) continue;
			var backward = false;
			for (node in nodes) for (target in node.successors) {
				final owner = owners.get(target).entry;
				if (owner == nodes[0].entry || owner == node.entry) backward = true;
			}
			if (backward) continue;
			final exits:Array<Int> = [];
			var exitingMembers = 0;
			for (node in nodes) {
				var exitsHere = false;
				for (target in node.successors) {
					if (inside.exists(owners.get(target).entry)) continue;
					exitsHere = true;
					if (exits.indexOf(target) < 0) exits.push(target);
				}
				if (exitsHere) exitingMembers++;
			}
			final tail = nodes[nodes.length - 1];
			final selector = exits.length == 2 && exitingMembers == 1 && tail.selector != null
				&& tail.successors.length == 2 ? tail.selector : null;
			final parts:Array<Region> = [];
			for (node in nodes) append(parts, node);
			var depth = 0;
			for (part in parts) if (part.depth >= depth) depth = part.depth + 1;
			if (depth > MAX_DEPTH) continue;
			// A run holding a computed transfer stays uncuttable: a loop formed around it could
			// need a `break` inside the table's `switch`, which on C++ would leave the switch.
			var computed = false;
			for (node in nodes) if (node.computed) computed = true;
			replace(new Region(Sequence(parts), nodes[0].entry, members(nodes), exits, selector,
				exits.length <= 1, depth, computed), nodes);
			sequences++;
			return true;
		}
		return false;
	}

	/**
		One natural loop, when its body collapses. A header dominates every block of its loop,
		so the loop has one entry; returns are not exits, and every other way out becomes a
		recorded `break`. Cutting the back-edges and the exit edges from the members and reducing
		what remains as its own sub-plan answers whether the body is one region — and a nested
		loop inside the body is reduced by that sub-plan, so inner loops come first by
		construction.
	**/
	function reduceLoop(incoming:Map<Int, Array<Int>>):Bool {
		final dom = dominators(incoming);
		for (head in roots) {
			final members = naturalLoop(head, incoming, dom);
			if (members == null) continue;
			final inside:Map<Int, Bool> = [];
			for (member in members) inside.set(member.entry, true);
			final exits:Array<Int> = [];
			for (member in members) for (target in member.successors) {
				if (inside.exists(owners.get(target).entry)) continue;
				if (exits.indexOf(target) < 0) exits.push(target);
			}
			final cut:Array<Region> = [];
			var cuttable = true;
			for (member in members) {
				final view = cutEdges(member, head.entry, exits);
				if (view == null) cuttable = false;
				else cut.push(view);
			}
			if (!cuttable) continue;
			final sub = new RegionPlan(ir, cut, head.entry);
			if (sub.roots.length != 1 || sub.roots[0].successors.length != 0) continue;
			final body = sub.roots[0];
			if (body.depth + 1 > MAX_DEPTH) continue;
			replace(new Region(Loop(body, exits), head.entry, body.members.copy(),
				exits.copy(), null, exits.length <= 1, body.depth + 1), members);
			sequences += sub.sequences;
			choices += sub.choices;
			loops += sub.loops + 1;
			return true;
		}
		return false;
	}

	/**
		A member's view of its loop: edges to the header and to the exits are removed, leaving
		the internal continuation if there is one. A conditional that lost an arm now follows
		its remaining target, because the emitter renders the lost arm as `continue` or `break`
		and falls into the other. A computed transfer cannot be cut and makes the loop stay.
	**/
	static function cutEdges(region:Region, header:Int, exits:Array<Int>):Null<Region> {
		final keep = [for (target in region.successors)
			if (target != header && exits.indexOf(target) < 0) target];
		if (keep.length == region.successors.length) return region;
		if (region.computed) return null;
		return new Region(region.body, region.entry, region.members, keep,
			keep.length == 2 ? region.selector : null, keep.length <= 1, region.depth);
	}

	/**
		The members of the natural loop whose header is `head`: the header plus everything that
		reaches one of its back-edges without passing through it. Null when no back-edge enters
		this header from a region it dominates, or when the header is unreachable from the entry
		(an interior-only entry, which the dispatcher keeps addressable).
	**/
	function naturalLoop(head:Region, incoming:Map<Int, Array<Int>>,
			dom:Map<Int, Map<Int, Bool>>):Null<Array<Region>> {
		final h = head.entry;
		if (!dom.exists(h)) return null;
		final inside:Map<Int, Bool> = [h => true];
		final stack:Array<Int> = [];
		var backEdges = 0;
		for (from in incoming.get(h)) {
			final d = dom.get(from);
			if (d == null || !d.exists(h)) continue;
			backEdges++;
			if (!inside.exists(from)) {
				inside.set(from, true);
				stack.push(from);
			}
		}
		if (backEdges == 0) return null;
		while (stack.length > 0) {
			final at = stack.pop();
			for (from in incoming.get(at)) {
				if (inside.exists(from)) continue;
				inside.set(from, true);
				stack.push(from);
			}
		}
		return [for (root in roots) if (inside.exists(root.entry)) root];
	}

	/**
		Dominators over the region graph from the plan's entry, by the textbook iteration: a
		node is dominated by itself and by whatever dominates all of its predecessors. Regions
		the entry cannot reach get no set, and are never loop members.
	**/
	function dominators(incoming:Map<Int, Array<Int>>):Map<Int, Map<Int, Bool>> {
		final start = owners.get(entryAddr).entry;
		final order:Array<Int> = [];
		final seen:Map<Int, Bool> = [];
		final stack = [start];
		while (stack.length > 0) {
			final at = stack.pop();
			if (seen.exists(at)) continue;
			seen.set(at, true);
			order.push(at);
			for (target in owners.get(at).successors) stack.push(owners.get(target).entry);
		}
		final dom:Map<Int, Map<Int, Bool>> = [];
		for (node in order) {
			final set:Map<Int, Bool> = [];
			if (node == start) set.set(node, true);
			else for (other in order) set.set(other, true);
			dom.set(node, set);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (node in order) {
				if (node == start) continue;
				var next:Null<Map<Int, Bool>> = null;
				for (from in incoming.get(node)) {
					final d = dom.get(from);
					if (d == null) continue;
					if (next == null) next = [for (key in d.keys()) key => true];
					else for (key in [for (key in next.keys()) key]) if (!d.exists(key)) next.remove(key);
				}
				if (next == null) next = [];
				next.set(node, true);
				if (!sameKeys(next, dom.get(node))) {
					dom.set(node, next);
					changed = true;
				}
			}
		}
		return dom;
	}

	static function sameKeys(a:Map<Int, Bool>, b:Map<Int, Bool>):Bool {
		var count = 0;
		for (key in a.keys()) {
			if (!b.exists(key)) return false;
			count++;
		}
		for (_ in b.keys()) count--;
		return count == 0;
	}

	static function append(parts:Array<Region>, node:Region):Void {
		switch (node.body) {
			case Sequence(children): for (child in children) parts.push(child);
			case _: parts.push(node);
		}
	}

	static function endsAt(node:Region, target:Int):Bool
		return node.follows && node.successors.length == 1 && node.successors[0] == target;

	function choice(head:Region, taken:Null<Region>, other:Null<Region>, join:Null<Int>):Bool {
		final nodes = [head];
		if (taken != null) nodes.push(taken);
		if (other != null) nodes.push(other);
		var depth = 0;
		for (node in nodes) if (node.depth >= depth) depth = node.depth + 1;
		if (depth > MAX_DEPTH) return false;
		replace(new Region(Choice(head, taken, other, join), head.entry, members(nodes),
			join == null ? [] : [join], null, true, depth), nodes);
		choices++;
		return true;
	}

	static function members(nodes:Array<Region>):Array<Int> {
		final ids = [];
		for (node in nodes) for (id in node.members) ids.push(id);
		ids.sort((a, b) -> a - b);
		return ids;
	}

	function replace(region:Region, old:Array<Region>):Void {
		for (node in old) roots.remove(node);
		for (id in region.members) owners.set(ir.blocks[id].addr, region);
		roots.push(region);
		roots.sort((a, b) -> a.entry - b.entry);
	}
}
