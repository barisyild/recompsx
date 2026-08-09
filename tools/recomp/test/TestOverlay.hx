import haxe.io.Bytes;
import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Program;
import recomp.codegen.Universe;
import recomp.config.GameConfig.OverlayConfig;
import recomp.loader.PsxExe;
import sys.io.File;

/**
	Overlays, on a program small enough to hold in your head.

	Crash Bash is the acceptance test; this is the regression test. The whole point of an overlay
	is that one window of memory holds different code at different times, and the questions that
	follow from it are all answerable on three tiny programs:

	- Does a call *into* a window compile to a dispatch, while a call inside the executable stays
	  a direct call? That distinction is the entire cost model — get it backwards and either the
	  program is wrong or every call in the game goes through a table.
	- Does an overlay calling itself stay direct? It can, because the caller running at all proves
	  the callee is resident, and it is most of the calls an overlay makes.
	- Do two overlays sharing a window each get their own rows, their own classes, and one shared
	  copy of the code they have in common?

	The synthetic programs are assembled by hand below, which is what makes a failure say which
	rule broke rather than "fewer functions than yesterday".
**/
class TestOverlay {
	static inline var BASE = 0x80010000;
	static inline var WINDOW = 0x80020000;
	static inline var WINDOW_BYTES = 0x80;

	// Encodings, named so the programs below read as programs.
	static inline var NOP = 0x00000000;
	static inline var JR_RA = 0x03E00008;
	static inline var ADDU_V0_ZZ = 0x00001021;

	static function jal(target:Int):Int return (0x03 << 26) | ((target & 0x0FFFFFFF) >> 2);

	static function words(w:Array<Int>):Bytes {
		final b = Bytes.alloc(w.length * 4);
		for (i in 0...w.length) b.setInt32(i * 4, w[i]);
		return b;
	}

	/**
		A PS-EXE around a payload, so the emitter sees the shape it sees in the real thing.

		`Program` reports the executable's entry point and stack in `GameInfo`, and the overlay
		images are built by laying bytes over the executable's — so a synthetic one is the honest
		way to test this, rather than reaching past the loader.
	**/
	static function exeOf(payload:Bytes):PsxExe {
		final b = Bytes.alloc(PsxExe.HEADER_SIZE + payload.length);
		b.blit(0, Bytes.ofString("PS-X EXE"), 0, 8);
		b.setInt32(0x10, BASE);              // initial pc
		b.setInt32(0x18, BASE);              // load address
		b.setInt32(0x1C, payload.length);    // payload size
		b.setInt32(0x30, 0x801FFFF0);        // stack base
		b.blit(PsxExe.HEADER_SIZE, payload, 0, payload.length);
		return PsxExe.parse(b);
	}

	/**
		The executable: one function that calls another, and one that calls into the window.

		The second call is the interesting one. At the moment it is emitted, nothing can know which
		overlay will be sitting there — that is decided when the game loads one — so it has to
		become a dispatch by address.
	**/
	static function baseProgram():Bytes {
		final w = [];
		for (i in 0...68) w.push(NOP);
		w[0] = jal(BASE + 0x100);   // a function in the executable: always resident
		w[1] = NOP;
		w[2] = jal(WINDOW);         // into the window: whoever is loaded there
		w[3] = NOP;
		w[4] = JR_RA;
		w[5] = NOP;
		// 0x80010100
		w[64] = ADDU_V0_ZZ;
		w[65] = JR_RA;
		w[66] = NOP;
		return words(w);
	}

	/**
		An overlay: calls the executable, and calls itself.

		`marker` is a single word of padding that differs between the two overlays, which is all it
		takes to give them different fingerprints — and the tool refuses to build a program whose
		overlays it could not tell apart.
	**/
	static function overlayProgram(marker:Int):Bytes {
		final w = [];
		for (i in 0...32) w.push(NOP);
		w[0] = jal(BASE + 0x100);      // into the executable: always resident
		w[1] = NOP;
		w[2] = jal(WINDOW + 0x40);     // into itself: resident because we are running
		w[3] = NOP;
		w[4] = JR_RA;
		w[5] = NOP;
		w[6] = marker;
		// WINDOW + 0x40 — identical in both overlays, which is the point.
		w[16] = ADDU_V0_ZZ;
		w[17] = JR_RA;
		w[18] = NOP;
		return words(w);
	}

	static function overlayConfig(id:String):OverlayConfig {
		return new OverlayConfig(id, WINDOW, WINDOW_BYTES,
			recomp.config.GameConfig.OverlaySource.MemDump("unused-in-this-test"), [], 64);
	}

	static function build(overlayIds:Array<String>, markers:Array<Int>):Program {
		final exe = exeOf(baseProgram());

		final baseImage = Image.ofExe("test", exe);
		final baseDiscovery = new Discovery(baseImage);
		baseDiscovery.addSeed(BASE, "entry", Confidence.Entry);
		baseDiscovery.run();

		final universes = [new Universe(null, baseImage, baseDiscovery, null)];
		for (i in 0...overlayIds.length) {
			final cfg = overlayConfig(overlayIds[i]);
			final bytes = overlayProgram(markers[i]);
			final image = Image.ofExeWithOverlay('test:${cfg.id}', exe, bytes, cfg.loadAddr);
			final d = new Discovery(image, cfg.loadAddr, cfg.endAddr(), true);
			d.addSeed(WINDOW, "ovl_entry", Confidence.Entry);
			d.run();
			universes.push(new Universe(cfg, image, d, bytes));
		}
		return new Program(universes, exe);
	}

	static function writeAndRead(p:Program, dir:String):Map<String, String> {
		if (!sys.FileSystem.exists("out")) sys.FileSystem.createDirectory("out");
		if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		p.writeTo(dir);
		final out = new Map<String, String>();
		for (name in sys.FileSystem.readDirectory(dir)) {
			out.set(name, File.getContent('$dir/$name'));
		}
		return out;
	}

	public static function run():Void {
		final dir = "out/_tooltest_overlay";
		final program = build(["a", "b"], [ADDU_V0_ZZ, JR_RA]);
		final files = writeAndRead(program, dir);

		Assert.group("overlay: a call into a window is dispatched, one inside the base is not");
		{
			final base = files.get("Fns_00_80010000.hx");
			Assert.isTrue(base != null, "the executable's shard was written");
			Assert.isTrue(base.indexOf("Fns_00_80010000.f_80010100(ctx)") >= 0,
				"a call inside the executable is a direct call");
			Assert.isTrue(base.indexOf("Runtime.call(ctx, 0x80020000)") >= 0,
				"a call into an overlay window is dispatched by address");
		}

		Assert.group("overlay: an overlay calls the base directly and itself directly");
		{
			final a = files.get("Ovl_a_01_80020000.hx");
			Assert.isTrue(a != null, "overlay a's shard was written");
			Assert.isTrue(a.indexOf("Fns_00_80010000.f_80010100(ctx)") >= 0,
				"an overlay calling the executable is a direct call");
			Assert.isTrue(a.indexOf("Ovl_a_01_80020000.f_80020040(ctx)") >= 0,
				"an overlay calling into its own window is a direct call");
			Assert.isTrue(a.indexOf("Runtime.call(ctx, 0x80020040)") < 0,
				"and is not also dispatched");
		}

		Assert.group("overlay: two overlays in one window keep their own classes");
		{
			final b = files.get("Ovl_b_02_80020000.hx");
			Assert.isTrue(b != null, "overlay b's shard was written");
			Assert.isTrue(b.indexOf("Ovl_b_02_80020000.f_80020040(ctx)") >= 0,
				"overlay b calls its own copy, not overlay a's");
		}

		Assert.group("overlay: identical code is emitted once and shared");
		{
			Assert.equals(program.deduplicated, 1, "one body was shared");
			final b = files.get("Ovl_b_02_80020000.hx");
			Assert.isTrue(b.indexOf("Identical to `Ovl_a_01_80020000.f_80020040`") >= 0,
				"the second copy forwards to the first");
			// The forwarder is still a real function, so callers and the shard's own dispatch
			// switch need no special case.
			Assert.isTrue(b.indexOf("public static function f_80020040(ctx:CpuState") >= 0,
				"and is still callable by that name");
		}

		Assert.group("overlay: the generated table describes both windows");
		{
			final o = files.get("Overlays.hx");
			Assert.isTrue(o != null, "Overlays.hx was written");
			Assert.isTrue(o.indexOf("COUNT = 2") >= 0, "both overlays are counted");
			Assert.isTrue(o.indexOf("0x80020000") >= 0, "the window's start is recorded");
			Assert.isTrue(o.indexOf("0x80020080") >= 0, "and where it ends");
			Assert.isTrue(o.indexOf("case 0: return \"a\";") >= 0, "overlays are named");
			Assert.isTrue(o.indexOf("case 1: return \"b\";") >= 0, "both of them");
		}

		Assert.group("overlay: the executable's own table excludes overlay code");
		{
			final t = files.get("FnTable.hx");
			Assert.isTrue(t.indexOf("0x80010100") >= 0, "a base function is in the base table");
			// The window's addresses belong to Overlays, because at most one overlay answers for
			// them at a time and one flat table cannot say which.
			Assert.isTrue(t.split("0x80020040").length == 1,
				"an overlay's blocks are not in the base table");
			Assert.isTrue(t.indexOf("case 1: Ovl_a_01_80020000.dispatch") >= 0,
				"but every shard is reachable from the one dispatch switch");
			Assert.isTrue(t.indexOf("case 2: Ovl_b_02_80020000.dispatch") >= 0,
				"including the second overlay's");
		}

		Assert.group("overlay: generation is deterministic");
		{
			final again = writeAndRead(build(["a", "b"], [ADDU_V0_ZZ, JR_RA]),
				"out/_tooltest_overlay2");
			var differing = 0;
			for (name in files.keys()) {
				if (again.get(name) != files.get(name)) differing++;
			}
			Assert.equals(differing, 0, "a second run produces the same files");
			Assert.equals(Lambda.count(again), Lambda.count(files), "and the same number of them");
		}

		Assert.group("overlay: two overlays the runtime could not tell apart are refused");
		{
			var refused = false;
			try {
				// The same bytes twice: identical fingerprints, so nothing could decide which of
				// them is in the window.
				build(["a", "b"], [NOP, NOP]);
			} catch (e:recomp.analysis.AnalysisError) {
				refused = e.message.indexOf("same fingerprint") >= 0;
			}
			Assert.isTrue(refused, "identical overlays are a build error, not a coin toss");
		}
	}
}
