package recomp.codegen;

import recomp.ir.FunctionIR.InstructionIR;
import recomp.mips.Instr;
import recomp.mips.Op;
import recomp.codegen.ScalarPlan.ScalarMemory;

/** Build-time SSA values and ordered memory operations. CFG memory operations carry the
    current block's reach predicate; all spans must pass preflight before any effect runs. */
class ScalarGraph {
	/** Definition order is execution order for memory nodes, not just a topological order.
	    Reordering them would require an alias/effect proof absent from this graph. */
	public final values:Array<ScalarValue> = [];
	/** Ordered plain-memory writes, retained even when they produce no register result. */
	public final effects:Array<ScalarValue> = [];
	public final initial:Array<ScalarValue> = [for (r in 0...32) new ScalarValue(r == 0 ? "0" : Instr.regName(r), [], null, r, 0)];
	public var memory:Null<ScalarMemory> = null;
	/** The GTE's registers are read or written (coprocessor 2, or a child call that does). They
	    are one global register file in program order: every write and command is an ordered
	    effect, and a read is materialized where it stands, never moved past a later write. */
	public var coprocessor = false;
	var memoryValues:Null<ScalarMemoryValues> = null;
	var memoryPredicate:Null<ScalarValue> = null;
	final reuseValues:Bool;
	final allowReturnRegister:Bool;
	final guardMemoryAliases:Bool;
	final pureValues:Map<String, ScalarValue> = [];
	public function new(reuseValues:Bool = false, allowReturnRegister:Bool = false, guardMemoryAliases:Bool = false) {
		this.reuseValues = reuseValues; this.allowReturnRegister = allowReturnRegister;
		this.guardMemoryAliases = guardMemoryAliases;
	}
	/** The CFG supplies the intersection of actual predecessor facts. Emission order alone
	    cannot supply a memory value; standalone callers start with no inherited facts. */
	public function beginBlock(predicate:Null<ScalarValue>, ?facts:ScalarMemoryValues):Void {
		memoryPredicate = predicate;
		memoryValues = facts == null ? null : facts.copy();
	}
	public function memoryFacts():ScalarMemoryValues return memoryValues == null ? new ScalarMemoryValues() : memoryValues.copy();
	public function make(expr:String, args:Array<ScalarValue>, ?read:ScalarRead):ScalarValue {
		final v = new ScalarValue('value${values.length}', args, expr, -1, 0, false, read);
		values.push(v); return v;
	}
	/** A real load node, distinct from an affine value or call result with read provenance. */
	public function load(read:ScalarRead):ScalarValue {
		final expr = read.expression();
		final value = memoryPredicate == null ? make(expr, [], read)
			: make('${memoryPredicate.ref} ? $expr : 0', [memoryPredicate], read);
		value.load = read; value.loadPredicate = memoryPredicate;
		if (memoryPredicate == null) value.sampleRead = read;
		value.memoryUses.push(read.source.span); return value;
	}
	/** A memory-fact proof supplies this read by conversion of an already captured value.
	    Keep the numeric identity but do not label the expression as an actual load. */
	public function forwardRead(expr:String, source:ScalarValue, read:ScalarRead):ScalarValue {
		final value = make(expr,[source],read);
		if (memoryPredicate == null) value.sampleRead = read;
		return value;
	}
	public function lift(x:InstructionIR, regs:Array<ScalarValue>, allowMemory:Bool):Bool {
		final i = x.decoded;
		if (x.effects.has(recomp.ir.Effect.TRAP)) return false;
		final a = regs[i.rs];
		final c = regs[i.rt];
		var rd = i.rd;
		var expr:String;
		var args:Array<ScalarValue>;
		var copy:Null<ScalarValue> = null;
		var addressBase = -1;
		var addressOffset = 0;
		var addressRead:Null<ScalarRead> = null;
		switch (i.op) {
			case ADD | ADDU | SUB | SUBU | AND | OR | XOR | NOR | SLT | SLTU:
				args = [a, c];
				expr = switch (i.op) {
					case ADD | ADDU: '(${a.ref} + ${c.ref}) | 0';
					case SUB | SUBU: '(${a.ref} - ${c.ref}) | 0';
					case AND: '${a.ref} & ${c.ref}';
					case OR: '${a.ref} | ${c.ref}';
					case XOR: '${a.ref} ^ ${c.ref}';
					case NOR: '~(${a.ref} | ${c.ref})';
					case SLT: '${a.ref} < ${c.ref} ? 1 : 0';
					case _: '(${a.ref} ^ 0x80000000) < (${c.ref} ^ 0x80000000) ? 1 : 0';
				};
				if (i.op == Op.ADD || i.op == Op.ADDU || i.op == Op.OR || i.op == Op.XOR) {
					if (a == initial[0]) copy = c;
					else if (c == initial[0]) copy = a;
				} else if ((i.op == Op.SUB || i.op == Op.SUBU) && c == initial[0]) copy = a;
				if (a == c) {
					if (i.op == Op.SUB || i.op == Op.SUBU || i.op == Op.XOR || i.op == Op.SLT || i.op == Op.SLTU) copy = initial[0];
					else if (i.op == Op.AND || i.op == Op.OR) copy = a;
				}
				if ((i.op == Op.ADD || i.op == Op.ADDU || i.op == Op.SUB || i.op == Op.SUBU) && a.hasAddress() && c.addressBase == 0) {
					addressBase = a.addressBase;
					addressRead = a.addressRead;
					addressOffset = (i.op == Op.ADD || i.op == Op.ADDU ? a.addressOffset + c.addressOffset : a.addressOffset - c.addressOffset) | 0;
				} else if ((i.op == Op.ADD || i.op == Op.ADDU) && a.addressBase == 0 && c.hasAddress()) {
					addressBase = c.addressBase;
					addressRead = c.addressRead;
					addressOffset = (a.addressOffset + c.addressOffset) | 0;
				}
			case ADDI | ADDIU | ANDI | ORI | XORI | SLTI | SLTIU:
				rd = i.rt; args = [a];
				expr = switch (i.op) {
					case ADDI | ADDIU: '(${a.ref} + ${i.immS}) | 0';
					case ANDI: '${a.ref} & ${i.immU}';
					case ORI: '${a.ref} | ${i.immU}';
					case XORI: '${a.ref} ^ ${i.immU}';
					case SLTI: '${a.ref} < ${i.immS} ? 1 : 0';
					case _: '(${a.ref} ^ 0x80000000) < ${i.immS ^ 0x80000000} ? 1 : 0';
				};
				if (i.immU == 0 && (i.op == Op.ADDI || i.op == Op.ADDIU || i.op == Op.ORI || i.op == Op.XORI)) copy = a;
				if ((i.op == Op.ADDI || i.op == Op.ADDIU) && a.hasAddress()) {
					addressBase = a.addressBase; addressRead = a.addressRead; addressOffset = (a.addressOffset + i.immS) | 0;
				} else if (a.addressBase == 0 && (i.op == Op.ORI || i.op == Op.ANDI || i.op == Op.XORI)) {
					addressBase = 0;
					addressOffset = switch (i.op) {
						case ORI: a.addressOffset | i.immU;
						case ANDI: a.addressOffset & i.immU;
						case _: a.addressOffset ^ i.immU;
					};
				}
			case LUI:
				rd = i.rt; args = []; expr = Std.string(i.immU << 16);
				addressBase = 0; addressOffset = i.immU << 16;
			case SLL | SRL | SRA:
				args = [c];
				expr = switch (i.op) {
					case SLL: '${c.ref} << ${i.shamt}';
					case SRL: '(${c.ref} >>> ${i.shamt}) | 0';
					case _: '${c.ref} >> ${i.shamt}';
				};
				if (i.shamt == 0) copy = c;
			case SLLV | SRLV | SRAV:
				args = [a, c];
				expr = switch (i.op) {
					case SLLV: '${c.ref} << (${a.ref} & 31)';
					case SRLV: '(${c.ref} >>> (${a.ref} & 31)) | 0';
					case _: '${c.ref} >> (${a.ref} & 31)';
				};
			case LB | LBU | LH | LHU | LW | SB | SH | SW | LWL | LWR:
				if (!allowMemory) return false;
				return liftMemory(i, a, c, regs);
			// The GTE (coprocessor 2) only where effects are ordered, never in a value region.
			case LWC2:
				if (!allowMemory) return false;
				return liftMemory(i, a, c, regs);
			case SWC2:
				if (!allowMemory) return false;
				return liftMemory(i, a, gteRead('gte.Gte.readData(${i.rt})'), regs);
			case MFC2 | CFC2:
				if (!allowMemory || (i.rt == 31 && !allowReturnRegister)) return false;
				// Reading has no effect, not even the SXY FIFO's mirror: a read into $zero is none.
				if (i.rt != 0) regs[i.rt] = gteRead(i.op == Op.MFC2 ? 'gte.Gte.readData(${i.rd})' : 'gte.Gte.readControl(${i.rd})');
				return true;
			case MTC2 | CTC2:
				if (!allowMemory) return false;
				gteEffect((i.op == Op.MTC2 ? 'gte.Gte.writeData' : 'gte.Gte.writeControl') + '(${i.rd}, ${c.ref})', [c]);
				return true;
			case COP2CMD:
				final command = allowMemory ? Emitter.scalarGteCommand(i.code) : null;
				if (command == null) return false;
				gteEffect(command, []);
				return true;
			// Whitelist: unproved overflow, HI/LO, coprocessor 0 and unknown GTE commands stay out.
			case _: return false;
		}
		if (rd == 31 && !allowReturnRegister) return false;
		if (rd == 0) return true;
		if (copy != null) regs[rd] = copy;
		else {
			// Value regions admit no reads/effects. Exact operand-version expressions may
			// share there; memory helpers must never reuse a load on expression text alone.
			if (reuseValues && !allowMemory && pureValues.exists(expr)) {
				regs[rd] = pureValues.get(expr); return true;
			}
			final v = new ScalarValue('value${values.length}', args, expr, addressBase, addressOffset, false, addressRead);
			if (addressRead != null && (a.sampleRead == addressRead || c.sampleRead == addressRead)) v.sampleRead = addressRead;
			values.push(v);
			if (reuseValues && !allowMemory) pureValues.set(expr, v);
			regs[rd] = v;
		}
		return true;
	}
	/** A GTE register read at its place in program order: no effect, but a value of the file's
	    current state, so the helper materializes it where it stands (ScalarPlan.emitHelper).
	    Not predicated: in a CFG it reads the state its path has reached, used only on that path. */
	function gteRead(expr:String):ScalarValue {
		coprocessor = true;
		return make(expr, []);
	}

	/** A GTE register write or command: an ordered effect, under its block's reach predicate. */
	function gteEffect(call:String, args:Array<ScalarValue>):Void {
		coprocessor = true;
		final expr = memoryPredicate == null ? call : 'if (${memoryPredicate.ref}) { $call; } else {}';
		final v = new ScalarValue('value${values.length}', memoryPredicate == null ? args : [memoryPredicate].concat(args), expr, -1, 0, true);
		values.push(v); effects.push(v);
	}

	function liftMemory(i:Instr, address:ScalarValue, source:ScalarValue, regs:Array<ScalarValue>):Bool {
		// Preflight even a forwarded/dead load or a read into $zero: it may be MMIO in the
		// fallback. A loaded address needs its immutable read version and an entry proof
		// that earlier writes cannot change the value sampled during preflight.
		if (!address.hasAddress()) return false;
		final offset = (address.addressOffset + i.immS) | 0;
		if (memory == null) memory = new ScalarMemory();
		if (memoryValues == null) memoryValues = new ScalarMemoryValues();
		if (i.op == Op.LWL || i.op == Op.LWR) return liftUnaligned(i, address, offset, regs);
		final store = i.op == Op.SB || i.op == Op.SH || i.op == Op.SW || i.op == Op.SWC2;
		final width = i.op == Op.LW || i.op == Op.SW || i.op == Op.LWC2 || i.op == Op.SWC2 ? 4 : (i.op == Op.LH || i.op == Op.LHU || i.op == Op.SH ? 2 : 1);
		final access = memory.add(address.addressBase, offset, width, address.addressRead);
		if (access == null) return false;
		if (store) {
			memory.recordWrite(access.name, access.delta, width);
			final write = 'Memory.spanWrite${width * 8}(${access.name}, ${access.delta}, ${source.ref})';
			final expr = memoryPredicate == null ? write : 'if (${memoryPredicate.ref}) { $write; } else {}';
			final v = new ScalarValue('value${values.length}', memoryPredicate == null ? [source] : [memoryPredicate, source], expr, -1, 0, true);
			v.memoryUses.push(access.name);
			values.push(v); effects.push(v);
			memoryValues.store(access.name, access.delta, width, source, guardMemoryAliases);
			return true;
		}
		// LWC2's target is a GTE register, $zero's number included: VXY0.
		if (i.op != Op.LWC2 && i.rt == 31 && !allowReturnRegister) return false;
		if (i.op != Op.LWC2 && i.rt == 0) return true;
		final signed = i.op == Op.LB || i.op == Op.LH;
		var value = memoryValues.load(access.name, access.delta, width, signed, this);
		if (value == null) {
			final root = memory.read(new recomp.codegen.ScalarPlan.ScalarWrite(access.name, access.delta, width), signed, memory.stores);
			value = load(root);
		}
		memoryValues.remember(access.name, access.delta, width, value, signed ? 1 : 0);
		if (i.op == Op.LWC2) gteEffect('gte.Gte.writeData(${i.rt}, ${value.ref})', [value]);
		else regs[i.rt] = value;
		return true;
	}

	/**
		LWL/LWR: the aligned word holding the addressed byte, merged into the register (Memory.spanLwl,
		spanLwr). Preflight checks that byte, whose word is then inside the same region; a word has
		no alignment to check. Always a real load in program order: never forwarded from a store,
		never sampled at entry, and its value is no address root — nothing hoists it.
	**/
	function liftUnaligned(i:Instr, address:ScalarValue, offset:Int, regs:Array<ScalarValue>):Bool {
		final access = memory.add(address.addressBase, offset, 1, address.addressRead);
		if (access == null) return false;
		if (i.rt == 31 && !allowReturnRegister) return false;
		if (i.rt == 0) return true;
		final current = regs[i.rt];
		final read = 'Memory.span${i.op == Op.LWL ? "Lwl" : "Lwr"}(${access.name}, ${access.delta}, ${current.ref})';
		final v = memoryPredicate == null ? make(read, [current])
			: make('${memoryPredicate.ref} ? $read : 0', [memoryPredicate, current]);
		v.memoryUses.push(access.name);
		regs[i.rt] = v;
		return true;
	}
	public static function mark(v:ScalarValue):Void {
		if (v.live) return;
		v.live = true;
		for (a in v.args) mark(a);
	}
}

class ScalarValue {
	public final ref:String;
	public final args:Array<ScalarValue>;
	public final expr:Null<String>;
	public final statement:Bool;
	/** Build-time lowering metadata; SSA expressions and memory-version identities stay immutable. */
	public final memoryUses:Array<String> = [];
	public var load:Null<ScalarRead> = null;
	public var loadPredicate:Null<ScalarValue> = null;
	/** Unconditional numeric equality to this read plus addressOffset. Pointer provenance
	    alone is weaker: predicated loads and opaque call results cannot establish this. */
	public var sampleRead:Null<ScalarRead> = null;
	/** -1: non-register value; 0: constant; 1..31: incoming register plus offset. */
	public final addressBase:Int;
	public final addressOffset:Int;
	public final addressRead:Null<ScalarRead>;
	public function hasAddress():Bool return addressBase >= 0 || addressRead != null;
	public var live = false;
	/** Exact wrapped affine identity, not an ABI assumption about a register's role. */
	public function equivalent(other:ScalarValue):Bool {
		return this == other || (addressOffset == other.addressOffset
			&& ((addressBase >= 0 && addressBase == other.addressBase)
				|| (addressRead != null && addressRead == other.addressRead)));
	}
	public function new(ref:String, args:Array<ScalarValue>, ?expr:String, addressBase:Int = -1, addressOffset:Int = 0, statement:Bool = false, ?addressRead:ScalarRead) {
		this.ref = ref; this.args = args; this.expr = expr;
		this.statement = statement;
		this.addressBase = addressBase; this.addressOffset = addressOffset;
		this.addressRead = addressRead;
	}
}
