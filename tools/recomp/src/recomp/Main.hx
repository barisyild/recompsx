package recomp;

import haxe.io.Bytes;
import recomp.analysis.AnalysisError;
import recomp.analysis.Confidence;
import recomp.analysis.Coverage;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.analysis.Kind;
import recomp.codegen.Emitter;
import recomp.codegen.Program;
import recomp.codegen.ModOutput;
import recomp.config.ModConfig;
import recomp.loader.LoaderError;
import recomp.loader.PsxExe;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.codegen.Universe;
import recomp.config.GameConfig;
import recomp.config.GameConfig.Hint;
import recomp.config.GameConfig.TableHint;
import recomp.config.GameConfig.OverlayConfig;
import recomp.config.GameConfig.OverlaySource;
import recomp.config.GameConfig.RelocConfig;
import recomp.codegen.Relocatable.RelocSet;
import recomp.codegen.Relocatable.Occurrence;
import recomp.loader.DiscImage;
import recomp.loader.IsoWalk;
import recomp.loader.SystemCnf;
import recomp.mips.Instr;
import sys.io.File;

/** What `gen` works from, whichever way it was invoked. */
typedef GenInput = {
	exe:PsxExe,
	name:String,
	seeds:Array<Hint>,
	tableHints:Array<TableHint>,
	overlays:Array<OverlayConfig>,
	/** Each overlay's bytes, read while the disc was open, keyed by id. */
	overlayBytes:Map<String, Bytes>,
	/** Relocatable code (ADR-0025), found and traced while the disc was open. */
	relocSets:Array<RelocSet>,
	/** The game's config directory, when a config was read: where its mods live (ADR-0033). */
	?configDir:String,
	/** The product code (SCUS94570) and the game's name: what its memory card is kept under
	    (ADR-0037). The code alone, as the name too, when there is no config; "" when neither. */
	?serial:String,
	?title:String,
};

/**
	The recompiler's command line.

	Two commands so far, both aimed at the part of this work a person has to do by looking:
	`info` says what an executable claims about itself, and `dis` shows the code. Analysis and
	code generation join them as they are built.

	Exit codes are meaningful because scripts read them — see docs/specs/tool.md §5.
**/
class Main {
	static inline var EXIT_OK = 0;
	static inline var EXIT_USAGE = 2;
	static inline var EXIT_LOADER = 3;
	static inline var EXIT_ANALYSIS = 4;

	/** `gen --cut-shared` (ADR-0045): hand-overs between functions that share code. */
	public static var cutShared = false;

	public static function main():Void {
		final args = Sys.args();
		if (args.length == 0) {
			usage();
			Sys.exit(EXIT_USAGE);
		}

		final command = args[0];
		final rest = args.slice(1);

		try {
			switch (command) {
				case "info": Sys.exit(cmdInfo(rest));
				case "dis": Sys.exit(cmdDis(rest));
				case "analyze": Sys.exit(cmdAnalyze(rest));
				case "emit": Sys.exit(cmdEmit(rest));
				case "gen": Sys.exit(cmdGen(rest));
				case "help" | "-h" | "--help": usage(); Sys.exit(EXIT_OK);
				case _:
					Sys.stderr().writeString('unknown command "$command"\n\n');
					usage();
					Sys.exit(EXIT_USAGE);
			}
		} catch (e:LoaderError) {
			Sys.stderr().writeString("error: " + e.message + "\n");
			Sys.exit(EXIT_LOADER);
		} catch (e:AnalysisError) {
			Sys.stderr().writeString("error: " + e.message + "\n");
			Sys.exit(EXIT_ANALYSIS);
		}
	}

	static function usage():Void {
		Sys.println("recompsx — PlayStation static recompiler

usage:
  recompsx info <file.exe>
      Parse a PS-EXE header and report what it claims, including anything suspicious.

  recompsx dis <file.exe> [--at <addr>] [--count <n>]
      Disassemble. Defaults to the entry point and 32 instructions. Addresses may be
      written as 0x80010000 or as a decimal number.

  recompsx gen <disc.cue | SERIAL | games/SERIAL/game.json | file.exe> [--out <dir>] [--seed <addr>] [--no-opt | --no-regions | --no-scalar | --no-value-regions | --no-projection-share | --no-scalar-calls] [--value-cfg | --no-value-cfg] [--cut-shared] [--mods <id,id | all>]
      Emit a recompiled program. Given a disc image, its SYSTEM.CNF names the executable
      and its product code, and games/<code>/game.json, when there is one, supplies the
      overlays and hints; without one the executable alone is compiled. Given a code or a
      config, the disc is the one that game's gitignored local.json names. Given a bare
      executable, seeds come from --seed.
      --no-opt keeps block dispatch, without fusion or forwarding, for differential testing.
      --no-scalar disables recovered parameter/return helpers, keeping other optimizations.
      --no-value-regions disables pure value SSA between observation boundaries.
      --value-cfg enables experimental propagation across pure structured CFG regions (off by default).
      --no-value-cfg disables it while retaining linear value regions.
      --no-projection-share emits every memory projection at its own call site, for comparisons.
      --no-scalar-calls keeps recovered helpers inside their functions but calls every function
        through its CpuState entry, for measuring call-site helper use.
      --no-regions keeps simple loops but disables region reductions.
      --cut-shared: functions hand over at each other's entries instead of carrying the code
        they share (ADR-0045): smaller, exact, and slower on the Dreamcast (ledger E-077).
      --mods builds in the named mods from games/<code>/mods (ADR-0033): their hooks are
      emitted, their sources copied beside the program; compile with -D recompsx_mods.

exit codes: 0 ok · 2 usage · 3 could not load the input");
	}

	static function cmdInfo(args:Array<String>):Int {
		final path = args.length > 0 ? args[0] : null;
		if (path == null) {
			Sys.stderr().writeString("info: expected a file\n");
			return EXIT_USAGE;
		}
		final exe = loadExe(path);
		Sys.println(exe.describe());
		return EXIT_OK;
	}

	static function cmdDis(args:Array<String>):Int {
		final path = args.length > 0 ? args[0] : null;
		if (path == null) {
			Sys.stderr().writeString("dis: expected a file\n");
			return EXIT_USAGE;
		}
		final exe = loadExe(path);

		var at = exe.initialPc;
		var count = 32;
		var i = 1;
		while (i < args.length) {
			switch (args[i]) {
				case "--at" if (i + 1 < args.length): at = parseAddr(args[i + 1]); i++;
				case "--count" if (i + 1 < args.length): count = Std.parseInt(args[i + 1]); i++;
				case other:
					Sys.stderr().writeString('dis: unexpected argument "$other"\n');
					return EXIT_USAGE;
			}
			i++;
		}

		if (!exe.containsAddr(at)) {
			Sys.stderr().writeString('error: ${Vaddr.hex(at)} is outside the loaded image '
				+ '(${Vaddr.hex(exe.loadAddr)}..${Vaddr.hex(exe.loadEnd())})\n');
			return EXIT_LOADER;
		}

		final instrs:Array<Instr> = [];
		var addr = at;
		var n = 0;
		while (n < count && exe.containsAddr(addr + 3)) {
			instrs.push(Decoder.decode(Vaddr.canonRam(addr), exe.readWord(addr)));
			addr += 4;
			n++;
		}
		Sys.println(Disasm.lines(instrs));
		return EXIT_OK;
	}

	static function cmdAnalyze(args:Array<String>):Int {
		final path = args.length > 0 ? args[0] : null;
		if (path == null) {
			Sys.stderr().writeString("analyze: expected a file\n");
			return EXIT_USAGE;
		}
		var sweep = true;
		var listFunctions = false;
		for (i in 1...args.length) {
			switch (args[i]) {
				case "--no-sweep": sweep = false;
				case "--functions": listFunctions = true;
				case other:
					Sys.stderr().writeString('analyze: unexpected argument "$other"\n');
					return EXIT_USAGE;
			}
		}

		final exe = loadExe(path);
		for (w in exe.warnings) Sys.println("warning: " + w);

		final image = Image.ofExe(nameOf(path), exe);
		final discovery = new Discovery(image);
		discovery.addSeed(exe.initialPc, "entry_point", Confidence.Entry);
		discovery.run(sweep);

		if (listFunctions) {
			final entries = [for (k in discovery.functions.keys()) k];
			entries.sort((a, b) -> a - b);
			for (e in entries) Sys.println(discovery.functions.get(e).describe());
			Sys.println("");
		}

		Sys.print(new Coverage(image, discovery).render());
		return EXIT_OK;
	}

	static function cmdEmit(args:Array<String>):Int {
		final path = args.length > 0 ? args[0] : null;
		if (path == null) {
			Sys.stderr().writeString("emit: expected a file\n");
			return EXIT_USAGE;
		}
		var at = -1;
		var i = 1;
		while (i < args.length) {
			switch (args[i]) {
				case "--at" if (i + 1 < args.length): at = parseAddr(args[i + 1]); i++;
				case other:
					Sys.stderr().writeString('emit: unexpected argument "$other"\n');
					return EXIT_USAGE;
			}
			i++;
		}

		final exe = loadExe(path);
		final image = Image.ofExe(nameOf(path), exe);
		final discovery = new Discovery(image);
		discovery.addSeed(exe.initialPc, "entry_point", Confidence.Entry);
		discovery.run();

		if (at < 0) at = exe.initialPc;
		final fn = discovery.functions.get(recomp.Vaddr.canonRam(at));
		if (fn == null) {
			Sys.stderr().writeString('error: no function starts at ${Vaddr.hex(at)}. '
				+ 'Use `analyze --functions` to list them.\n');
			return EXIT_ANALYSIS;
		}

		// The original, so the two can be read side by side.
		Sys.println("// original:");
		var a = fn.entry;
		while (a < fn.endAddr && image.containsWord(a)) {
			Sys.println("//   " + recomp.mips.Disasm.line(
				recomp.mips.Decoder.decode(a, image.readWord(a))));
			a += 4;
		}
		Sys.println("");
		Sys.print(new Emitter(image, discovery).emitFunction(fn));
		return EXIT_OK;
	}

	static function cmdGen(args:Array<String>):Int {
		// Extra function entries, for targets only reachable through data the analysis cannot
		// read — a library's function-pointer tables, typically. The runtime names them when it
		// misses ("no function at 0x..."), and feeding them back here is the loop closing.
		final seeds:Array<String> = [];
		final path = args.length > 0 ? args[0] : null;
		if (path == null) {
			Sys.stderr().writeString("gen: expected a file\n");
			return EXIT_USAGE;
		}
		var outDir = "out/gen";
		var limit = 0;
		var optimize = true;
		var structureRegions = true;
		var scalarFunctions = true;
		var valueRegions = true;
		var valueCfg = false;
		var shareProjections = true;
		var scalarCalls = true;
		var modsWanted:Null<String> = null;
		var i = 1;
		while (i < args.length) {
			switch (args[i]) {
				case "--out" if (i + 1 < args.length): outDir = args[i + 1]; i++;
				case "--limit" if (i + 1 < args.length): limit = Std.parseInt(args[i + 1]); i++;
				case "--seed" if (i + 1 < args.length): seeds.push(args[i + 1]); i++;
				case "--no-opt": optimize = false;
				case "--no-regions": structureRegions = false;
				case "--no-scalar": scalarFunctions = false;
				case "--no-value-regions": valueRegions = false;
				case "--value-cfg": valueCfg = true;
				case "--no-value-cfg": valueCfg = false;
				case "--no-projection-share": shareProjections = false;
				case "--no-scalar-calls": scalarCalls = false;
				case "--cut-shared": cutShared = true;
				case "--mods" if (i + 1 < args.length): modsWanted = args[i + 1]; i++;
				case other:
					Sys.stderr().writeString('gen: unexpected argument "$other"\n');
					return EXIT_USAGE;
			}
			i++;
		}

		// Several ways in, one pipeline. A disc finds its own config by the product code in its
		// SYSTEM.CNF; a code or a config names a disc through local.json; a bare executable is the
		// homebrew and fixture path, where there is no disc to name. Everything after this point
		// sees the same executable and the same seeds whichever it was.
		final input = if (StringTools.endsWith(path.toLowerCase(), ".json")) {
			fromConfig(path);
		} else if (!sys.FileSystem.exists(path) && SystemCnf.isSerial(path)) {
			fromConfig(configFor(path));
		} else if (isPsxExe(path)) {
			fromBareExe(path, seeds);
		} else {
			fromDisc(path, seeds);
		}

		final exe = input.exe;
		var discovery = analyseBase(input, []);
		final universes = [new Universe(null, discovery.image, discovery, null)];
		for (o in input.overlays) universes.push(analyseOverlay(input, exe, o));
		// Functions of the executable that only an overlay calls. The base pass never saw a call to
		// them, so it never traced them, and the overlay's call finds nothing there at run time ("no
		// function at"). Library stubs are the usual case: a save screen in an overlay calls
		// libcard's `_card_info` wrapper, which nothing in the executable itself calls — Crash
		// Bandicoot: Warped then said no memory card was inserted. The base is analysed again with
		// them as seeds, as if a `jal` in the executable had named them.
		final reached = calledFromOverlays(universes, discovery, input.overlays);
		if (reached.length > 0) {
			discovery = analyseBase(input, reached);
			universes[0] = new Universe(null, discovery.image, discovery, null);
		} else {}

		final program = new Program(universes, exe, limit, optimize, structureRegions,
			input.relocSets, scalarFunctions, valueRegions, valueCfg);
		program.setGame(input.serial != null ? input.serial : "", input.title != null ? input.title : "");
		program.shareProjections = shareProjections;
		program.scalarCalls = scalarCalls;
		// Mods (ADR-0033): only with --mods does anything below change what is written.
		final mods = modsWanted == null ? [] : modsFor(input, modsWanted);
		final hooks = [for (m in mods) for (h in m.hooks) h];
		if (mods.length > 0) program.setHooks(hooks);
		program.writeTo(outDir);
		ModOutput.clean(outDir);
		if (mods.length > 0) {
			final missed = program.unmatchedHooks(hooks);
			if (missed.length > 0) {
				throw new LoaderError('no function begins at ' + [for (h in missed)
					Vaddr.hex(h.addr) + (h.scope != null ? ' in "${h.scope}"' : '')].join(", ")
					+ ' — a mod hooks it. Check the address, or add it as a function hint so the '
					+ 'analysis finds it.');
			}
			final files = ModOutput.write(outDir, mods);
			for (m in mods) Sys.println(m.describe());
			Sys.println('wrote $files mod files; build with -D recompsx_mods');
		}

		Sys.println('wrote ${program.filesWritten} files, ${program.linesWritten} lines to $outDir');
		Sys.println('${Lambda.count(discovery.functions)} functions, '
			+ '${Lambda.count(discovery.tables)} switch tables');
		for (i in 1...universes.length) {
			final u = universes[i];
			Sys.println('overlay ${u.overlay.describe()}: '
				+ '${Lambda.count(u.discovery.functions)} functions'
				+ (u.discovery.rejected > 0 ? ', ${u.discovery.rejected} rejected as data' : ''));
		}
		for (r in input.relocSets) Sys.println(r.describe());
		if (program.deduplicated > 0) {
			Sys.println('${program.deduplicated} function bodies shared between universes');
		}
		if (program.projectionsShared > 0) {
			Sys.println('${program.projectionsShared} memory projection call sites share an earlier site\'s helper');
		}
		return EXIT_OK;
	}

	/** The mods `--mods` asked for, from the config the input was read through. */
	static function modsFor(input:GenInput, which:String):Array<ModConfig> {
		if (input.configDir == null) {
			throw new LoaderError('--mods needs a game config: mods live in games/<SERIAL>/mods, and '
				+ 'this input was read without one');
		}
		final mods = ModConfig.select(input.configDir, which);
		if (mods.length == 0) Sys.println('--mods $which: ${input.configDir}/mods has none');
		return mods;
	}

	/**
		The executable's own pass: its entry point, the config's hints and tables, and `extra`, the
		entries only overlays call (see `calledFromOverlays`).
	**/
	public static function analyseBase(input:GenInput, extra:Array<Int>):Discovery {
		final exe = input.exe;
		final discovery = new Discovery(Image.ofExe(input.name, exe));
		discovery.cutShared = cutShared;
		// Its code inside an overlay window is called by address: never handed over to.
		discovery.cutTarget = a -> !inAnyWindow(a, input.overlays);
		discovery.addSeed(exe.initialPc, "entry_point", Confidence.Entry);
		// Fed in before the run so everything they call is discovered too, exactly as if a `jal`
		// had named them.
		for (h in input.seeds) discovery.addSeed(h.addr, h.name, Confidence.Entry);
		for (a in extra) discovery.addSeed(a, Discovery.defaultName(a), Confidence.Called);
		for (t in input.tableHints) discovery.addTableHint(t.jrAddr, t.tableBase, t.count, t.targets);
		discovery.run();
		return discovery;
	}

	/**
		Addresses in the executable that overlays reach with a `jal` and the base pass did not find.

		Only where the executable's bytes are certain — outside every overlay window, since a call
		into another overlay's window means that overlay's code, not what the executable has there —
		and only in words the base pass left unclaimed, which read as code: a call into the middle
		of a traced function, or into data, is not a new entry. Sorted, so the output does not
		depend on map order.
	**/
	public static function calledFromOverlays(universes:Array<Universe>, base:Discovery,
			overlays:Array<OverlayConfig>):Array<Int> {
		final found:Map<Int, Bool> = [];
		for (i in 1...universes.length) {
			for (fn in universes[i].discovery.functions) {
				for (c in fn.calls) {
					if (c.indirect || c.target == 0) continue;
					final t = Vaddr.canonRam(c.target);
					if (found.exists(t) || base.functions.exists(t) || inAnyWindow(t, overlays)) continue;
					if (base.image.kindAt(t) != Kind.Unknown || !base.plausibleEntry(t)) continue;
					found.set(t, true);
				}
			}
		}
		final out = [for (t in found.keys()) t];
		out.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return out;
	}

	static function inAnyWindow(addr:Int, overlays:Array<OverlayConfig>):Bool {
		for (o in overlays) {
			if (addr >= Vaddr.canonRam(o.loadAddr) && addr < Vaddr.canonRam(o.endAddr())) return true;
		}
		return false;
	}

	/**
		One overlay, analysed against the memory it will actually see.

		Its bytes are laid over the executable so that a jump table inside the overlay reads the
		overlay's data, and the pass is scoped to the window: the base has already been analysed
		once, and re-tracing it here would emit every base function a second time under an
		overlay's name. Calls out of the window are left for the emitter to resolve against the
		base pass.
	**/
	static function analyseOverlay(input:GenInput, exe:PsxExe, o:OverlayConfig):Universe {
		final bytes = input.overlayBytes.get(o.id);
		if (bytes == null) {
			throw new LoaderError('overlay "${o.id}" has no bytes; its source could not be read');
		}
		if (bytes.length != o.length) {
			throw new LoaderError('overlay "${o.id}" declares ${o.length} bytes but its source '
				+ 'gave ${bytes.length}');
		}
		final image = Image.ofExeWithOverlay('${input.name}:${o.id}', exe, bytes, o.loadAddr);
		final d = new Discovery(image, o.loadAddr, o.endAddr(), true);
		d.cutShared = cutShared;
		for (t in input.tableHints) d.addTableHint(t.jrAddr, t.tableBase, t.count, t.targets);
		for (h in o.entryHints) {
			// A hint here is a guess recovered from a run, and a window holds artwork as well as
			// code, so it is read before it is believed.
			if (d.plausibleEntry(h.addr)) d.addSeed(h.addr, h.name, Confidence.Entry);
			else {
				Sys.stderr().writeString('gen: overlay "${o.id}" hint ${Vaddr.hex(h.addr)} does '
					+ 'not read as code — ignoring it\n');
			}
		}
		d.run();
		return new Universe(o, image, d, bytes);
	}

	/** What `gen` needs, however it was asked for: an executable, a name for it, and seeds. */
	static function fromBareExe(path:String, seeds:Array<String>):GenInput {
		return exeAlone(loadExe(path), nameOf(path), seeds);
	}

	/**
		An executable with no config: its own entry point and whatever --seed adds. Its product
		code is the disc's when there is one, else read from its name — SCUS_945.70 is SCUS94570 —
		else none, and a game with none keeps no memory card between runs.
	**/
	static function exeAlone(exe:PsxExe, name:String, seeds:Array<String>, ?serial:String):GenInput {
		final hints = [];
		for (sd in seeds) {
			final a = parseAddr(sd);
			hints.push({addr: a, name: 'f_${StringTools.hex(Vaddr.canonRam(a), 8).toLowerCase()}'});
		}
		final code = serial != null ? serial : SystemCnf.serialOf(name);
		return {exe: exe, name: name, seeds: hints, tableHints: [], overlays: [],
			overlayBytes: new Map(), relocSets: [], serial: code != null ? code : "",
			title: code != null ? code : ""};
	}

	/**
		The same, read out of a game's config and the disc it names.

		The executable is pulled from the disc rather than from a file somebody extracted, which
		is the point: extraction is a step that can be done differently on two machines, and a
		build that reads the disc has one less way to disagree with itself. The name given to the
		image is the executable's own — `\SCUS_945.70;1` is `SCUS_945.70` — so generated output
		says where it came from without saying anything about whose disk it was read from.
	**/
	static function fromConfig(path:String, ?disc:String):GenInput {
		final config = GameConfig.load(path, disc);
		if (config.exeFile != null) {
			// Homebrew: local.json names a loose executable and there is no disc at all.
			return {exe: loadExe(config.exeFile), name: nameOf(config.exeFile),
				seeds: config.functionHints, tableHints: config.tableHints, overlays: config.overlays,
				overlayBytes: memDumpsOnly(config), relocSets: noDiscReloc(config), configDir: config.dir,
				serial: config.id, title: config.title};
		}
		if (config.discPath == null) {
			throw new LoaderError('${config.dir}/local.json does not say where the disc is. '
				+ 'Copy local.json.example to local.json and set "cue" (or "exeFile" for a game '
				+ 'with no disc). It is gitignored: dumps stay on your machine.');
		}
		if (config.exePath == null) {
			throw new LoaderError('${config.path} has no exePath, so there is no way to know '
				+ 'which file on the disc is the executable');
		}

		final disc = DiscImage.open(config.discPath);
		final found = new IsoWalk(disc).find(config.exePath);
		if (found == null) {
			disc.close();
			throw new LoaderError('${config.discPath} has no ${config.exePath}. Either the config '
				+ 'names the wrong file or this is not the right disc.');
		}
		final bytes = disc.readExtent(found.lba, 0, found.length);
		checkSha256(config, bytes);
		final exe = PsxExe.parse(bytes);
		final overlayBytes = readOverlays(config, disc);
		final relocSets = [for (r in config.relocatable) readRelocatable(r, exe, config, disc)];
		disc.close();
		return {exe: exe, name: isoName(config.exePath),
			seeds: config.functionHints, tableHints: config.tableHints, overlays: config.overlays,
			overlayBytes: overlayBytes, relocSets: relocSets, configDir: config.dir,
			serial: config.id, title: config.title};
	}

	/**
		A disc image, taken as it is: SYSTEM.CNF says which executable boots and, in that name, the
		product code the repository files the game's facts under.

		With `games/<code>/game.json` present the build is exactly the config's, read from this
		disc — the config's hints and overlays, its executable path, its hash check. Without one it
		is the executable alone, as for a bare one, which is where a new game starts: the runtime
		reports what the analysis missed, and those reports become the config.
	**/
	static function fromDisc(path:String, seeds:Array<String>):GenInput {
		final disc = DiscImage.open(path);
		final walk = new IsoWalk(disc);
		final cnf = walk.find("\\SYSTEM.CNF;1");
		if (cnf == null) {
			disc.close();
			throw new LoaderError('$path has no SYSTEM.CNF, so nothing says what it boots. A bare '
				+ 'executable, a code (SCUS94570) or games/<code>/game.json can be given instead.');
		}
		final boot = SystemCnf.bootPath(disc.readExtent(cnf.lba, 0, cnf.length).toString());
		if (boot == null) {
			disc.close();
			throw new LoaderError('$path: its SYSTEM.CNF has no BOOT line naming an executable');
		}
		final serial = SystemCnf.serialOf(boot);
		final config = serial != null ? configFor(serial) : null;
		if (config != null && sys.FileSystem.exists(config)) {
			disc.close();
			Sys.println('$serial: $config');
			return fromConfig(config, path);
		}
		Sys.println(serial != null
			? '$serial: no $config yet, so the executable alone ($boot): no overlays, no hints'
			: 'boot executable $boot carries no product code: compiling it alone, with no config');
		final found = walk.find(boot);
		if (found == null) {
			disc.close();
			throw new LoaderError('$path: SYSTEM.CNF boots $boot, which is not on the disc');
		}
		final exe = PsxExe.parse(disc.readExtent(found.lba, 0, found.length));
		disc.close();
		return exeAlone(exe, isoName(boot), seeds, serial);
	}

	/** Where a game's committed facts live: `games/SCUS94570/game.json`, from the repository root. */
	static function configFor(serial:String):String {
		return 'games/$serial/game.json';
	}

	/** Whether `path` is a loose PS-EXE, by its magic — a disc image is anything else. */
	static function isPsxExe(path:String):Bool {
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) return false;
		final input = File.read(path, true);
		final head = input.read(8).toString();
		input.close();
		return head == "PS-X EXE";
	}

	/**
		A config's facts are about one pressing. The same product code can name a later printing
		with a different executable, and hints for the wrong one fail far from here, as functions
		that are not there; so the executable is checked against the hash the config records.
	**/
	static function checkSha256(config:GameConfig, bytes:Bytes):Void {
		if (config.exeSha256 == null) return;
		final got = haxe.crypto.Sha256.make(bytes).toHex();
		if (got != config.exeSha256) {
			throw new LoaderError('${config.exePath} on this disc has SHA-256 $got, but '
				+ '${config.path} describes the one with ${config.exeSha256}: a different '
				+ 'pressing or a damaged image, and its hints would point at the wrong code');
		}
	}

	static function noDiscReloc(config:GameConfig):Array<RelocSet> {
		if (config.relocatable.length > 0) {
			throw new LoaderError('relocatable code is read from the disc, but local.json names a '
				+ 'bare executable');
		} else {}
		return [];
	}

	/**
		One relocatable stanza: every file it names, scanned, traced and keyed (ADR-0025).

		The units are analysed at a nominal base at the top of RAM. It must not overlap the
		executable or any overlay window, or a call from relocatable code into real code there
		would look like a call into itself.
	**/
	static function readRelocatable(r:RelocConfig, exe:PsxExe, config:GameConfig,
			disc:DiscImage):RelocSet {
		final base = RelocSet.chooseBase(r.unit);
		final end = base + r.unit;
		final exeLo = Vaddr.canonRam(exe.loadAddr);
		final exeHi = exeLo + exe.fileSize;
		if (base < exeHi && end > exeLo) {
			throw new LoaderError('relocatable "${r.id}": its analysis window '
				+ '${Vaddr.hex(base)}..${Vaddr.hex(end)} overlaps the executable; lower unit');
		} else {}
		for (o in config.overlays) {
			if (base < o.endAddr() && end > o.loadAddr) {
				throw new LoaderError('relocatable "${r.id}": its analysis window overlaps overlay "${o.id}"');
			} else {}
		}
		final set = new RelocSet(r, base);
		final iso = new IsoWalk(disc);
		final occurrences:Array<Occurrence> = [];
		for (pattern in r.files) {
			final paths = iso.glob(pattern);
			if (paths.length == 0) {
				throw new LoaderError('relocatable "${r.id}": nothing on the disc matches $pattern');
			} else {}
			for (p in paths) {
				final e = iso.find(p);
				set.addFile(isoName(p), disc.readExtent(e.lba, 0, e.length), occurrences);
			}
		}
		set.finish(occurrences);
		return set;
	}

	/**
		Each overlay's bytes, read while the disc is open.

		Three shapes. `discFile` names a file and an offset into it, which is how a game that keeps
		its overlays in one archive describes them; `sectors` names raw sectors, for a game with a
		layout of its own; `memdump` names a file on this machine, which is the only way to analyse
		an overlay that is compressed on the disc — the bytes that run are not the bytes that are
		stored, and nothing but a capture has them.

		A memdump path is relative to the config, and is never committed: it is game code, and
		golden rule 4 keeps that out of the repository. The master plan once said to commit these
		under `games/<id>/dumps/`; that was wrong for the same reason, and ADR-0006 records the
		correction.
	**/
	static function readOverlays(config:GameConfig, disc:DiscImage):Map<String, Bytes> {
		final out = new Map<String, Bytes>();
		if (config.overlays.length == 0) return out;
		final iso = new IsoWalk(disc);
		for (o in config.overlays) {
			out.set(o.id, switch (o.source) {
				case DiscFile(p, offset, length):
					final f = iso.find(p);
					if (f == null) {
						throw new LoaderError('overlay "${o.id}" wants $p, which is not on this disc');
					}
					disc.readExtent(f.lba, offset, length > 0 ? length : o.length);
				case Sectors(lba, count):
					disc.readExtent(lba, 0, count * DiscImage.USER_BYTES);
				case MemDump(p):
					readMemDump(config, o, p);
			});
		}
		return out;
	}

	/** The overlays a game with no disc can still have: captures, and nothing else. */
	static function memDumpsOnly(config:GameConfig):Map<String, Bytes> {
		final out = new Map<String, Bytes>();
		for (o in config.overlays) {
			switch (o.source) {
				case MemDump(p): out.set(o.id, readMemDump(config, o, p));
				case _:
					throw new LoaderError('overlay "${o.id}" reads from the disc, but local.json '
						+ 'names a bare executable and there is no disc to read');
			}
		}
		return out;
	}

	static function readMemDump(config:GameConfig, o:OverlayConfig, p:String):Bytes {
		final at = StringTools.startsWith(p, "/") ? p : '${config.dir}/$p';
		if (!sys.FileSystem.exists(at)) {
			throw new LoaderError('overlay "${o.id}" needs the capture $at, which is not there. '
				+ 'Captures are never committed — record one on this machine.');
		}
		final all = File.getBytes(at);
		// A capture may be a whole memory image; the window says which part of it is the overlay.
		if (all.length == o.length) return all;
		final within = Vaddr.canonRam(o.loadAddr) & 0x1FFFFF;
		if (within + o.length > all.length) {
			throw new LoaderError('the capture $at is ${all.length} bytes, too small to hold '
				+ 'overlay "${o.id}" at ${Vaddr.hex(o.loadAddr)}');
		}
		return all.sub(within, o.length);
	}

	/** The last component of an ISO9660 path, without its version suffix. */
	static function isoName(path:String):String {
		final parts = StringTools.replace(path, "\\", "/").split("/");
		final leaf = parts[parts.length - 1];
		final semi = leaf.indexOf(";");
		return semi >= 0 ? leaf.substr(0, semi) : leaf;
	}

	static function nameOf(path:String):String {
		final slash = path.lastIndexOf("/");
		return slash >= 0 ? path.substr(slash + 1) : path;
	}

	static function loadExe(path:String):PsxExe {
		if (!sys.FileSystem.exists(path)) throw new LoaderError('no such file: $path');
		final bytes:Bytes = File.getBytes(path);
		return PsxExe.parse(bytes);
	}

	/** Accepts 0x-prefixed hex, and decimal — including values above 2^31, which `Std.parseInt`
	    rejects but which are perfectly ordinary here since every RAM address has the top bit set. */
	static function parseAddr(s:String):Int {
		final direct = Std.parseInt(s);
		if (direct != null) return direct;

		final f = Std.parseFloat(s);
		if (Math.isNaN(f)) throw new LoaderError('could not read "$s" as an address');
		if (f < 0 || f > 4294967295.0) {
			throw new LoaderError('"$s" is outside the 32-bit address range');
		}
		// Above 2^31 the value wraps into a negative Int, which is the representation the rest of
		// the tool uses for KSEG0 addresses anyway.
		return f >= 2147483648.0 ? Std.int(f - 4294967296.0) : Std.int(f);
	}
}
