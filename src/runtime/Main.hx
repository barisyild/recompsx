import core.Hash;
import gpu.Vram;
import shim.Backend;

/**
	Entry point for the native build.

	Right now this is the walking skeleton for M0.5/M0.6: it proves that a Haxe program compiled
	through reflaxe.CPP can drive the C backend, put pixels on screen, and produce a bit-identical
	digest run after run. The emulator proper grows into this loop — the frame body becomes
	"run recompiled code until the next vertical blank" and everything around it stays.

	Note there is no `Sys.args()`: the generated `_main_.cpp` discards argv, so we supply our own
	`main` and read arguments back through the backend (see docs/specs/backend.md §1.1).
**/
class Main {
	// NTSC-ish frame budget in microseconds. The real value will come from the emulated clock;
	// this is only the pacing target for the skeleton.
	static inline var FRAME_US = 16683;

	static inline var DISPLAY_W = 320;
	static inline var DISPLAY_H = 240;

	public static function main():Void {
		var headlessFrames = 0;

		// No loop, no nesting, no ternary. reflaxe.CPP silently deletes `if` statements inside
		// `while` loops in several common shapes (upstream defect 8 in PROGRESS.md), so the
		// skeleton avoids the construct entirely rather than relying on a workaround that the next
		// version might invalidate. Real argument handling waits for a trustworthy code path.
		final argc = Backend.argCount();
		if (argc >= 2) {
			final flag = Backend.arg(0);
			if (flag == "--headless-hash") headlessFrames = parseInt(Backend.arg(1));
		}

		// if/else, never a guard clause. reflaxe.CPP deletes `if (c) { ...; return; }` outright
		// and lets the wrong path run — see upstream defect 8 in PROGRESS.md. This is the single
		// most dangerous defect found so far: no error, no crash, just different behaviour.
		if (headlessFrames > 0) runHeadless(headlessFrames);
		else runWindowed();
	}

	static function runWindowed():Void {
		if (Backend.init("recompsx") != 0) {
			Backend.log(Backend.LOG_ERROR, "backend init failed");
		} else {
			runWindowedLoop();
		}
	}

	static function runWindowedLoop():Void {
		Vram.init();
		Backend.log(Backend.LOG_INFO, "recompsx skeleton: escape or window close to quit");

		Backend.paceFrame(0);   // establish the pacing reference

		var frame = 0;
		while (!Backend.quitRequested()) {
			Backend.inputPoll();
			Vram.testPattern(DISPLAY_W, DISPLAY_H, frame);
			Backend.present(Vram.data, 0, 0, DISPLAY_W, DISPLAY_H, 0);
			Backend.paceFrame(FRAME_US);
			frame++;
		}

		Backend.log(Backend.LOG_INFO, "frames presented: " + frame);
		Backend.shutdown();
	}

	/**
		The determinism gate. No window, no pacing, no host input: run a fixed number of frames
		and fold each one into a running digest. Two runs must print the same final value, and
		later the JVM build must print it too — that is the whole cross-platform promise reduced
		to one comparable number.
	**/
	static function runHeadless(frames:Int):Void {
		Vram.init();

		var digest = Hash.FNV_OFFSET;
		var frame = 0;
		while (frame < frames) {
			Vram.testPattern(DISPLAY_W, DISPLAY_H, frame);
			digest = Hash.rect(digest, Vram.data, Vram.WIDTH, 0, 0, DISPLAY_W, DISPLAY_H);
			frame++;
		}

		// Printed in a fixed, greppable shape so scripts and PROGRESS.md entries can quote it.
		Backend.log(Backend.LOG_INFO, "frames=" + frames + " digest=" + Hash.hex(digest));
	}

	/** Small non-negative integer parser. `Std.parseInt` pulls in machinery the runtime has no
	    reason to carry, and argument parsing is the only place we need this. */
	static function parseInt(s:String):Int {
		var v = 0;
		var i = 0;
		while (i < s.length) {
			final c = s.charCodeAt(i);
			if (c == null || c < 48 || c > 57) return v;
			v = v * 10 + (c - 48);
			i++;
		}
		return v;
	}
}
