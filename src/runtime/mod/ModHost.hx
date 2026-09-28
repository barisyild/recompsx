package mod;

import core.CpuState;
import mem.Memory;

/**
	Where mods meet the recompiled game (ADR-0033).

	A mod is per-game Haxe code, kept beside the game's config in `games/<SERIAL>/mods/<id>/`, that
	gives a recompiled game something it never had — a menu entry, a fix, a new mode — without a
	single generated line being edited. It reaches the game three ways, all of them here:

	- **Hooks.** A mod names guest functions by address in its `mod.json`; `recompsx gen --mods`
	  then emits one line at the entry of each, `if (entry == 0 && ModHost.enter(ctx, addr)) return;`,
	  and nothing anywhere else. The mod's handler runs with the guest's arguments in `ctx`, and
	  either lets the original run (returns false), or answers the call itself (returns true) —
	  which may include running the original in between, through `callOriginal`.
	- **Frames.** `onFrame` handlers run at every vblank, after the machine's own frame work.
	- **Boot.** `onBoot` handlers run once the executable is in RAM, before its first instruction.

	And it owns memory the game can read but never owned — the mod heap, in `ModRam` past the
	machine's 2 MB — for the records, strings and tables it hands the game.

	A build without mods never calls `install` (the launcher does, under `recompsx_mods`) and its
	generated code contains no `enter`, so it is the same program it was before this file existed.
	A build with mods runs a different program on purpose: its digests are its own.

	Mods are held to the runtime's rules — no host time, no floats in state, nothing that could
	make two runs of one build differ — and to its portable subset, because they ship with the
	console builds too. Handlers are static functions held as function values, the pattern
	`Runtime.bindDispatch` already relies on; there is no inheritance to verify.
**/
class ModHost {
	/** True once a mod has installed anything: the launcher's and the kernel's calls check it. */
	public static var active(default, null) = false;

	static final hookAddrs:Array<Int> = [];
	static final hookFns:Array<CpuState -> Int -> Bool> = [];
	static final frameFns:Array<CpuState -> Void> = [];
	static final bootFns:Array<CpuState -> Void> = [];

	/** Addresses the generated code enters us at, as `gen --mods` emitted them. */
	static final declared:Array<Int> = [];

	/** The next entry at this address is the original's own: `callOriginal` is running it. */
	static var bypass = 0;

	/** The mod heap: a bump allocator over guest RAM that no guest code uses. */
	static var heapBase = 0;
	static var heapEnd = 0;
	static var heapNext = 0;

	// ---- installing (from the generated ModList, once, before the game runs) ---------------------

	/** The addresses `gen --mods` emitted an entry at. A hook anywhere else would never run. */
	public static function declare(addr:Int):Void {
		declared.push(addr);
	}

	/**
		The mod heap in memory of the mods' own, past the machine's 2 MB (`ModRam`, 9F000000h):
		nothing a game does can reach it by accident. The default; `gen --mods` asks for it.
	**/
	public static function expansion(bytes:Int):Void {
		#if recompsx_mods
		ModRam.allocate(bytes);
		heap(0x80000000 | (ModRam.BASE + ModRam.RESERVED), bytes - ModRam.RESERVED);
		#else
		shim.Backend.log(shim.Backend.LOG_ERROR, "mod: memory past 2 MB is decoded only with -D recompsx_mods");
		#end
	}

	/** The mod heap in guest RAM instead, where a manifest says nothing lives: for data a game
	    must reach by DMA, which addresses RAM only. */
	public static function heap(base:Int, size:Int):Void {
		heapBase = base;
		heapEnd = (base + size) | 0;
		heapNext = base;
	}

	/**
		`fn` runs whenever the guest calls `addr` (and the call really enters there: a resumed
		function is not called again). True from `fn` means the call is answered and the original
		does not run.
	**/
	public static function hook(addr:Int, fn:CpuState -> Int -> Bool):Void {
		if (!isDeclared(addr)) {
			shim.Backend.log(shim.Backend.LOG_ERROR, "mod: hook at " + hex(addr)
				+ " is not in any mod.json — the generated code never enters there");
		} else {}
		hookAddrs.push(addr);
		hookFns.push(fn);
		active = true;
	}

	static function isDeclared(addr:Int):Bool {
		var found = false;
		for (a in declared) found = found || a == addr;
		return found;
	}

	public static function onFrame(fn:CpuState -> Void):Void {
		frameFns.push(fn);
		active = true;
	}

	public static function onBoot(fn:CpuState -> Void):Void {
		bootFns.push(fn);
		active = true;
	}

	// ---- the runtime's side ---------------------------------------------------------------------

	/** Generated code, at the entry of every hooked function. True: a mod took the call. */
	public static function enter(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (bypass == addr) bypass = 0;
		else taken = runHooks(ctx, addr);
		return taken;
	}

	static function runHooks(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		var i = 0;
		while (i < hookAddrs.length) {
			if (!taken && hookAddrs[i] == addr) taken = hookFns[i](ctx, addr);
			else {}
			i++;
		}
		return taken;
	}

	/** The launcher, once the executable is loaded and before its first instruction. */
	public static function boot(ctx:CpuState):Void {
		heapNext = heapBase;
		for (fn in bootFns) fn(ctx);
	}

	/** The kernel's frame boundary (`Kernel.onFrame`), every vblank. */
	public static function frame(ctx:CpuState):Void {
		for (fn in frameFns) fn(ctx);
	}

	// ---- what a mod may do ------------------------------------------------------------------------

	/**
		Runs the function a hook was entered at, as the guest called it: the registers in `ctx` are
		the arguments, and on return they hold what it left (`v0`, and the saved registers the
		guest ABI restores). For a hook that works around the original — before and after —
		rather than instead of it; the hook then returns true.

		It runs to completion: a cooperative build does not yield inside it, since the frame it
		would resume into is the mod's, not the game's.
	**/
	public static function callOriginal(ctx:CpuState, addr:Int):Void {
		bypass = addr;
		call(ctx, addr);
		bypass = 0;
	}

	/**
		Calls any guest function by address, with the arguments the mod put in `ctx.a0..a3` (and
		on the guest stack, past the sixteen bytes a caller reserves, for more). `ra` is kept.
	**/
	public static function call(ctx:CpuState, addr:Int):Void {
		final ra = ctx.ra;
		final pc = ctx.pc;
		ctx.pc = addr;
		#if recompsx_cooperative
		core.Cooperative.blocked++;
		#end
		core.Runtime.call(ctx, addr);
		#if recompsx_cooperative
		core.Cooperative.blocked--;
		#end
		ctx.ra = ra;
		ctx.pc = pc;
	}

	/** `bytes` of the mod heap, word-aligned; 0 if it is full. Reset at every boot. */
	public static function alloc(bytes:Int):Int {
		var at = 0;
		final size = (bytes + 3) & ~3;
		if (heapNext != 0 && ((heapEnd - heapNext) | 0) >= size) {
			at = heapNext;
			heapNext = (heapNext + size) | 0;
		} else {
			shim.Backend.log(shim.Backend.LOG_ERROR, "mod: heap full, " + bytes + " bytes wanted");
		}
		return at;
	}

	/** A NUL-terminated ASCII string in the mod heap, for the game to read; its address. */
	public static function cstring(s:String):Int {
		final at = alloc(s.length + 1);
		if (at != 0) {
			for (i in 0...s.length) write8((at + i) | 0, codeAt(s, i));
			write8((at + s.length) | 0, 0);
		} else {}
		return at;
	}

	/** A character's code, or 0 past the end: `charCodeAt` answers `Null<Int>`. */
	static function codeAt(s:String, i:Int):Int {
		final c:Null<Int> = s.charCodeAt(i);
		var v = 0;
		if (c != null) v = c & 0xFF;
		else {}
		return v;
	}

	/** A copy of `bytes` of guest memory, in the mod heap; its address. */
	public static function copy(from:Int, bytes:Int):Int {
		final at = alloc(bytes);
		if (at != 0) {
			for (i in 0...bytes) write8((at + i) | 0, read8u((from + i) | 0));
		} else {}
		return at;
	}

	// Guest memory by its virtual address, as the game's own pointers hold it.
	public static inline function read8u(a:Int):Int return Memory.read8u(a & 0x1FFFFFFF);

	public static inline function read16s(a:Int):Int return Memory.read16s(a & 0x1FFFFFFF);

	public static inline function read16u(a:Int):Int return Memory.read16u(a & 0x1FFFFFFF);

	public static inline function read32(a:Int):Int return Memory.read32(a & 0x1FFFFFFF);

	public static inline function write8(a:Int, v:Int):Void Memory.write8(a & 0x1FFFFFFF, v);

	public static inline function write16(a:Int, v:Int):Void Memory.write16(a & 0x1FFFFFFF, v);

	public static inline function write32(a:Int, v:Int):Void Memory.write32(a & 0x1FFFFFFF, v);

	/**
		A console setting (`kernel.KSettings`, ADR-0034): kept across sessions by the backend, shared
		by every game and mod, "" until something sets it. Name mods' keys `<area>.<name>`.
	**/
	public static inline function setting(key:String):String return kernel.KSettings.get(key);

	/** Sets and keeps a console setting; false when the backend could not keep it. */
	public static inline function setSetting(key:String, value:String):Bool return kernel.KSettings.set(key, value);

	/** The buttons held on a port, PS1 layout, active high — what the game will read this frame. */
	public static inline function buttons(port:Int):Int return sio.Pads.buttonsOf(port);

	/**
		Text entry on the host's keyboard (`kernel.KKeyboard`, ADR-0036), for a field the mod has
		open: while it is on, the keyboard types rather than plays. Turn it off when the field closes.
	**/
	public static inline function textEntry(on:Bool):Void kernel.KKeyboard.textEntry(on);

	/**
		The next thing typed while text entry is on, oldest first: a Unicode code point, or
		`KKeyboard.BACKSPACE`, `ENTER` or `ESCAPE`; -1 when nothing is waiting. What the game cannot
		show is the mod's to ignore.
	**/
	public static inline function typed():Int return kernel.KKeyboard.next();

	/** Mouse buttons, for `mouseHeld` and `mouseClicks`. */
	public static inline var MOUSE_LEFT = 0;
	public static inline var MOUSE_RIGHT = 1;
	public static inline var MOUSE_MIDDLE = 2;
	/** The side buttons: back (nearer the wrist) and forward. */
	public static inline var MOUSE_BACK = 3;
	public static inline var MOUSE_FORWARD = 4;

	/**
		Whether the pointer is over the picture (`kernel.KMouse`, ADR-0038); never where the machine
		has no mouse. Its position is in the display's pixels, `pictureWidth` x `pictureHeight`.
	**/
	public static inline function mouseOver():Bool return kernel.KMouse.over;

	public static inline function mouseX():Int return kernel.KMouse.x;

	public static inline function mouseY():Int return kernel.KMouse.y;

	public static inline function pictureWidth():Int return kernel.KMouse.width;

	public static inline function pictureHeight():Int return kernel.KMouse.height;

	public static inline function mouseHeld(button:Int):Bool return (kernel.KMouse.buttons & (1 << button)) != 0;

	/**
		Presses of a button, and moves of the pointer, counted from boot: keep the last count seen,
		and a different one is a click, or a move, since then — nothing is taken from another reader.
	**/
	public static inline function mouseClicks(button:Int):Int return kernel.KMouse.clicks(button);

	public static inline function mouseMoves():Int return kernel.KMouse.moves;

	/** Whether an address is in mod memory (`mod.ModRam`): data a mod made, not the game. */
	public static inline function isModMemory(addr:Int):Bool return ModRam.contains(addr & 0x1FFFFFFF);

	public static function log(what:String):Void {
		shim.Backend.log(shim.Backend.LOG_INFO, "mod: " + what);
	}

	public static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var s = "";
		for (i in 0...8) s += digits.charAt((v >>> ((7 - i) * 4)) & 15);
		return "0x" + s;
	}
}
