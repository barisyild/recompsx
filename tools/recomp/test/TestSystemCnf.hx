import recomp.loader.SystemCnf;

/**
	SYSTEM.CNF parsing: how a disc names its executable, and the product code that names its
	directory under `games/`. The first two cases are the two discs this project brings up,
	verbatim, trailing tab included.
**/
class TestSystemCnf {
	public static function run():Void {
		Assert.group("system.cnf: the boot path");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:\\SCUS_942.44;1\r\nTCB = 4\r\nEVENT = 16\r\nSTACK = 801FFFF0"),
			"\\SCUS_942.44;1", "Crash Bandicoot: Warped");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:\\SCUS_945.70;1\t\r\nTCB = 4\r\nEVENT = 16\r\nSTACK = 801FFF00\r\n"),
			"\\SCUS_945.70;1", "Crash Bash: the tab after the path is not part of it");
		Assert.equals(SystemCnf.bootPath("TCB=4\nBOOT=cdrom:\\SLUS_012.34;1\n"), "\\SLUS_012.34;1",
			"no spaces, LF endings, not the first line");
		Assert.equals(SystemCnf.bootPath("boot = cdrom:\\slus_012.34;1"), "\\slus_012.34;1",
			"a lower-case key");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:\\GAME\\SLPS_000.01;1 arg"), "\\GAME\\SLPS_000.01;1",
			"a subdirectory, and an argument after the path");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom0:/SCES_123.45"), "\\SCES_123.45",
			"another device name, a forward slash, no version");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:SLUS_000.02;1"), "\\SLUS_000.02;1",
			"no slash after the device");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:\\\\SLUS_000.03;1"), "\\SLUS_000.03;1",
			"a doubled backslash");
		Assert.equals(SystemCnf.bootPath("BOOTX = cdrom:\\A.EXE;1\nTCB = 4"), null, "a key that only starts with BOOT");
		Assert.equals(SystemCnf.bootPath("TCB = 4\nEVENT = 16"), null, "no BOOT line");
		Assert.equals(SystemCnf.bootPath("BOOT = cdrom:"), null, "a BOOT line naming nothing");

		Assert.group("system.cnf: the product code");
		Assert.equals(SystemCnf.serialOf("\\SCUS_945.70;1"), "SCUS94570", "Crash Bash");
		Assert.equals(SystemCnf.serialOf("\\SCUS_942.44;1"), "SCUS94244", "Crash Bandicoot: Warped");
		Assert.equals(SystemCnf.serialOf("\\slus_012.34;1"), "SLUS01234", "upper-cased");
		Assert.equals(SystemCnf.serialOf("\\GAME\\SLPS_000.01;1"), "SLPS00001", "from the last component");
		Assert.equals(SystemCnf.serialOf("\\SCES_123.45"), "SCES12345", "without a version");
		Assert.equals(SystemCnf.serialOf("\\PSX.EXE;1"), null, "a homebrew name is not a code");
		Assert.equals(SystemCnf.serialOf("\\SPYRO3\\SPYRO3.EXE;1"), null, "nor is a demo's");
		Assert.equals(SystemCnf.serialOf("\\SCUS_9457.0;1"), "SCUS94570",
			"punctuation dropped wherever it falls");
		Assert.equals(SystemCnf.serialOf("\\SCU_945.701;1"), null, "three letters and six digits is not one");
		Assert.isTrue(SystemCnf.isSerial("SCUS94570"), "SCUS94570 is the directory form");
		Assert.isTrue(!SystemCnf.isSerial("SCUS-94570"), "the printed form with a dash is not");
		Assert.isTrue(!SystemCnf.isSerial("scus94570"), "nor is lower case");
	}
}
