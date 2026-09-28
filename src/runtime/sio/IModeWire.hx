package sio;

/**
	The i-mode adaptor's wire formats (psx-spx, "Controllers - I-Mode Adaptor"), shared by the
	adaptor (`sio.IModeAdaptor`), the phone and centre behind it (`kernel.KIMode`) and the console's
	side of the conversation (`mod.LibImode`), so that all three count the same way.

	- **Command checksums** (14h, 15h): the covered bytes XORed together.
	- **Packet CRC**: CRC16-CCITT reversed — polynomial 8408h, initial FFFFh, the result XOR FFFFh
	  (the X.25 CRC: "123456789" gives 906Eh) — sent little-endian after the packet's bytes.
	- **TLP checksum**: the one's complement sum of the message's 16-bit values after the checksum
	  itself, big-endian, a last odd byte as the high half, carries folded back, XOR FFFFh.
	- **Snippets**: a command 14h carries 80h data bytes — snippets of a length (1..58h, bit7 on a
	  packet's last) and its bytes, 00h after the last snippet, padding, and the flags at 7Fh.
**/
class IModeWire {
	/** Data bytes one snippet carries, at most. */
	public static inline var SNIPPET = 0x58;
	/** The data area of a command 14h, and where its flags are. */
	public static inline var BLOCK = 0x80;
	public static inline var FLAGS = 0x7F;
	/** Flags bit0: the phone is busy. */
	public static inline var PHONE_BUSY = 1;

	/** XOR of `n` bytes from `from`. */
	public static function xorOf(b:Array<Int>, from:Int, n:Int):Int {
		var x = 0;
		for (i in 0...n) x = x ^ (b[from + i] & 0xFF);
		return x;
	}

	/** The X.25 CRC of `n` bytes from `from`. */
	public static function crc16(b:Array<Int>, from:Int, n:Int):Int {
		var crc = 0xFFFF;
		for (i in 0...n) {
			crc = crc ^ (b[from + i] & 0xFF);
			for (k in 0...8) crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0x8408) : (crc >> 1);
		}
		return crc ^ 0xFFFF;
	}

	/** The TLP checksum of `n` bytes from `from` (the bytes after the checksum field). */
	public static function tlpSum(b:Array<Int>, from:Int, n:Int):Int {
		var sum = 0;
		var i = 0;
		while (i < n) {
			final hi = b[from + i] & 0xFF;
			final lo = i + 1 < n ? b[from + i + 1] & 0xFF : 0;
			sum = sum + ((hi << 8) | lo);
			sum = (sum & 0xFFFF) + (sum >> 16);
			i += 2;
		}
		return (sum & 0xFFFF) ^ 0xFFFF;
	}

	/** Writes a TLP message's checksum over its `n` bytes from `from` (the first two are it). */
	public static function sealTlp(b:Array<Int>, from:Int, n:Int):Void {
		final s = tlpSum(b, from + 2, n - 2);
		b[from] = s >> 8;
		b[from + 1] = s & 0xFF;
	}

	/** Whether a TLP message of `n` bytes from `from` carries the checksum of the rest. */
	public static function tlpSound(b:Array<Int>, from:Int, n:Int):Bool {
		return n >= 3 && ((b[from] << 8) | b[from + 1]) == tlpSum(b, from + 2, n - 2);
	}
}
