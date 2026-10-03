package recomp.codegen;

import recomp.codegen.ScalarPlan.ScalarWrite;

/** One immutable memory version usable as an address root. Preflight may sample it only
    from a checked plain-memory span and must exclude every write preceding its real load.
    This is build-time provenance, never a runtime pointer object or guest instruction. */
class ScalarRead {
	public final name:String;
	public final source:ScalarWrite;
	public final signed:Bool;
	public final before:Array<ScalarWrite>;
	public var active = false;
	public function new(name:String, source:ScalarWrite, signed:Bool, before:Array<ScalarWrite>) {
		this.name = name; this.source = source; this.signed = signed; this.before = before.copy();
	}
	public function expression():String {
		final accessor = source.width == 4 ? 'spanRead32' : 'spanRead${source.width * 8}${signed ? "s" : "u"}';
		return 'Memory.$accessor(${source.span}, ${source.offset})';
	}
	/** Equal entry samples, not equal guest memory versions. Each version still needs
	    its own preceding-write proof before a shared sample can replace its load. */
	public function sampleKey():String return '${source.span}:${source.offset}:${source.width}:$signed';
}
