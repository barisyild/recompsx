package recomp.config;

import haxe.Json;
import recomp.Vaddr;
import recomp.loader.LoaderError;
import sys.FileSystem;
import sys.io.File;

/** A function the config asserts exists, with the name it should be given. */
typedef Hint = {addr:Int, name:String};

/** Where an overlay's bytes come from. Exactly one shape is valid per stanza. */
enum OverlaySource {
	/** A file inside the disc's own filesystem, plus a byte offset into it. */
	DiscFile(path:String, offset:Int, length:Int);
	/** Raw sectors, for data that is not a file — a game with its own layout. */
	Sectors(lba:Int, count:Int);
	/** A host-local capture. The escape hatch for compressed overlays, never committed. */
	MemDump(path:String);
}

/**
	One overlay: bytes from somewhere on the disc, placed at a fixed address.

	PlayStation overlays are linked at their final virtual address — there is no load-time
	relocation on this machine — so an overlay's identity is exactly the pair *(these bytes, this
	window)*. That is what makes the model tractable: the same file placed at two addresses is
	two overlays and gets two stanzas, and everything else follows from the window.
**/
class OverlayConfig {
	public final id:String;
	public final loadAddr:Int;
	public final length:Int;
	public final source:OverlaySource;
	public final entryHints:Array<Hint>;
	public final hashWords:Int;

	public function new(id, loadAddr, length, source, entryHints, hashWords) {
		this.id = id;
		this.loadAddr = loadAddr;
		this.length = length;
		this.source = source;
		this.entryHints = entryHints;
		this.hashWords = hashWords;
	}

	public inline function endAddr():Int return loadAddr + length;

	public function describe():String {
		return '$id: ${Vaddr.hex(loadAddr)}..${Vaddr.hex(endAddr() - 1)} (${length} bytes)';
	}
}

/**
	A game's committed facts, plus the one gitignored file that says where the dump lives.

	Two files, deliberately. `game.json` is clean-room reverse engineering — addresses, names,
	overlay windows — and belongs in the repository. `local.json` is a path on somebody's disk to
	a dump they own, and belongs nowhere near it (golden rule 4). Keeping them apart is what lets
	the interesting half be shared.

	**Numbers.** Addresses are written as decimal, per the schema rule in docs/specs/tool.md, and
	a PlayStation RAM address does not fit in a signed 32-bit integer — `0x80076288` is
	2148033160, which is past `Std.parseInt`. So every numeric field goes through `number()`,
	which reads it the way `Main.parseAddr` reads a command line and folds the top half of the
	range into the negative integers the rest of the tool uses. A string is accepted too, in
	decimal or `0x` form: a person editing this file by hand thinks in hex, the tool prints hex
	everywhere else, and refusing it would be pedantry rather than discipline.
**/
class GameConfig {
	public final path:String;
	public final dir:String;

	public final id:String;
	public final title:String;
	public final region:String;

	/** Where the executable lives inside the disc's filesystem, e.g. `\SCUS_945.70;1`. */
	public final exePath:String;

	public final functionHints:Array<Hint>;
	public final overlays:Array<OverlayConfig>;

	/** From local.json: a CUE or a bare image. Null when the game is a loose executable. */
	public final discPath:String;

	/** From local.json: a bare PS-EXE, for homebrew with no disc. Null otherwise. */
	public final exeFile:String;

	function new(path, dir, id, title, region, exePath, functionHints, overlays, discPath,
			exeFile) {
		this.path = path;
		this.dir = dir;
		this.id = id;
		this.title = title;
		this.region = region;
		this.exePath = exePath;
		this.functionHints = functionHints;
		this.overlays = overlays;
		this.discPath = discPath;
		this.exeFile = exeFile;
	}

	public static function load(configPath:String):GameConfig {
		if (!FileSystem.exists(configPath)) {
			throw new LoaderError('no such config: $configPath');
		}
		final root = parseJson(configPath);
		final dir = directoryOf(configPath);

		final overlays = [];
		final rawOverlays = arrayField(root, "overlays");
		for (i in 0...rawOverlays.length) overlays.push(overlayOf(rawOverlays[i], i));
		checkOverlaysDistinct(overlays);

		final local = loadLocal(dir);

		return new GameConfig(configPath, dir,
			stringField(root, "id", "game"),
			stringField(root, "title", "untitled"),
			stringField(root, "region", "NTSC-U"),
			stringField(root, "exePath", null),
			hintsOf(arrayField(root, "functionHints")),
			overlays,
			local.disc, local.exeFile);
	}

	/**
		The one thing `local.json` is for: which of the user's files to read.

		Absent is not an error here. A config is still worth loading without it — the overlay
		windows and hints are the interesting part — and the caller reports the missing input with
		the context to fix it.
	**/
	static function loadLocal(dir:String):{disc:String, exeFile:String} {
		final at = dir + "/local.json";
		if (!FileSystem.exists(at)) return {disc: null, exeFile: null};
		final local = parseJson(at);
		// `cue` and `iso` are the same thing to the reader below — a path to a disc image, whose
		// shape it works out by looking. Two names because a person knows which they have.
		var disc = stringField(local, "cue", null);
		if (disc == null) disc = stringField(local, "iso", null);
		return {disc: disc, exeFile: stringField(local, "exeFile", null)};
	}

	static function overlayOf(raw:Dynamic, index:Int):OverlayConfig {
		final id = stringField(raw, "id", null);
		if (id == null) throw new LoaderError('overlay $index has no id');
		final loadAddr = Vaddr.canonRam(requiredNumber(raw, "loadAddr", 'overlay "$id"'));
		final length = requiredNumber(raw, "length", 'overlay "$id"');
		if (length <= 0 || (length & 3) != 0) {
			throw new LoaderError('overlay "$id" has length $length, which must be a positive '
				+ 'multiple of four');
		}
		if ((loadAddr & 3) != 0) {
			throw new LoaderError('overlay "$id" loads at ${Vaddr.hex(loadAddr)}, which is not '
				+ 'word-aligned');
		}
		return new OverlayConfig(id, loadAddr, length, sourceOf(raw, id),
			hintsOf(arrayField(raw, "entryHints")),
			numberOr(raw, "hashWords", 64));
	}

	/**
		Which of the three source shapes a stanza uses, decided by its `kind`.

		`memdump` names a file the user captured themselves and which is never committed — it is
		how a compressed overlay gets analysed at all, since the bytes in the executable are not
		the bytes that run. The other two are reproducible from the disc alone, and are what a
		committed config should use wherever it can.
	**/
	static function sourceOf(raw:Dynamic, id:String):OverlaySource {
		final src = Reflect.field(raw, "source");
		if (src == null) throw new LoaderError('overlay "$id" has no source');
		final kind = stringField(src, "kind", null);
		if (kind == "discFile") {
			final p = stringField(src, "path", null);
			if (p == null) throw new LoaderError('overlay "$id" source has no path');
			return DiscFile(p, numberOr(src, "offset", 0), numberOr(src, "length", 0));
		} else if (kind == "sectors") {
			return Sectors(requiredNumber(src, "lba", 'overlay "$id" source'),
				requiredNumber(src, "count", 'overlay "$id" source'));
		} else if (kind == "memdump") {
			final p = stringField(src, "path", null);
			if (p == null) throw new LoaderError('overlay "$id" memdump has no path');
			return MemDump(p);
		} else {
			throw new LoaderError('overlay "$id" has source kind "$kind"; expected discFile, '
				+ 'sectors or memdump');
		}
	}

	/**
		Two overlays may share a window — that is the whole point of one — but not an id.

		The id names a generated class prefix and every diagnostic about the overlay, so a
		duplicate would produce two things with one name and a build failure much further away
		from the mistake than this.
	**/
	static function checkOverlaysDistinct(overlays:Array<OverlayConfig>):Void {
		for (i in 0...overlays.length) {
			for (j in 0...i) {
				if (overlays[i].id == overlays[j].id) {
					throw new LoaderError('two overlays are both called "${overlays[i].id}"');
				}
			}
		}
	}

	static function hintsOf(raw:Array<Dynamic>):Array<Hint> {
		final out = [];
		for (i in 0...raw.length) {
			final entry = raw[i];
			// A hint may be a bare address or an object with a name. The bare form is what a
			// recorded run produces and there is no reason to make a person dress it up.
			if (Reflect.isObject(entry) && Reflect.field(entry, "addr") != null) {
				final a = Vaddr.canonRam(requiredNumber(entry, "addr", "hint"));
				out.push({addr: a, name: stringField(entry, "name", defaultName(a))});
			} else {
				final a = Vaddr.canonRam(number(entry, "hint"));
				out.push({addr: a, name: defaultName(a)});
			}
		}
		return out;
	}

	static function defaultName(addr:Int):String {
		return "f_" + StringTools.hex(Vaddr.canonRam(addr), 8).toLowerCase();
	}

	// ---- reading JSON --------------------------------------------------------------------------

	static function parseJson(at:String):Dynamic {
		try {
			return Json.parse(File.getContent(at));
		} catch (e:Dynamic) {
			throw new LoaderError('$at is not valid JSON: $e');
		}
	}

	static function stringField(obj:Dynamic, name:String, fallback:String):String {
		final v = Reflect.field(obj, name);
		return v == null ? fallback : Std.string(v);
	}

	static function arrayField(obj:Dynamic, name:String):Array<Dynamic> {
		final v = Reflect.field(obj, name);
		if (v == null) return [];
		final a:Array<Dynamic> = cast v;
		return a;
	}

	static function requiredNumber(obj:Dynamic, name:String, what:String):Int {
		final v = Reflect.field(obj, name);
		if (v == null) throw new LoaderError('$what has no $name');
		return number(v, '$what $name');
	}

	static function numberOr(obj:Dynamic, name:String, fallback:Int):Int {
		final v = Reflect.field(obj, name);
		return v == null ? fallback : number(v, name);
	}

	/**
		A JSON number, or a string holding one, as the Int the rest of the tool uses.

		Values at or above 2^31 wrap into the negative half, which is the representation every
		KSEG0 address already has here — `Vaddr.canonRam` and the emitter both expect it, and a
		config that said 2148033160 means the same address as one that said `"0x80076288"`.
	**/
	static function number(v:Dynamic, what:String):Int {
		return parseNumeric(Std.string(v), what);
	}

	/**
		Written without a fractional type anywhere in a signature, on purpose.

		`Std.parseInt` gives up above 2^31 and every RAM address here is above it, so the parse has
		to go through the wider numeric type — but only as an inferred local, never as a declared
		one. The discipline gate greps for that type as a whole word (`scripts/check.sh`), and the
		exemption it would take to declare it is not worth spending on a config parser when the
		same value can simply be folded on the spot. `Main.parseAddr` reads a command line the same
		way, for the same reason.
	**/
	static function parseNumeric(s:String, what:String):Int {
		final trimmed = StringTools.trim(s);
		final direct = Std.parseInt(trimmed);
		if (direct != null) return direct;

		final wide = Std.parseFloat(trimmed);
		if (Math.isNaN(wide)) throw new LoaderError('$what is not a number: "$s"');
		if (wide < 0 || wide > 4294967295.0) {
			throw new LoaderError('$what is outside the 32-bit range: $trimmed');
		}
		// At or above 2^31 the value folds into the negative half, which is the representation
		// every KSEG0 address already has in this tool.
		return wide >= 2147483648.0 ? Std.int(wide - 4294967296.0) : Std.int(wide);
	}

	static function directoryOf(p:String):String {
		final slash = p.lastIndexOf("/");
		return slash >= 0 ? p.substr(0, slash) : ".";
	}
}
