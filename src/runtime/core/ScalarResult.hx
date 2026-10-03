package core;

/** Additional return words for generated scalar leaves. `valueN` carries the Nth unique
	computed output, with no association to a guest register. Constants, aliases and affine
	inputs are reconstructed by the caller without slots. `accounting` packs CFG
	cycles:10, instructions:10, blocks:10. These are ABI temporaries, never emulated state.
	The helper cannot call the runtime, suspend or pump; memory helpers access prechecked plain
	spans. Recovered helpers may call each other and immediately capture these words in locals
	before another helper runs or they publish their own results. Runtime callbacks and reentrant
	observers must not use these slots. This avoids allocating a tuple
	merely to return values and their path-dependent accounting.
**/
class ScalarResult {
	public static var accounting:Int = 0;
	// At most 30 changed GPRs (ra is preserved); one value uses the ordinary Int return.
	public static var value1:Int = 0;
	public static var value2:Int = 0;
	public static var value3:Int = 0;
	public static var value4:Int = 0;
	public static var value5:Int = 0;
	public static var value6:Int = 0;
	public static var value7:Int = 0;
	public static var value8:Int = 0;
	public static var value9:Int = 0;
	public static var value10:Int = 0;
	public static var value11:Int = 0;
	public static var value12:Int = 0;
	public static var value13:Int = 0;
	public static var value14:Int = 0;
	public static var value15:Int = 0;
	public static var value16:Int = 0;
	public static var value17:Int = 0;
	public static var value18:Int = 0;
	public static var value19:Int = 0;
	public static var value20:Int = 0;
	public static var value21:Int = 0;
	public static var value22:Int = 0;
	public static var value23:Int = 0;
	public static var value24:Int = 0;
	public static var value25:Int = 0;
	public static var value26:Int = 0;
	public static var value27:Int = 0;
	public static var value28:Int = 0;
	public static var value29:Int = 0;
}
