package recomp.analysis;

/** How much to trust a recovered table. */
enum abstract TableConfidence(Int) to Int {
	/** A bound check was found, so the entry count is the compiler's own, not a guess. */
	var Bounded;
	/** No bound check was found; entries were read until one stopped looking like a target. */
	var Scanned;
	/** Supplied by `jumpTableHints` in game.json. */
	var Hinted;
}
