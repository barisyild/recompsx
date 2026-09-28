package onlinemenu;

/**
	Whether what was typed is an address to connect to: four numbers 0..255 separated by dots, and
	nothing else — the port is the game's own (`Online.PORT`), never typed. No leading zeros ("010"
	reads as octal to some resolvers and as decimal to others, so it is refused, not guessed at).
**/
class Address {
	public static function valid(chars:Array<Int>, length:Int):Bool {
		var ok = length > 0;
		var numbers = 0;
		var value = 0;
		var digits = 0;
		var leadingZero = false;
		var i = 0;
		while (ok && i <= length) {
			var c = -1;               // -1 marks the end
			if (i < length) c = chars[i];
			else {}
			if (c >= "0".code && c <= "9".code) {
				if (digits == 1 && leadingZero) ok = false;
				else {}
				if (digits == 0 && c == "0".code) leadingZero = true;
				else {}
				value = value * 10 + (c - "0".code);
				digits++;
				if (digits > 3) ok = false;
				else {}
			} else {
				// A number ends here: it must have digits and fit a byte.
				if (digits == 0 || value > 255) ok = false;
				else {}
				numbers++;
				if (c == ".".code) {
					if (numbers >= 4) ok = false;
					else {}
				} else if (c == -1) {
					if (numbers != 4) ok = false;
					else {}
				} else {
					ok = false;
				}
				value = 0;
				digits = 0;
				leadingZero = false;
			}
			i++;
		}
		return ok;
	}
}
