import kernel.KIMode;
import mod.LibImode;
import mod.ModHost;
import sio.IModeAdaptor;
import sio.IModeWire;

/**
	The i-mode adaptor (ADR-0040) the same on every target: its wire formats (the X.25 CRC, the TLP
	checksum), its answers to the controller port's commands, and a whole session driven by
	`mod.LibImode` against the phone the kernel plays — authentication, the gateway, a request out
	(its absolute URL made origin-form, a Host header added), a response of several segments back,
	and everything closed again — a request with no network, which the centre rejects, and URLs it
	cannot take (a bad or missing port or host), rejected before any host hears of them. The
	backends here have no network: the responses are canned.
**/
class IMode {
	static var send:Array<Int>;
	static var reply:Array<Int>;

	public static function main():Void {
		Conf.feedName("IMode");
		final digits = [for (c in 0...9) 0x31 + c];
		Conf.expect("X.25 of 123456789", IModeWire.crc16(digits, 0, 9), 0x906E);
		Conf.expect("the TLP checksum of 0001 F203 F4F5 F6F7", IModeWire.tlpSum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7], 0, 8), 0x220D);
		Conf.expect("an odd byte is a high half", IModeWire.tlpSum([0x12, 0x34, 0x56], 0, 3), 0x97CB);
		Conf.expect("XOR", IModeWire.xorOf([0x0F, 0xF0, 0x33], 0, 3), 0xCC);

		KIMode.init();
		send = [for (_ in 0...0x88) 0];
		reply = [for (_ in 0...0x88) 0];
		final port = ModHost.plugIMode();
		Conf.expect("a port", port, 0);
		Conf.expect("one adaptor", ModHost.plugIMode(), -1);
		Conf.expect("a pad's address is not its", command(port, [0x01, 0x42, 0, 0, 0]) ? 1 : 0, 0);
		Conf.expect("11h answers", command(port, [0x41, 0x11, 0, 0, 0]) ? 1 : 0, 1);
		Conf.expect("00h under the address", reply[0], 0x00);
		Conf.expect("5Ah", reply[1], 0x5A);
		Conf.expect("8Eh", reply[2], 0x8E);
		Conf.expect("asleep", reply[3], 0x00);
		command(port, [0x41, 0x12, 0x07, 0x03, 0, 0, 0]);
		Conf.expect("12h: 6Fh", reply[2], 0x6F);
		Conf.expect("X past 4 is 0", reply[3], 0x00);
		Conf.expect("Y as written", reply[4], 0x03);
		command(port, [0x41, 0x13, 0x0F, 0, 0]);
		Conf.expect("13h: C0h", reply[2], 0xC0);
		Conf.expect("awake", reply[3], 0x01);
		command(port, [0x41, 0x16, 0x01, 0, 0]);
		Conf.expect("16h: 4Ah", reply[2], 0x4A);
		command(port, [0x41, 0x17, 0x10, 0, 0]);
		Conf.expect("17h: 56h", reply[2], 0x56);
		Conf.expect("reset: asleep again", reply[3], 0x00);
		Conf.expect("a command it does not know", command(port, [0x41, 0x19, 0, 0, 0]) ? 1 : 0, 0);

		// A whole session, against a canned host.
		LibImode.init(port);
		Conf.expect("dormant", LibImode.status, LibImode.DORMANT);
		final body = [for (i in 0...3000) 0x41 + (i % 26)];
		final head = bytes("HTTP/1.0 200 OK\r\nContent-Length: 3000\r\n\r\n");
		final answer = head.concat(body);
		KIMode.answerWith(answer);
		final request = bytes("GET http://10.0.0.1:9457/SCUS94570 HTTP/1.0\r\nUser-Agent: DoCoMo/1.0/recompsx\r\n\r\n");
		LibImode.setSend(request, request.length);
		run(LibImode.CMD_AUTH_START, "auth", LibImode.AUTH_STARTED, LibImode.OK);
		run(LibImode.CMD_GW_CONNECT, "gateway", LibImode.GW_CONNECTED, LibImode.OK);
		run(LibImode.CMD_SND, "send", LibImode.SENDCOMPLETE, LibImode.OK);
		final asked = bytes("GET /SCUS94570 HTTP/1.0\r\nHost: 10.0.0.1:9457\r\nUser-Agent: DoCoMo/1.0/recompsx\r\n\r\n");
		Conf.expect("the request as it went to the host", KIMode.hostRequestLength(), asked.length);
		var same = 0;
		for (i in 0...asked.length) {
			if (KIMode.hostRequestByte(i) == asked[i]) same++;
			else {}
		}
		Conf.expect("origin-form, with a Host", same, asked.length);
		run(LibImode.CMD_RCV, "receive", LibImode.DISCONNECTED, LibImode.OK);
		Conf.expect("the whole response", LibImode.receivedSize, answer.length);
		var equal = 0;
		for (i in 0...answer.length) {
			if (LibImode.received[i] == answer[i]) equal++;
			else {}
		}
		Conf.expect("as the host sent it", equal, answer.length);

		// No network here: the centre rejects the next request.
		run(LibImode.CMD_SND, "send again", LibImode.SENDCOMPLETE, LibImode.OK);
		run(LibImode.CMD_RCV, "no host", LibImode.DISCONNECTED, LibImode.REJECTED);

		// A URL the centre cannot take is rejected before any host hears of it, canned or not.
		KIMode.answerWith(answer);
		refused("GET http://10.0.0.1:94a7/SCUS94570 HTTP/1.0\r\n\r\n", "a port with a letter");
		refused("GET http://10.0.0.1:99999/SCUS94570 HTTP/1.0\r\n\r\n", "a port past 65535");
		refused("GET http://10.0.0.1:4294967297/SCUS94570 HTTP/1.0\r\n\r\n", "a port past 32 bits");
		refused("GET http://10.0.0.1:/SCUS94570 HTTP/1.0\r\n\r\n", "an empty port");
		refused("GET http://:9457/SCUS94570 HTTP/1.0\r\n\r\n", "no host");
		refused("GET /SCUS94570 HTTP/1.0\r\n\r\n", "no absolute URL");
		// No port is 80, no path is "/"; the canned answer is still there for it.
		final plain = bytes("GET http://example.com HTTP/1.0\r\n\r\n");
		LibImode.setSend(plain, plain.length);
		run(LibImode.CMD_SND, "a plain URL", LibImode.SENDCOMPLETE, LibImode.OK);
		final plainAsked = bytes("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");
		Conf.expect("a plain URL as it went", KIMode.hostRequestLength(), plainAsked.length);
		var plainSame = 0;
		for (i in 0...plainAsked.length) {
			if (KIMode.hostRequestByte(i) == plainAsked[i]) plainSame++;
			else {}
		}
		Conf.expect("a path of its own", plainSame, plainAsked.length);
		run(LibImode.CMD_RCV, "its answer", LibImode.DISCONNECTED, LibImode.OK);
		Conf.expect("its answer, whole", LibImode.receivedSize, answer.length);

		run(LibImode.CMD_GW_DISCONNECT, "gateway down", LibImode.GW_DISCONNECTED, LibImode.OK);
		run(LibImode.CMD_AUTH_END, "auth end", LibImode.AUTH_ENDED, LibImode.OK);
		Conf.report("IMode");
	}

	/** A command of the adaptor's, padded with zeros to 88h bytes of room; whether it answered. */
	static function command(port:Int, bytes:Array<Int>):Bool {
		for (i in 0...bytes.length) send[i] = bytes[i];
		final ok = ModHost.exchange(port, send, bytes.length, reply);
		for (i in 0...bytes.length) Conf.feed(reply[i]);
		return ok;
	}

	/** A LibImode command to its end, the kernel's side stepped with it: the vblanks it took. */
	static function run(cmd:Int, what:String, expected:Int, error:Int):Void {
		LibImode.issue(cmd);
		var frames = 0;
		while (LibImode.running && frames < 10000) {
			LibImode.poll();
			KIMode.sample();
			frames++;
		}
		Conf.feed(frames);
		Conf.expect(what + ": the state", LibImode.status, expected);
		Conf.expect(what + ": the error", LibImode.lastError, error);
	}

	/** A request the centre must reject: sent whole, then rejected when it is to be answered. */
	static function refused(text:String, what:String):Void {
		final request = bytes(text);
		LibImode.setSend(request, request.length);
		run(LibImode.CMD_SND, what + ", sent", LibImode.SENDCOMPLETE, LibImode.OK);
		run(LibImode.CMD_RCV, what + ", rejected", LibImode.DISCONNECTED, LibImode.REJECTED);
	}

	static function bytes(s:String):Array<Int> {
		final out:Array<Int> = [];
		for (i in 0...s.length) {
			final c:Null<Int> = s.charCodeAt(i);
			var v = 0;
			if (c != null) v = c;
			else {}
			out.push(v);
		}
		return out;
	}
}
