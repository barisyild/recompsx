package mod;

import sio.IModeWire;

/**
	libimode: the console's side of the i-mode adaptor, shaped after Sony's library for it (psx-spx,
	"Controllers - I-Mode Adaptor - Libimode Library"; ADR-0040) — the commands and states of its
	sceImode_Param, driven over a port of the mod's own (`ModHost.plugIMode`) one controller transfer
	a vblank, as the PS1's software drove the cable.

	A mod gives a command and calls `poll` every vblank until it is done (`running` false); the
	state is then the one the command leads to, or `lastError` says why not:

	    CMD_AUTH_START     the adaptor woken and configured, the phone authenticated  AUTH_STARTED
	    CMD_GW_CONNECT     the gateway connected, then the transport                  GW_CONNECTED
	    CMD_SND            the request given to `setSend` — a whole HTTP request with an absolute
	                       URL, `GET http://host:port/path HTTP/1.0` — as TLP_CONNECT_REQ, TLP_DATA
	                       and TLP_DATA_EOF                                            SENDCOMPLETE
	    CMD_RCV            the response, as the server sent it, into `received`; then the
	                       connection closed                                           DISCONNECTED
	    CMD_GW_DISCONNECT  the transport down, then the gateway                        GW_DISCONNECTED
	    CMD_AUTH_END       the phone left, the adaptor reset                           AUTH_ENDED
	    CMD_ABORT          the connection dropped                                      DISCONNECTED
	    CMD_STS            nothing: the state can always be read

	What goes over the cable is the documented protocol: commands 12h, 13h, 16h and 17h to set the
	adaptor up, the small stream through command 15h for the session's messages (AUTH_START_REQ,
	AUTH_CRYPT_REQ, AUTH_DONE, GW_CONNECT_REQ, GW_DISCONNECT_REQ, DEAUTH_REQ), and the large one
	through command 14h for the transport's packets (01h,3Fh up, 01h,53h down) and the TLP messages,
	as snippets with their CRC (`sio.IModeWire`).
**/
class LibImode {
	// Commands (IMODE_CMD_*).
	public static inline var CMD_RCV = 0;
	public static inline var CMD_SND = 1;
	public static inline var CMD_STS = 2;
	public static inline var CMD_ABORT = 3;
	public static inline var CMD_AUTH_START = 4;
	public static inline var CMD_AUTH_END = 5;
	public static inline var CMD_GW_CONNECT = 6;
	public static inline var CMD_GW_DISCONNECT = 7;

	// States.
	public static inline var UNINITIALIZED = -1;
	public static inline var DORMANT = 0x00;
	public static inline var AUTH_STARTING = 0x01;
	public static inline var AUTH_STARTED = 0x02;
	public static inline var GW_CONNECTING = 0x03;
	public static inline var GW_CONNECTED = 0x04;
	public static inline var CONNECTING = 0x05;
	public static inline var CONNECTED = 0x06;
	public static inline var SENDING = 0x07;
	public static inline var SENDCOMPLETE = 0x08;
	public static inline var RECEIVING = 0x09;
	public static inline var RECEIVECOMPLETE = 0x0A;
	public static inline var DISCONNECTING = 0x0B;
	public static inline var DISCONNECTED = 0x0C;
	public static inline var GW_DISCONNECTING = 0x0D;
	public static inline var GW_DISCONNECTED = 0x0E;
	public static inline var AUTH_ENDING = 0x0F;
	public static inline var AUTH_ENDED = 0x10;

	// Errors (0, or negative).
	public static inline var OK = 0;
	public static inline var NO_ADAPTOR = -1;
	public static inline var TIMEOUT = -2;
	public static inline var REJECTED = -3;
	public static inline var BAD_STATE = -4;

	public static var status(default, null) = UNINITIALIZED;
	public static var lastError(default, null) = OK;
	/** Whether a command is running. */
	public static var running(default, null) = false;
	/** The response as the server sent it (status line, headers, body): `receivedSize` bytes. */
	public static var received(default, null):Array<Int>;
	public static var receivedSize(default, null) = 0;

	static inline var RECEIVE = 16384;        // the most of a response kept (the browser kept 10240)
	static inline var SEND = 4096;            // a request's bytes, at most
	static inline var SEGMENT = 1400;         // Transmit Data a TLP message carries
	static inline var MESSAGES = 128;         // the small stream's bytes waiting to go
	static inline var PACKETS = 8192;         // the large stream's
	static inline var PACKET_COUNT = 16;
	static inline var PACKET_IN = 2048;
	/** Vblanks a step may wait for the phone; and for a response, while the phone is busy. */
	static inline var PATIENCE = 600;
	static inline var BUSY_PATIENCE = 2400;

	// What was heard on the small stream and the large one (bits of `heard`).
	static inline var WOKEN = 1;
	static inline var AUTH_START_ACK = 2;
	static inline var AUTH_CRYPT_ACK = 4;
	static inline var DEAUTH_ACK = 8;
	static inline var GW_CONNECT_ACK = 16;
	static inline var GW_DISCONNECT_ACK = 32;
	static inline var TRANSPORT_UP = 64;
	static inline var TRANSPORT_DOWN = 128;
	static inline var DATA_EOF = 256;
	static inline var REJECT = 512;
	static inline var DISCONNECT_ACK = 1024;

	static var port = -1;
	static var command = 0;
	static var step = 0;
	static var waited = 0;
	static var heard = 0;
	static var phoneBusy = false;

	static var out:Array<Int>;
	static var back:Array<Int>;

	static var messages:Array<Int>;
	static var messageHead = 0;
	static var messageCount = 0;
	static var heardMessage:Array<Int>;
	static var heardLength = 0;

	static var packets:Array<Int>;
	static var packetHead = 0;
	static var packetBytes = 0;
	static var packetLengths:Array<Int>;
	static var packetFirst = 0;
	static var packetCount = 0;
	static var packetSent = 0;
	static var packetIn:Array<Int>;
	static var packetInLength = 0;
	static var packetInBad = false;
	static var tlp:Array<Int>;

	static var request:Array<Int>;
	static var requestSize = 0;
	static var logical = 0;
	static var ourBlock = 0;
	static var theirBlock = 0;

	/** Once, when the mod installs: the port its adaptor is on (`ModHost.plugIMode`). */
	public static function init(adaptorPort:Int):Void {
		port = adaptorPort;
		out = [for (_ in 0...0x88) 0];
		back = [for (_ in 0...0x88) 0];
		messages = [for (_ in 0...MESSAGES) 0];
		heardMessage = [for (_ in 0...64) 0];
		packets = [for (_ in 0...PACKETS) 0];
		packetLengths = [for (_ in 0...PACKET_COUNT) 0];
		packetIn = [for (_ in 0...PACKET_IN) 0];
		tlp = [for (_ in 0...SEGMENT + 64) 0];
		request = [for (_ in 0...SEND) 0];
		received = [for (_ in 0...RECEIVE) 0];
		status = DORMANT;
		lastError = OK;
		running = false;
	}

	/** The request CMD_SND sends: `size` bytes of `bytes`. */
	public static function setSend(bytes:Array<Int>, size:Int):Void {
		requestSize = size < SEND ? size : SEND;
		for (i in 0...requestSize) request[i] = bytes[i] & 0xFF;
	}

	/** Starts a command; false while another runs, or before `init`. */
	public static function issue(cmd:Int):Bool {
		var started = false;
		if (!running && port >= 0) {
			command = cmd;
			step = 0;
			waited = 0;
			heard = 0;
			lastError = OK;
			running = cmd != CMD_STS;
			started = true;
		} else {}
		return started;
	}

	/** Once a vblank while a command runs: one transfer, and the command on as far as it goes. */
	public static function poll():Void {
		if (running) {
			waited++;
			switch (command) {
				case CMD_AUTH_START: authStart();
				case CMD_GW_CONNECT: gwConnect();
				case CMD_SND: sendRequest();
				case CMD_RCV: receive();
				case CMD_GW_DISCONNECT: gwDisconnect();
				case CMD_AUTH_END: authEnd();
				case CMD_ABORT: abort();
				default: running = false;
			}
			if (running && waited > (phoneBusy ? BUSY_PATIENCE : PATIENCE)) fail(TIMEOUT);
			else {}
		} else {}
	}

	// ---- the commands ------------------------------------------------------------------------------

	static function authStart():Void {
		status = AUTH_STARTING;
		if (step == 0) {
			if (control(0x13, 0x0F)) next();     // wake up
			else {}
		} else if (step == 1) {
			out[0] = 0x41;
			out[1] = 0x12;                       // config: X 0, Y 3 (used before shutdown)
			out[2] = 0x00;
			out[3] = 0x03;
			out[4] = 0x00;
			out[5] = 0x00;
			out[6] = 0x00;
			if (transfer(7)) next();
			else {}
		} else if (step == 2) {
			if (control(0x16, 0x00)) next();     // single-stream: command 15h
			else {}
		} else if (step == 3) {
			if (control(0x17, 0x03)) {           // both queues clear
				// AUTH_START_REQ: 85h,01h,01h,02h, eight nibbles of our random, 00h,03h,00h,00h,01h.
				say4(0x85, 0x01, 0x01, 0x02);
				for (i in 0...8) say(randomNibble(i));
				say4(0x00, 0x03, 0x00, 0x00);
				say(0x01);
				next();
			} else {}
		} else if (step == 4) {
			if (single() && (heard & AUTH_START_ACK) != 0) {
				// AUTH_CRYPT_REQ: 85h,01h,04h,02h, eight nibbles.
				say4(0x85, 0x01, 0x04, 0x02);
				for (i in 0...8) say(randomNibble(i + 3));
				next();
			} else {}
		} else if (step == 5) {
			if (single() && (heard & AUTH_CRYPT_ACK) != 0) {
				say4(0x85, 0x01, 0x05, 0x02);    // AUTH_DONE
				next();
			} else {}
		} else if (single() && messageCount == 0) {
			done(AUTH_STARTED);
		} else {}
	}

	static function gwConnect():Void {
		status = GW_CONNECTING;
		if (step == 0) {
			// GW_CONNECT_REQ: F2h,00h,01h,02h,08h,00h,00h,00h,00h.
			say4(0xF2, 0x00, 0x01, 0x02);
			say4(0x08, 0x00, 0x00, 0x00);
			say(0x00);
			next();
		} else if (step == 1) {
			if (single() && (heard & GW_CONNECT_ACK) != 0) next();
			else {}
		} else if (step == 2) {
			if (control(0x16, 0x01)) {           // dual-stream: command 14h
				queueControl(0x3F);              // the transport up
				next();
			} else {}
		} else if (dual() && (heard & TRANSPORT_UP) != 0) {
			ourBlock = 0;
			theirBlock = 0;
			done(GW_CONNECTED);
		} else {}
	}

	static function sendRequest():Void {
		if (step == 0) {
			if (status != GW_CONNECTED && status != DISCONNECTED && status != RECEIVECOMPLETE) {
				fail(BAD_STATE);
			} else {
				logical = logical >= 0x7F ? 1 : logical + 1;
				receivedSize = 0;
				status = CONNECTING;
				// TLP_CONNECT_REQ with the request's first 1400 bytes; TLP_DATA with the rest.
				var sent = 0;
				var segment = 0;
				while (sent < requestSize || segment == 0) {
					final n = requestSize - sent < SEGMENT ? requestSize - sent : SEGMENT;
					var at = 2;
					if (segment == 0) {
						at = t(at, 0x10);        // TLP_CONNECT_REQ
						at = t(at, 0x0A);        // Service Identifier
						at = t(at, logical);
						at = t(at, 0x01);        // Communication Mode
						at = t(at, 0x01);        // Communication Parameters: 1400-byte packets
						at = t(at, 0x01);
						at = t(at, 0x8C);
						at = t(at, 0x01);
						at = t(at, 0xFF);
						at = t(at, 0x00);
						at = t(at, 0x0A);
						at = t(at, 0x09);        // Logic State: Operator Specific Information, data
						at = t(at, 0x48);        // Operator Specific Information, as the PSX sent it
						at = t(at, 0x21);
					} else {
						at = t(at, 0x30);        // TLP_DATA
						at = t(at, logical);
						at = t(at, 0x03);        // Logic State
						at = t(at, 0x01);        // Requested Segment Number
					}
					at = t(at, 0xC0 | (segment & 0x3F));
					at = t(at, n >> 8);
					at = t(at, n & 0xFF);
					for (i in 0...n) at = t(at, request[sent + i]);
					queueTlp(at);
					sent += n;
					segment++;
				}
				var eof = 2;
				eof = t(eof, 0x31);              // TLP_DATA_EOF
				eof = t(eof, logical);
				eof = t(eof, 0x01);
				queueTlp(eof);
				next();
			}
		} else if (dual()) {
			status = packetCount > 0 ? SENDING : SENDCOMPLETE;
			if (packetCount == 0) done(SENDCOMPLETE);
			else {}
		} else {}
	}

	static function receive():Void {
		if (step == 0) {
			if (status != SENDCOMPLETE) fail(BAD_STATE);
			else {
				status = RECEIVING;
				next();
			}
		} else if (step == 1) {
			if (dual()) {
				if ((heard & REJECT) != 0) {
					lastError = REJECTED;
					done(DISCONNECTED);
				} else if ((heard & DATA_EOF) != 0) {
					status = RECEIVECOMPLETE;
					queueDisconnect();
					next();
				} else {}
			} else {}
		} else if (dual()) {
			status = DISCONNECTING;
			if ((heard & DISCONNECT_ACK) != 0) done(DISCONNECTED);
			else {}
		} else {}
	}

	static function gwDisconnect():Void {
		status = GW_DISCONNECTING;
		if (step == 0) {
			queueControl(0x53);                  // the transport down
			next();
		} else if (step == 1) {
			if (dual() && (heard & TRANSPORT_DOWN) != 0) next();
			else {}
		} else if (step == 2) {
			if (control(0x16, 0x00)) {
				// GW_DISCONNECT_REQ: F2h,00h,01h,02h,00h,00h,00h,00h,00h.
				say4(0xF2, 0x00, 0x01, 0x02);
				say4(0x00, 0x00, 0x00, 0x00);
				say(0x00);
				next();
			} else {}
		} else if (single() && (heard & GW_DISCONNECT_ACK) != 0) {
			done(GW_DISCONNECTED);
		} else {}
	}

	static function authEnd():Void {
		status = AUTH_ENDING;
		if (step == 0) {
			say(0x85);                           // DEAUTH_REQ: 85h,01h,06h
			say(0x01);
			say(0x06);
			next();
		} else if (step == 1) {
			if (single() && (heard & DEAUTH_ACK) != 0) next();
			else {}
		} else if (control(0x17, 0x10)) {        // reset
			done(AUTH_ENDED);
		} else {}
	}

	static function abort():Void {
		if (step == 0) {
			if (status >= CONNECTING && status < DISCONNECTED) {
				queueDisconnect();
				next();
			} else {
				done(status);
			}
		} else if (dual() && (heard & (DISCONNECT_ACK | REJECT)) != 0) {
			done(DISCONNECTED);
		} else {}
	}

	static inline function next():Void {
		step++;
		waited = 0;
	}

	static function done(state:Int):Void {
		status = state;
		running = false;
	}

	static function fail(error:Int):Void {
		lastError = error;
		running = false;
	}

	/** Our random nibbles: any will do for the phone; these are fixed, so runs repeat. */
	static inline function randomNibble(i:Int):Int return (i * 7 + 3) & 0x0F;

	// ---- transfers -----------------------------------------------------------------------------------

	/** A five-byte command: 41h, the command, its byte, two zeros. */
	static function control(cmd:Int, value:Int):Bool {
		out[0] = 0x41;
		out[1] = cmd;
		out[2] = value;
		out[3] = 0x00;
		out[4] = 0x00;
		return transfer(5);
	}

	/** Command 15h: up to 19h of our message bytes out, the phone's back. */
	static function single():Bool {
		out[0] = 0x41;
		out[1] = 0x15;
		final n = messageCount < 0x19 ? messageCount : 0x19;
		out[2] = n;
		for (i in 0...0x19) out[3 + i] = i < n ? messages[(messageHead + i) & (MESSAGES - 1)] : 0;
		out[0x1C] = IModeWire.xorOf(out, 2, 0x1A);
		out[0x1D] = 0x00;
		out[0x1E] = 0x00;
		final ok = transfer(0x1F);
		if (ok) {
			messageHead = (messageHead + n) & (MESSAGES - 1);
			messageCount -= n;
			if (IModeWire.xorOf(back, 2, 0x1A) == back[0x1C]) {
				final m = back[2] <= 0x19 ? back[2] : 0;
				for (i in 0...m) hear(back[3 + i]);
			} else {}
		} else {}
		return ok;
	}

	/** Command 14h: our packets' next snippets and up to two message bytes out; theirs back. */
	static function dual():Bool {
		out[0] = 0x41;
		out[1] = 0x14;
		fillBlock();
		final n = messageCount < 2 ? messageCount : 2;
		out[0x82] = n;
		for (i in 0...2) out[0x83 + i] = i < n ? messages[(messageHead + i) & (MESSAGES - 1)] : 0;
		out[0x85] = IModeWire.xorOf(out, 2, 0x83);
		out[0x86] = 0x00;
		out[0x87] = 0x00;
		final ok = transfer(0x88);
		if (ok) {
			messageHead = (messageHead + n) & (MESSAGES - 1);
			messageCount -= n;
			if (IModeWire.xorOf(back, 2, 0x83) == back[0x85]) {
				phoneBusy = (back[2 + IModeWire.FLAGS] & IModeWire.PHONE_BUSY) != 0;
				takeBlock();
				final m = back[0x82] <= 2 ? back[0x82] : 0;
				for (i in 0...m) hear(back[0x83 + i]);
			} else {}
		} else {}
		return ok;
	}

	/** One transfer of `length` bytes; false, and the command failed, when nothing answered. */
	static function transfer(length:Int):Bool {
		final ok = ModHost.exchange(port, out, length, back) && back[1] == 0x5A;
		if (!ok) fail(NO_ADAPTOR);
		else {}
		return ok;
	}

	// ---- the small stream ------------------------------------------------------------------------------

	static function say(b:Int):Void {
		if (messageCount < MESSAGES) {
			messages[(messageHead + messageCount) & (MESSAGES - 1)] = b & 0xFF;
			messageCount++;
		} else {}
	}

	static inline function say4(a:Int, b:Int, c:Int, d:Int):Void {
		say(a);
		say(b);
		say(c);
		say(d);
	}

	/** A byte of the phone's messages. */
	static function hear(b:Int):Void {
		if (heardLength < 64) {
			heardMessage[heardLength] = b & 0xFF;
			heardLength++;
		} else {}
		final need = heardNeeds();
		if (need == 0) {
			heardLength = 0;
		} else if (need > 0 && heardLength >= need) {
			understood();
			heardLength = 0;
		} else {}
	}

	/** How long the message being heard is: 0 when no message starts so, -1 until it can be told. */
	static function heardNeeds():Int {
		final m = heardMessage;
		final got = heardLength;
		var need = 0;
		if (m[0] == 0x38) need = 2;
		else if (m[0] == 0xAA) need = 1;
		else if (m[0] == 0x85) {
			if (got < 3) need = -1;
			else if (m[2] == 0x02) need = got < 7 ? -1 : 7 + nibbles(m[5], m[6]);
			else if (m[2] == 0x03) need = 6;
			else if (m[2] == 0x04) need = got < 14 ? -1 : 14 + nibbles(m[12], m[13]);
			else need = 3;
		} else if (m[0] == 0xF2) {
			if (got < 3) need = -1;
			else if (m[2] == 0x03) need = got < 7 ? -1 : 7 + nibbles(m[5], m[6]);
			else if (got < 8) need = -1;
			else need = 8 + nibbles(m[6], m[7]) + (m[4] == 0x01 || m[4] == 0x09 ? 1 : 4);
		} else {}
		return need;
	}

	static inline function nibbles(h:Int, l:Int):Int return ((h & 0x0F) << 4) | (l & 0x0F);

	static function understood():Void {
		final m = heardMessage;
		if (m[0] == 0x38) heard |= WOKEN;
		else if (m[0] == 0x85 && m[2] == 0x04) heard |= AUTH_START_ACK;
		else if (m[0] == 0x85 && m[2] == 0x02) heard |= AUTH_CRYPT_ACK;
		else if (m[0] == 0x85 && m[2] == 0x07) heard |= DEAUTH_ACK;
		else if (m[0] == 0xF2 && m[2] == 0x02 && m[4] == 0x08) heard |= GW_CONNECT_ACK;
		else if (m[0] == 0xF2 && m[2] == 0x02 && m[4] == 0x00) heard |= GW_DISCONNECT_ACK;
		else {}
	}

	// ---- the large stream ------------------------------------------------------------------------------

	static inline function t(at:Int, v:Int):Int {
		tlp[at] = v & 0xFF;
		return at + 1;
	}

	/** The TLP message built in `tlp[0..n)`, its checksum sealed, as a transfer message. */
	static function queueTlp(n:Int):Void {
		IModeWire.sealTlp(tlp, 0, n);
		final total = 3 + n + 2;
		if (packetCount < PACKET_COUNT && packetBytes + total <= PACKETS) {
			final start = packetBytes;
			packetPut(0x01);
			packetPut((theirBlock << 5) | (ourBlock << 1));
			packetPut(0x01);
			for (i in 0...n) packetPut(tlp[i]);
			final crc = crcOfLast(start, 3 + n);
			packetPut(crc & 0xFF);
			packetPut(crc >> 8);
			packetLengths[(packetFirst + packetCount) & (PACKET_COUNT - 1)] = total;
			packetCount++;
			ourBlock = (ourBlock + 1) & 7;
		} else {}
	}

	/** A control packet of two bytes: 01h and its code. */
	static function queueControl(code:Int):Void {
		if (packetCount < PACKET_COUNT && packetBytes + 4 <= PACKETS) {
			final start = packetBytes;
			packetPut(0x01);
			packetPut(code);
			final crc = crcOfLast(start, 2);
			packetPut(crc & 0xFF);
			packetPut(crc >> 8);
			packetLengths[(packetFirst + packetCount) & (PACKET_COUNT - 1)] = 4;
			packetCount++;
		} else {}
	}

	static function queueDisconnect():Void {
		var at = 2;
		at = t(at, 0x20);                        // TLP_DISCONNECT_REQ
		at = t(at, logical);
		at = t(at, 0x00);                        // Disconnect Reason: done
		at = t(at, 0x00);                        // Logic State
		queueTlp(at);
	}

	static inline function packetPut(b:Int):Void {
		packets[(packetHead + packetBytes) & (PACKETS - 1)] = b & 0xFF;
		packetBytes++;
	}

	/** The CRC of `n` bytes queued from `start` (relative to the queue's head). */
	static function crcOfLast(start:Int, n:Int):Int {
		var crc = 0xFFFF;
		for (i in 0...n) {
			crc = crc ^ packets[(packetHead + start + i) & (PACKETS - 1)];
			for (k in 0...8) crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0x8408) : (crc >> 1);
		}
		return crc ^ 0xFFFF;
	}

	/** Our next data block into out[2..0x81]: snippets of the queued packets, the flags last. */
	static function fillBlock():Void {
		for (i in 0...IModeWire.BLOCK) out[2 + i] = 0;
		var pos = 0;
		var going = packetCount > 0;
		while (going) {
			final left = packetLengths[packetFirst] - packetSent;
			final space = IModeWire.FLAGS - pos - 2;
			var n = left < IModeWire.SNIPPET ? left : IModeWire.SNIPPET;
			if (n > space) n = space;
			else {}
			if (n <= 0) {
				going = false;
			} else {
				final last = n == left;
				out[2 + pos] = n | (last ? 0x80 : 0);
				for (i in 0...n) out[3 + pos + i] = packets[(packetHead + i) & (PACKETS - 1)];
				packetHead = (packetHead + n) & (PACKETS - 1);
				packetBytes -= n;
				pos += 1 + n;
				if (last) {
					packetFirst = (packetFirst + 1) & (PACKET_COUNT - 1);
					packetCount--;
					packetSent = 0;
					going = packetCount > 0;
				} else {
					packetSent += n;
					going = false;
				}
			}
		}
	}

	/** Their data block, back[2..0x81]: snippets into the packet being taken. */
	static function takeBlock():Void {
		var pos = 0;
		var going = true;
		while (going) {
			final len = pos < IModeWire.FLAGS ? back[2 + pos] : 0;
			final n = len & 0x7F;
			if (n == 0 || n > IModeWire.SNIPPET || pos + 1 + n > IModeWire.FLAGS) {
				going = false;
			} else {
				for (i in 0...n) {
					if (packetInLength < PACKET_IN) {
						packetIn[packetInLength] = back[3 + pos + i];
						packetInLength++;
					} else {
						packetInBad = true;
					}
				}
				pos += 1 + n;
				if ((len & 0x80) != 0) {
					final whole = packetInLength - 2;
					if (!packetInBad && whole > 0
						&& IModeWire.crc16(packetIn, 0, whole) == (packetIn[whole] | (packetIn[whole + 1] << 8)))
						packetTaken(whole);
					else {}
					packetInLength = 0;
					packetInBad = false;
				} else {}
			}
		}
	}

	/** A packet from the phone, whole and sound. */
	static function packetTaken(n:Int):Void {
		final b1 = n >= 2 ? packetIn[1] : 0;
		if (n == 2 && b1 == 0x73) heard |= TRANSPORT_UP;
		else if (n == 2 && b1 == 0x1F) heard |= TRANSPORT_DOWN;
		else if (n >= 3 && (b1 & 1) == 0 && IModeWire.tlpSound(packetIn, 3, n - 3)) {
			theirBlock = (b1 >> 1) & 7;
			final type = packetIn[5];
			if (type == 0x11) keep(3, n, 12, 13);    // TLP_CONNECT_ACK
			else if (type == 0x30) keep(3, n, 4, 5); // TLP_DATA
			else if (type == 0x31) heard |= DATA_EOF;
			else if (type == 0x12) heard |= REJECT;
			else if (type == 0x21) heard |= DISCONNECT_ACK;
			else {}
		} else {}
	}

	/** A message's Transmit Data (after its Logic State and what that says comes first) kept. */
	static function keep(from:Int, n:Int, stateAt:Int, partsAt:Int):Void {
		final logic = packetIn[from + stateAt];
		var pos = from + partsAt;
		if ((logic & 0x08) != 0) pos += 2;
		else {}
		if ((logic & 0x02) != 0) pos += 1;
		else {}
		if ((logic & 0x01) != 0 && pos + 3 <= n) {
			var len = (packetIn[pos + 1] << 8) | packetIn[pos + 2];
			pos += 3;
			if (pos + len > n) len = n - pos;
			else {}
			for (i in 0...len) {
				if (receivedSize < RECEIVE) {
					received[receivedSize] = packetIn[pos + i];
					receivedSize++;
				} else {}
			}
		} else {}
	}
}
