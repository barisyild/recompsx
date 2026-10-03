/**
	Vertices for the SH-4 RTPS core's offline check (ADR-0046, scripts/dc-shrun.py): with
	`-D recompsx_rtp_capture` (JavaScript only), Gte.project's inputs and outputs, every `every`-th
	vertex from vblank RTP_FROM (an environment variable, 3300 by default) on, `limit` of them,
	appended to RTP_OUT (rtpcap.txt). A line is sf, lm, vh, last, register-file words 0-80 and the
	packed matrix (648-652) before, and words 0-80 after.
**/
class RtpCapture {
	static var calls = 0;
	static var taken = 0;
	static var on = false;
	static var line:Array<Int> = [];
	static var buf:Array<String> = [];
	public static var every = 7;
	public static var from = 3300;
	public static var limit = 30000;

	static var inited = false;
	static var out = 'rtpcap.txt';

	public static function before(sf:Int, lm:Bool, vh:Int, last:Bool):Void {
		if (!inited) {
			inited = true;
			from = Std.parseInt(js.Syntax.code("process.env.RTP_FROM || '3300'"));
			out = js.Syntax.code("process.env.RTP_OUT || 'rtpcap.txt'");
		} else {}
		on = false;
		if (kernel.Kernel.vblankCount < from || taken >= limit) return;
		calls++;
		if (calls % every != 0) return;
		on = true;
		line = [sf, lm ? 1 : 0, vh, last ? 1 : 0];
		for (i in 0...81) line.push(shim.GteFile.get(i));
		for (i in 648...653) line.push(shim.GteFile.get(i));
	}

	public static function after():Void {
		if (!on) return;
		on = false;
		for (i in 0...81) line.push(shim.GteFile.get(i));
		buf.push(line.join(' '));
		taken++;
		if (buf.length >= 2000 || taken >= limit) {
			js.Syntax.code("require('fs').appendFileSync({0}, {1} + '\\n')", out, buf.join('\n'));
			buf = [];
		}
	}
}
