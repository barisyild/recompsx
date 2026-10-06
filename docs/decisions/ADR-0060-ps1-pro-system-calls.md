# ADR-0060: PS1 Pro system calls — the kernel's own services, through `syscall`
Status: accepted   Date: 2026-10-05
Direction set by the project owner: the code that sets the resolution moves out of the game into
the HLE BIOS as a system call, so that future programs can build it into themselves and use it
("Çözünürlük set eden kodu oyundan ayırıp HLE Bios'a taşımak istiyorum bu bir sistem çağırısı
olacak ve gelecekte insanlar bu sistem çağrısını oyuna entegre edip kullanabilecekler").
Changes ADR-0056's interface: the resolution is the kernel's, reached by a program's own call.

## Context

ADR-0056 put the picture's resolution in the HLE kernel as a console setting (`kernel.KVideo`),
but reached it through host-side calls a mod makes (`ModHost.videoScale`, `setVideoScale`): the
Crash 3 mod owned the logic of choosing and applying, and no PlayStation program could ask for it.
The kernel already has three ways in for a program — the A0h/B0h/C0h function tables, `syscall`
and `break` — and the project's rule is that the machine's own mechanisms come first (ADR-0040).

A new service needs a number nothing else uses and a way for a program to know it is there,
since the same program may run on a console. psx-spx "BIOS Function Summary" settles both:

- An unused A/B/C function jumps to address 0 on a retail kernel (`A(B5h..BFh)`,
  `B(5Eh..FFh)`, `C(1Eh..7Fh)` "N/A ;jump_to_00000000h"; `B(100h....)` garbage): a program that
  calls one on a console crashes, and cannot test first.
- SYSCALL defines 00h-03h, and `SYS(04h..FFFFFFFFh) calls DeliverEvent(F0000010h,4000h)`.
  OpenBIOS's `handlers/syscall.c` (MIT) shows the rest: the default case delivers the event and
  returns from the exception, every register restored from the thread — `$v0` as the caller left it.

## Decision

- **The PS1 Pro calls are `syscall`s** with the function in `$a0`, 50524F00h + n ("PRO" in the top
  three bytes), arguments in `$a1`-`$a3`, the answer in `$v0`, every other register kept.
  `Kernel.syscall` sends that range to **`kernel.KPro`**; anything else in it is reported once and
  leaves `$v0`, as a retail kernel does.
- **Identify** (50524F00h) answers 50524F31h ("PRO1"). A program zeroes `$v0` and calls it: only
  here is the magic there. Elsewhere the call is a harmless event no one listens to.
- **The video family** (50524F1xh): GetVideoScale, SetVideoScale (`$a1` percent, held to 25..400,
  kept as the console's `video.scale` and handed to the backend), GetVideoLines (`$a1` percent, 0
  for now: the lines the display is drawn at on this console — what a menu calls the choice), and
  HoldPicture (50524F13h, `$a1` vblanks, held to 60; 0 shows the next picture at once): the picture
  on screen stays up while a program draws it anew, so its in-between frames are never seen — the
  scanout passes BP_PRESENT_HOLD, which a backend that can keep a picture honours (the browser
  skips the blit; the Dreamcast renders the records into its pictures and builds no screen scene).
  Presentation only: nothing emulated depends on it. All of the logic is the
  kernel's: the setting, the backend, what each backend can draw (BP_CAP_GPU_LINES).
- **Mods make the calls as a game would**: `ModHost.syscall(ctx)` runs the kernel's `syscall` with
  the guest's registers. ModHost's own video calls are gone; Crash 3's RES line Identifies once and
  then uses GetVideoLines, SetVideoScale and, while it has the game draw its pause picture anew,
  HoldPicture.
- **docs/specs/ps1pro.md** is the reference for programs: the table, a C wrapper (GCC inline
  `syscall`), the Psy-Q stub, an options line. Numbers are never reused or changed.

## Alternatives

- **A B0h function past the table** (B(60h..) for instance). The PlayStation's usual way into the
  kernel, but on a retail kernel it jumps to address 0, and there is no harmless way to ask first.
- **A signature in the BIOS ROM window** (a maker string at BFC00108h) for detection. Reading the
  ROM is harmless, but it says something about the machine every game can read, where Identify
  answers only a program that asks.
- **A new vector (D0h)**. Nothing in the PlayStation's calling convention; a program would jump
  into kernel RAM on a console.
- **Keeping the calls host-side for mods** (ADR-0056 as it was). No PlayStation program could
  reach them, and the logic stayed in each game's mod.

## Consequences

- A program built for recompsx runs unchanged on a console: Identify fails, the menu line is not
  offered, nothing else happens (the kernel delivers F0000010h/4000h; the HLE kernel does not deliver
  it for numbers outside the PS1 Pro range yet, and reports them, as before).
- Video numbers are fixed: 50524F10h-16h (14h-16h the screen's shape — GetWidescreen,
  SetWidescreen, SetWidePicture — ADR-0064). The family has room to 50524F1Fh; a new family takes
  the next 10h (settings, network) when one is wanted.
- Verified: conformance `ProCalls` (Identify, an unknown PS1 Pro number and a retail one leaving
  `$v0`, the scale set, held and read back, the lines, the registers kept) JS = C++; Crash 3's RES
  line through the calls on JavaScript headless (one value, 240P, where nothing scales) and in the
  browser.
