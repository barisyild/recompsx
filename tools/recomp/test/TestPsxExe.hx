import haxe.io.Bytes;
import recomp.Vaddr;
import recomp.loader.PsxExe;

/**
	PS-EXE loader tests, built on synthetic headers so they commit no game data.

	The interesting cases are the rejections. A truncated dump, a misaligned load address or a
	bogus magic must fail *at load time* with a message naming the problem — otherwise the failure
	surfaces several passes later as a disassembly that walks off a cliff, and the person reading
	the error has no way back to the cause.
**/
class TestPsxExe {
	/** Builds a header with the fields a real one carries, plus a payload of `payloadWords`. */
	static function makeExe(?initialPc = 0x80010000, ?loadAddr = 0x80010000, ?payloadWords = 4,
			?declaredSize:Null<Int>, ?spBase = 0x801FFFF0, ?magic = "PS-X EXE"):Bytes {
		final payloadBytes = payloadWords * 4;
		final b = Bytes.alloc(PsxExe.HEADER_SIZE + payloadBytes);
		b.blit(0, Bytes.ofString(magic), 0, magic.length);
		b.setInt32(0x10, initialPc);
		b.setInt32(0x14, 0);                                   // gp
		b.setInt32(0x18, loadAddr);
		b.setInt32(0x1C, declaredSize != null ? declaredSize : payloadBytes);
		b.setInt32(0x30, spBase);
		b.setInt32(0x34, 0);
		final region = "Sony Computer Entertainment Inc. for North America area";
		b.blit(0x4C, Bytes.ofString(region), 0, region.length);
		// A recognisable payload: nop, addiu, jr ra, nop
		if (payloadWords > 0) b.setInt32(PsxExe.HEADER_SIZE + 0, 0x00000000);
		if (payloadWords > 1) b.setInt32(PsxExe.HEADER_SIZE + 4, 0x24420001);
		if (payloadWords > 2) b.setInt32(PsxExe.HEADER_SIZE + 8, 0x03E00008);
		if (payloadWords > 3) b.setInt32(PsxExe.HEADER_SIZE + 12, 0x00000000);
		return b;
	}

	public static function run():Void {
		Assert.group("psx-exe: a well-formed header");
		final exe = PsxExe.parse(makeExe());
		Assert.equals(exe.initialPc, 0x80010000, "entry point");
		Assert.equals(exe.loadAddr, 0x80010000, "load address");
		Assert.equals(exe.fileSize, 16, "payload size");
		Assert.equals(exe.loadEnd(), 0x8001000F, "end of the loaded range");
		Assert.equals(exe.initialSp(), 0x801FFFF0, "initial stack pointer");
		Assert.equals(exe.payload.length, 16, "payload length matches the header");
		Assert.isTrue(exe.regionMarker.indexOf("North America") >= 0, "region marker is read");
		Assert.equals(exe.readWord(0x80010008), 0x03E00008, "reading a word by address");
		Assert.isTrue(exe.containsAddr(0x80010000), "start is inside the image");
		Assert.isTrue(exe.containsAddr(0x8001000F), "last byte is inside the image");
		Assert.isTrue(!exe.containsAddr(0x80010010), "one past the end is outside");

		Assert.group("psx-exe: segments are equivalent");
		// The same physical memory through KUSEG, KSEG0 and KSEG1. Code that computes an address
		// in one segment and uses it in another is ordinary, not exotic.
		Assert.isTrue(exe.containsAddr(0xA0010000), "KSEG1 view of the load address");
		Assert.isTrue(exe.containsAddr(0x00010000), "KUSEG view of the load address");
		Assert.equals(exe.readWord(0xA0010008), 0x03E00008, "reading through KSEG1");
		Assert.equals(Vaddr.canonRam(0xA0010000), 0x80010000, "addresses canonicalise to KSEG0");
		Assert.equals(Vaddr.canonRam(0x00010000), 0x80010000, "KUSEG canonicalises too");
		// RAM mirrors: the 2 MB is visible four times in the 8 MB window.
		Assert.equals(Vaddr.canonRam(0x80210000), 0x80010000, "the RAM mirror folds");

		Assert.group("psx-exe: rejections name the problem");
		Assert.rejects(() -> PsxExe.parse(Bytes.alloc(16)), "too short",
			"a file shorter than the header");
		Assert.rejects(() -> PsxExe.parse(makeExe(0x80010000, 0x80010000, 4, null, 0x801FFFF0, "NOT-AN-EXE")),
			"not a PS-EXE", "wrong magic");
		Assert.rejects(() -> PsxExe.parse(makeExe(0x80010000, 0x80010000, 4, 0x10000)),
			"truncated", "a header claiming more payload than the file holds");
		Assert.rejects(() -> PsxExe.parse(makeExe(0x80010000, 0x80010002)),
			"not word-aligned", "a misaligned load address");
		Assert.rejects(() -> PsxExe.parse(makeExe(0x80010001)),
			"not word-aligned", "a misaligned entry point");
		Assert.rejects(() -> PsxExe.parse(makeExe(0x80010000, 0x80010000, 0, 0)),
			"empty payload", "a header claiming no payload");

		Assert.group("psx-exe: warnings for the suspicious but survivable");
		// Homebrew linkers routinely emit non-sector-aligned payloads; retail images never do.
		final homebrew = PsxExe.parse(makeExe());
		Assert.isTrue(homebrew.warnings.length > 0, "a 16-byte payload is flagged as unaligned");

		// An entry point outside the loaded image is legal but almost always a mistake.
		final strayEntry = PsxExe.parse(makeExe(0x80020000));
		var mentionsEntry = false;
		for (w in strayEntry.warnings) if (w.indexOf("entry point") >= 0) mentionsEntry = true;
		Assert.isTrue(mentionsEntry, "an entry point outside the image is flagged");

		Assert.group("psx-exe: the stack-pointer convention");
		// spBase == 0 means "keep the caller's stack", which the BIOS honours and homebrew uses.
		final keepStack = PsxExe.parse(makeExe(0x80010000, 0x80010000, 4, null, 0));
		Assert.equals(keepStack.initialSp(), 0, "spBase 0 leaves the stack alone");
	}
}
