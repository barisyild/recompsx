import kernel.KVideo;

/**
	The picture's resolution as the console's setting keeps it (`kernel.KVideo`, ADR-0056): a
	multiplier ("0.8", "1", "2", "3") read as percent of the PlayStation's resolution and written back
	the same way on every target, anything else read as no setting; and the lines a display is drawn
	at at a scale, as a menu shows them (`drawnLines`: rounded, held to a backend's limit). What a
	backend then draws at is its own.
**/
class VideoScale {
	public static function main():Void {
		Conf.feedName("VideoScale");
		final texts = ["0.8", "1", "1.5", "2", "3", "4", "0.25", "0.5", "1.25", "2.0", "0.80", "1.", "01",
			"0", "5", "", "x", ".5", "1.255", "-1", "2x", "10", "0.2", "4.01"];
		final percents = [80, 100, 150, 200, 300, 400, 25, 50, 125, 200, 80, 100, 100,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
		for (i in 0...texts.length) {
			final p = KVideo.parse(texts[i]);
			Conf.expect("parse " + texts[i], p, percents[i]);
			Conf.feed(p);
		}
		final kept = [25, 50, 75, 80, 100, 105, 125, 150, 200, 250, 300, 400];
		for (p in kept) {
			final s = KVideo.format(p);
			Conf.expect("format and back " + p, KVideo.parse(s), p);
			Conf.feed(s.length);
			for (k in 0...s.length) Conf.feed(code(s, k));
		}
		Conf.expect("four fifths", KVideo.format(80) == "0.8" ? 1 : 0, 1);
		Conf.expect("five hundredths", KVideo.format(105) == "1.05" ? 1 : 0, 1);
		Conf.expect("three", KVideo.format(300) == "3" ? 1 : 0, 1);
		// Lines: 240 and 480 at each offered scale, with no limit and with the Dreamcast's 480.
		final scales = [80, 100, 200, 300];
		final expect = [192, 240, 480, 720, 384, 480, 960, 1440, 192, 240, 480, 480, 384, 480, 480, 480];
		var k = 0;
		for (most in [0, 480]) {
			for (lines in [240, 480]) {
				for (p in scales) {
					final n = KVideo.drawnLines(p, lines, most);
					Conf.expect("lines " + lines + " at " + p + " under " + most, n, expect[k]);
					Conf.feed(n);
					k++;
				}
			}
		}
		Conf.expect("never none", KVideo.drawnLines(25, 2, 0), 1);
		Conf.report("VideoScale");
	}

	static function code(s:String, i:Int):Int {
		final c:Null<Int> = s.charCodeAt(i);
		var v = 0;
		if (c != null) v = c;
		else {}
		return v;
	}
}
