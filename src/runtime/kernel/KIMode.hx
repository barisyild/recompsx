package kernel;

import shim.Backend;
import shim.RawBuf;
import shim.RawMem;
import sio.IModeAdaptor;
import sio.IModeWire;

/**
	The i-mode phone at the far end of the adaptor, and DoCoMo's i-mode centre behind it (ADR-0040):
	the half of the PS1's internet that was never in the box, played by the HLE kernel so that the
	console's side — the adaptor (`sio.IModeAdaptor`) and the software that drives it — is the
	original, standard by standard (psx-spx, "Controllers - I-Mode Adaptor").

	**The small stream** starts and ends a session. The phone answers each message of the console's
	as the documented one does: wake-up with 38h,02h; AUTH_START_REQ with AUTH_START_ACK,
	AUTH_CRYPT_REQ with AUTH_CRYPT_ACK, DEAUTH_REQ with DEAUTH_ACK, AUTH_PING_REQ (8Eh) with AAh;
	GW_CONNECT_REQ, GW_DISCONNECT_REQ and GW_PING_REQ (F2h ...) with their ACKs. No length field in
	them carries anything, and any key is accepted: there is no DoCoMo account behind it.

	**The large stream** carries packets: 01h,3Fh brings the transport up (01h,73h back), 01h,53h
	takes it down (01h,1Fh), and 01h/03h with bit0 of the second byte clear carries a TLP message —
	the block numbers in that byte counted as the console counts them. A connection is one HTTP
	exchange: TLP_CONNECT_REQ brings the request's header and first bytes, TLP_DATA the rest,
	TLP_DATA_EOF says it is whole. The centre then does what the real one did (and what no$psx
	does): the request line's absolute URL, `GET http://host:port/path HTTP/1.0`, becomes
	`GET /path HTTP/1.0` with a `Host:` header, and goes to that host and port on the host's network
	(`bp_http_open`), https not at all. The phone is busy while it waits. The response — status
	line, header and body, as the server sent it — comes back as TLP_CONNECT_ACK with its first
	1400 bytes, TLP_DATA with the rest, 1400 at a time, and TLP_DATA_EOF; a request that cannot be
	made is TLP_CONNECT_REJECT. The console ends it with TLP_DISCONNECT_REQ.

	Everything reaches the machine at vblanks, as input does. A headless run has no network: every
	request there is rejected, unless a test has canned the answer.
**/
class KIMode {
	static inline var MESSAGE = 32;           // the longest console message, AUTH_START_REQ, is 17
	static inline var PACKET = 1500;          // a TLP message of ours and its headers
	static inline var REQUEST = 8192;         // an HTTP request's bytes, at most
	static inline var OUTGOING = REQUEST + 256;
	static inline var RESPONSE = 65536;       // a response's (the PSX browser stops at 10240)
	static inline var SEGMENT = 1400;         // Transmit Data a TLP message carries, at most
	static inline var CHUNK = 4096;           // read from the host a vblank, at most
	/** Vblanks the centre waits for a host: half a minute. */
	public static inline var PATIENCE = 1800;

	// A connection, as the centre sees it.
	static inline var IDLE = 0;
	static inline var REQUESTING = 1;         // the console is sending its request
	static inline var WAITING = 2;            // the host has the request
	static inline var ANSWERING = 3;          // the response is going back
	static inline var ANSWERED = 4;           // all of it went; the console will disconnect

	// Reasons in TLP_CONNECT_REJECT (00h..08h is the documented range; what each meant is not known).
	static inline var REASON_BAD_REQUEST = 1;
	static inline var REASON_NO_HOST = 2;
	static inline var REASON_TIMEOUT = 3;

	static var state = IDLE;
	static var logical = 0;
	static var consoleBlock = 0;
	static var ourBlock = 0;

	static var message:Array<Int>;
	static var messageLength = 0;
	static var packetOut:Array<Int>;

	static var request:RawBuf;
	static var requestLength = 0;
	static var outgoing:RawBuf;               // the request as it goes to the host
	static var response:RawBuf;
	static var responseLength = 0;
	static var responseSent = 0;
	static var segment = 0;
	static var chunk:RawBuf;
	static var handle = -1;
	static var waited = 0;
	static var hostLength = 0;

	/** Tests: a host that answers with these bytes, not the network (`answerWith`). */
	static var canned:Array<Int>;
	static var cannedOn = false;

	public static function init():Void {
		IModeAdaptor.init();
		message = [for (_ in 0...MESSAGE) 0];
		packetOut = [for (_ in 0...PACKET) 0];
		request = RawMem.alloc(REQUEST);
		outgoing = RawMem.alloc(OUTGOING);
		response = RawMem.alloc(RESPONSE);
		chunk = RawMem.alloc(CHUNK);
		cannedOn = false;
		handle = -1;
		reset();
	}

	/** Everything dropped: the adaptor was reset, or powered on. */
	public static function reset():Void {
		closeHost();
		state = IDLE;
		logical = 0;
		consoleBlock = 0;
		ourBlock = 0;
		messageLength = 0;
		requestLength = 0;
		responseLength = 0;
		responseSent = 0;
		segment = 0;
		IModeAdaptor.busy = false;
	}

	/** Tests: the next request is answered with `bytes`, as a host would send them. */
	public static function answerWith(bytes:Array<Int>):Void {
		canned = bytes;
		cannedOn = true;
	}

	/** Tests: the last request as it went to the host — its length, and its bytes. */
	public static function hostRequestLength():Int return hostLength;

	public static function hostRequestByte(i:Int):Int return RawMem.get8(outgoing, i);

	// ---- the small stream ---------------------------------------------------------------------------

	/** The adaptor woke up: the phone says so. */
	public static function wake():Void {
		say(0x38);
		say(0x02);
	}

	/** A byte of a message from the console. */
	public static function fromConsole(b:Int):Void {
		if (messageLength < MESSAGE) {
			message[messageLength] = b & 0xFF;
			messageLength++;
		} else {}
		final first = message[0];
		var need = 0;
		if (first == 0x85) need = messageLength >= 3 ? authLength(message[2]) : 3;
		else if (first == 0x8E || first == 0xA8) need = 1;
		else if (first == 0xF2) need = 9;
		else {}
		if (need == 0) {
			messageLength = 0;
		} else if (messageLength >= need) {
			answer();
			messageLength = 0;
		} else {}
	}

	/** An authentication message's length, by its third byte. */
	static function authLength(kind:Int):Int {
		return switch (kind) {
			case 0x01: 17;                   // AUTH_START_REQ
			case 0x04: 12;                   // AUTH_CRYPT_REQ
			case 0x05: 4;                    // AUTH_DONE
			default: 3;                      // DEAUTH_REQ, and what is not known
		}
	}

	/** The phone's answer to a whole message. */
	static function answer():Void {
		final first = message[0];
		if (first == 0x85) {
			final kind = message[2];
			if (kind == 0x01) {
				// AUTH_START_ACK: 85h,01h,04h,x, the phone's eight random nibbles, H,L = no more.
				say(0x85);
				say(0x01);
				say(0x04);
				say(0x00);
				for (i in 0...8) say(i & 0x0F);
				say(0x00);
				say(0x00);
			} else if (kind == 0x04) {
				// AUTH_CRYPT_ACK: 85h,01h,02h,x,x,H,L.
				say(0x85);
				say(0x01);
				say(0x02);
				for (i in 0...4) say(0x00);
			} else if (kind == 0x06) {
				// DEAUTH_ACK.
				say(0x85);
				say(0x01);
				say(0x07);
			} else {}
		} else if (first == 0x8E) {
			say(0xAA);                       // AUTH_PING_ACK
		} else if (first == 0xF2 && message[2] == 0x01) {
			// GW_CONNECT_ACK (08h), GW_DISCONNECT_ACK (00h), GW_PING_ACK (01h): F2h,00h,02h,x,
			// what was asked, x, H,L = 0, then four data nibbles (one for a ping).
			final what = message[4];
			say(0xF2);
			say(0x00);
			say(0x02);
			say(0x00);
			say(what);
			for (i in 0...3) say(0x00);
			final nibbles = what == 0x01 ? 1 : 4;
			for (i in 0...nibbles) say(0x00);
		} else {}
	}

	static inline function say(b:Int):Void {
		IModeAdaptor.message(b);
	}

	// ---- the large stream ---------------------------------------------------------------------------

	/** A packet from the console, whole and sound: its `n` bytes, the CRC taken off. */
	public static function packetFromConsole(buf:Array<Int>, n:Int):Void {
		if (n >= 2 && (buf[0] == 0x01 || buf[0] == 0x03)) {
			final b1 = buf[1];
			if ((b1 & 1) == 0 && n >= 3) {
				consoleBlock = (b1 >> 1) & 7;
				tlp(buf, 3, n - 3);
			} else if (b1 == 0x3F) {
				// The transport up: blocks counted from 0.
				consoleBlock = 0;
				ourBlock = 0;
				control(0x73);
			} else if (b1 == 0x53) {
				closeHost();
				state = IDLE;
				IModeAdaptor.busy = false;
				control(0x1F);
			} else {}
		} else {}
	}

	static function control(code:Int):Void {
		packetOut[0] = 0x01;
		packetOut[1] = code;
		IModeAdaptor.packet(packetOut, 2);
	}

	/** A TLP message: `n` bytes of `buf` from `from`. */
	static function tlp(buf:Array<Int>, from:Int, n:Int):Void {
		if (IModeWire.tlpSound(buf, from, n)) {
			final type = buf[from + 2];
			if (type == 0x10 && n >= 14) {
				// TLP_CONNECT_REQ: a new connection, and the request's first bytes.
				closeHost();
				logical = buf[from + 4];
				requestLength = 0;
				responseLength = 0;
				responseSent = 0;
				segment = 0;
				state = REQUESTING;
				take(buf, from, n, 13, 14);
			} else if (type == 0x30 && n >= 5 && state == REQUESTING && buf[from + 3] == logical) {
				take(buf, from, n, 4, 5);    // TLP_DATA: more of it
			} else if (type == 0x31 && n >= 4 && state == REQUESTING && buf[from + 3] == logical) {
				ask();                       // TLP_DATA_EOF: it is whole
			} else if (type == 0x20) {
				// TLP_DISCONNECT_REQ: acknowledged, and the connection gone.
				final l = n >= 4 ? buf[from + 3] : logical;
				closeHost();
				state = IDLE;
				IModeAdaptor.busy = false;
				var at = 5;
				at = w(at, 0x21);            // TLP_DISCONNECT_ACK
				at = w(at, l);
				at = w(at, 0x00);            // Disconnect Reason: done
				at = w(at, 0x00);            // Logic State
				sendTlp(at - 3);
			} else if (type == 0x21) {
				state = IDLE;
			} else {}
		} else {}
	}

	/**
		A message's optional parts, after its Logic State at `stateAt` (the Operator Specific
		Information, the Requested Segment Number, and the Transmit Segment Number, Length and Data):
		the data into the request.
	**/
	static function take(buf:Array<Int>, from:Int, n:Int, stateAt:Int, partsAt:Int):Void {
		final logic = buf[from + stateAt];
		var pos = partsAt;
		if ((logic & 0x08) != 0) pos += 2;
		else {}
		if ((logic & 0x02) != 0) pos += 1;
		else {}
		if ((logic & 0x01) != 0 && pos + 3 <= n) {
			var len = (buf[from + pos + 1] << 8) | buf[from + pos + 2];
			pos += 3;
			if (pos + len > n) len = n - pos;
			else {}
			for (i in 0...len) {
				if (requestLength < REQUEST) {
					RawMem.set8(request, requestLength, buf[from + pos + i]);
					requestLength++;
				} else {}
			}
		} else {}
	}

	/**
		The console's request is whole: to its host. The request line's absolute URL gives the host
		and port (80 when none); the line goes on with the path alone, and a `Host:` header is added
		when the request has none.
	**/
	static function ask():Void {
		final eol = find(request, requestLength, 0, 0x0D, 0x0A);
		final s1 = eol < 0 ? -1 : find(request, eol, 0, 0x20, -1);
		final s2 = s1 < 0 ? -1 : find(request, eol, s1 + 1, 0x20, -1);
		final url = s1 + 1;
		final http = s2 > url + 7 && lower(url) == 0x68 && lower(url + 1) == 0x74 && lower(url + 2) == 0x74
			&& lower(url + 3) == 0x70 && RawMem.get8(request, url + 4) == 0x3A
			&& RawMem.get8(request, url + 5) == 0x2F && RawMem.get8(request, url + 6) == 0x2F;
		if (!http) {
			reject(REASON_BAD_REQUEST);
		} else {
			final authority = url + 7;
			var slash = find(request, s2, authority, 0x2F, -1);
			if (slash < 0) slash = s2;
			else {}
			final colon = find(request, slash, authority, 0x3A, -1);
			var port = 80;
			var hostEnd = slash;
			if (colon >= 0) {
				hostEnd = colon;
				port = portOf(colon + 1, slash);
			} else {}
			// The request as it goes: the method, the path (or "/"), the rest of the line, a Host.
			var o = copy(0, s1 + 1, 0);
			if (slash < s2) o = copy(slash, s2, o);
			else o = put(0x2F, o);
			o = copy(s2, eol + 2, o);
			if (!hasHost(eol + 2)) {
				o = put(0x48, o);            // "Host: "
				o = put(0x6F, o);
				o = put(0x73, o);
				o = put(0x74, o);
				o = put(0x3A, o);
				o = put(0x20, o);
				o = copy(authority, slash, o);
				o = put(0x0D, o);
				o = put(0x0A, o);
			} else {}
			o = copy(eol + 2, requestLength, o);
			var host = "";
			for (i in authority...hostEnd) host += String.fromCharCode(RawMem.get8(request, i));
			open(host, port, o < OUTGOING ? o : OUTGOING);
		}
	}

	/**
		The port in the URL's bytes `from`..`to`: its decimal digits, or 0 — no port, which the request
		is rejected for — when there are none, or anything else, or more than a port can be.
	**/
	static function portOf(from:Int, to:Int):Int {
		var port = to > from ? 0 : -1;
		for (i in from...to) {
			final d = RawMem.get8(request, i) - 0x30;
			if (port < 0 || d < 0 || d > 9) port = -1;
			else if (port > 65535) port = 65536;
			else port = port * 10 + d;
		}
		return port < 0 || port > 65535 ? 0 : port;
	}

	/** The host's side of the request: the network, or what a test has canned. */
	static function open(host:String, port:Int, length:Int):Void {
		responseLength = 0;
		hostLength = length;
		if (host.length == 0 || port <= 0 || port > 65535) {
			reject(REASON_BAD_REQUEST);
		} else if (cannedOn) {
			for (i in 0...canned.length) keep(canned[i]);
			cannedOn = false;
			state = ANSWERING;
		} else if (Kernel.haltAt != 0) {
			reject(REASON_NO_HOST);
		} else {
			handle = Backend.httpOpen(host, port, outgoing, length);
			if (handle < 0) {
				reject(REASON_NO_HOST);
			} else {
				state = WAITING;
				waited = 0;
				IModeAdaptor.busy = true;
			}
		}
	}

	static function reject(reason:Int):Void {
		closeHost();
		IModeAdaptor.busy = false;
		state = IDLE;
		var at = 5;
		at = w(at, 0x12);                    // TLP_CONNECT_REJECT
		at = w(at, logical);
		at = w(at, reason);
		sendTlp(at - 3);
	}

	static function closeHost():Void {
		if (handle >= 0) Backend.httpClose(handle);
		else {}
		handle = -1;
	}

	// ---- each vblank ------------------------------------------------------------------------------

	/** Once per vblank: the host's answer read on, and sent on to the console as there is room. */
	public static function sample():Void {
		if (state == WAITING) {
			waited++;
			var reading = true;
			var rounds = 0;
			while (reading && rounds < 4) {
				final r = Backend.httpRead(handle, chunk, CHUNK);
				if (r > 0) {
					for (i in 0...r) keep(RawMem.get8(chunk, i));
				} else if (r == -1) {
					closeHost();
					IModeAdaptor.busy = false;
					state = ANSWERING;
					reading = false;
				} else if (r < -1) {
					reject(REASON_NO_HOST);
					reading = false;
				} else {
					reading = false;
				}
				rounds++;
			}
			if (state == WAITING && waited > PATIENCE) reject(REASON_TIMEOUT);
			else {}
		} else {}
		if (state == ANSWERING) send();
		else {}
	}

	static inline function keep(b:Int):Void {
		if (responseLength < RESPONSE) {
			RawMem.set8(response, responseLength, b);
			responseLength++;
		} else {}
	}

	/** The response to the console: TLP_CONNECT_ACK, TLP_DATA and TLP_DATA_EOF, as there is room. */
	static function send():Void {
		var going = true;
		while (going && state == ANSWERING) {
			final left = responseLength - responseSent;
			final n = left < SEGMENT ? left : SEGMENT;
			final data = segment == 0 || n > 0;
			var at = 5;
			if (segment == 0) {
				at = w(at, 0x11);            // TLP_CONNECT_ACK
				at = w(at, logical);
				at = w(at, 0x01);            // Communication Mode
				at = w(at, 0x01);            // Communication Parameters[7], as the request's
				at = w(at, 0x01);
				at = w(at, 0x8C);
				at = w(at, 0x01);
				at = w(at, 0xFF);
				at = w(at, 0x00);
				at = w(at, 0x0A);
				at = w(at, 0x07);            // Logic State: bit2, a requested segment, data
				at = w(at, 0x01);            // Requested Segment Number
			} else if (n > 0) {
				at = w(at, 0x30);            // TLP_DATA
				at = w(at, logical);
				at = w(at, 0x03);            // Logic State
				at = w(at, 0x01);            // Requested Segment Number
			} else {
				at = w(at, 0x31);            // TLP_DATA_EOF
				at = w(at, logical);
				at = w(at, 0x01);            // Requested Segment Number
			}
			if (data) {
				at = w(at, 0xC0 | (segment & 0x3F));
				at = w(at, n >> 8);
				at = w(at, n & 0xFF);
				for (i in 0...n) at = w(at, RawMem.get8(response, responseSent + i));
			} else {}
			if (sendTlp(at - 3)) {
				if (data) {
					responseSent += n;
					segment++;
				} else {
					state = ANSWERED;
				}
			} else {
				going = false;
			}
		}
	}

	static inline function w(at:Int, v:Int):Int {
		packetOut[at] = v & 0xFF;
		return at + 1;
	}

	/**
		A TLP message of `n` bytes at packetOut[3..], its checksum at [3..4] filled in, sent as a
		transfer message: 01h, the block numbers, 01h. False when the adaptor has no room yet.
	**/
	static function sendTlp(n:Int):Bool {
		packetOut[0] = 0x01;
		packetOut[1] = (consoleBlock << 5) | (ourBlock << 1);
		packetOut[2] = 0x01;
		IModeWire.sealTlp(packetOut, 3, n);
		final sent = IModeAdaptor.packet(packetOut, 3 + n);
		if (sent) ourBlock = (ourBlock + 1) & 7;
		else {}
		return sent;
	}

	// ---- bytes of the request ---------------------------------------------------------------------

	/** Where `a` (then `b`, when not -1) is first found in `buf[from..end)`, or -1. */
	static function find(buf:RawBuf, end:Int, from:Int, a:Int, b:Int):Int {
		var found = -1;
		var i = from;
		while (found < 0 && i < end) {
			if (RawMem.get8(buf, i) == a && (b < 0 || (i + 1 < end && RawMem.get8(buf, i + 1) == b))) found = i;
			else {}
			i++;
		}
		return found;
	}

	static inline function lower(i:Int):Int return RawMem.get8(request, i) | 0x20;

	/** Whether the header lines from `at` have a `Host:` one. */
	static function hasHost(at:Int):Bool {
		var found = false;
		var line = at;
		var going = true;
		while (going && line + 5 <= requestLength) {
			final eol = find(request, requestLength, line, 0x0D, 0x0A);
			if (eol < 0 || eol == line) {
				going = false;
			} else {
				if (lower(line) == 0x68 && lower(line + 1) == 0x6F && lower(line + 2) == 0x73
					&& lower(line + 3) == 0x74 && RawMem.get8(request, line + 4) == 0x3A) found = true;
				else {}
				line = eol + 2;
			}
		}
		return found;
	}

	static function copy(from:Int, to:Int, o:Int):Int {
		var at = o;
		for (i in from...to) at = put(RawMem.get8(request, i), at);
		return at;
	}

	static function put(b:Int, o:Int):Int {
		if (o < OUTGOING) RawMem.set8(outgoing, o, b);
		else {}
		return o + 1;
	}
}
