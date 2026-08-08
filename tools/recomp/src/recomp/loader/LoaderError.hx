package recomp.loader;

/** Anything a loader rejects. Carries a message meant to be read by a person fixing a config. */
class LoaderError {
	public final message:String;
	public function new(message:String) this.message = message;
	public function toString():String return message;
}
