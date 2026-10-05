package recomp.codegen;

/** Shared emission of the observation boundary around a state-free scalar computation.
    Borrowed-span adapters are ordinary entry glue, not guest-addressable functions. */
class ScalarEntry {
	/** No internal guest call may reach a pump, suspension or pre-existing unwind. Bounds
	    cover the entire DAG/call tree, including paths not taken; equality takes fallback. */
	public static function callWindow(cycles:Int):String {
		return '(ctx.unwindToken == 0 && ((ctx.cycles - core.Runtime.deadline(ctx)) | 0) < -$cycles'
			+ '\n\t\t#if recompsx_cooperative\n'
			+ '\t\t&& (!core.Cooperative.enabled || (core.Cooperative.every <= 0'
			+ ' && ((ctx.cycles - core.Cooperative.deadline) | 0) < -$cycles))'
			+ '\n\t\t#end\n\t\t)';
	}
	public static function slowGuard(ind:String, projected:Bool = false, ?extra:String):String {
		final buf = new StringBuf();
		buf.add('${ind}if (shim.MemA.unlikely(((ctx.cycles - core.Runtime.deadline(ctx)) | 0) >= 0)\n');
		if (projected) buf.add('${ind}\t|| ctx.unwindToken != 0\n');
		if (extra != null) buf.add('${ind}\t|| !($extra)\n');
		buf.add('${ind}\t#if recompsx_cooperative\n');
		buf.add('${ind}\t|| core.Cooperative.resumeEntry >= 0\n');
		buf.add('${ind}\t|| (core.Cooperative.enabled && (core.Cooperative.every > 0\n');
		buf.add('${ind}\t\t|| ((ctx.cycles - core.Cooperative.deadline) | 0) >= 0))\n');
		buf.add('${ind}\t#end\n${ind}) {\n');
		return buf.toString();
	}
	public static function charges(plan:ScalarPlan, ind:String, cycles:String):String {
		final buf = new StringBuf();
		if (plan.accounting == null) {
			if (plan.cycles > 0) buf.add('${ind}$cycles = ($cycles + ${plan.cycles}) | 0;\n');
			buf.add('${ind}#if recompsx_insns\n');
			buf.add('${ind}Runtime.insns = (Runtime.insns + ${plan.instructions}) | 0;\n');
			buf.add('${ind}Runtime.blocks = (Runtime.blocks + 1) | 0;\n');
		} else if (!plan.pathAccounting()) {
			// Every path costs the same: the packed word is a constant, charged lane by lane.
			final packed = plan.accounting.addressOffset;
			if ((packed & 1023) > 0) buf.add('${ind}$cycles = ($cycles + ${packed & 1023}) | 0;\n');
			buf.add('${ind}#if recompsx_insns\n');
			buf.add('${ind}Runtime.insns = (Runtime.insns + ${(packed >>> 10) & 1023}) | 0;\n');
			buf.add('${ind}Runtime.blocks = (Runtime.blocks + ${packed >>> 20}) | 0;\n');
		} else {
			// Consume the ABI word immediately after the helper, before any observation/call.
			buf.add('${ind}final scalarAccounting = core.ScalarResult.accounting;\n');
			buf.add('${ind}$cycles = ($cycles + (scalarAccounting & 1023)) | 0;\n');
			buf.add('${ind}#if recompsx_insns\n');
			buf.add('${ind}Runtime.insns = (Runtime.insns + ((scalarAccounting >>> 10) & 1023)) | 0;\n');
			buf.add('${ind}Runtime.blocks = (Runtime.blocks + (scalarAccounting >>> 20)) | 0;\n');
		}
		buf.add('${ind}#end\n');
		return buf.toString();
	}
	/** Caller-specific result liveness changes only the helper, never its original access
	    preflight. Failed checks run the complete original entry before any guest effects. */
	public static function projectedAdapter(plan:ScalarPlan, fallbackOwner:String):String {
		if (plan.memory == null || plan.omitted == 0) return '';
		final fallback = fallbackOwner + '.' + plan.name + '(ctx);\n';
		final buf = new StringBuf();
		buf.add('\tpublic static function ${plan.projectedName()}(ctx:core.Ctx):Void {\n');
		buf.add(slowGuard('\t\t', true, plan.horizon == 0 ? null : callWindow(plan.horizon)));
		buf.add('\t\t\t' + fallback + '\t\t} else {\n');
		buf.add(plan.memory.guard('\t\t\t'));
		buf.add(plan.apply('\t\t\t\t'));
		buf.add(charges(plan, '\t\t\t\t', 'ctx.cycles'));
		buf.add('\t\t\t\treturn;\n\t\t\t} else {}\n');
		buf.add('\t\t\t' + fallback + '\t\t}\n\t}\n');
		return buf.toString();
	}
	/** Callers pass spans anchored at the callee's input registers. Coverage is a build-time
	    proof; validity and alignment are checked here before applying the callee's own offset. */
	public static function borrowedAdapter(plan:ScalarPlan, ?owner:String, ?fallbackOwner:String):String {
		if (plan.memory == null) return '';
		// Constants and loaded addresses have no incoming register/span to borrow ($zero
		// is not a CpuState field). Their entries must construct the complete preflight.
		for (span in plan.memory.spans) if (span.base <= 0) return '';
		final params = ['ctx:core.Ctx']; final args = ['ctx']; final values = []; final conditions = [];
		for (i in 0...plan.memory.spans.length) {
			final span = plan.memory.spans[i]; final name = 'checked$i';
			params.push('$name:shim.Span'); args.push(name);
			conditions.push(span.borrowedCondition(name));
			values.push(span.offset == 0 ? name : 'Memory.spanOffset($name, ${span.offset})');
		}
		for (condition in plan.memory.separationConditions(name -> {
			for (i in 0...plan.memory.spans.length) {
				final span = plan.memory.spans[i];
				if (span.name == name) return {name:'checked$i', delta:span.offset};
			}
			throw 'unknown checked span $name';
		})) conditions.push(condition);
		if (plan.horizon > 0) conditions.push('(' + callWindow(plan.horizon) + ')');
		final buf = new StringBuf();
		buf.add('\tpublic static function ${plan.borrowedName()}(' + params.join(', ') + '):Void {\n');
		if (owner != null) buf.add('\t\t$owner.${plan.borrowedName()}(' + args.join(', ') + ');\n');
		else {
			buf.add(slowGuard('\t\t', plan.omitted != 0, conditions.join(' && ')));
			final fallback = fallbackOwner == null ? plan.name : fallbackOwner + '.' + plan.name;
			buf.add('\t\t\t$fallback(ctx);\n\t\t} else {\n');
			buf.add(plan.apply('\t\t\t', null, null, values));
			buf.add(charges(plan, '\t\t\t', 'ctx.cycles'));
			buf.add('\t\t}\n');
		}
		buf.add('\t}\n');
		return buf.toString();
	}
}
