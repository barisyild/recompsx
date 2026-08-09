package mem;

import shim.RawBuf;
import shim.RawMem;

/**
	The character ROM's ASCII half, drawn for this emulator.

	A real machine's BIOS carries a font, and games use it two ways: through the kernel
	(`Krom2RawAdd`, for the full-width Shift-JIS set) and by reading the ROM window directly.
	Crash Bash's English text is the second kind — its renderer computes
	`0xBFC7F8DE + (char - 33) * 15` and reads fifteen bytes, one per row, eight pixels wide with
	the most significant bit leftmost. Those three numbers are the whole interface, and they were
	measured from the *game's own code* (the address arithmetic is right there in its
	disassembly), not from any ROM.

	The glyphs are ours. Golden rule 4 keeps a real BIOS out of this repository, and a bitmap
	derived from one would be the same thing with extra steps — so these were drawn for this
	project: a 5x7 design per character, stretched to seven ink columns and doubled vertically
	into the 8x15 cell games expect. They will not match Sony's pixel for pixel and are not
	supposed to, but the *metrics* have to be close, because a game lays text out by measuring
	each glyph's ink and advancing by it. The first draft was five columns wide against fourteen
	tall, and every line of Crash Bash's warning ended forty pixels early — which, with the line
	pinned at its left edge, reads as text shifted left rather than as text set too narrow.

	Only the printable ASCII range exists (33..126). The full-width Shift-JIS set a Japanese
	game would ask for is absent, and `Krom2RawAdd` still reports itself when called — a font
	someone actually needs is better added against a game that shows it.
**/
class RomFont {
	/** The first character with a glyph: '!' — space is nothing everywhere. */
	public static inline var FIRST = 33;

	public static inline var COUNT = 94;

	/** One byte per row, fifteen rows. */
	public static inline var BYTES_PER_GLYPH = 15;

	static var table:RawBuf;

	public static function init():Void {
		table = RawMem.alloc(COUNT * BYTES_PER_GLYPH);
		var i = 0;
		while (i < COUNT * BYTES_PER_GLYPH) {
			RawMem.set8(table, i, (nib(i * 2) << 4) | nib(i * 2 + 1));
			i++;
		}
	}

	/** A byte of the glyph table, by offset from the first row of the first glyph. */
	public static function byteAt(off:Int):Int {
		if (off < 0 || off >= COUNT * BYTES_PER_GLYPH) return 0;
		else {}
		return RawMem.get8(table, off);
	}

	static function nib(i:Int):Int {
		final c = HEX.charCodeAt(i);
		if (c == null) return 0;
		else {}
		if (c >= 48 && c <= 57) return c - 48;
		else {}
		if (c >= 65 && c <= 70) return c - 55;
		else {}
		return 0;
	}

	/** Thirty hex characters per glyph — one line per character, '!' through '~'. */
	static inline var HEX = ""
		+ "000808080808080808080800000808"   // !
		+ "003636363636360000000000000000"   // double quote
		+ "00363636367F7F36367F7F36363636"   // #
		+ "0008083F3F48483E3E09097E7E0808"   // $
		+ "00717176760606080830304E4E4747"   // %
		+ "003838464648483030494946463939"   // &
		+ "000808080830300000000000000000"   // '
		+ "000606080830303030303008080606"   // (
		+ "003030080806060606060608083030"   // )
		+ "000000080849493E3E494908080000"   // *
		+ "000000080808087F7F080808080000"   // +
		+ "000000000000000000383808083030"   // ,
		+ "000000000000007F7F000000000000"   // -
		+ "000000000000000000000038383838"   // .
		+ "000101060606060808303030304040"   // /
		+ "003E3E414147474949717141413E3E"   // 0
		+ "000808383808080808080808083E3E"   // 1
		+ "003E3E414101010E0E303040407F7F"   // 2
		+ "007F7F010106060E0E010141413E3E"   // 3
		+ "0006060E0E363646467F7F06060606"   // 4
		+ "007F7F40407E7E0101010141413E3E"   // 5
		+ "000E0E303040407E7E414141413E3E"   // 6
		+ "007F7F010106060808303030303030"   // 7
		+ "003E3E414141413E3E414141413E3E"   // 8
		+ "003E3E414141413F3F010106063838"   // 9
		+ "000000383838380000383838380000"   // :
		+ "000000383838380000383808083030"   // ;
		+ "000606080830304040303008080606"   // <
		+ "00000000007F7F00007F7F00000000"   // =
		+ "003030080806060101060608083030"   // >
		+ "003E3E414101010606080800000808"   // ?
		+ "003E3E41414F4F49494E4E40403F3F"   // @
		+ "003E3E414141417F7F414141414141"   // A
		+ "007E7E414141417E7E414141417E7E"   // B
		+ "003E3E414140404040404041413E3E"   // C
		+ "007E7E414141414141414141417E7E"   // D
		+ "007F7F404040407E7E404040407F7F"   // E
		+ "007F7F404040407E7E404040404040"   // F
		+ "003E3E414140404F4F414141413F3F"   // G
		+ "004141414141417F7F414141414141"   // H
		+ "003E3E080808080808080808083E3E"   // I
		+ "000F0F060606060606060646463838"   // J
		+ "004141464648487070484846464141"   // K
		+ "004040404040404040404040407F7F"   // L
		+ "004141777749494949414141414141"   // M
		+ "004141717149494747414141414141"   // N
		+ "003E3E414141414141414141413E3E"   // O
		+ "007E7E414141417E7E404040404040"   // P
		+ "003E3E414141414141494946463939"   // Q
		+ "007E7E414141417E7E484846464141"   // R
		+ "003F3F404040403E3E010101017E7E"   // S
		+ "007F7F080808080808080808080808"   // T
		+ "004141414141414141414141413E3E"   // U
		+ "004141414141414141414136360808"   // V
		+ "004141414141414949494977774141"   // W
		+ "004141414136360808363641414141"   // X
		+ "004141414136360808080808080808"   // Y
		+ "007F7F010106060808303040407F7F"   // Z
		+ "003E3E303030303030303030303E3E"   // [
		+ "004040303030300808060606060101"   // backslash
		+ "003E3E060606060606060606063E3E"   // ]
		+ "000808363641410000000000000000"   // ^
		+ "000000000000000000000000007F7F"   // _
		+ "003030080806060000000000000000"   // `
		+ "00000000003E3E01013F3F41413F3F"   // a
		+ "00404040407E7E4141414141417E7E"   // b
		+ "00000000003E3E4040404041413E3E"   // c
		+ "00010101013F3F4141414141413F3F"   // d
		+ "00000000003E3E41417F7F40403E3E"   // e
		+ "000E0E313130307878303030303030"   // f
		+ "0000003F3F414141413F3F01013E3E"   // g
		+ "00404040407E7E4141414141414141"   // h
		+ "000808000038380808080808083E3E"   // i
		+ "00060600000E0E0606060646463838"   // j
		+ "004040404046464848707048484646"   // k
		+ "003838080808080808080808083E3E"   // l
		+ "000000000076764949494949494949"   // m
		+ "00000000007E7E4141414141414141"   // n
		+ "00000000003E3E4141414141413E3E"   // o
		+ "0000007E7E414141417E7E40404040"   // p
		+ "0000003F3F414141413F3F01010101"   // q
		+ "00000000004E4E7171404040404040"   // r
		+ "00000000003F3F40403E3E01017E7E"   // s
		+ "003030303078783030303031310E0E"   // t
		+ "000000000041414141414147473939"   // u
		+ "000000000041414141414136360808"   // v
		+ "000000000041414141494949493636"   // w
		+ "000000000041413636080836364141"   // x
		+ "000000414141413F3F010141413E3E"   // y
		+ "00000000007F7F0606080830307F7F"   // z
		+ "000707080808083030080808080707"   // {
		+ "000808080808080808080808080808"   // |
		+ "007070080808080606080808087070"   // }
		+ "000000000030304949060600000000";  // ~
}
