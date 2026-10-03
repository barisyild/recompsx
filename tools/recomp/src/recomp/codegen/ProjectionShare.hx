package recomp.codegen;

/**
	One memory projection as `Emitter.finishFunction` appended it to its caller: the helper
	(`<callee>_value_from_<caller>_<site>`), its adapter (`_projected_from_…`, which builds the
	whole access preflight, or `_withSpans_from_…`, which takes the caller's spans) and their text.
**/
typedef ProjectionText = {helper:String, adapter:String, text:String};

/**
	Exact sharing of caller-specific memory projections within one emitted class (ADR-0044).

	Their names are site-specific, but several call sites of one class often produce the same pair.
	Two pairs are one only when their complete texts are equal after the pair's own two names are
	replaced by placeholders. Everything else is text and therefore part of the key: parameters, the
	Int/Void result and the extra ScalarResult words, which registers are published, every span,
	alias and alignment check of the preflight, the ordered memory effects, signedness and `| 0`
	wrapping, path/cycle/instruction/block accounting, the fallback owner and callee, the borrowed or
	fresh form, and the entry-event, resume and unwind guards. No address, hash or algebraic rule
	decides equality, so a single semantic difference keeps both pairs.

	The first pair in emission order keeps its names; a later call site is renamed to it and its own
	copy is not emitted. Only call sites change: what any call executes is the same text. Sharing
	never crosses a class, so the shared methods are always defined where they are called, and it
	runs after `Program.bodyOf` has compared the complete original texts across universes: a body
	forwarded to another universe's owner still runs that owner's own projections.
**/
class ProjectionShare {
	final kept:Map<String, ProjectionText> = [];
	/** Call sites that now use an earlier site's pair instead of their own. */
	public var shared(default, null) = 0;

	public function new() {}

	/**
		`text` is a function's emitted text, which ends with exactly `attachments`, in order.
		Returns it with every pair this class has already seen removed and its call site renamed.
	**/
	public function apply(text:String, attachments:Array<ProjectionText>):String {
		if (attachments.length == 0) return text;
		final tail = [for (a in attachments) a.text].join('');
		if (!StringTools.endsWith(text, tail)) {
			throw 'memory projections are not the end of their caller\'s text';
		}
		var body = text.substr(0, text.length - tail.length);
		final out = new StringBuf();
		for (a in attachments) {
			final first = defines(a) ? kept.get(keyOf(a)) : null;
			if (first == null) {
				if (defines(a)) kept.set(keyOf(a), a);
				out.add(a.text);
			} else {
				body = rename(body, a.adapter, first.adapter);
				shared++;
			}
		}
		return body + out.toString();
	}

	/** Only a pair that defines both of its names can stand in for another. */
	static function defines(a:ProjectionText):Bool {
		return a.text.indexOf('public static function ${a.helper}(') >= 0
			&& a.text.indexOf('public static function ${a.adapter}(') >= 0;
	}

	public static function keyOf(a:ProjectionText):String {
		return rename(rename(a.text, a.helper, '\x01helper\x01'), a.adapter, '\x01adapter\x01');
	}

	/** Whole identifiers only: no name is a part of another, but a prefix must never match. */
	static function rename(text:String, from:String, to:String):String {
		return new EReg('\\b' + EReg.escape(from) + '\\b', 'g').replace(text, to);
	}
}
