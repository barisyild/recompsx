package recomp;

import haxe.io.Bytes;
import recomp.loader.LoaderError;
import recomp.loader.PsxExe;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.mips.Instr;
import sys.io.File;

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
				case "help" | "-h" | "--help": usage(); Sys.exit(EXIT_OK);
				case _:
					Sys.stderr().writeString('unknown command "$command"\n\n');
					usage();
					Sys.exit(EXIT_USAGE);
			}
		} catch (e:LoaderError) {
			Sys.stderr().writeString("error: " + e.message + "\n");
			Sys.exit(EXIT_LOADER);
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

	static function loadExe(path:String):PsxExe {
		if (!sys.FileSystem.exists(path)) throw new LoaderError('no such file: $path');
		final bytes:Bytes = File.getBytes(path);
		return PsxExe.parse(bytes);
	}

	static function parseAddr(s:String):Int {
		final v = Std.parseInt(s);
		if (v == null) throw new LoaderError('could not read "$s" as an address');
		return v;
	}
}
