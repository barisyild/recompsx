package recomp.config;

import recomp.Vaddr;
import recomp.loader.LoaderError;
import sys.FileSystem;

/** A guest function a mod enters at; `scope` is an overlay id, "exe", or null for any code there. */
typedef ModHook = {addr:Int, scope:Null<String>};

/**
	One mod, as its `games/<SERIAL>/mods/<id>/mod.json` describes it (ADR-0033).

	The manifest says what the code generator has to know and nothing else: which guest functions
	the mod enters at, the class whose `install` registers it, and — optionally — where in guest
	memory its data may live. Everything the mod *does* is in its Haxe sources beside the
	manifest, in the package named by its id, which `gen --mods` copies next to the generated code.

	```json
	{
	  "id": "onlinemenu",
	  "title": "ONLINE in the main menu",
	  "entry": "onlinemenu.OnlineMenu",
	  "hooks": [{"_addr": "0x800b3ca8", "addr": 2148220072, "in": "stage"}],
	  "memory": 65536
	}
	```

	The heap lives in the mods' own memory past the machine's 2 MB (runtime `mod.ModRam`, guest
	9F000000h), `memory` bytes of it (64 KB when unsaid; the largest request wins). A manifest may
	instead name a `heap` {addr, size} in guest RAM, for data the game must reach by DMA.

	Addresses are decimal, as in game.json, with the hex beside them under an underscore key. A
	hook's `in` scopes it to one overlay (or "exe"): windows are shared, and the same address is a
	different function in each overlay that loads there.
**/
@:access(recomp.config.GameConfig)
class ModConfig {
	/** Mod memory when a manifest asks for none in particular. */
	public static inline var DEFAULT_MEMORY = 0x10000;

	public final id:String;
	public final title:String;
	/** Fully qualified: `<id>.<Class>`. */
	public final entry:String;
	public final hooks:Array<ModHook>;
	public final heapAddr:Null<Int>;
	public final heapSize:Int;
	/** Bytes of mod memory past 2 MB this mod wants; 0 when it did not say. */
	public final memory:Int;
	/** The directory holding mod.json and the sources. */
	public final dir:String;

	function new(id:String, title:String, entry:String, hooks:Array<ModHook>, heapAddr:Null<Int>,
			heapSize:Int, memory:Int, dir:String) {
		this.id = id;
		this.title = title;
		this.entry = entry;
		this.hooks = hooks;
		this.heapAddr = heapAddr;
		this.heapSize = heapSize;
		this.memory = memory;
		this.dir = dir;
	}

	/**
		The mods `--mods` names, from a game's config directory: a comma-separated list of ids, or
		"all" for every directory under `mods/` that has a mod.json.
	**/
	public static function select(configDir:String, which:String):Array<ModConfig> {
		final root = configDir + "/mods";
		final ids = if (which == "all") {
			if (!FileSystem.exists(root)) [];
			else {
				final found = [for (d in FileSystem.readDirectory(root))
					if (FileSystem.exists('$root/$d/mod.json')) d];
				found.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
				found;
			}
		} else [for (s in which.split(",")) if (StringTools.trim(s) != "") StringTools.trim(s)];
		return [for (id in ids) load('$root/$id')];
	}

	public static function load(dir:String):ModConfig {
		final at = dir + "/mod.json";
		if (!FileSystem.exists(at)) throw new LoaderError('no mod at $dir (no mod.json)');
		final root = GameConfig.parseJson(at);
		final id = GameConfig.stringField(root, "id", null);
		if (id == null || !validId(id)) {
			throw new LoaderError('$at: "id" must be a lowercase Haxe package name (letters, digits, '
				+ 'underscores; a letter first), because it is the package of the mod\'s sources');
		}
		final name = dir.split("/").pop();
		if (name != id) throw new LoaderError('$at: id "$id" does not match its directory "$name"');
		final entry = GameConfig.stringField(root, "entry", null);
		if (entry == null || !StringTools.startsWith(entry, id + ".")) {
			throw new LoaderError('$at: "entry" must name a class in package $id, e.g. "$id.Main"');
		}
		final hooks:Array<ModHook> = [];
		for (raw in GameConfig.arrayField(root, "hooks")) {
			final addr = Vaddr.canonRam(GameConfig.requiredNumber(raw, "addr", 'hook in $at'));
			hooks.push({addr: addr, scope: GameConfig.stringField(raw, "in", null)});
		}
		final heap = Reflect.field(root, "heap");
		var heapAddr:Null<Int> = null;
		var heapSize = 0;
		if (heap != null) {
			heapAddr = Vaddr.canonRam(GameConfig.requiredNumber(heap, "addr", 'heap in $at'));
			heapSize = GameConfig.requiredNumber(heap, "size", 'heap in $at');
		}
		final memory = GameConfig.numberOr(root, "memory", 0);
		if (memory < 0 || memory > 0x800000 || (memory & 3) != 0) {
			throw new LoaderError('$at: "memory" is $memory; it must be a multiple of 4, at most 8 MB '
				+ '(expansion region 1)');
		}
		return new ModConfig(id, GameConfig.stringField(root, "title", id), entry, hooks, heapAddr,
			heapSize, memory, dir);
	}

	static function validId(s:String):Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			final c = s.charCodeAt(i);
			final letter = c >= 'a'.code && c <= 'z'.code;
			final ok = letter || c == '_'.code || (i > 0 && c >= '0'.code && c <= '9'.code);
			if (!ok) return false;
		}
		return true;
	}

	/** The Haxe sources to copy, relative to the mod's directory (subpackages included). */
	public function sources():Array<String> {
		final out = [];
		function walk(rel:String) {
			final abs = rel == "" ? dir : '$dir/$rel';
			final names = FileSystem.readDirectory(abs);
			names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			for (n in names) {
				final r = rel == "" ? n : '$rel/$n';
				if (FileSystem.isDirectory('$dir/$r')) walk(r);
				else if (StringTools.endsWith(n, ".hx")) out.push(r);
			}
		}
		walk("");
		return out;
	}

	public function describe():String {
		return 'mod $id ($title): ${hooks.length} hook${hooks.length == 1 ? "" : "s"}';
	}

	public static function hexOf(a:Int):String return Vaddr.hex(a);
}
