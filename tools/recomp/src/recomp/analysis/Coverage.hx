package recomp.analysis;

import recomp.Vaddr;
import recomp.mips.Decoder;
import recomp.mips.Disasm;
import recomp.analysis.Confidence;
import recomp.analysis.Func;
import recomp.analysis.Image;
import recomp.analysis.Kind;

/**
	The coverage report: what analysis found, and more usefully, what it did not.

	This is the instrument the whole bring-up runs on. Recompiling a game is not a single
	operation that succeeds or fails; it is a conversation in which the tool says which parts of
	the program it could not reach and a person decides which of those matter. So the report is
	ordered by what deserves attention — the largest unreached regions first, the unresolved
	computed jumps that will need hints, the functions nothing calls — rather than by address.

	A number worth internalising: 100% is not the target and not achievable. Data lives in the
	text segment, libraries contain unused functions, and code reached only through function
	pointers is invisible to static analysis by definition. What matters is that every remaining
	gap has an explanation.
**/
class Coverage {
	final image:Image;
	final discovery:Discovery;

	public function new(image:Image, discovery:Discovery) {
		this.image = image;
		this.discovery = discovery;
	}

	public function render(?maxGaps = 15):String {
		final out = new StringBuf();
		final tally = image.tally();
		final totalWords = image.size >> 2;

		final code = tally[Kind.Code];
		final data = tally[Kind.DataInText];
		final padding = tally[Kind.Padding];
		final unknown = tally[Kind.Unknown];

		out.add('coverage: ${image.name}\n');
		out.add('  image            ${Vaddr.hex(image.baseAddr)}..${Vaddr.hex(image.endAddr() - 1)}'
			+ '  (${image.size} bytes)\n');
		out.add('  code             ${pct(code, totalWords)}  ${code * 4} bytes\n');
		out.add('  data in text     ${pct(data, totalWords)}  ${data * 4} bytes\n');
		out.add('  padding          ${pct(padding, totalWords)}  ${padding * 4} bytes\n');
		out.add('  unreached        ${pct(unknown, totalWords)}  ${unknown * 4} bytes\n');

		// Where the code ends. A PS-EXE holds code and initialised data in one blob, so the
		// single most useful thing to know about a coverage number is whether the unreached part
		// is spread through the code or sitting past the end of it. The latter is the data
		// segment and is not a gap at all.
		var lastCode = image.baseAddr;
		var a = image.baseAddr;
		while (a < image.endAddr()) {
			if (image.kindAt(a) == Kind.Code) lastCode = a;
			a += 4;
		}
		final tailWords = (image.endAddr() - lastCode - 4) >> 2;
		var unreachedBeforeTail = 0;
		a = image.baseAddr;
		while (a <= lastCode) {
			if (image.kindAt(a) == Kind.Unknown) unreachedBeforeTail++;
			a += 4;
		}
		out.add('  last code at     ${Vaddr.hex(lastCode)}\n');
		out.add('    beyond it      ${tailWords * 4} bytes  (the data segment; not a gap)\n');
		out.add('    within it      ${unreachedBeforeTail * 4} bytes unreached'
			+ '  = ${pct(unreachedBeforeTail, (lastCode - image.baseAddr) >> 2)} of the code region\n');

		// Functions, split by how much we trust each one.
		var byEntry = 0, byCall = 0, bySymbol = 0, bySweep = 0;
		var totalInstrs = 0;
		var largest:Func = null;
		for (fn in discovery.functions) {
			switch (fn.confidence) {
				case Entry: byEntry++;
				case Called: byCall++;
				case Symbol: bySymbol++;
				case Swept: bySweep++;
			}
			totalInstrs += fn.instructionCount();
			if (largest == null || fn.sizeBytes() > largest.sizeBytes()) largest = fn;
		}
		final total = byEntry + byCall + bySymbol + bySweep;
		out.add('\n  functions        $total  ($totalInstrs instructions)\n');
		out.add('    from entry points or hints   $byEntry\n');
		out.add('    reached by a call            $byCall\n');
		if (bySymbol > 0) out.add('    named in syms.txt            $bySymbol\n');
		out.add('    guessed by prologue sweep    $bySweep\n');
		if (largest != null) {
			out.add('    largest: ${largest.name} at ${Vaddr.hex(largest.entry)}, '
				+ '${largest.sizeBytes()} bytes\n');
		}

		// Indirect calls and computed jumps: not failures, but the list of things that will
		// dispatch at run time, and the places where a hint would help.
		var unresolvedJumps = 0;
		final jumpSites = [];
		for (fn in discovery.functions) {
			for (a in fn.unresolvedJumps) {
				unresolvedJumps++;
				if (jumpSites.length < 10) jumpSites.push({fn: fn, addr: a});
			}
		}
		out.add('\n  indirect calls (jalr)          ${discovery.indirectCalls.length}\n');
		out.add('  computed jumps (jr, not ra)    $unresolvedJumps\n');
		if (jumpSites.length > 0) {
			out.add('    each is a switch or a call through a register; the runtime dispatches\n');
			out.add('    them by address. A jumpTableHint in game.json resolves one statically.\n');
			for (s in jumpSites) {
				out.add('      ${Vaddr.hex(s.addr)}  in ${s.fn.name}\n');
			}
			if (unresolvedJumps > jumpSites.length) {
				out.add('      ... and ${unresolvedJumps - jumpSites.length} more\n');
			}
		}

		// The unreached regions, largest first. This is the working list.
		final gaps = image.unknownRuns(1);
		if (gaps.length > 0) {
			var gapWords = 0;
			for (g in gaps) gapWords += g.words;
			out.add('\n  unreached regions              ${gaps.length}  (${gapWords * 4} bytes)\n');
			final shown = gaps.length < maxGaps ? gaps.length : maxGaps;
			for (i in 0...shown) {
				final g = gaps[i];
				out.add('    ${Vaddr.hex(g.addr)}  ${rightPad(g.words * 4 + " bytes", 12)}'
					+ '  ${firstWords(g.addr, g.words)}\n');
			}
			if (gaps.length > shown) out.add('    ... and ${gaps.length - shown} smaller\n');
		}

		// Anything a function itself complained about.
		final fnWarnings = [];
		for (fn in discovery.functions) {
			for (w in fn.warnings) fnWarnings.push('${fn.name}: $w');
		}
		if (fnWarnings.length > 0) {
			out.add('\n  warnings                       ${fnWarnings.length}\n');
			final shown = fnWarnings.length < 10 ? fnWarnings.length : 10;
			for (i in 0...shown) out.add('    ${fnWarnings[i]}\n');
			if (fnWarnings.length > shown) {
				out.add('    ... and ${fnWarnings.length - shown} more\n');
			}
		}

		return out.toString();
	}

	/**
		A peek at what a gap contains, which is usually enough to classify it at a glance:
		printable text is a string table, small ascending numbers are a jump table, and something
		that disassembles cleanly is code the closure could not reach.
	**/
	function firstWords(addr:Int, words:Int):String {
		final w0 = image.readWord(addr);

		// Does it look like text?
		var printable = 0;
		for (shift in [0, 8, 16, 24]) {
			final c = (w0 >>> shift) & 0xFF;
			if (c >= 0x20 && c <= 0x7E) printable++;
		}
		if (printable == 4) {
			return 'text? "' + ascii(w0) + '"';
		}

		// Does it look like a table of addresses into this image?
		if (words >= 2) {
			final w1 = image.readWord(addr + 4);
			if (image.contains(w0) && image.contains(w1) && (w0 & 3) == 0 && (w1 & 3) == 0) {
				return 'pointers? ${Vaddr.hex(w0)} ${Vaddr.hex(w1)}';
			}
		}

		// Otherwise show it as an instruction; if it reads as something sensible, it is a
		// candidate for a missing seed.
		final i = Decoder.decode(addr, w0);
		return 'first word ${Vaddr.hex(w0)}  (' + Disasm.text(i) + ')';
	}

	static function ascii(w:Int):String {
		var s = "";
		for (shift in [0, 8, 16, 24]) {
			final c = (w >>> shift) & 0xFF;
			s += (c >= 0x20 && c <= 0x7E) ? String.fromCharCode(c) : ".";
		}
		return s;
	}

	static function pct(part:Int, whole:Int):String {
		if (whole == 0) return "  0.0%";
		final tenths = Math.round(part * 1000.0 / whole);
		final s = (tenths / 10) + "";
		final withPoint = s.indexOf(".") >= 0 ? s : s + ".0";
		return leftPad(withPoint + "%", 6);
	}

	static function leftPad(s:String, n:Int):String {
		var out = s;
		while (out.length < n) out = " " + out;
		return out;
	}

	static function rightPad(s:String, n:Int):String {
		var out = s;
		while (out.length < n) out += " ";
		return out;
	}
}
