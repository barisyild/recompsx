package recomp.analysis;

/**
	A problem serious enough that continuing would produce wrong output.

	Analysis errors carry a full explanation, including disassembled context and a suggestion,
	because the person who sees one is usually being told that a region of the program is not
	what the tool assumed — and they need enough to decide whether to add a hint or fix a
	boundary. A bare address would send them back to a disassembler to reconstruct what the tool
	already knew.
**/
class AnalysisError {
	public final message:String;
	public function new(message:String) this.message = message;
	public function toString():String return message;
}
