import haxe.io.Bytes;
import recomp.codegen.Relocatable.RelocSet;
import recomp.config.GameConfig.RelocConfig;

/** Relocatable code recognised by content (ADR-0025): what a key covers, and shared keys. */
class TestRelocatable {
	static inline var MARKER = 0x49BE0BE0;

	public static function run():Void {
		Assert.group("relocatable: a key covers the function's own instructions, never data after them");
		// Crash Bandicoot: Warped's fish (FshOC): seven words, then an entry reference that the
		// game turns into a pointer once the page is loaded. Twice, with different references.
		final a = [0x8ec2fffc, 0, 0xae020070, 0x26d6fffc, 0xae1600bc, 0x03e00008, 0x34150000];
		// Two longer functions sharing their first eight words, told apart by the ninth.
		final b = [0x24020001, 0x24030002, 0x00432021, 0x24050003, 0x24060004, 0x24070005,
			0x24080006, 0x24090007, 0x03e00008, 0];
		final c = b.slice(0, 8).concat([0x240a0009, 0x03e00008, 0]);
		final words:Array<Int> = [];
		for (data in [0x52e2394d, 0x12345679]) {
			words.push(MARKER);
			for (w in a) words.push(w);
			words.push(data);
		}
		words.push(MARKER);
		for (w in b) words.push(w);
		words.push(MARKER);
		for (w in c) words.push(w);
		final bytes = Bytes.alloc(4096);
		for (i in 0...words.length) bytes.setInt32(i * 4, words[i]);
		final set = new RelocSet(new RelocConfig("t", ["x"], 4096, MARKER, 8), RelocSet.chooseBase(4096));
		final occurrences = [];
		set.addFile("x", bytes, occurrences);
		set.finish(occurrences);
		Assert.equals(set.functions.length, 3, "three distinct functions");
		Assert.equals(set.rejected, 0, "no entry rejected");
		Assert.equals(set.functions[0].keyWords, 7, "a seven-word function is keyed on seven words");
		Assert.equals(set.functions[1].keyWords, 8, "a longer one on hashWords");
		Assert.equals(occurrences.length, 4, "every occurrence keyed");
		Assert.equals(occurrences[0].key, occurrences[1].key, "the data after the code is not part of the key");
		final code = Bytes.alloc(a.length * 4);
		for (i in 0...a.length) code.setInt32(i * 4, a[i]);
		Assert.equals(occurrences[0].key, RelocSet.withLength(RelocSet.keyOf(code, 0, 7), 7),
			"the key is the hash of the code and its length");
		Assert.equals(set.keys.length, 2, "one key for the short function, one the long ones share");
		Assert.equals(set.groups.length, 1, "the shared key is a group");
		final g = set.groups[0];
		Assert.equals(g.positions.join(","), "8", "told apart by the first word they differ in");
		Assert.equals(g.rowWords.length, 2, "one row each");
		Assert.equals(g.rowMasks.join(","), "1,1", "a word both occupy counts in both rows");
		Assert.equals(set.lengthsLongestFirst().join(","), "8,7", "lengths longest first");
	}
}
