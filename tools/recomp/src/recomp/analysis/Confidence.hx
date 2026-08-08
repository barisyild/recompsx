package recomp.analysis;

/**
	How a function came to be discovered.

	Confidence is what makes the coverage report readable rather than merely long. A function
	reached by a call is a fact; one guessed from a prologue is a hypothesis; one that nothing
	calls is either dead code or evidence that a caller was missed — and those deserve different
	reactions from the person reading the report.
**/
enum abstract Confidence(Int) to Int {
	var Entry;      // the executable's entry point, or a configured hint
	var Called;     // the target of a jal from code already known to be a function
	var Symbol;     // named in syms.txt
	var Swept;      // found by scanning a gap for something that looks like a prologue
}
