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

	/** The buttons held on the host's pad `pad` (0..3; with the multitap, slot A..D), PS1 layout,
	    active high — what the game will read this frame. */
	public static inline function buttons(pad:Int):Int return sio.Pads.buttonsOf(pad);

	/**
		The game quits — a menu's QUIT: its memory card kept, then the host's own menu (the
		Dreamcast's BIOS menu, the desktop, the page's start screen; `kernel.Kernel.exitToMenu`).
		Nothing happens in a headless run.
	**/
	public static inline function exitToMenu():Void kernel.Kernel.exitToMenu();

	// ---- controllers of the mod's own (ADR-0040) --------------------------------------------------
	//
	// The machine's own peripherals, each on a controller port that is the mod's alone — the game
	// never sees it — and spoken to the way the machine speaks to one: a transfer (`exchange`), byte
	// for byte, as SIO0 makes it. What the bytes mean is the device's documented protocol (psx-spx,
	// "Controllers and Memory Cards"), and nothing else.

	/**
		A Sony Mouse (SCPH-1030, `sio.SonyMouse`): the port, or -1. Read it with 01h, 42h and four
		zeros: back come Hi-Z, ID 12h, 5Ah, the buttons (bit 10 right, bit 11 left of the halfword, 0 =
		pressed) and the motion since the last read (signed bytes, across then down). A cursor that
		starts in the middle of the display (`displayWidth` x `displayHeight`), adds the motion up and
		stays inside the display is where the host's pointer is. While a mod reads one, the machine
		shows its pointer on it (hidden while a pad is in use).
	**/
	public static function plugMouse():Int {
		final unit = sio.SonyMouse.plug();
		return unit >= 0 ? addPort(PORT_MOUSE, unit) : -1;
	}

	/**
		The PS1 keyboard (`sio.Ps2Keyboard`, the protocol of Sony's SCPH-2000 PS/2 adaptor): the port,
		or -1. Read it with 01h, 42h, twelve zeros and 06h: back come Hi-Z, ID 96h, 5Ah, how many
		scancode bytes follow (0..11) and those bytes, PS/2 Scan Code Set 2 as a US keyboard sends
		them. While a mod reads one, the host's keyboard types into it rather than playing the pad.
	**/
	public static function plugKeyboard():Int {
		final unit = sio.Ps2Keyboard.plug();
		return unit >= 0 ? addPort(PORT_KEYBOARD, unit) : -1;
	}

	/**
		The i-mode adaptor (SCPH-10180, `sio.IModeAdaptor`): the port, or -1. Addressed with 41h, it
		takes commands 11h..18h; `mod.LibImode` speaks it as Sony's libimode did, and the phone behind
		it takes HTTP requests to the host's network.
	**/
	public static function plugIMode():Int {
		final unit = sio.IModeAdaptor.plug();
		return unit >= 0 ? addPort(PORT_IMODE, unit) : -1;
	}

	/**
		One transfer on one of the mod's ports, as SIO0 makes it: `send[0..length)` goes out — the
		address byte first (01h a controller, 41h the i-mode adaptor), then the command and its bytes —
		and as many come back into `reply`, one for each sent. False when nothing answered — no mouse
		on the host, a transfer the device does not take — and `reply` then reads FFh throughout.
	**/
	public static function exchange(port:Int, send:Array<Int>, length:Int, reply:Array<Int>):Bool {
		var answered = false;
		if (port >= 0 && port < portKinds.length) {
			final kind = portKinds[port];
			if (kind == PORT_MOUSE) answered = sio.SonyMouse.exchange(portUnits[port], send, length, reply);
			else if (kind == PORT_KEYBOARD) answered = sio.Ps2Keyboard.exchange(portUnits[port], send, length, reply);
			else answered = sio.IModeAdaptor.exchange(portUnits[port], send, length, reply);
		} else {
			for (i in 0...length) reply[i] = 0xFF;
		}
		return answered;
	}

	/** The display's size at the last vblank, in its pixels: what a mouse's motion is counted in. */
	public static inline function displayWidth():Int return kernel.KMouse.width;

	public static inline function displayHeight():Int return kernel.KMouse.height;

	static inline var PORT_MOUSE = 1;
	static inline var PORT_KEYBOARD = 2;
	static inline var PORT_IMODE = 3;
	static final portKinds:Array<Int> = [];
	static final portUnits:Array<Int> = [];

	static function addPort(kind:Int, unit:Int):Int {
		portKinds.push(kind);
		portUnits.push(unit);
		return portKinds.length - 1;
	}

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
