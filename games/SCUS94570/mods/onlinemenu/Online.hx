package onlinemenu;

import mod.ModHost;

/**
	Crash Bash online, as this mod will play it (ADR-0035: built per game, never netplay).

	So far, where it connects: the player types only an address, and DONE tries this game's own
	port there. Every game that goes online gets a port of its own the same way — a fact of its
	protocol, kept with its mod, never typed. What follows is the rest of the protocol (the
	lobby, then the match), over the network service the HLE kernel does not have yet.
**/
class Online {
	/** Crash Bash's port, taken from its product code (SCUS-94570) so that it is easy to recall. */
	public static inline var PORT = 9457;

	/**
		DONE on the address keyboard: a connection to `address` on this game's port. There is no
		network service in the kernel yet, so today this only says so, and the menu shows it;
		false while there is nothing to connect with.
	**/
	public static function connect(address:String):Bool {
		ModHost.log("onlinemenu: connect to " + address + " port " + PORT + ": the kernel has no network service yet");
		return false;
	}
}
