import recomp.codegen.Program;
import recomp.config.ModConfig;
import recomp.config.ModConfig.ModHook;

/**
	Mods' hooks in the generated code (ADR-0033), on TestOverlay's three small programs: an
	executable, and two overlays sharing one window with an identical function at WINDOW + 40h.

	What must hold: a hook reaches exactly the functions it names, in the universes its scope
	names; everything else is emitted as if mods did not exist; and a hook that could never run
	— no function there, or a scope the game does not have — is refused rather than ignored. And
	a mod that builds on others (`needs`) brings them along, each once and before it.
**/
@:access(TestOverlay)
class TestMods {
	static inline var BASE = 0x80010000;
	static inline var WINDOW = 0x80020000;
	static inline var SHARED = WINDOW + 0x40;

	static function build(hooks:Null<Array<ModHook>>):{program:Program, files:Map<String, String>} {
		final p = TestOverlay.build(["a", "b"], [0x00001021, 0x03E00008]);
		if (hooks != null) p.setHooks(hooks);
		final dir = "out/_tooltest_mods";
		if (sys.FileSystem.exists(dir)) {
			for (n in sys.FileSystem.readDirectory(dir)) sys.FileSystem.deleteFile('$dir/$n');
		}
		return {program: p, files: TestOverlay.writeAndRead(p, dir)};
	}

	static function enters(src:Null<String>, addr:String):Bool {
		return src != null && src.indexOf('mod.ModHost.enter(ctx, $addr)') >= 0;
	}

	public static function run():Void {
		final plain = build(null).files;

		Assert.group("mods: no hooks, no change");
		{
			final empty = build([]).files;
			for (name in plain.keys()) {
				Assert.equals(empty.get(name), plain.get(name), 'an empty hook list leaves $name as it was');
			}
			for (name in plain.keys()) {
				Assert.isTrue(plain.get(name).indexOf("ModHost") < 0, '$name mentions no mod host');
			}
		}

		Assert.group("mods: a scoped hook reaches one overlay of a shared window");
		{
			final hooked = build([{addr: SHARED, scope: "a"}]);
			final a = hooked.files.get("Ovl_a_01_80020000.hx");
			final b = hooked.files.get("Ovl_b_02_80020000.hx");
			Assert.isTrue(enters(a, "0x80020040"), "overlay a's function enters the host");
			Assert.isTrue(a.indexOf('f_80020040_value(') < 0, "hooked code has no scalar entry to bypass its hook");
			Assert.isTrue(b.indexOf('f_80020040_value(') >= 0, "a hook in another universe does not disable a safe scalar entry");
			Assert.isTrue(!enters(b, "0x80020040"), "overlay b's, at the same address, does not");
			Assert.isTrue(b.indexOf("public static function f_80020040(") >= 0,
				"and b now emits its own copy, since the two texts differ");
			Assert.isTrue(!enters(a, "0x80020000"), "a's other function is untouched");
			Assert.equals(hooked.files.get("Fns_00_80010000.hx"), plain.get("Fns_00_80010000.hx"),
				"the executable is untouched");
			Assert.equals(hooked.program.unmatchedHooks([{addr: SHARED, scope: "a"}]).length, 0,
				"and the hook matched");
		}

		Assert.group("mods: the hook line: a real call only, before the body");
		{
			final src = build([{addr: BASE + 0x100, scope: null}]).files.get("Fns_00_80010000.hx");
			Assert.isTrue(src.indexOf("if (entry == 0 && entryPump && mod.ModHost.enter(ctx, 0x80010100)) return;") >= 0,
				"a cooperative build enters only at a fresh call or the entry's own resume");
			Assert.isTrue(src.indexOf("if (entry == 0 && mod.ModHost.enter(ctx, 0x80010100)) return;") >= 0,
				"a plain build enters only at entry 0");
			final fn = src.indexOf("public static function f_80010100(");
			final hook = src.indexOf("mod.ModHost.enter(ctx, 0x80010100)");
			final pump = src.indexOf("Runtime.pump(ctx)", fn);
			Assert.isTrue(fn >= 0 && pump > fn && hook > pump, "after the function's entry pump");
			Assert.isTrue(!enters(src, "0x80010000"), "the entry point, unhooked, is untouched");
		}

		Assert.group("mods: an unscoped hook reaches every universe that has the function");
		{
			final files = build([{addr: SHARED, scope: null}]).files;
			Assert.isTrue(enters(files.get("Ovl_a_01_80020000.hx"), "0x80020040"), "overlay a");
			final b = files.get("Ovl_b_02_80020000.hx");
			Assert.isTrue(enters(b, "0x80020040")
				|| b.indexOf("Identical to `Ovl_a_01_80020000.f_80020040`") >= 0,
				"overlay b, or b shares a's hooked body");
		}

		Assert.group("mods: a hook that could never run is refused");
		{
			final nowhere = build([{addr: BASE + 4, scope: null}]);
			Assert.equals(nowhere.program.unmatchedHooks([{addr: BASE + 4, scope: null}]).length, 1,
				"no function begins mid-function");
			final p = TestOverlay.build(["a", "b"], [0x00001021, 0x03E00008]);
			Assert.rejects(() -> p.setHooks([{addr: SHARED, scope: "c"}]), 'in "c"',
				"a scope that is no overlay of the game");
		}

		Assert.group("mods: a mod brings the mods it needs, each before it");
		{
			final root = "out/_tooltest_mods_needs";
			writeMod(root, "menu", []);
			writeMod(root, "res", ["menu"]);
			writeMod(root, "wide", ["menu"]);
			Assert.equals(ids(ModConfig.select(root, "res")), "menu,res", "the one it needs comes along, first");
			Assert.equals(ids(ModConfig.select(root, "wide,res")), "menu,wide,res", "once, before the first that needs it");
			Assert.equals(ids(ModConfig.select(root, "res,menu")), "menu,res", "named as well, still once");
			Assert.equals(ids(ModConfig.select(root, "all")), "menu,res,wide", "all of them");
			final broken = "out/_tooltest_mods_needs_broken";
			writeMod(broken, "loop", ["loop2"]);
			writeMod(broken, "loop2", ["loop"]);
			writeMod(broken, "lost", ["nowhere"]);
			Assert.rejects(() -> ModConfig.select(broken, "loop"), "needs itself", "a mod that needs itself");
			Assert.rejects(() -> ModConfig.select(broken, "lost"), 'needs "nowhere"', "a mod the game does not have");
		}
	}

	/** A mod directory with nothing but its manifest: `id`, needing `needs`. */
	static function writeMod(root:String, id:String, needs:Array<String>):Void {
		final dir = '$root/mods/$id';
		sys.FileSystem.createDirectory(dir);
		final list = [for (n in needs) '"$n"'].join(", ");
		sys.io.File.saveContent('$dir/mod.json', '{ "id": "$id", "entry": "$id.Main", "hooks": [], "needs": [$list] }\n');
	}

	static function ids(mods:Array<ModConfig>):String return [for (m in mods) m.id].join(",");
}
