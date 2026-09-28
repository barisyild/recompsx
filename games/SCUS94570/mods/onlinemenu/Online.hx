package onlinemenu;

import core.CpuState;
import mod.LibImode;
import mod.ModHost;

/**
	Crash Bash online, as this mod plays it (ADR-0035: built per game, never netplay), over the PS1's
	own way onto the internet: the i-mode adaptor (SCPH-10180) on a port of the mod's own, spoken to
	through libimode, the phone behind it taking HTTP requests to the network (ADR-0040).

	A player types only an address; the game's port is fixed here. DONE runs one session — the
	phone authenticated, the gateway connected, one request, `GET http://<address>:9457/SCUS94570
	HTTP/1.0`, its answer, everything closed again — one libimode transfer a vblank, as the PS1's
	software did; any HTTP response means a server is there. What follows, the lobby and then the
	match, is the game's protocol to come, over the same requests.
**/
class Online {
	/** Crash Bash's port, taken from its product code (SCUS-94570) so that it is easy to recall. */
	public static inline var PORT = 9457;

	// What the last attempt came to.
	public static inline var IDLE = 0;
	public static inline var TRYING = 1;
	public static inline var ANSWERED = 2;
	public static inline var NO_ANSWER = 3;
	public static inline var NO_NETWORK = 4;

	public static var result(default, null) = IDLE;
	/** The address of the last attempt. */
	public static var address(default, null) = "";

	// A session's commands, in order; after a failure it goes on from where it can close.
	static inline var AUTH = 0;
	static inline var GATEWAY = 1;
	static inline var SEND = 2;
	static inline var RECEIVE = 3;
	static inline var GATEWAY_DOWN = 4;
	static inline var AUTH_END = 5;
	static var commands:Array<Int>;
	static var step = -1;
	static var answered = false;
	static var request:Array<Int>;

	/** When the mod installs: the adaptor, plugged into a port of the mod's own. */
	public static function install():Void {
		LibImode.init(ModHost.plugIMode());
		commands = [LibImode.CMD_AUTH_START, LibImode.CMD_GW_CONNECT, LibImode.CMD_SND, LibImode.CMD_RCV,
			LibImode.CMD_GW_DISCONNECT, LibImode.CMD_AUTH_END];
		request = [for (_ in 0...256) 0];
		ModHost.onFrame(frame);
	}

	/**
		DONE on the address keyboard: a session with a server at `to`, on this game's port. False
		while one is still running.
	**/
	public static function connect(to:String):Bool {
		var started = false;
		if (step < 0) {
			final text = "GET http://" + to + ":" + PORT + "/SCUS94570 HTTP/1.0\r\nUser-Agent: DoCoMo/1.0/recompsx\r\n\r\n";
			var n = 0;
			for (i in 0...text.length) {
				final c:Null<Int> = text.charCodeAt(i);
				if (n < request.length) {
					request[n] = c != null ? c : 0x20;
					n++;
				} else {}
			}
			LibImode.setSend(request, n);
			address = to;
			answered = false;
			result = TRYING;
			step = AUTH;
			LibImode.issue(commands[step]);
			started = true;
		} else {}
		return started;
	}

	/** Every vblank: the session one transfer on. */
	static function frame(ctx:CpuState):Void {
		if (step >= 0) {
			LibImode.poll();
			if (!LibImode.running) finished();
			else {}
		} else {}
	}

	/** A command has ended: the next, or the one that closes what is open, or the result. */
	static function finished():Void {
		final error = LibImode.lastError;
		if (step == RECEIVE) answered = error == LibImode.OK && isHttp();
		else {}
		var next = step + 1;
		if (error == LibImode.NO_ADAPTOR) next = -1;
		else if (error != LibImode.OK && step == AUTH) next = -1;
		else if (error != LibImode.OK && step == GATEWAY) next = AUTH_END;
		else if (error != LibImode.OK && step == SEND) next = GATEWAY_DOWN;
		else {}
		if (next < 0 || next > AUTH_END) {
			step = -1;
			result = error == LibImode.NO_ADAPTOR ? NO_NETWORK : (answered ? ANSWERED : NO_ANSWER);
		} else {
			step = next;
			LibImode.issue(commands[step]);
		}
	}

	/** Whether what came back is an HTTP response: "HTTP/". */
	static function isHttp():Bool {
		final r = LibImode.received;
		return LibImode.receivedSize >= 5 && r[0] == 0x48 && r[1] == 0x54 && r[2] == 0x54 && r[3] == 0x50 && r[4] == 0x2F;
	}

	/** What the menu says of the last attempt. */
	public static function describe():String {
		return switch (result) {
			case TRYING: "connecting to\n" + address;
			case ANSWERED: "connected to\n" + address;
			case NO_ANSWER: "no answer from\n" + address;
			case NO_NETWORK: "no network\n" + address;
			default: "";
		}
	}
}
