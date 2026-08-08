package recomp.analysis;

/** What analysis has concluded about each word of an image. */
enum abstract Kind(Int) to Int {
	var Unknown;      // never reached
	var Code;         // an instruction inside a discovered function
	var DataInText;   // a jump table, or a region a hint marked as data
	var Padding;      // alignment filler between functions
}
