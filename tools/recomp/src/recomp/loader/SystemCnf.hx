package recomp.loader;

/**
	SYSTEM.CNF: the text file in a PlayStation disc's root that tells the BIOS what to boot.

	`BOOT = cdrom:\SCUS_945.70;1` names the executable, and on a licensed disc its name is the
	product code, written the way the discs write it: four letters, an underscore, three digits, a
	dot, two digits. That code is how the repository keys a game's facts — `games/SCUS94570/` —
	so a disc can find its own configuration without anyone saying which game it is.

	Read loosely, as the BIOS does: the key in any case, spaces or none around `=`, any device
	(`cdrom:`, `cdrom0:`), either slash, and whatever follows the path on the line (Crash Bash ends
	it with a tab; some games pass arguments).
**/
class SystemCnf {
	/**
		The executable's path inside the disc's filesystem, as a config writes it — `\SCUS_945.70;1`
		— or null when the file names none.
	**/
	public static function bootPath(text:String):Null<String> {
		for (raw in ~/\r\n|\r|\n/g.split(text)) {
			final line = StringTools.trim(raw);
			final eq = line.indexOf("=");
			if (eq < 0 || StringTools.trim(line.substr(0, eq)).toUpperCase() != "BOOT") continue;
			var value = StringTools.trim(line.substr(eq + 1));
			final space = firstSpace(value);
			if (space >= 0) value = value.substr(0, space);
			final colon = value.indexOf(":");
			if (colon >= 0) value = value.substr(colon + 1);
			value = StringTools.replace(value, "/", "\\");
			while (StringTools.startsWith(value, "\\\\")) value = value.substr(1);
			if (value.length == 0 || value == "\\") return null;
			return StringTools.startsWith(value, "\\") ? value : "\\" + value;
		}
		return null;
	}

	/**
		The product code in the form `games/` uses — `SCUS94570` — or null when the executable's
		name is not one (a homebrew disc's `PSX.EXE`, say). Upper case, with the underscore and the
		dot dropped.
	**/
	public static function serialOf(bootPath:String):Null<String> {
		var leaf = StringTools.replace(bootPath, "/", "\\");
		leaf = leaf.substr(leaf.lastIndexOf("\\") + 1);
		final semi = leaf.indexOf(";");
		if (semi >= 0) leaf = leaf.substr(0, semi);
		final code = StringTools.replace(StringTools.replace(leaf, "_", ""), ".", "").toUpperCase();
		return isSerial(code) ? code : null;
	}

	/** Whether `s` has the shape of a product code as `games/` spells it: `SCUS94570`. */
	public static function isSerial(s:String):Bool {
		return ~/^[A-Z]{4}[0-9]{5}$/.match(s);
	}

	static function firstSpace(s:String):Int {
		for (i in 0...s.length) {
			final c = s.charCodeAt(i);
			if (c == " ".code || c == "\t".code) return i;
		}
		return -1;
	}
}
