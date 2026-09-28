import kernel.KSettings;
import shim.RawMem;

/**
	The console settings file (`kernel.KSettings`, ADR-0034) read and written the same way on every
	target: `key=value` lines, a value holding '=' kept whole, junk lines skipped, a file that would
	not fit refused. Storage itself is the backend's and differs by design (a file, the browser's
	local storage, nothing), so only the format is held to one digest here.
**/
class Settings {
	public static function main():Void {
		Conf.feedName("Settings");
		final buf = RawMem.alloc(256);

		final keys = ["net.last_address", "ui.lang", "ui.scale"];
		final values = ["192.168.1.20", "tr", "2"];
		final n = KSettings.serialize(keys, values, buf, 256);
		Conf.expect("three lines", n, "net.last_address=192.168.1.20\nui.lang=tr\nui.scale=2\n".length);
		for (i in 0...n) Conf.feed(RawMem.get8(buf, i));

		final k2:Array<String> = [];
		final v2:Array<String> = [];
		KSettings.parse(buf, n, k2, v2);
		Conf.expect("read back: count", k2.length, 3);
		Conf.expect("read back: a key", k2[0] == "net.last_address" ? 1 : 0, 1);
		Conf.expect("read back: a value", v2[0] == "192.168.1.20" ? 1 : 0, 1);
		Conf.expect("read back: the last", v2[2] == "2" ? 1 : 0, 1);

		// A value with '=' in it, a line without one, an empty key and no final newline.
		final raw = "a=b=c\nnothing here\n=orphan\nlast=1";
		for (i in 0...raw.length) RawMem.set8(buf, i, code(raw, i));
		final k3:Array<String> = [];
		final v3:Array<String> = [];
		KSettings.parse(buf, raw.length, k3, v3);
		Conf.expect("junk skipped", k3.length, 2);
		Conf.expect("the first '=' splits", v3[0] == "b=c" ? 1 : 0, 1);
		Conf.expect("no newline at the end", v3[1] == "1" ? 1 : 0, 1);
		for (s in k3) Conf.feed(s.length);
		for (s in v3) Conf.feed(s.length);

		Conf.expect("too big is refused", KSettings.serialize(keys, values, buf, 20), -1);
		Conf.report("Settings");
	}

	static function code(s:String, i:Int):Int {
		final c:Null<Int> = s.charCodeAt(i);
		var v = 0;
		if (c != null) v = c;
		else {}
		return v;
	}
}
