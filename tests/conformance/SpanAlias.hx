import mem.Memory;

/** Checked-view alias exclusions use physical arena positions, including RAM mirrors.
    Explicit reference positions below are independent of spanIndex and host pointers. */
class SpanAlias {
	public static function main():Void {
		Memory.init();
		final addresses = [0x80040020,0xa0040020,0x00240020,0x80040024,0x80040018,
			0x1f800020,0x9f800020,0x1f800024];
		final positions = [0x40020,0x40020,0x40020,0x40024,0x40018,0x2000c0,0x2000c0,0x2000c4];
		for (i in 0...addresses.length) for (j in 0...addresses.length) {
			final a = Memory.span(addresses[i],-8,15); final b = Memory.span(addresses[j],-8,15);
			Conf.expect('valid first alias view',Memory.spanOk(a)?1:0,1);
			Conf.expect('valid second alias view',Memory.spanOk(b)?1:0,1);
			for (ao in [-4,0,3,7]) for (bo in [-4,0,3,7]) for (aw in [1,2,4,8,9]) for (bw in [1,2,4,8,9]) {
				final start = positions[i]+ao; final other = positions[j]+bo;
				final expected = start+aw<=other || other+bw<=start;
				Conf.expect('physical byte-range exclusion',Memory.spansDisjoint(a,ao,aw,b,bo,bw)?1:0,expected?1:0);
				Conf.expect('symmetric byte-range exclusion',Memory.spansDisjoint(b,bo,bw,a,ao,aw)?1:0,expected?1:0);
			}
		}
		Conf.report('SpanAlias');
	}
}
