package recomp.codegen;

import recomp.codegen.Emitter.FunctionSpan;
import recomp.codegen.ScalarPlan.ScalarMemory;
import recomp.analysis.CallAliases;

/** A direct call can borrow existing function spans only when they cover every callee
    access. Their registers become uses in the caller's span liveness AFTER the delay slot.
    Runtime validity/alignment and the ordinary entry-observation guard still apply. */
class ScalarBorrow {
	public final registers:Int;
	/** Spans anchored at callee input values. Affine aliases shift valid donor spans only. */
	public final args:Array<String>;
	function new(registers:Int, args:Array<String>) {
		this.registers = registers; this.args = args;
	}
	public static function analyze(memory:ScalarMemory, available:Null<Map<Int, FunctionSpan>>, ?aliases:CallAliases):Null<ScalarBorrow> {
		if (available == null) return null;
		var registers = 0; final args = [];
		for (span in memory.spans) {
			if (span.base <= 0) return null;
			var donor = span.base; var delta = 0; var existing = available.get(donor);
			if (existing == null || !span.coveredBy(existing.lo, existing.hi)) {
				existing = null;
				if (aliases != null) for (r in 1...32) {
					final candidate = available.get(r); if (candidate == null) continue;
					final offset = aliases.difference(span.base, r); if (offset == null) continue;
					// A shifted pointer itself must stay in the checked range, even before
					// the callee adds its own offset. Bound subtractions before range tests.
					if (offset != 0 && (offset < candidate.lo || offset > candidate.hi)) continue;
					if (!span.coveredBy(candidate.lo - offset, candidate.hi - offset)) continue;
					donor = r; delta = offset; existing = candidate; break;
				}
			}
			if (existing == null) return null;
			registers |= 1 << donor;
			// Never perform pointer arithmetic on a failed C++ span. The shared adapter
			// receives a span anchored at the callee input, or none and takes full fallback.
			args.push(delta == 0 ? existing.v : '(Memory.spanOk(${existing.v}) ? Memory.spanOffset(${existing.v}, $delta) : Memory.spanNone())');
		}
		return new ScalarBorrow(registers, args);
	}
}
