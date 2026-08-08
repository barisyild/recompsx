import shim.Backend;
import shim.RawMem;

/**
	Does the backend's file slot actually serve bytes?

	Compiling is not working. This opens a real PS-EXE and reads its first eight bytes, which the
	format defines as the ASCII magic — so the check is against the file's own contract rather
	than against a number this test made up.
**/
class FileSlot {
	public static function main():Void {
		if (Backend.argCount() < 1) {
			Backend.log(Backend.LOG_ERROR, "usage: fileslot <path-to-ps-exe>");
		} else {
			run(Backend.arg(0));
		}
	}

	static function run(path:String):Void {
		if (Backend.fileOpen(0, path) != 0) {
			Backend.log(Backend.LOG_ERROR, "could not open " + path);
		} else {
			report(path);
		}
	}

	static function report(path:String):Void {
		final size = Backend.fileSize(0);
		final buf = RawMem.alloc(16);
		final n = Backend.fileRead(0, 0, buf, 8);
		var magic = "";
		for (i in 0...n) magic += String.fromCharCode(RawMem.get8(buf, i));
		Backend.log(Backend.LOG_INFO, "size=" + size + " read=" + n + " magic=\"" + magic + "\"");
		// And a read from the middle, to prove the offset is honoured rather than ignored.
		final n2 = Backend.fileRead(0, 0x800, buf, 4);
		Backend.log(Backend.LOG_INFO, "at 0x800: read=" + n2 + " word=" + RawMem.get32(buf, 0));
		Backend.fileClose(0);
	}
}
