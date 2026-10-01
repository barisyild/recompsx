import core.CpuState;
import core.Runtime;
import mem.Memory;

/**
	An `lwr`/`lwl` pair fused into one read (`Memory.lwu`, the recompiler's PatternMatcher) against
	the two run one after the other, as the guest wrote them.

	Every alignment, both orders, and every place the fused read must give up its RAM path and run
	the pair as it is: the scratchpad, a pair whose two words straddle the end of a RAM mirror, the
	last word of RAM. The register's old value is a pattern in every lane, so a lane the fused
	read failed to replace shows. The digest covers each answer; a few are asserted outright.
**/
class Unaligned {
	static var ctx:CpuState;
	static var seed = 0x2545F491;

	static function next():Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return seed;
	}

	public static function main():Void {
		Conf.feedName("Unaligned");
		ctx = new CpuState();
		Runtime.boot(ctx);

		// Bytes everywhere the pairs below read: low RAM, the top of RAM, the scratchpad.
		var a = 0x10000;
		while (a < 0x10400) {
			Memory.write32(a, next());
			a += 4;
		}
		a = 0x1FFC00;
		while (a < 0x200000) {
			Memory.write32(a, next());
			a += 4;
		}
		a = 0x1F800000;
		while (a < 0x1F800400) {
			Memory.write32(a, next());
			a += 4;
		}

		final bases = [0x10000, 0x10100, 0x801001F0, 0xA0010200, 0x1FFFF0, 0x801FFFF8, 0x1F800000, 0x1F8003F0];
		var mismatches = 0;
		for (base in bases) {
			for (k in 0...12) {
				final aR = (base + k) & 0x1FFFFFFF;
				final aL = (base + k + 3) & 0x1FFFFFFF;
				for (order in 0...2) {
					final current = 0x5A3C96E1 ^ (k << 8) ^ order;
					final pair = order == 0 ? Memory.lwl(aL, Memory.lwr(aR, current))
						: Memory.lwr(aR, Memory.lwl(aL, current));
					final fused = Memory.lwu(aR, aL, current, order == 0, ctx, ctx.cycles);
					Conf.feed(fused);
					if (fused != pair) mismatches++;
					else {}
				}
			}
		}
		Conf.expect("fused pair reads as the pair does", mismatches, 0);

		// The aligned case is one word, the same one twice.
		Memory.write32(0x10200, 0x11223344);
		Conf.expect("aligned pair", Memory.lwu(0x10200, 0x10203, 0, true, ctx, ctx.cycles), 0x11223344);
		Memory.write32(0x10204, 0x55667788);
		Conf.expect("pair at +1", Memory.lwu(0x10201, 0x10204, 0, false, ctx, ctx.cycles), 0x88112233);
		Conf.report("Unaligned");
	}
}
