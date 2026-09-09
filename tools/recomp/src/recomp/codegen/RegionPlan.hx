package recomp.codegen;

import recomp.ir.FunctionIR;
import recomp.ir.FunctionIR.BlockIR;

/** A tree owns each block once; its members are the original, stable resume IDs. */
enum RegionBody {
	Block(block:BlockIR);
	Sequence(parts:Array<Region>);
	Choice(head:Region, taken:Null<Region>, notTaken:Null<Region>, join:Null<Int>);
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
	public final depth:Int;

	public function new(body:RegionBody, entry:Int, members:Array<Int>, successors:Array<Int>,
			selector:Null<BlockIR>, follows:Bool, depth:Int) {
		this.body = body;
		this.entry = entry;
		this.members = members;
		this.successors = successors;
		this.selector = selector;
		this.follows = follows;
		this.depth = depth;
	}
}

/**
	Reduce single-entry regions, keeping arbitrary block resumes and irreducible CFGs intact.
	A sequence removes an edge whose destination has one predecessor. A choice consumes arms
	owned solely by its header and meeting at one continuation (or both leaving the function).
	Computed transfers retain their target checks. There are no game addresses or ABI guesses.
**/
class RegionPlan {
	public final roots:Array<Region> = [];
	public var sequences(default, null):Int = 0;
	public var choices(default, null):Int = 0;
	final ir:FunctionIR;
	final owners:Map<Int, Region> = [];
	static inline final MAX_DEPTH = 32;

	public function new(ir:FunctionIR) {
		this.ir = ir;
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
				block.conditional() && loopExit == null ? block : null, follows, 0);
			roots.push(region);
			owners.set(block.addr, region);
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
		for (head in roots) {
			if (!head.follows || head.successors.length != 1) continue;
			final target = head.successors[0];
			final next = owners.get(target);
			if (next.entry != target || !onlyFrom(next, head, incoming)) continue;
			final parts:Array<Region> = [];
			append(parts, head); append(parts, next);
			var depth = 0;
			for (part in parts) if (part.depth >= depth) depth = part.depth + 1;
			if (depth > MAX_DEPTH) continue;
			replace(new Region(Sequence(parts), head.entry, members([head, next]),
				next.successors.copy(), next.selector, next.follows, depth), [head, next]);
			sequences++;
			return true;
		}
		return false;
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
