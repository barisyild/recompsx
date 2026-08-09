package recomp;

import haxe.io.Bytes;
import recomp.analysis.AnalysisError;
import recomp.analysis.Confidence;
import recomp.analysis.Coverage;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.Program;
import recomp.loader.LoaderError;
import recomp.loader.PsxExe;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.config.GameConfig;
import recomp.config.GameConfig.Hint;
import recomp.loader.DiscImage;
import recomp.loader.IsoWalk;
import recomp.mips.Instr;
import sys.io.File;

/** What `gen` works from, whichever way it was invoked. */
typedef GenInput = {exe:PsxExe, name:String, seeds:Array<Hint>};

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

  recompsx gen <games/<id>/game.json | file.exe> [--out <dir>] [--seed <addr>]
      Emit a recompiled program. Given a config, the executable is read from the disc
      that game's gitignored local.json names, and its hints are used as seeds. Given a
      bare executable, seeds come from --seed.

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
		var i = 1;
		while (i < args.length) {
			switch (args[i]) {
				case "--out" if (i + 1 < args.length): outDir = args[i + 1]; i++;
				case "--limit" if (i + 1 < args.length): limit = Std.parseInt(args[i + 1]); i++;
				case "--seed" if (i + 1 < args.length): seeds.push(args[i + 1]); i++;
				case other:
					Sys.stderr().writeString('gen: unexpected argument "$other"\n');
					return EXIT_USAGE;
			}
			i++;
		}

		// Two ways in, one pipeline. A config names a disc and carries the game's hints; a bare
		// executable is the homebrew and fixture path, where there is no disc to name. Everything
		// after this point sees the same executable and the same seeds either way.
		final input = StringTools.endsWith(path.toLowerCase(), ".json")
			? fromConfig(path) : fromBareExe(path, seeds);

		final exe = input.exe;
		final image = Image.ofExe(input.name, exe);
		final discovery = new Discovery(image);
		discovery.addSeed(exe.initialPc, "entry_point", Confidence.Entry);
		// Fed in before the run so everything they call is discovered too, exactly as if a `jal`
		// had named them.
		for (h in input.seeds) discovery.addSeed(h.addr, h.name, Confidence.Entry);
		discovery.run();

		final program = new Program(image, discovery, exe, limit);
		program.writeTo(outDir);

		Sys.println('wrote ${program.filesWritten} files, ${program.linesWritten} lines to $outDir');
		Sys.println('${Lambda.count(discovery.functions)} functions, '
			+ '${Lambda.count(discovery.tables)} switch tables');
		return EXIT_OK;
	}

	/** What `gen` needs, however it was asked for: an executable, a name for it, and seeds. */
	static function fromBareExe(path:String, seeds:Array<String>):GenInput {
		final hints = [];
		for (sd in seeds) {
			final a = parseAddr(sd);
			hints.push({addr: a, name: 'f_${StringTools.hex(Vaddr.canonRam(a), 8).toLowerCase()}'});
		}
		return {exe: loadExe(path), name: nameOf(path), seeds: hints};
	}

	/**
		The same, read out of a game's config and the disc it names.

		The executable is pulled from the disc rather than from a file somebody extracted, which
		is the point: extraction is a step that can be done differently on two machines, and a
		build that reads the disc has one less way to disagree with itself. The name given to the
		image is the executable's own — `\SCUS_945.70;1` is `SCUS_945.70` — so generated output
		says where it came from without saying anything about whose disk it was read from.
	**/
	static function fromConfig(path:String):GenInput {
		final config = GameConfig.load(path);
		if (config.exeFile != null) {
			// Homebrew: local.json names a loose executable and there is no disc at all.
			return {exe: loadExe(config.exeFile), name: nameOf(config.exeFile),
				seeds: config.functionHints};
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
		disc.close();
		return {exe: PsxExe.parse(bytes), name: isoName(config.exePath),
			seeds: config.functionHints};
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
