package kernel;

import core.CpuState;
import mem.Memory;
import sio.MemoryCard;

/**
	The `bu` device: files on the memory cards, as the kernel's file calls reach them — `bu00:` is
	slot 1 and `bu10:` slot 2. open (with create and asynchronous modes), read, write, close,
	lseek, and B(41h) format, B(42h) firstfile, B(43h) nextfile, B(44h) rename and B(45h) erase.
	`KFiles` owns the descriptors and hands a `bu` one over here.

	Adapted from OpenBIOS `openbios/card/device.c` (MIT License, Copyright (c) 2021 PCSX-Redux
	authors) and the device-independent halves of `openbios/fileio/stdio.c`, `misc.c` and
	`filesystem.c` (MIT License, Copyright (c) 2020-2021 PCSX-Redux authors), pcsx-redux/nugget,
	on top of `KCard`'s backup unit, and keeping what a game can see of the BIOS's behaviour: a
	synchronous open re-reads frame 0, and a card changed since reloads the whole directory; a
	file is created first-fit, its size fixed at creation, its directory entries written back
	middle-first and head last; an erase only changes the states, so the names stay; lseek from
	the end does nothing; firstfile's '*' matches anything after it and '?' one character — or
	the end of a name. Where OpenBIOS copies a retail slip that corrupts memory (a create whose
	directory write fails spins for ever; a find pattern written one byte past its buffer) this
	does the sane thing instead, and where psx-spx and OpenBIOS disagree psx-spx wins: reads and
	writes must be whole frames, and a frame run is cut at the end of its block.
**/
class KBu {
	// Errors, psx-spx "BIOS File Functions" and OpenBIOS psxlibc/stdio.h.
	static inline var ENOERR = 0x00;
	static inline var ENOENT = 0x02;
	public static inline var EBADF = 0x09;
	static inline var EBUSY = 0x10;
	static inline var EEXIST = 0x11;
	static inline var EXDEV = 0x12;
	static inline var ENODEV = 0x13;
	static inline var EINVAL = 0x16;
	static inline var EMFILE = 0x18;
	static inline var ENOSPC = 0x1C;

	// Open modes.
	static inline var CREATE = 0x0200;
	static inline var ASYNC = 0x8000;

	static inline var MAX_FD = 16;

	// A descriptor's state, OpenBIOS `struct File`.
	static var mode:Array<Int>;
	static var deviceId:Array<Int>;
	static var offset:Array<Int>;
	static var length:Array<Int>;
	/** The file's first block, as its directory index (0..14). */
	static var first:Array<Int>;
	static var error:Array<Int>;

	/** C(1Ah) set_card_find_mode: 0 finds files, 1 finds deleted ones. Every open, erase and
	    rename sets it back to 0, as the BIOS's do. */
	public static var findMode = 0;

	// firstfile/nextfile: the slot searched, the pattern, where the last match was. A lookup by
	// name uses the name as given, and a name longer than 20 characters then matches nothing on
	// the card, whose names are cut at 20 — a retail quirk kept.
	static inline var PATTERN = 64;
	static var searchId = -1;
	static var pattern:Array<Int>;
	static var nextIndex = -1;
	/** The error of the last failed operation on a device, OpenBIOS `s_buOpError`. */
	static var opError:Array<Int>;
	/** The error the last firstfile, erase, rename or format left, as the temporary FCB holds it. */
	static var scratchError = 0;

	public static function init():Void {
		mode = [for (_ in 0...MAX_FD) 0];
		deviceId = [for (_ in 0...MAX_FD) 0];
		offset = [for (_ in 0...MAX_FD) 0];
		length = [for (_ in 0...MAX_FD) 0];
		first = [for (_ in 0...MAX_FD) 0];
		error = [for (_ in 0...MAX_FD) 0];
		findMode = 0;
		searchId = -1;
		pattern = [for (_ in 0...PATTERN) 0];
		nextIndex = -1;
		opError = [0, 0];
		scratchError = 0;
	}

	// ---- what KCard asks of a descriptor --------------------------------------------------------------

	public static inline function advance(fd:Int, by:Int):Void offset[fd] = (offset[fd] + by) | 0;

	public static inline function firstBlock(fd:Int):Int return first[fd];

	/** B(55h) _get_error(fd): the descriptor's own error. */
	public static inline function errorOf(fd:Int):Int return error[fd];

	// ---- open and close ------------------------------------------------------------------------------

	/**
		OpenBIOS `dev_bu_open`, for the descriptor `KFiles` allocated: the name looked up — '?'
		matching any character — or, with 200h in the mode, a file of `mode >> 16` blocks created
		under it. True when the file is open; else the descriptor's error says why.
	**/
	public static function open(ctx:CpuState, fd:Int, id:Int, nameAt:Int, openMode:Int):Bool {
		mode[fd] = openMode;
		deviceId[fd] = id;
		offset[fd] = 0;
		error[fd] = EBUSY;
		final port = KCard.portOf(id);
		if (KCard.buOperation[port] != KCard.BU_IDLE) return false;
		else {}
		KCard.resetStatus(ctx);
		if ((openMode & ASYNC) == 0 && !devInit(ctx, id)) return false;
		else {}
		findMode = 0;
		setPattern(nameAt, false);
		var index = nextMatch(port, 0);
		if ((openMode & CREATE) != 0) {
			if (index != -1) {
				error[fd] = EEXIST;
				return false;
			} else {}
			index = create(ctx, fd, id, nameAt, (openMode >>> 16) & 0xFFFF);
			if (index < 0) return false;
			else {}
		} else if (index == -1) {
			error[fd] = ENOENT;
			return false;
		} else {}
		first[fd] = index;
		offset[fd] = 0;
		error[fd] = ENOERR;
		length[fd] = KCard.sizeAt(port * 15 + index);
		return true;
	}

	/**
		A new file of `blocks` blocks: the first free entries in directory order, the head 51h with
		the size and the name, the ones after it 52h and the last 53h, each linked to the next; then
		the directory written back. Its index, or -1 with the descriptor's error set.
	**/
	static function create(ctx:CpuState, fd:Int, id:Int, nameAt:Int, blocks:Int):Int {
		final port = KCard.portOf(id);
		final base = port * 15;
		var available = 0;
		for (i in 0...15) {
			if ((KCard.stateAt(base + i) & 0xF0) == MemoryCard.FREE) available++;
			else {}
		}
		length[fd] = blocks << 13;
		if (blocks > available) {
			error[fd] = ENOSPC;
			return -1;
		} else {}
		final marks = [for (_ in 0...15) 0];
		var head = -1;
		var prev = -1;
		var count = 0;
		var index = 0;
		while (index < 15 && (count == 0 || count < blocks)) {
			final e = base + index;
			if ((KCard.stateAt(e) & 0xF0) == MemoryCard.FREE) {
				if (count == 0) {
					KCard.setState(e, MemoryCard.FIRST);
					KCard.setSize(e, length[fd]);
					copyName(e, nameAt, 20);
					marks[index] = MemoryCard.FIRST;
					head = index;
				} else {
					KCard.setNext(base + prev, index);
					KCard.setState(e, MemoryCard.MIDDLE);
					marks[index] = MemoryCard.MIDDLE;
				}
				prev = index;
				count++;
			} else {}
			index++;
		}
		// A file of 0 blocks still takes one, sized 0 — the BIOS's loop allocates before it counts.
		if (head < 0) {
			error[fd] = ENOSPC;
			return -1;
		} else {}
		KCard.setNext(base + prev, -1);
		if (count > 1) KCard.setState(base + prev, MemoryCard.LAST);
		else {}
		if (KCard.writeToc(ctx, id, marks)) {
			for (i in 0...15) {
				if (marks[i] != 0) freeEntry(base + i);
				else {}
			}
			error[fd] = EBUSY;
			return -1;
		} else {}
		return head;
	}

	/**
		OpenBIOS `buDevInit`: frame 0 read — which a card changed since the directory was last read
		refuses as "new card", and that reloads the whole directory (`KCard.buInit`).
	**/
	static function devInit(ctx:CpuState, id:Int):Bool {
		final port = KCard.portOf(id);
		if (KCard.queue(id, 0, KCard.OP_READ, 0, true) == 0) {
			KCard.forget(port);
			return false;
		} else {}
		final status = KCard.waitIndex(ctx);
		var ok = false;
		if (status != 0) ok = status == 3 && KCard.buInit(ctx, id) != 0;
		else if (bufferByte(port, 0) == 0x4D && bufferByte(port, 1) == 0x43) ok = true;
		else ok = autoFormat(ctx, id);
		return ok;
	}

	static function autoFormat(ctx:CpuState, id:Int):Bool {
		return KCard.formatsBlankCards() && KCard.format(ctx, id) != 0;
	}

	/** OpenBIOS `dev_bu_close`: refused while an asynchronous transfer is running. */
	public static function close(ctx:CpuState, fd:Int):Bool {
		final port = KCard.portOf(deviceId[fd]);
		var ok = false;
		if (KCard.buOperation[port] == KCard.BU_IDLE) {
			KCard.resetStatus(ctx);
			ok = true;
		} else {}
		return ok;
	}

	/** lseek, as the BIOS's generic one: from the start or from here; from the end it does nothing. */
	public static function lseek(fd:Int, by:Int, whence:Int):Int {
		var result = 0;
		if (whence == 0) {
			offset[fd] = by;
			result = offset[fd];
		} else if (whence == 1) {
			offset[fd] = (offset[fd] + by) | 0;
			result = offset[fd];
		} else if (whence == 2) {
			result = offset[fd];
		} else {
			error[fd] = EINVAL;
			Kernel.lastError = EINVAL;
			result = -1;
		}
		return result;
	}

	// ---- read and write ---------------------------------------------------------------------------

	/** OpenBIOS `dev_bu_read`: -1, a negative error, or the bytes read (0 when asynchronous). */
	public static function read(ctx:CpuState, fd:Int, buf:Int, size:Int):Int {
		return transfer(ctx, fd, buf, size, false);
	}

	/** OpenBIOS `dev_bu_write`. */
	public static function write(ctx:CpuState, fd:Int, buf:Int, size:Int):Int {
		return transfer(ctx, fd, buf, size, true);
	}

	static function transfer(ctx:CpuState, fd:Int, buf:Int, size:Int, write:Bool):Int {
		final id = deviceId[fd];
		final port = KCard.portOf(id);
		if (KCard.buOperation[port] != KCard.BU_IDLE) return -1;
		else {}
		KCard.resetStatus(ctx);
		final at = offset[fd];
		if ((at & 0x7F) != 0 || at < 0 || at >= length[fd] || (size & 0x7F) != 0) {
			error[fd] = EINVAL;
			return -1;
		} else {}
		final start = at >> 7;
		final count = (size < 0 ? (size + 0x7F) | 0 : size) >> 7;
		var result = 0;
		if ((mode[fd] & ASYNC) != 0) {
			error[fd] = EBUSY;
			if (KCard.startTransfer(ctx, fd, id, write, start, count, buf)) {
				error[fd] = ENOERR;
				result = 0;
			} else result = -1;
		} else result = synchronous(ctx, fd, buf, size, write, start, count);
		return result;
	}

	/**
		A synchronous transfer, a block's worth of frames at a time — the frames left in the block
		the run starts in, where OpenBIOS's transcription counts 80h minus the frame — each frame
		waited for, and a write's run confirmed with a probe.
	**/
	static function synchronous(ctx:CpuState, fd:Int, buf:Int, size:Int, write:Bool, start:Int, count:Int):Int {
		final id = deviceId[fd];
		final port = KCard.portOf(id);
		var rel = start;
		var left = count;
		var done = 0;
		var at = buf;
		var going = true;
		while (going && left > 0) {
			final limit = 0x40 - (rel & 0x3F);
			final n = left > limit ? limit : left;
			final ok = run(ctx, id, port, fd, rel, n, at, write);
			left -= n;
			if (ok) {
				rel += n;
				at = (at + (n << 7)) | 0;
				done += n;
			} else going = false;
		}
		final bytes = done << 7;
		offset[fd] = (offset[fd] + bytes) | 0;
		error[fd] = ENOERR;
		KCard.buOperation[port] = KCard.BU_IDLE;
		return size != bytes ? -opError[port] : size;
	}

	/** OpenBIOS `buReadBuffer`/`buWriteBuffer`: `n` frames of one block, from the file's `rel`th. */
	static function run(ctx:CpuState, id:Int, port:Int, fd:Int, rel:Int, n:Int, buf:Int, write:Bool):Bool {
		var ok = true;
		for (i in 0...n) {
			if (ok) {
				final sec = KCard.fileSector(port, first[fd], rel + i);
				if (KCard.queue(id, sec, write ? KCard.OP_WRITE : KCard.OP_READ, (buf + (i << 7)) | 0, false) == 0) ok = false;
				else {
					final status = KCard.waitIndex(ctx);
					if (status != 0) {
						opError[port] = status;
						ok = false;
					} else {}
				}
			} else {}
		}
		if (ok && write) {
			if (KCard.cardInfo(id) == 0) ok = false;
			else {
				final status = KCard.waitIndex(ctx);
				if (status != 0) {
					opError[port] = status;
					ok = false;
				} else {}
			}
		} else {}
		return ok;
	}

	// ---- the rest of the device ---------------------------------------------------------------------

	/**
		B(45h) erase(name): the file's entries marked deleted — A1h, A2h, A3h — with names, sizes
		and links kept, and written back. 1, or 0 with the error in _get_errno.
	**/
	public static function erase(ctx:CpuState, id:Int, nameAt:Int):Int {
		scratchError = EBUSY;
		final port = KCard.portOf(id);
		final base = port * 15;
		if (KCard.buOperation[port] != KCard.BU_IDLE) return failed(scratchError);
		else {}
		KCard.resetStatus(ctx);
		if (!devInit(ctx, id)) return failed(scratchError);
		else {}
		findMode = 0;
		setPattern(nameAt, false);
		final index = nextMatch(port, 0);
		if (index == -1) return failed(ENOENT);
		else {}
		final marks = [for (_ in 0...15) 0];
		KCard.setState(base + index, 0xA1);
		marks[index] = MemoryCard.FIRST;
		var count = blocksOf(base + index) - 1;
		var next = KCard.nextOf(base + index);
		if (count > 0 && next >= 0 && next < 15) {
			var walking = true;
			while (walking && KCard.nextOf(base + next) != -1 && KCard.stateAt(base + next) == MemoryCard.MIDDLE) {
				final block = next;
				next = KCard.nextOf(base + next);
				KCard.setState(base + block, 0xA2);
				count--;
				marks[block] = MemoryCard.MIDDLE;
				walking = count >= 1 && next >= 0 && next < 15;
			}
		} else {}
		if (count > 0 && next >= 0 && next < 15) {
			if (KCard.nextOf(base + next) == -1 && KCard.stateAt(base + next) == MemoryCard.LAST) {
				KCard.setState(base + next, 0xA3);
				marks[next] = MemoryCard.MIDDLE;
			} else {}
		} else {}
		if (KCard.writeToc(ctx, id, marks)) {
			for (i in 0...15) {
				if (marks[i] != 0) freeEntry(base + i);
				else {}
			}
			return failed(EBUSY);
		} else {}
		scratchError = ENOERR;
		return 1;
	}

	/** B(44h) rename(old, new): the head entry's name, written back. 1, or 0. */
	public static function rename(ctx:CpuState, id:Int, oldAt:Int, newId:Int, newAt:Int):Int {
		scratchError = EBUSY;
		final port = KCard.portOf(id);
		if (id != newId) return failed(EXDEV);
		else {}
		if (KCard.buOperation[port] != KCard.BU_IDLE) return failed(scratchError);
		else {}
		KCard.resetStatus(ctx);
		if (!devInit(ctx, id)) return failed(scratchError);
		else {}
		findMode = 0;
		setPattern(newAt, false);
		if (nextMatch(port, 0) != -1) return failed(EEXIST);
		else {}
		setPattern(oldAt, false);
		final index = nextMatch(port, 0);
		if (index == -1) return failed(ENOENT);
		else {}
		final e = port * 15 + index;
		final marks = [for (_ in 0...15) 0];
		copyName(e, newAt, 21);
		marks[index] = MemoryCard.FIRST;
		if (KCard.writeToc(ctx, id, marks)) {
			copyName(e, oldAt, 21);
			return failed(EBUSY);
		} else {}
		scratchError = ENOERR;
		return 1;
	}

	/** B(41h) format("bu00:"): a blank card written frame by frame. 1, or 0. */
	public static function format(ctx:CpuState, id:Int):Int {
		final port = KCard.portOf(id);
		if (KCard.buOperation[port] != KCard.BU_IDLE) return failed(EBUSY);
		else {}
		KCard.resetStatus(ctx);
		if (KCard.format(ctx, id) == 0) return failed(EBUSY);
		else {}
		scratchError = ENOERR;
		return 1;
	}

	/**
		B(42h) firstfile(name, direntry): the directory re-read, and the first file matching `name`
		— '?' any one character, '*' anything after it, "" every file — into the 28h-byte
		DIRENTRY at `entryAt`. The entry's address, or 0.
	**/
	public static function firstFile(ctx:CpuState, id:Int, nameAt:Int, entryAt:Int):Int {
		scratchError = EBUSY;
		searchId = id;
		final port = KCard.portOf(id);
		if (KCard.buOperation[port] != KCard.BU_IDLE) return 0;
		else {}
		KCard.resetStatus(ctx);
		if (!devInit(ctx, id)) return 0;
		else {}
		setPattern(nameAt, true);
		nextIndex = -1;
		return nextFile(ctx, entryAt);
	}

	/** Whether the last firstfile was on a card, so nextfile is ours. */
	public static inline function searching():Bool return searchId >= 0;

	/**
		B(43h) nextfile(direntry): the next match — attribute (the state's high nibble), size,
		first sector and name, the name last, so a 20-character one's terminator lands on the
		attribute's low byte as the BIOS's does. The entry's address, or 0.
	**/
	public static function nextFile(ctx:CpuState, entryAt:Int):Int {
		final port = KCard.portOf(searchId);
		if (KCard.buOperation[port] != KCard.BU_IDLE) {
			scratchError = EBUSY;
			return 0;
		} else {}
		KCard.resetStatus(ctx);
		final index = nextMatch(port, nextIndex + 1);
		if (index == -1) {
			scratchError = ENOENT;
			return 0;
		} else {}
		final e = port * 15 + index;
		Memory.write32((entryAt + 0x14) | 0, KCard.stateAt(e) & 0xF0);
		Memory.write32((entryAt + 0x20) | 0, (index + 1) * 0x40);
		Memory.write32((entryAt + 0x18) | 0, KCard.sizeAt(e));
		var i = 0;
		var c = 1;
		while (c != 0 && i < 22) {
			c = KCard.nameByte(e, i);
			Memory.write8((entryAt + i) | 0, c);
			i++;
		}
		scratchError = ENOERR;
		return entryAt;
	}

	/** What erase, rename, format and firstfile left in their FCB, for _get_errno after them. */
	public static inline function lastScratchError():Int return scratchError;

	// ---- names ------------------------------------------------------------------------------------

	/**
		The pattern a lookup matches against: the name as given for open, erase and rename; for
		firstfile, the name up to a '*' and '?' after it to 20 characters, or 19 '?' for "".
	**/
	static function setPattern(nameAt:Int, expand:Bool):Void {
		for (i in 0...PATTERN) pattern[i] = 0;
		final empty = Memory.read8u(nameAt) == 0;
		final limit = expand ? 20 : PATTERN - 1;
		if (expand && empty) {
			for (i in 0...19) pattern[i] = 0x3F;
		} else {
			var i = 0;
			var c = Memory.read8u(nameAt);
			while (c != 0 && !(expand && c == 0x2A) && i < limit) {
				pattern[i] = c;
				i++;
				c = Memory.read8u((nameAt + i) | 0);
			}
			if (expand && c == 0x2A) {
				while (i < 20) {
					pattern[i] = 0x3F;
					i++;
				}
			} else {}
		}
	}

	/**
		OpenBIOS `buNextFileInternal`: the first entry from `from` in use (51h, or deleted A1h in
		find mode 1) with a name that matches the pattern. Remembered for nextfile, as the BIOS
		remembers every search's.
	**/
	static function nextMatch(port:Int, from:Int):Int {
		var found = -1;
		var index = from < 0 ? 0 : from;
		while (found < 0 && index < 15) {
			final e = port * 15 + index;
			final state = KCard.stateAt(e);
			final listed = findMode == 0 ? state == MemoryCard.FIRST : state == 0xA1;
			if (listed && KCard.nameByte(e, 0) != 0 && matches(e)) found = index;
			else {}
			index++;
		}
		if (found >= 0) nextIndex = found;
		else {}
		return found;
	}

	/** OpenBIOS `patternMatch`: '?' matches any character, and — past the name — its end. */
	static function matches(e:Int):Bool {
		var i = 0;
		var ok = true;
		var c = KCard.nameByte(e, 0);
		while (ok && c != 0) {
			final p = pattern[i];
			if (p != 0x3F && p != c) ok = false;
			else {}
			i++;
			c = i < 22 ? KCard.nameByte(e, i) : 0;
		}
		if (ok && pattern[i] != 0 && pattern[i] != 0x3F) ok = false;
		else {}
		return ok;
	}

	/** A name from guest memory into an entry: up to `limit` characters, NUL-padded as strncpy
	    pads (`limit` 20, create) or NUL-terminated as strcpy ends (21, rename). */
	static function copyName(e:Int, nameAt:Int, limit:Int):Void {
		var i = 0;
		var c = Memory.read8u(nameAt);
		while (i < limit) {
			KCard.setNameByte(e, i, c);
			i++;
			if (c != 0) c = Memory.read8u((nameAt + i) | 0);
			else {}
		}
		if (limit > 20) KCard.setNameByte(e, 21, 0);
		else {}
	}

	static function freeEntry(e:Int):Void {
		KCard.setSize(e, 0);
		KCard.setNext(e, -1);
		KCard.setState(e, MemoryCard.FREE);
	}

	static function blocksOf(e:Int):Int {
		var size = KCard.sizeAt(e);
		if (size < 0) size = (size + 0x1FFF) | 0;
		else {}
		return size >> 13;
	}

	static inline function bufferByte(port:Int, i:Int):Int return shim.RawMem.get8(KCard.buffers, (port << 7) + i);

	static function failed(code:Int):Int {
		scratchError = code;
		Kernel.lastError = code;
		return 0;
	}

}
