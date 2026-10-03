package recomp.codegen;

import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.ir.FunctionIR;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.codegen.ScalarGraph.ScalarValue;

/**
	A bounded value-SSA lift for linear leaves and acyclic call trees (ADR-0044). Each register definition
	gets a value; moves share values. All final register values are outputs, including the
	ABI's scratch registers. Unique computed results cross an allocation-free return ABI;
	constants, aliases, affine incoming values and proved entry samples are reconstructed at
	the call boundary. Only unconditional sample equality permits omitting a result word.
	The default requires all outputs, while caller projections prove specific outputs dead.
	Memory accesses are admitted behind checked plain-memory spans. Ordered writes are roots
	in the value graph, independent of register results. No calling-convention assumptions,
	heap tuples or CpuState in helpers.
**/
class ScalarPlan {
	/** Bound proof construction separately from the code which survives value recovery. */
	static inline final MAX_INSTRUCTIONS = 256;
	static inline final MAX_BODY_COST = 96;
	public final name:String;
	public final inputs:Array<Int>;
	public final outputs:Array<Int>;
	final outputValues:Array<ScalarValue>;
	final results:Array<ScalarValue>;
	public final cycles:Int;
	public final instructions:Int;
	public final memory:Null<ScalarMemory>;
	public final signature:ScalarSignature;
	/** Non-null for an acyclic CFG with path-dependent guest accounting. */
	public final accounting:Null<ScalarValue>;
	/** Outputs omitted only in a caller-specific version, proved dead before any observation. */
	public final omitted:Int;
	/** Whole acyclic call-tree bounds; nonzero horizon requires no internal observation. */
	public final bounds:ScalarBounds;
	public final horizon:Int;
	/** The helper reads or writes the GTE's registers (ScalarGraph.coprocessor): its body keeps
	    program order, and it is never pooled as a pure computation. */
	public final coprocessor:Bool;
	final suffix:String;
	final values:Array<ScalarValue>;
	final result:Null<ScalarValue>;

	function new(name:String, inputs:Array<Int>, outputs:Array<Int>, outputValues:Array<ScalarValue>, results:Array<ScalarValue>, block:recomp.ir.FunctionIR.BlockIR,
			values:Array<ScalarValue>, memory:Null<ScalarMemory>, signature:ScalarSignature, omitted:Int, suffix:String,
			coprocessor:Bool, ?accounting:ScalarValue, ?bounds:ScalarBounds) {
		this.coprocessor = coprocessor;
		this.name = name;
		this.inputs = inputs;
		this.outputs = outputs; this.outputValues = outputValues; this.results = results;
		this.cycles = block.cycles;
		this.instructions = block.instructions.length;
		this.values = values;
		this.result = results.length == 0 ? null : results[0];
		this.memory = memory;
		this.signature = signature;
		this.omitted = omitted;
		this.suffix = suffix;
		this.accounting = accounting;
		this.bounds = bounds == null ? {cycles:block.cycles, instructions:block.instructions.length, blocks:1, calls:false} : bounds;
		this.horizon = this.bounds.calls ? this.bounds.cycles : 0;
	}

	public static function analyze(fn:Func, image:Image, required:Int = 0xFFFFFFFE, suffix:String = "", ?callee:Int -> Null<ScalarCall>):Null<ScalarPlan> {
		if (!fn.blocks.keys().hasNext() || fn.instructionCount() > MAX_INSTRUCTIONS
				|| (callee == null && fn.checkedReturns.keys().hasNext())) return null;
		final ir = new FunctionIR(fn, image);
		if (ir.blocks.length != 1) return ScalarCfg.analyze(fn, ir, required, suffix, callee);
		if (fn.checkedReturns.keys().hasNext()) return null;
		final b = ir.blocks[0];
		if (b.successors.length != 0 || b.transfer == null || b.delaySlot == null
				|| b.transfer.decoded.op != Op.JR || b.transfer.decoded.rs != 31) return null;
		final graph = new ScalarGraph();
		final regs = graph.initial.copy();
		final body = b.body.copy(); body.push(b.delaySlot);
		for (x in body) if (!graph.lift(x, regs, true)) return null;
		return fromGraph(fn, graph, regs, b, required, suffix);
	}

	public static function fromGraph(fn:Func, graph:ScalarGraph, regs:Array<ScalarValue>,
			b:recomp.ir.FunctionIR.BlockIR, required:Int, suffix:String, ?accounting:ScalarValue, ?bounds:ScalarBounds):Null<ScalarPlan> {
		final initial = graph.initial; final values = graph.values; final memory = graph.memory;
		final outputs:Array<Int> = [];
		var omitted = 0;
		for (r in 1...32) if (!regs[r].equivalent(initial[r])) {
			if ((required & (1 << r)) == 0) { omitted |= 1 << r; continue; }
			outputs.push(r);
		}
		// A caller may discard every read result, but preflight and the original MMIO
		// fallback still observe those guest accesses. Such a projected helper is Void.
		if (outputs.length == 0 && graph.effects.length == 0 && (omitted == 0 || memory == null)) return null;
		final outputValues = [for (r in outputs) regs[r]];
		final results:Array<ScalarValue> = [];
		for (v in outputValues) if (v.addressBase < 0 && !sampleResult(v) && results.indexOf(v) < 0) results.push(v);
		// Pure-pool signatures retain their normal Int return. Memory and GTE helpers may return
		// Void when all outputs are already proved entry values, even with ordered effects.
		if (memory == null && !graph.coprocessor && results.length == 0 && outputValues.length != 0) results.push(outputValues[0]);
		for (v in results) ScalarGraph.mark(v);
		for (v in graph.effects) ScalarGraph.mark(v);
		if (accounting != null) ScalarGraph.mark(accounting);
		final inputs = [for (r in 1...32) if (initial[r].live) r];
		final live = [for (v in values) if (v.live) v];
		// Dead guest definitions and boundary-only values need no helper body. Charge
		// surviving SSA definitions/effects, output words and path accounting instead
		// of rejecting a compact recovered calculation by its original instruction count.
		if (live.length + results.length + (accounting == null ? 0 : 1) > MAX_BODY_COST) return null;
		final signature = new ScalarSignature(inputs.length,live,memory);
		if (inputs.length + signature.spans.length + signature.samples.length > 6) return null;
		// Dropping unused body parameters must not silently unbound entry preflight.
		if (memory != null && memory.spans.length > 6) return null;
		// Never specialize a known hardware address, or a constant span which cannot pass.
		if (memory != null && !memory.possible()) return null;
		return new ScalarPlan(fn.name, inputs, outputs, outputValues, results, b, live, memory, signature, omitted, suffix,
			graph.coprocessor, accounting, bounds);
	}

	/** Path-dependent accounting, returned in ScalarResult.accounting. A CFG whose every path
	    costs the same (one reachable path, or equal arms) has a constant word instead, which
	    callers charge directly: the helper neither stores it nor needs its result kept apart. */
	public function pathAccounting():Bool return accounting != null && accounting.addressBase != 0;

	public function helperName():String return name + "_value" + suffix;
	public function borrowedName():String return name + "_withSpans" + suffix;
	public function projectedName():String return name + "_projected" + suffix;
	static function sampleResult(value:ScalarValue):Bool return value.sampleRead != null && value.sampleRead.active;

	/** Exact calculation, with argument/value names normalized. Register destinations and
	    guest addresses belong to the caller. CFG accounting is part of the returned result,
	    so it participates in the key; fixed linear costs remain solely in the caller. */
	public function sharedBody():String {
		if (memory != null) throw 'memory helpers cannot enter the pure scalar pool';
		if (coprocessor) throw 'GTE helpers cannot enter the pure scalar pool';
		final names:Map<String, String> = [];
		final params = [];
		for (i in 0...inputs.length) {
			names.set(Instr.regName(inputs[i]), 'arg$i');
			params.push('arg$i:Int');
		}
		for (i in 0...values.length) names.set(values[i].ref, 'value$i');
		final tokens = ~/\b[A-Za-z_][A-Za-z0-9_]*\b/g;
		function rename(expr:String):String {
			return tokens.map(expr, token -> {
				final id = token.matched(0);
				// ABI members such as ScalarResult.value1 are not local SSA identifiers.
				final pos = token.matchedPos().pos;
				return names.exists(id) && (pos == 0 || expr.charAt(pos - 1) != '.') ? names.get(id) : id;
			});
		}
		final buf = new StringBuf();
		buf.add('(' + params.join(', ') + '):Int {\n');
		final path = pathAccounting();
		for (v in values) if (v != result || path || results.length > 1) buf.add('\t\tfinal ${names.get(v.ref)} = ${rename(v.expr)};\n');
		for (i in 1...results.length) buf.add('\t\tcore.ScalarResult.value$i = ${rename(results[i].ref)};\n');
		if (path) buf.add('\t\tcore.ScalarResult.accounting = ${rename(accounting.ref)};\n');
		buf.add('\t\treturn ' + rename(result.expr == null || path || results.length > 1 ? result.ref : result.expr) + ';\n\t}\n');
		return buf.toString();
	}

	/** No forced inline: the target compiler controls the size/speed tradeoff. */
	public function emitHelper(?owner:String):String {
		final buf = new StringBuf();
		final params = [for (r in inputs) Instr.regName(r) + ':Int'];
		final args = [for (r in inputs) Instr.regName(r)];
		for (span in signature.spans) { params.push(span.name + ':shim.Span'); args.push(span.name); }
		for (sample in signature.samples) { params.push(sample.name + ':Int'); args.push(sample.name); }
		buf.add('\tpublic static function ${helperName()}('
			+ params.join(', ') + '):${result == null ? "Void" : "Int"} {\n');
		if (owner != null) {
			buf.add('\t\t' + (result == null ? '' : 'return ') + '$owner.${helperName()}(' + args.join(', ') + ');\n');
		} else {
			// A final result can have been loaded before a later, possibly aliasing store, or
			// read from the GTE before a later write to it. Materialize it in instruction order
			// rather than moving its expression to return.
			final ordered = (memory != null && memory.writes) || coprocessor;
			final path = pathAccounting();
			for (v in values) {
				final expr = signature.expression(v);
				if (v.statement) buf.add('\t\t$expr;\n');
				else if (v != result || path || results.length > 1 || ordered) buf.add('\t\tfinal ${v.ref} = $expr;\n');
			}
			for (i in 1...results.length) buf.add('\t\tcore.ScalarResult.value$i = ${results[i].ref};\n');
			if (path) buf.add('\t\tcore.ScalarResult.accounting = ${accounting.ref};\n');
			if (result != null) buf.add('\t\treturn ${result.expr == null || path || results.length > 1 || ordered ? result.ref : signature.expression(result)};\n');
		}
		buf.add('\t}\n');
		return buf.toString();
	}

	public function apply(ind:String, ?owner:String, ?shared:String, ?memoryArgs:Array<String>):String {
		final prefix = owner == null ? "" : owner + ".";
		final args = [for (r in inputs) 'ctx.' + Instr.regName(r)];
		if (memory != null) {
			if (memoryArgs != null && memoryArgs.length != memory.spans.length) throw 'incomplete scalar memory arguments';
			for (span in signature.spans) args.push(memoryArgs == null ? span.name : memoryArgs[memory.spans.indexOf(span)]);
			for (sample in signature.samples) args.push(sample.name);
		}
		final target = shared == null ? prefix + helperName() : shared;
		if (outputs.length == 0) return '$ind$target(' + args.join(', ') + ');\n';
		if (outputs.length == 1 && results.length == 1) return '${ind}ctx.${Instr.regName(outputs[0])} = $target(' + args.join(', ') + ');\n';
		final buf = new StringBuf();
		final captured:Map<Int, Bool> = [];
		// A reconstructed input may itself be overwritten by another output. Capture once,
		// before any publication; no calling-convention preservation is assumed.
		for (v in outputValues) if (results.indexOf(v) < 0 && v.addressBase > 0 && !captured.exists(v.addressBase)) {
			captured.set(v.addressBase, true);
			buf.add('${ind}final scalarInput${v.addressBase} = ctx.${Instr.regName(v.addressBase)};\n');
		}
		buf.add(ind + (result == null ? '' : 'final scalarResult0 = ') + '$target(' + args.join(', ') + ');\n');
		for (i in 1...results.length) buf.add('${ind}final scalarResult$i = core.ScalarResult.value$i;\n');
		for (n in 0...outputs.length) {
			final v = outputValues[n]; final slot = results.indexOf(v);
			final expr = if (slot >= 0) 'scalarResult$slot';
				else if (v.addressBase == 0) Std.string(v.addressOffset);
				else if (v.addressBase > 0) v.addressOffset == 0 ? 'scalarInput${v.addressBase}' : '(scalarInput${v.addressBase} + ${v.addressOffset}) | 0';
				else if (sampleResult(v)) v.addressOffset == 0 ? v.sampleRead.name : '(${v.sampleRead.name} + ${v.addressOffset}) | 0';
				else throw 'unbound scalar output';
			buf.add('${ind}ctx.${Instr.regName(outputs[n])} = $expr;\n');
		}
		return buf.toString();
	}
}

/** Preflight every access before executing any guest instruction in the helper. Multiple
	spans may alias, including across RAM mirrors; their names never imply non-aliasing. */
class ScalarMemory {
	public final spans:Array<ScalarSpan> = [];
	public final reads:Array<ScalarRead> = [];
	/** Every possible write, including conditional and transitive child writes. Keeping
	    individual byte ranges preserves holes; a bounding interval would lose saved slots. */
	public final stores:Array<ScalarWrite> = [];
	/** Alias exclusions requested by values actually reused across possibly aliased writes. */
	public final separations:Array<{a:ScalarWrite, b:ScalarWrite}> = [];
	public var writes(get, never):Bool;
	function get_writes():Bool return stores.length != 0;
	public function new() {}
	public function read(source:ScalarWrite, signed:Bool, before:Array<ScalarWrite>):ScalarRead {
		final value = new ScalarRead('pointer${reads.length}', source, signed, before);
		reads.push(value); return value;
	}
	public function spanNamed(name:String):ScalarSpan {
		for (span in spans) if (span.name == name) return span;
		throw 'unknown scalar span $name';
	}
	/** Hoisting performs only checked RAM reads. Earlier writes must not change this
	    version; later writes may alias it because the real load still runs in order. */
	function useRead(read:ScalarRead):Bool {
		if (read.active) return true;
		for (write in read.before) if (!requireSeparate(read.source, write)) return false;
		read.active = true; return true;
	}
	public function recordWrite(span:String, offset:Int, width:Int):Void {
		for (old in stores) if (old.span == span && old.offset == offset && old.width == width) return;
		stores.push(new ScalarWrite(span, offset, width));
	}
	public function requireSeparate(a:ScalarWrite, b:ScalarWrite):Bool {
		if (a.span == b.span) return a.offset + a.width <= b.offset || b.offset + b.width <= a.offset;
		// disjoint(A,B) && disjoint(A,C) equals disjoint(A,union(B,C)) only when
		// B/C overlap or touch. Preserve holes, and repeat after merging either side.
		var i = 0;
		while (i < separations.length) {
			final old = separations[i];
			var joined:Null<ScalarWrite> = null;
			if (a.same(old.a)) joined = b.join(old.b);
			else if (a.same(old.b)) joined = b.join(old.a);
			if (joined != null) b = joined;
			else {
				if (b.same(old.a)) joined = a.join(old.b);
				else if (b.same(old.b)) joined = a.join(old.a);
				if (joined != null) a = joined;
			}
			if (joined == null) i++;
			else { separations.splice(i,1); i = 0; }
		}
		separations.push({a:a, b:b}); return true;
	}
	/** The supplied spans must all have passed validity/alignment before these conditions. */
	public function separationConditions(?view:String -> {name:String, delta:Int}):Array<String> {
		if (view == null) view = name -> {name:name, delta:0};
		return [for (pair in separations) {
			final a = view(pair.a.span); final b = view(pair.b.span);
			'Memory.spansDisjoint(${a.name}, ${a.delta + pair.a.offset}, ${pair.a.width}, '
				+ '${b.name}, ${b.delta + pair.b.offset}, ${pair.b.width})';
		}];
	}
	public function add(base:Int, offset:Int, width:Int, ?read:ScalarRead):Null<{name:String, delta:Int}> {
		if (read != null && !useRead(read)) return null;
		for (span in spans) if (span.base == base && span.read == read) {
			final delta = (offset - span.offset) | 0;
			if (delta < -32768 || delta > 32767) continue;
			if (!span.add(base, delta, width)) return null;
			return {name:span.name, delta:delta};
		}
		final span = new ScalarSpan(base, offset, 'memory${spans.length}', read);
		if (!span.add(base, 0, width)) return null;
		spans.push(span);
		return {name:span.name, delta:0};
	}
	public function possible():Bool {
		// Bound entry glue as well as the helper. Exceeding this proof budget keeps the
		// original function; it never drops a requested alias check.
		if (separations.length > 16) return false;
		for (span in spans) if (!span.possible()) return false;
		return true;
	}
	/** Translate a callee's checked view into this helper's incoming address space. */
	public function include(span:ScalarSpan, base:Int, offset:Int, ?read:ScalarRead):Null<{name:String, delta:Int}> {
		if (read != null && !useRead(read)) return null;
		for (existing in spans) if (existing.base == base && existing.read == read) {
			final delta = (offset - existing.offset) | 0;
			if (existing.include(span, delta)) return {name:existing.name, delta:delta};
		}
		final created = new ScalarSpan(base, offset, 'memory${spans.length}', read);
		if (!created.include(span, 0)) return null;
		spans.push(created); return {name:created.name, delta:0};
	}
	/** Opens one checked arm. A failed guard runs the entire original body, never a suffix
	    after a partial speculative write. Span creation and alignment checks have no effects. */
	public function guard(ind:String):String {
		final buf = new StringBuf(); final conditions = [];
		final captured:Map<String,Bool> = []; final loaded:Map<String,Bool> = []; final samples:Map<String,String> = [];
		function capture(span:ScalarSpan):Void {
			if (captured.exists(span.name)) return;
			if (span.read != null) {
				final read = span.read; final source = spanNamed(read.source.span);
				capture(source);
				if (!loaded.exists(read.name)) {
					final key = read.sampleKey();
					final expr = samples.exists(key) ? samples.get(key) : '(${source.condition()}) ? ${read.expression()} : 0';
					buf.add('${ind}final ${read.name} = $expr;\n');
					samples.set(key,read.name);
					loaded.set(read.name,true);
				}
				buf.add(span.capture(ind,source.condition()));
			} else buf.add(span.capture(ind));
			captured.set(span.name,true);
		}
		for (span in spans) {
			capture(span); conditions.push(span.condition());
		}
		for (condition in separationConditions()) conditions.push(condition);
		buf.add(ind + 'if (' + conditions.join(' && ') + ') {\n');
		return buf.toString();
	}
}

/** One register, constant or proved loaded base and a bounded plain-memory range. */
class ScalarSpan {
	public final base:Int;
	public final read:Null<ScalarRead>;
	public final offset:Int;
	var lo = 0;
	var hi = 0;
	var alignMask = 0;
	var alignBits = 0;
	public final name:String;
	public function new(base:Int, offset:Int, name:String, ?read:ScalarRead) { this.base = base; this.offset = offset; this.name = name; this.read = read; }
	public function add(r:Int, delta:Int, width:Int):Bool {
		if (r != base || delta < -32768 || delta > 32767) return false;
		final mask = width - 1;
		final bits = -delta & mask;
		if (((bits ^ alignBits) & mask & alignMask) != 0) return false;
		if (mask > alignMask) { alignMask = mask; alignBits = bits; }
		if (delta < lo) lo = delta;
		if (delta + width - 1 > hi) hi = delta + width - 1;
		return true;
	}
	public function possible():Bool {
		if (base != 0) return true;
		if ((offset & alignMask) != alignBits) return false;
		// Same regions as Memory.span; this is only a rejection filter. Generated code still
		// checks the runtime's span, which remains the authority on the backing storage.
		final ram = offset & 0x1F9FFFFF;
		final scratch = offset & 0x3FF;
		return (ram + lo >= 0 && ram + hi < 0x200000)
			|| ((offset & 0x1FFFFC00) == 0x1F800000 && scratch + lo >= 0 && scratch + hi < 0x400);
	}
	public function include(source:ScalarSpan, delta:Int):Bool {
		if (delta < -32768 || delta > 32767) return false;
		final low = delta + source.lo; final high = delta + source.hi;
		if (low < -32768 || high > 32770) return false;
		final bits = (source.alignBits - delta) & source.alignMask;
		if (((bits ^ alignBits) & source.alignMask & alignMask) != 0) return false;
		if (source.alignMask > alignMask) { alignMask = source.alignMask; alignBits = bits; }
		if (low < lo) lo = low;
		if (high > hi) hi = high;
		return true;
	}
	public function capture(ind:String, ?available:String):String {
		final addr = base == 0 ? Std.string(offset) : read != null ? '(${read.name} + $offset) | 0' : '(ctx.${Instr.regName(base)} + $offset) | 0';
		final span = 'Memory.span(${name}Address, $lo, $hi)';
		return '${ind}final ${name}Address = $addr;\n'
			+ '${ind}final $name = ' + (available == null ? span : '($available) ? $span : Memory.spanNone()') + ';\n';
	}
	public function condition():String return 'Memory.spanOk($name) && (${name}Address & $alignMask) == $alignBits';
	/** Caller bounds come from signed 16-bit instruction offsets. Requiring the anchor
	    inside them bounds these additions too; no wrapped interval proves coverage. */
	public function coveredBy(low:Int, high:Int):Bool {
		return offset >= low && offset <= high && offset + lo >= low && offset + hi <= high;
	}
	public function borrowedCondition(existing:String):String {
		final address = offset == 0 ? 'ctx.${Instr.regName(base)}' : '((ctx.${Instr.regName(base)} + $offset) | 0)';
		return 'Memory.spanOk($existing)' + (alignMask == 0 ? '' : ' && ($address & $alignMask) == $alignBits');
	}
}

typedef ScalarBounds = {cycles:Int, instructions:Int, blocks:Int, calls:Bool};

/** Build-time effect summary in one checked span's coordinates; never a no-alias promise. */
class ScalarWrite {
	public final span:String;
	public final offset:Int;
	public final width:Int;
	public function new(span:String, offset:Int, width:Int) {
		this.span = span; this.offset = offset; this.width = width;
	}
	public function same(other:ScalarWrite):Bool return span == other.span && offset == other.offset && width == other.width;
	/** Exact connected union; disjoint gaps must remain separate exclusions. */
	public function join(other:ScalarWrite):Null<ScalarWrite> {
		if (span != other.span || offset + width < other.offset || other.offset + other.width < offset) return null;
		final lo = offset < other.offset ? offset : other.offset;
		final hi = offset + width > other.offset + other.width ? offset + width : other.offset + other.width;
		return new ScalarWrite(span,lo,hi-lo);
	}
}
