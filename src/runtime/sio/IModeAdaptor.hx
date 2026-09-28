package sio;

/**
	The i-mode adaptor (SCPH-10180): the cable that joins an i-mode phone to a controller port —
	the PS1's own way onto the internet (psx-spx, "Controllers - I-Mode Adaptor", ADR-0040). The
	phone, and DoCoMo's i-mode centre behind it, are the kernel's (`kernel.KIMode`), which takes the
	HTTP requests it carries out to the host's network.

	Addressed with 41h, it answers 00h under the address byte (a quirk of the real one: not Hi-Z),
	5Ah, and then, command by command:

	    11h  (5)    unknown                      8Eh, Stat[2]
	    12h  (7)    config X (0..4), Y           6Fh, X, Y, Stat[2]
	    13h  (5)    wake up (0Fh)                C0h, Stat[2] = 01h,00h
	    14h  (88h)  dual-stream transfer         Data[80h], MsgLen, Msg[2], Chksum, Stat[2]
	    15h  (1Fh)  single-stream transfer       MsgLen, Msg[19h], Chksum, Stat[2]
	    16h  (5)    stream mode (1: command 14h) 4Ah, Stat[2]
	    17h  (5)    clear and reset              56h, Stat[2]
	    18h  (6)    one-byte transfer            MsgLen, Msg[1], Stat[2]

	Two streams run through it, both ways. The small one carries the messages that start and end a
	session — authentication, the gateway — a few bytes a transfer, their checksum the XOR of what it
	covers. The large one carries packets, 80h bytes a command 14h, as snippets (`sio.IModeWire`),
	each packet ending in its X.25 CRC; the flags byte says when the phone is busy. What a transfer
	brings back was waiting before it began; what it takes is handed on once it is whole and sound.
	17h clears the console's side of the streams (bit0), the adaptor's (bit1), and with bit4 resets
	it all (Stat 00h,00h).

	In a headless digest run the phone finds no network (`kernel.KIMode`), so nothing from the host
	reaches the machine there.
**/
class IModeAdaptor {
	public static inline var ADDRESS = 0x41;

	/** Bytes waiting for the console on the small stream, at most. */
	static inline var DOWN = 512;
	/** Packet bytes waiting for the console, and packets. */
	static inline var OUT_BYTES = 8192;
	static inline var OUT_PACKETS = 64;
	/** The largest packet taken from the console: a 1400-byte TLP message and its headers. */
	static inline var IN_BYTES = 2048;

	static var plugged = false;
	static var stat0 = 0;
	static var stat1 = 0;
	static var configX = 0;
	static var configY = 0;
	static var dual = false;
	/** Whether the phone is busy: flags bit0 of every data block. */
	public static var busy = false;

	static var down:Array<Int>;
	static var downHead = 0;
	static var downCount = 0;

	static var outBytes:Array<Int>;
	static var outByteHead = 0;
	static var outByteCount = 0;
	static var outLengths:Array<Int>;
	static var outPacketHead = 0;
	static var outPacketCount = 0;
	/** Bytes of the first waiting packet already sent. */
	static var outSent = 0;

	static var inBytes:Array<Int>;
	static var inLength = 0;
	static var inTooLong = false;
	/** The data block a command 14h brings back, built before it goes. */
	static var block:Array<Int>;

	public static function init():Void {
		down = [for (_ in 0...DOWN) 0];
		outBytes = [for (_ in 0...OUT_BYTES) 0];
		outLengths = [for (_ in 0...OUT_PACKETS) 0];
		inBytes = [for (_ in 0...IN_BYTES) 0];
		block = [for (_ in 0...IModeWire.BLOCK) 0];
		plugged = false;
		reset();
	}

	/** Plugs the adaptor in; 0, or -1 when it already is (there is one). */
	public static function plug():Int {
		var unit = -1;
		if (!plugged) {
			plugged = true;
			unit = 0;
		} else {}
		return unit;
	}

	/** Its power-on state: asleep, the streams empty. */
	static function reset():Void {
		stat0 = 0;
		stat1 = 0;
		configX = 0;
		configY = 0;
		dual = false;
		busy = false;
		clearDown();
		clearUp();
	}

	static function clearDown():Void {
		downHead = 0;
		downCount = 0;
		outByteHead = 0;
		outByteCount = 0;
		outPacketHead = 0;
		outPacketCount = 0;
		outSent = 0;
	}

	static function clearUp():Void {
		inLength = 0;
		inTooLong = false;
	}

	// ---- the phone's side (kernel.KIMode) -------------------------------------------------------------

	/** A byte for the console on the small stream; false when it is full. */
	public static function message(b:Int):Bool {
		var kept = false;
		if (downCount < DOWN) {
			down[(downHead + downCount) & (DOWN - 1)] = b & 0xFF;
			downCount++;
			kept = true;
		} else {}
		return kept;
	}

	/** Room for a packet of `n` bytes (its CRC added) on the large stream. */
	public static function room(n:Int):Bool {
		return outPacketCount < OUT_PACKETS && outByteCount + n + 2 <= OUT_BYTES;
	}

	/** A packet for the console: `n` bytes of `b`, its CRC appended; false when there is no room. */
	public static function packet(b:Array<Int>, n:Int):Bool {
		var kept = false;
		if (n > 0 && room(n)) {
			final crc = IModeWire.crc16(b, 0, n);
			for (i in 0...n) outPut(b[i]);
			outPut(crc & 0xFF);
			outPut(crc >> 8);
			outLengths[(outPacketHead + outPacketCount) & (OUT_PACKETS - 1)] = n + 2;
			outPacketCount++;
			kept = true;
		} else {}
		return kept;
	}

	static inline function outPut(b:Int):Void {
		outBytes[(outByteHead + outByteCount) & (OUT_BYTES - 1)] = b & 0xFF;
		outByteCount++;
	}

	// ---- the controller port ------------------------------------------------------------------------

	/**
		One transfer, as SIO0 makes it: `send[0..length)` out — address 41h, a command, its bytes —
		and as many bytes back into `reply`. False, and FFh throughout, when nothing answers: the
		adaptor not plugged in, another address, a command it does not know.
	**/
	public static function exchange(unit:Int, send:Array<Int>, length:Int, reply:Array<Int>):Bool {
		for (i in 0...length) reply[i] = 0xFF;
		var answered = unit == 0 && plugged && length >= 2 && send[0] == ADDRESS;
		if (answered) {
			reply[0] = 0x00;
			reply[1] = 0x5A;
			final cmd = send[1];
			if (cmd == 0x11) {
				put(reply, length, 2, 0x8E);
				status(reply, length, 3);
			} else if (cmd == 0x12) {
				final x = at(send, length, 2);
				configX = x <= 4 ? x : 0;
				configY = at(send, length, 3);
				put(reply, length, 2, 0x6F);
				put(reply, length, 3, configX);
				put(reply, length, 4, configY);
				status(reply, length, 5);
			} else if (cmd == 0x13) {
				wake();
				put(reply, length, 2, 0xC0);
				status(reply, length, 3);
			} else if (cmd == 0x14) {
				dualTransfer(send, length, reply);
			} else if (cmd == 0x15) {
				singleTransfer(send, length, reply, 0x19);
			} else if (cmd == 0x16) {
				dual = (at(send, length, 2) & 1) != 0;
				put(reply, length, 2, 0x4A);
				status(reply, length, 3);
			} else if (cmd == 0x17) {
				clear(at(send, length, 2));
				put(reply, length, 2, 0x56);
				status(reply, length, 3);
			} else if (cmd == 0x18) {
				singleTransfer(send, length, reply, 1);
			} else {
				answered = false;
				for (i in 0...length) reply[i] = 0xFF;
			}
		} else {}
		return answered;
	}

	static function wake():Void {
		final asleep = stat0 == 0;
		stat0 = 1;
		stat1 = 0;
		if (asleep) kernel.KIMode.wake();
		else {}
	}

	static function clear(flags:Int):Void {
		if ((flags & 0x10) != 0) {
			reset();
			kernel.KIMode.reset();
		} else {
			if ((flags & 1) != 0) clearUp();
			else {}
			if ((flags & 2) != 0) clearDown();
			else {}
		}
	}

	/** Command 14h: 80h data bytes and up to two message bytes each way, then Stat. */
	static function dualTransfer(send:Array<Int>, length:Int, reply:Array<Int>):Void {
		fillBlock();
		for (i in 0...IModeWire.BLOCK) put(reply, length, 2 + i, block[i]);
		final n = downCount < 2 ? downCount : 2;
		put(reply, length, 0x82, n);
		for (i in 0...2) put(reply, length, 0x83 + i, i < n ? takeDown() : 0);
		put(reply, length, 0x85, IModeWire.xorOf(reply, 2, length >= 0x85 ? 0x83 : 0));
		status(reply, length, 0x86);
		if (length >= 0x86 && IModeWire.xorOf(send, 2, 0x83) == send[0x85]) {
			takeBlock(send, 2);
			final m = send[0x82] <= 2 ? send[0x82] : 2;
			for (i in 0...m) kernel.KIMode.fromConsole(send[0x83 + i]);
		} else {}
	}

	/** Commands 15h (up to 19h message bytes, checksummed) and 18h (one byte, not). */
	static function singleTransfer(send:Array<Int>, length:Int, reply:Array<Int>, size:Int):Void {
		final n = downCount < size ? downCount : size;
		put(reply, length, 2, n);
		for (i in 0...size) put(reply, length, 3 + i, i < n ? takeDown() : 0);
		final summed = size > 1;
		if (summed) put(reply, length, 3 + size, IModeWire.xorOf(reply, 2, length >= 3 + size ? 1 + size : 0));
		else {}
		status(reply, length, summed ? 4 + size : 3 + size);
		final whole = length >= (summed ? 4 + size : 3 + size);
		if (whole && (!summed || IModeWire.xorOf(send, 2, 1 + size) == send[3 + size])) {
			final m = send[2] <= size ? send[2] : size;
			for (i in 0...m) kernel.KIMode.fromConsole(send[3 + i]);
		} else {}
	}

	static function takeDown():Int {
		final b = down[downHead];
		downHead = (downHead + 1) & (DOWN - 1);
		downCount--;
		return b;
	}

	/** The next data block for the console: snippets of the waiting packets, then the flags. */
	static function fillBlock():Void {
		for (i in 0...IModeWire.BLOCK) block[i] = 0;
		var pos = 0;
		var going = outPacketCount > 0;
		while (going) {
			final left = outLengths[outPacketHead] - outSent;
			final space = IModeWire.FLAGS - pos - 2;
			var n = left < IModeWire.SNIPPET ? left : IModeWire.SNIPPET;
			if (n > space) n = space;
			else {}
			if (n <= 0) {
				going = false;
			} else {
				final last = n == left;
				block[pos] = n | (last ? 0x80 : 0);
				for (i in 0...n) block[pos + 1 + i] = outBytes[(outByteHead + i) & (OUT_BYTES - 1)];
				outByteHead = (outByteHead + n) & (OUT_BYTES - 1);
				outByteCount -= n;
				pos += 1 + n;
				if (last) {
					outPacketHead = (outPacketHead + 1) & (OUT_PACKETS - 1);
					outPacketCount--;
					outSent = 0;
					going = outPacketCount > 0;
				} else {
					outSent += n;
					going = false;
				}
			}
		}
		block[IModeWire.FLAGS] = busy ? IModeWire.PHONE_BUSY : 0;
	}

	/** A data block from the console: its snippets into the packet being taken. */
	static function takeBlock(send:Array<Int>, from:Int):Void {
		var pos = 0;
		var going = true;
		while (going) {
			final len = pos < IModeWire.FLAGS ? send[from + pos] : 0;
			final n = len & 0x7F;
			if (n == 0 || n > IModeWire.SNIPPET || pos + 1 + n > IModeWire.FLAGS) {
				going = false;
			} else {
				for (i in 0...n) {
					if (inLength < IN_BYTES) {
						inBytes[inLength] = send[from + pos + 1 + i] & 0xFF;
						inLength++;
					} else {
						inTooLong = true;
					}
				}
				pos += 1 + n;
				if ((len & 0x80) != 0) packetTaken();
				else {}
			}
		}
	}

	/** A packet taken whole: handed on when it fits and its CRC holds, dropped otherwise. */
	static function packetTaken():Void {
		if (!inTooLong && inLength > 2) {
			final n = inLength - 2;
			if (IModeWire.crc16(inBytes, 0, n) == (inBytes[n] | (inBytes[n + 1] << 8))) kernel.KIMode.packetFromConsole(inBytes, n);
			else {}
		} else {}
		clearUp();
	}

	static inline function status(reply:Array<Int>, length:Int, i:Int):Void {
		put(reply, length, i, stat0);
		put(reply, length, i + 1, stat1);
	}

	static inline function put(reply:Array<Int>, length:Int, i:Int, v:Int):Void {
		if (i < length) reply[i] = v & 0xFF;
		else {}
	}

	static inline function at(send:Array<Int>, length:Int, i:Int):Int return i < length ? send[i] & 0xFF : 0;
}
