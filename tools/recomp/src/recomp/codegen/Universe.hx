package recomp.codegen;

import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.config.GameConfig.OverlayConfig;

/**
	One view of the machine's memory, analysed on its own.

	The executable is a universe. Each overlay is another: the executable with that overlay's bytes
	laid over its window, because while the overlay is resident that is what the memory holds. They
	are analysed separately and emitted together, and a handle in the finished program names a
	function in exactly one of them.

	The name comes from the master plan §6.2, which described this shape before anything
	implemented it.
**/
class Universe {
	/** Null for the executable; the overlay's config otherwise. */
	public final overlay:OverlayConfig;

	public final image:Image;
	public final discovery:Discovery;

	/** The overlay's own bytes, for fingerprinting. Null for the executable. */
	public final bytes:Bytes;

	/** Filled in by `Program`, which decides the program-wide shard numbering. */
	public var shards:Shards;
	public var emitter:Emitter;

	public function new(overlay:OverlayConfig, image:Image, discovery:Discovery, bytes:Bytes) {
		this.overlay = overlay;
		this.image = image;
		this.discovery = discovery;
		this.bytes = bytes;
	}

	public inline function isBase():Bool return overlay == null;

	public inline function id():String return overlay == null ? "base" : overlay.id;

	/** Whether an address falls in this universe's window. The executable has no window. */
	public function contains(addr:Int):Bool {
		if (overlay == null) return false;
		final a = Vaddr.canonRam(addr);
		return a >= overlay.loadAddr && a < overlay.endAddr();
	}

	/**
		The prefix its shard classes are named with.

		`Ovl_<id>_…` rather than a package, because reflaxe.CPP flattens a package into the
		generated header's name and every extra level is another way for two generated files to
		collide with each other or with a system header (`scripts/check.sh` guards the latter).
		A prefix on a top-level name has neither problem.
	**/
	public function classPrefix():String {
		return overlay == null ? "Fns" : "Ovl_" + sanitize(overlay.id);
	}

	/** An id is a human's slug; a class name is an identifier. */
	static function sanitize(id:String):String {
		var out = "";
		for (i in 0...id.length) {
			final c = id.charAt(i);
			final ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9");
			out += ok ? c : "_";
		}
		return out;
	}

	/**
		FNV-1a over the first `hashWords` words of the overlay's bytes.

		This is how the runtime recognises which overlay is sitting in a window. The first words of
		an overlay are its own code, which differs between overlays built from the same libraries
		far more reliably than anything later in the image does — and the tool checks at generation
		time that no two fingerprints collide, so a game whose overlays start alike says so at
		build time rather than misdispatching at run time.
	**/
	public function fingerprint():Int {
		var n = overlay.hashWords * 4;
		if (n > bytes.length) n = bytes.length;
		var h = 0x811C9DC5;
		for (i in 0...n) {
			h = (h ^ bytes.get(i)) | 0;
			// The FNV prime, 16777619, written as the shifts it is made of. A multiply that wide
			// loses low bits wherever Int is a double, and this number has to come out the same
			// here and in `kernel.OverlayMgr`, which computes it over emulated RAM — the two are
			// deliberately the same seven lines.
			h = (h + ((h << 1) | 0) + ((h << 4) | 0) + ((h << 7) | 0) + ((h << 8) | 0)
				+ ((h << 24) | 0)) | 0;
		}
		return h;
	}
}
