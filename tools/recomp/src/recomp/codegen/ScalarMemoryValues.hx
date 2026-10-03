package recomp.codegen;

import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.codegen.ScalarPlan.ScalarWrite;

/** Build-time memory values within one fully preflighted acyclic helper. A checked span is
    contiguous backing storage: disjoint byte ranges in that span cannot alias. Distinct spans
    carry no such promise; guarded call trees can defer the proof to an entry exclusion. */
class ScalarMemoryValues {
	var known:Array<MemoryValue> = [];
	public function new() {}
	/** Snapshot a path's facts. Entries are immutable and stores replace the array. */
	public function copy():ScalarMemoryValues {
		final result = new ScalarMemoryValues(); result.known = known.copy(); return result;
	}
	/** Only byte facts valid on EVERY incoming path survive a join. Neither a shared
	    address nor a similar expression proves equal values; immutable SSA identity does. */
	public static function intersect(paths:Array<ScalarMemoryValues>):ScalarMemoryValues {
		final result = new ScalarMemoryValues();
		if (paths.length == 0) return result;
		for (value in paths[0].known) {
			var present = true;
			final excluded = value.excluded.copy();
			for (i in 1...paths.length) {
				final matches = paths[i].known.filter(other -> other.span == value.span
					&& other.offset == value.offset && other.width == value.width
					&& other.extension == value.extension && other.value.equivalent(value.value));
				if (matches.length == 0) {
					present = false; break;
				}
				for (write in matches[0].excluded) excluded.push(write);
			}
			if (present) result.known.push(new MemoryValue(value.span, value.offset, value.width,
				value.value, value.extension, excluded));
		}
		return result;
	}

	/** Every write remains an emitted effect. Same-view overlaps invalidate values. Other
	    views invalidate them too unless guarded call-tree recovery explicitly defers proof. */
	public function store(span:String, offset:Int, width:Int, value:ScalarValue, guarded:Bool = false):Void {
		invalidate(span, offset, width, guarded);
		remember(span, offset, width, value, -1);
	}

	/** A callee's may-write range never supplies a new known value. Same-view overlaps kill
	    facts; other views kill them unless a call tree may request an explicit alias guard. */
	public function invalidate(span:String, offset:Int, width:Int, guarded:Bool = false):Void {
		final remaining:Array<MemoryValue> = [];
		for (v in known) {
			if (v.span == span) {
				if (offset + width <= v.offset || v.offset + v.width <= offset) remaining.push(v);
			} else if (guarded) {
				final excluded = v.excluded.copy(); excluded.push(new ScalarWrite(span, offset, width));
				remaining.push(new MemoryValue(v.span, v.offset, v.width, v.value, v.extension, excluded));
			}
		}
		known = remaining;
	}

	/** -1: unnormalized store input; 0: unsigned load; 1: signed load. Only the stored low
	    width bytes are memory facts; extension bits are relevant solely to exact value reuse. */
	public function remember(span:String, offset:Int, width:Int, value:ScalarValue, extension:Int):Void {
		known.push(new MemoryValue(span, offset, width, value, extension));
	}

	public function load(span:String, offset:Int, width:Int, signed:Bool, graph:ScalarGraph):Null<ScalarValue> {
		var n = known.length;
		while (n > 0) {
			final v = known[--n];
			if (v.span != span || offset < v.offset || offset + width > v.offset + v.width) continue;
			// A potentially aliased write is not a fact until whole-helper preflight proves
			// it disjoint. Only a reused value requests these guards; dead facts add no work.
			if (v.excluded.length > 0 && graph.memory == null) continue;
			var proved = true;
			for (write in v.excluded) if (!graph.memory.requireSeparate(
				new ScalarWrite(v.span, v.offset, v.width), write)) { proved = false; break; }
			if (!proved) continue;
			final shift = (offset - v.offset) * 8;
			if (width == 4 || (shift == 0 && width == v.width && v.extension == (signed ? 1 : 0))) return v.value;
			// PS1 memory is little endian. Shift before truncation/sign extension; never reuse
			// the upper bits of a byte/halfword store's source as if they had been written.
			// The final truncation discards the high bits, so arithmetic shift is sufficient.
			// Do not use >>> here: reflaxe.CPP leaves its nested expression unsigned, which
			// would turn the sign-extending >> below into a logical shift too.
			final bits = shift == 0 ? v.value.ref : '(${v.value.ref} >> $shift)';
			final expr = signed ? '(($bits) << ${32 - width * 8}) >> ${32 - width * 8}'
				: '($bits) & ${width == 1 ? 255 : 65535}';
			// The forwarded expression equals this exact guest read, including its new
			// width and extension. Keep that version for pointer/return proofs without
			// emitting a second load. Its own prefix writes still decide whether it may
			// ever use an entry sample; an overlapping earlier store must reject that.
			final read = graph.memory.read(new ScalarWrite(span,offset,width),signed,graph.memory.stores);
			return graph.forwardRead(expr,v.value,read);
		}
		return null;
	}
}

private class MemoryValue {
	public final span:String;
	public final offset:Int;
	public final width:Int;
	public final value:ScalarValue;
	public final extension:Int;
	public final excluded:Array<ScalarWrite>;
	public function new(span:String, offset:Int, width:Int, value:ScalarValue, extension:Int, ?excluded:Array<ScalarWrite>) {
		this.span = span; this.offset = offset; this.width = width; this.value = value; this.extension = extension;
		this.excluded = excluded == null ? [] : excluded;
	}
}
