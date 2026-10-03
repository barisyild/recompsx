package recomp.codegen;

/** Build-time interning of pure scalar computations across call sites, shards and universes.
	Exact normalized signatures/bodies are keys, never just addresses or a truncated hash.
	The call site keeps its own input/output mapping, guards and original callee. Every returned
	value and any CFG path accounting participate in the sharing key.
**/
class ScalarPool {
	public final className:String;
	public var count(get, never):Int;
	final names:Map<String, String> = [];
	final bodies:Array<String> = [];

	public function new(className:String) { this.className = className; }
	function get_count():Int return bodies.length;

	public function clear():Void {
		names.clear(); bodies.resize(0);
	}

	public function intern(plan:ScalarPlan):String {
		final body = plan.sharedBody();
		var name = names.get(body);
		if (name == null) {
			name = 'value_${bodies.length}';
			names.set(body, name);
			bodies.push('\tpublic static function $name$body');
		}
		return className + '.' + name;
	}

	public function source():String {
		return '/** Shared pure computations; callers retain guest state and timing. */\n'
			+ 'class $className {\n' + bodies.join('\n') + '}\n';
	}
}
