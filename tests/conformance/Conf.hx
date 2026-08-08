/**
	Shared machinery for cross-target conformance tests.

	A conformance test is one file in this directory: a class with a `main` that feeds values
	into the digest and calls `Conf.report`. `scripts/conformance.sh` finds it, builds it for
	every target the project supports, runs it, and requires every target to print the same
	digest. Adding a test is dropping in a file — that is deliberate, because a discipline that
	costs effort per test does not survive contact with a deadline.

	Why a digest rather than assertions: an assertion tells you a value is wrong on the target you
	ran. A digest compared across targets tells you the targets *disagree*, which is the failure
	this project actually fears — the one where each target looks individually plausible and the
	emulator quietly behaves differently on someone else's machine. Assertions are still welcome
	inside a test for things with a known-correct answer; the digest catches the rest.

	Written in the portable subset: whatever a conformance test is allowed to do, generated game
	code is allowed to do, so the tests exercise the same language surface the emulator uses.
**/
class Conf {
	static inline var FNV_OFFSET = 0x811C9DC5;
	static inline var FNV_PRIME = 16777619;

	static var digest = FNV_OFFSET;
	static var count = 0;
	static var failures = 0;

	/** Folds a 32-bit value in, byte by byte, least significant first. */
	public static function feed(v:Int):Void {
		var h = digest;
		h = shim.IntMath.mul(h ^ (v & 0xFF), FNV_PRIME);
		h = shim.IntMath.mul(h ^ ((v >>> 8) & 0xFF), FNV_PRIME);
		h = shim.IntMath.mul(h ^ ((v >>> 16) & 0xFF), FNV_PRIME);
		digest = shim.IntMath.mul(h ^ ((v >>> 24) & 0xFF), FNV_PRIME);
		count++;
	}

	/** Folds in a string, so a test cannot accidentally match another's digest. */
	public static function feedName(s:String):Void {
		var i = 0;
		while (i < s.length) {
			final c = s.charCodeAt(i);
			feed(c == null ? 0 : c);
			i++;
		}
	}

	/** For values with a known-correct answer. Failures are reported and also perturb the digest,
	    so a target that fails an assertion cannot coincidentally match one that passed. */
	public static function expect(label:String, actual:Int, expected:Int):Void {
		feed(actual);
		// The `else {}` is not decoration. reflaxe.CPP deletes an `if` that has no `else` and
		// more than one statement in its body — this very function was silently compiled to
		// `feed(actual);` alone, which made every assertion pass on that target while failing on
		// the other. See PROGRESS.md upstream defect 8.
		if (actual != expected) {
			failures++;
			feedName("FAIL:" + label);
			shim.Backend.log(shim.Backend.LOG_ERROR,
				"  " + label + " = " + actual + ", expected " + expected);
		} else {}
	}

	/** Prints the line `scripts/conformance.sh` parses. */
	public static function report(name:String):Void {
		final status = failures == 0 ? "ok" : (failures + " failed");
		shim.Backend.log(shim.Backend.LOG_INFO,
			name + " values=" + count + " " + status + " digest=" + hex(digest));
	}

	public static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return out;
	}
}
