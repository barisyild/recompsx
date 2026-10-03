package recomp.codegen;

import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.codegen.ScalarPlan.ScalarMemory;
import recomp.codegen.ScalarPlan.ScalarWrite;

/** A resolved, effect-bounded call with explicit inputs/results. This composes signatures,
    never inlines the callee's body or assumes ABI-preserved registers/stack slots. */
@:access(recomp.codegen.ScalarPlan)
@:access(recomp.codegen.ScalarGraph)
class ScalarCall {
	public final plan:ScalarPlan;
	final owner:String;
	public function new(plan:ScalarPlan, owner:String) { this.plan = plan; this.owner = owner; }
	public function lift(graph:ScalarGraph, regs:Array<ScalarValue>):Null<ScalarValue> {
		final before = regs.copy(); final predicate = graph.memoryPredicate;
		final deps = [for (r in plan.inputs) before[r]];
		final args = [for (v in deps) v.ref];
		final memoryUses:Array<String> = [];
		final prepared:Map<String,ScalarValue> = [];
		var imported:Null<ScalarCallMemory> = null;
		function sample(read:ScalarRead):Null<ScalarValue> {
			if (prepared.exists(read.name)) return prepared.get(read.name);
			final root = imported.read(read); if (root == null) return null;
			final value = graph.load(root); prepared.set(read.name,value); return value;
		}
		if (plan.memory != null) {
			if (graph.memory == null) graph.memory = new ScalarMemory();
			imported = new ScalarCallMemory(plan.memory, graph.memory, before);
			for (span in plan.memory.spans) {
				final view = imported.view(span.name);
				if (view == null) return null;
			}
			for (span in plan.signature.spans) {
				final view = imported.view(span.name);
				args.push(view.delta == 0 ? view.name : 'Memory.spanOffset(${view.name}, ${view.delta})');
				memoryUses.push(view.name);
			}
			for (read in plan.signature.samples) {
				// The child's proof makes this read valid at call entry, before its prefix
				// writes. Parent lowering may replace it by its own checked entry sample.
				final value = sample(read); if (value == null) return null;
				deps.push(value); args.push(value.ref);
			}
			// Boundary-only outputs need no helper parameter or result word. Capture their
			// own read versions before child writes; never substitute another version just
			// because preflight coalesces their equal numeric samples.
			for (value in plan.outputValues) if (ScalarPlan.sampleResult(value) && sample(value.sampleRead) == null) return null;
			// A returned pointer may not have been dereferenced in the child. Preserve its
			// exact read version now; activate its entry proof only if the parent uses it.
			for (value in plan.outputValues) if (value.addressRead != null && imported.read(value.addressRead) == null) return null;
			// May-writes include every callee path, whether or not this invocation takes it.
			// Same-view disjoint bytes need no extra guard. Different views may alias through
			// guest RAM mirrors or arbitrary inputs and require an explicit entry exclusion.
			for (write in plan.memory.stores) {
				final effect = imported.access(write);
				if (effect == null) return null;
				graph.memory.recordWrite(effect.span, effect.offset, effect.width);
				if (graph.memoryValues != null) graph.memoryValues.invalidate(effect.span, effect.offset, effect.width, graph.guardMemoryAliases);
			}
			// A composed helper must carry all of its child's alias preconditions too.
			for (pair in plan.memory.separations) {
				final a = imported.access(pair.a); final b = imported.access(pair.b);
				if (a == null || b == null || !graph.memory.requireSeparate(a,b)) return null;
			}
		}
		if (predicate != null) deps.push(predicate);
		final expression = '$owner.${plan.helperName()}(' + args.join(', ') + ')';
		final statement = plan.result == null;
		final expr = predicate == null ? expression : statement
			? 'if (${predicate.ref}) { $expression; } else {}' : '${predicate.ref} ? $expression : 0';
		final primary = plan.result;
		final call = new ScalarValue('value${graph.values.length}', deps, expr, -1,
			primary == null ? 0 : primary.addressOffset, statement,
			primary == null || primary.addressRead == null ? null : imported.read(primary.addressRead));
		// Numeric equality is a body proof distinct from address provenance. It may
		// become usable only when the parent later proves this read's entry source.
		// Conditional invocations cannot export unconditional equality.
		if (predicate == null && primary != null && primary.sampleRead != null) call.sampleRead = imported.read(primary.sampleRead);
		for (name in memoryUses) call.memoryUses.push(name);
		graph.values.push(call);
		// A child's GTE accesses are the parent's too, in the call's place in program order.
		if (plan.coprocessor) graph.coprocessor = true;
		if ((plan.memory != null && plan.memory.writes) || plan.coprocessor) graph.effects.push(call);
		final returned = [call];
		// Capture every ABI word before another call can overwrite it. Dependencies retain
		// the call even when only a secondary result or its path accounting is live.
		for (i in 1...plan.results.length) {
			final value = plan.results[i];
			final word = new ScalarValue('value${graph.values.length}', [call], predicate == null
				? 'core.ScalarResult.value$i' : '${predicate.ref} ? core.ScalarResult.value$i : 0',
				-1, value.addressOffset, false, value.addressRead == null ? null : imported.read(value.addressRead));
			if (predicate == null && value.sampleRead != null) word.sampleRead = imported.read(value.sampleRead);
			graph.values.push(word); returned.push(word);
		}
		for (i in 0...plan.outputs.length) {
			final value = plan.outputValues[i]; final slot = plan.results.indexOf(value);
			regs[plan.outputs[i]] = value.addressBase >= 0 ? affine(graph, before[value.addressBase], value.addressOffset)
				: ScalarPlan.sampleResult(value) ? affine(graph, prepared.get(value.sampleRead.name), value.addressOffset) : returned[slot];
		}
		if (plan.accounting != null && plan.accounting.addressBase != 0) return graph.make(predicate == null
			? 'core.ScalarResult.accounting' : '${predicate.ref} ? core.ScalarResult.accounting : 0', [call]);
		// A proved fixed charge does not require executing a dead read-only child just
		// to fetch its ABI word. Effects and any live numeric result still root the call.
		final packed = plan.accounting != null ? plan.accounting.addressOffset : plan.cycles | (plan.instructions << 10) | (1 << 20);
		return predicate == null ? new ScalarValue(Std.string(packed), [], null, 0, packed)
			: graph.make('${predicate.ref} ? $packed : 0', [predicate]);
	}
	static function affine(graph:ScalarGraph, base:ScalarValue, offset:Int):ScalarValue {
		if (offset == 0) return base;
		final value = new ScalarValue('value${graph.values.length}', [base], '(${base.ref} + $offset) | 0',
			base.addressBase, base.hasAddress() ? (base.addressOffset + offset) | 0 : 0, false, base.addressRead);
		value.sampleRead = base.sampleRead;
		graph.values.push(value); return value;
	}
}

/** Translate the child's dependency graph, including read versions not yet used as
    pointers. Every invocation owns fresh versions and includes only writes before that
    read: the caller's prefix plus the child's prefix, never its later writes. */
private class ScalarCallMemory {
	final child:ScalarMemory;
	final parent:ScalarMemory;
	final regs:Array<ScalarValue>;
	final before:Array<ScalarWrite>;
	final views:Map<String, {name:String, delta:Int}> = [];
	final reads:Map<String, ScalarRead> = [];
	final resolving:Map<String, Bool> = [];
	public function new(child:ScalarMemory, parent:ScalarMemory, regs:Array<ScalarValue>) {
		this.child = child; this.parent = parent; this.regs = regs; before = parent.stores.copy();
	}
	public function view(name:String):Null<{name:String, delta:Int}> {
		if (views.exists(name)) return views.get(name);
		if (resolving.exists(name)) return null;
		resolving.set(name,true);
		final span = child.spanNamed(name);
		var root:Null<ScalarRead> = null;
		var base = -1; var offset = span.offset;
		if (span.read != null) {
			root = read(span.read);
			if (root == null) return null;
		} else {
			final value = regs[span.base];
			if (!value.hasAddress()) return null;
			base = value.addressBase; root = value.addressRead;
			offset = (offset + value.addressOffset) | 0;
		}
		final mapped = parent.include(span,base,offset,root);
		if (mapped == null) return null;
		views.set(name,mapped); resolving.remove(name); return mapped;
	}
	public function access(value:ScalarWrite):Null<ScalarWrite> {
		final mapped = view(value.span);
		return mapped == null ? null : new ScalarWrite(mapped.name,mapped.delta+value.offset,value.width);
	}
	public function read(value:ScalarRead):Null<ScalarRead> {
		if (reads.exists(value.name)) return reads.get(value.name);
		final source = access(value.source);
		if (source == null) return null;
		final writes = before.copy();
		for (write in value.before) {
			final mapped = access(write);
			if (mapped == null) return null;
			writes.push(mapped);
		}
		final root = parent.read(source,value.signed,writes);
		reads.set(value.name,root); return root;
	}
}
