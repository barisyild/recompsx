package recomp.codegen;

import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.codegen.ScalarPlan.ScalarMemory;
import recomp.codegen.ScalarPlan.ScalarSpan;

/** Lower live helper inputs after the complete memory proof. Entry samples can replace
    only active read versions; all original spans remain in the preflight regardless of
    which ones the helper body needs. No runtime tuple or extra result ABI is introduced. */
class ScalarSignature {
	public final spans:Array<ScalarSpan>;
	public final samples:Array<ScalarRead> = [];
	final selected:Map<String, ScalarRead> = [];
	public function new(inputs:Int, values:Array<ScalarValue>, memory:Null<ScalarMemory>) {
		if (memory == null) { spans = []; return; }
		final candidates:Array<ScalarRead> = [];
		final seen:Map<String,Bool> = [];
		for (value in values) if (value.load != null && value.load.active) {
			final read = value.load; final key = read.sampleKey();
			if (!seen.exists(key)) { seen.set(key,true); candidates.push(read); }
		}
		// Prefer samples which remove a span argument, then those replacing more live
		// loads. A sample which would exceed the existing six-argument budget stays a
		// checked load inside the helper; it must not make an old signature ineligible.
		while (candidates.length != 0) {
			var best:Null<ScalarRead> = null; var bestCost = 0x7fffffff; var bestLoads = -1;
			for (candidate in candidates) {
				selected.set(candidate.sampleKey(),candidate);
				final cost = inputs + samples.length + 1 + usedSpans(values,memory).length;
				selected.remove(candidate.sampleKey());
				var loads = 0;
				for (value in values) if (value.load != null && value.load.active && value.load.sampleKey() == candidate.sampleKey()) loads++;
				if (cost <= 6 && (cost < bestCost || cost == bestCost && loads > bestLoads)) {
					best = candidate; bestCost = cost; bestLoads = loads;
				}
			}
			if (best == null) break;
			selected.set(best.sampleKey(),best); samples.push(best); candidates.remove(best);
		}
		spans = usedSpans(values,memory);
	}
	function sampled(value:ScalarValue):Null<ScalarRead> {
		return value.load != null && value.load.active ? selected.get(value.load.sampleKey()) : null;
	}
	function usedSpans(values:Array<ScalarValue>, memory:ScalarMemory):Array<ScalarSpan> {
		final used:Map<String,Bool> = [];
		for (value in values) if (sampled(value) == null) for (name in value.memoryUses) used.set(name,true);
		return [for (span in memory.spans) if (used.exists(span.name)) span];
	}
	public function expression(value:ScalarValue):Null<String> {
		final sample = sampled(value);
		if (sample == null) return value.expr;
		return value.loadPredicate == null ? sample.name : '${value.loadPredicate.ref} ? ${sample.name} : 0';
	}
}
