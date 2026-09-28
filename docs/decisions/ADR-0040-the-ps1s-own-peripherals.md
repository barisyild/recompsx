# ADR-0040: The PS1's own mouse, keyboard and internet — the Sony Mouse, the PS/2 keyboard adaptor, the i-mode adaptor
Status: accepted   Date: 2026-09-28
Direction set by the project owner: no custom mouse or keyboard API — the official devices instead,
our pointer still shown while the mouse is in use — and the internet through the original adaptor:
"the aim is to do it with the original standards". Supersedes the kernel services of ADR-0036
(keyboard) and ADR-0038 (mouse), whose backend ABIs stay, and ADR-0035's planned network service.

## Context

ADR-0036 and ADR-0038 gave mods services the PS1 never had — the host's keyboard as text, a
pointer over the picture — and ADR-0035 planned a network service in the kernel. The PS1 has its
own answer to each, documented by psx-spx ("Controllers and Memory Cards"):

- **The Sony Mouse (SCPH-1030)**: a controller-port device, ID 5A12h, two buttons and the motion
  since the last read; psx-spx lists some fifty games that read it through the ordinary pad calls.
- **No retail keyboard** — but one documented keyboard protocol: the one the Lightspan Online
  Connection CD (1997) reads, 01h 42h ... 06h answered with ID 96h, a count and up to eleven bytes
  of PS/2 Scan Code Set 2. Sony's own PS/2 keyboard/mouse adaptor, SCPH-2000 — a handful known,
  none of their owners knowing how to use it — "might work" with it, psx-spx says.
- **The i-mode adaptor (SCPH-10180)**: a cable from a controller port to an i-mode phone, the PS1's
  way onto the internet in Japan. The nocash edition of psx-spx documents it from Hamster Club-i and
  the CompactNetFront browser: address 41h, commands 11h..18h, a small stream of session messages
  (authentication, the gateway), a large one of packets carrying TLP messages, and HTTP/1.0 inside
  them, sent with an absolute URL for DoCoMo's i-mode centre to take out to the internet — what
  no$psx does with them today.

## Decision

The machine has these three devices, and a mod reaches them only as the machine would: on a
controller port of its own (`ModHost.plugMouse`, `plugKeyboard`, `plugIMode`) that the game never
sees, one transfer at a time (`ModHost.exchange`: the bytes out, as many back, as SIO0 moves them).
What the bytes mean is the documented protocol and nothing else. `ModHost.displayWidth`/`Height`
give the display's size, which is hardware state and what the mouse's motion is counted in. The
custom calls are gone: `enableMouse`, `mouseOver`/`X`/`Y`/`Held`/`Clicks`/`Moves`,
`pictureWidth`/`Height`, `textEntry`, `typed`.

**The devices** (`sio.SonyMouse`, `sio.Ps2Keyboard`, `sio.IModeAdaptor`) answer their transfers
byte for byte: Hi-Z under a controller's address, the ID, 5Ah, the data — or, for the adaptor, 00h
under 41h (a quirk of the real one), 5Ah and each command's documented reply, with the XOR
checksums of commands 14h and 15h, snippets of 58h bytes with a last-snippet bit, and the X.25 CRC
of every packet (`sio.IModeWire`). A mouse or keyboard **unit** is one reader's: two mods polling
the mouse never take motion or presses from each other.

**The host's side** is the kernel's, sampled at each vblank like the pads:

- `kernel.KMouse` keeps the host's pointer in the display's pixels and hands every mouse unit the
  motion from where that unit's reader is taken to be — the middle of the display at first, then the
  sum of what it reported, held inside the display — to where the host's pointer is, at most 7Fh a
  read. So a reader that keeps its cursor the way a PS1 mouse program does has it exactly where the
  host's pointer is, however often it reads; the relative device loses nothing of the absolute one.
  The left button is the mouse's left; the right one and the side buttons are its right, the button
  that goes back; a click shorter than a reader's frame is kept for its next read.
- **Our pointer is shown while the mouse is in use**: while something reads a Sony Mouse — a mod
  driving its game with the mouse does every frame — `bp_mouse_pointer` shows the machine's pointer
  (the art of `pointer_art.h`), hides it while a pad is in use (a pad button pressed; the mouse
  moving or clicking shows it again), and takes it away half a second after the reads stop. A game
  that reads the mouse through its own ports draws its own cursor: those reads are not these.
- `kernel.KKeyboard` makes the host's keyboard **type while a keyboard is read**: from the first
  read `bp_key_text` stops the keyboard pressing pad buttons (arrows apart), and what the host typed
  goes to the keyboard units as the key presses that type it **on a US keyboard** — left Shift
  around it when needed, its key down and up. The protocol is positional, and the host's layout has
  already made characters of its keys; sending the presses a US keyboard would need keeps every
  layout right — a Turkish Q keyboard's '.' included — for any reader that decodes US Set 2, which is
  what the Online Connection CD expects. What a US keyboard cannot type (ş, é) is not sent. When the
  reads stop, it plays the pad again.
- `kernel.KIMode` is **the phone and the i-mode centre**: it answers the session messages as the
  documented phone does (wake-up 38h,02h; AUTH_START_ACK, AUTH_CRYPT_ACK, DEAUTH_ACK, AUTH_PING_ACK;
  GW_CONNECT/DISCONNECT/PING_ACK), brings the transport up and down (01h,3Fh / 01h,73h; 01h,53h /
  01h,1Fh), and takes the TLP messages: TLP_CONNECT_REQ, TLP_DATA and TLP_DATA_EOF are one HTTP
  request, whose absolute URL (`GET http://host:port/path HTTP/1.0`) it makes origin-form with a
  `Host:` header and sends to the host's network (`bp_http_open`/`read`/`close`, new in the ABI);
  the response goes back raw as TLP_CONNECT_ACK and TLP_DATA of 1400 bytes and TLP_DATA_EOF, or a
  TLP_CONNECT_REJECT when it cannot be made; TLP_DISCONNECT_REQ ends it. What psx-spx leaves
  unknown it fills plainly: every key is accepted (there is no DoCoMo account), the length fields
  it sends are zero, the reject reasons are its own.

**The console's side of i-mode** is `mod.LibImode`, shaped after Sony's libimode as psx-spx
records it — the commands of `sceImode_Param` (RCV, SND, STS, ABORT, AUTH_START, AUTH_END,
GW_CONNECT, GW_DISCONNECT) and its states (DORMANT .. AUTH_ENDED) — one transfer a vblank, as the
PS1's software drove the cable.

**Crash Bash** reads the mouse in both mods and the keyboard in the address keyboard, from ports
of their own; DONE runs one i-mode session to the address typed on the game's port (9457):
`GET http://<address>:9457/SCUS94570 HTTP/1.0`, and any HTTP response means a server is there.

**Backends**: `bp_http_*` over non-blocking TCP on SDL2 (POSIX sockets, Winsock), over
KallistiOS's TCP on the Dreamcast (the network brought up at the first request, in a thread:
the broadband or LAN adaptor, DHCP), and as `fetch` in the page, the raw response rebuilt; none
on the null backend, JVM or Node.

## Alternatives

- **Keep the HLE services** — the owner chose the original devices.
- **Positional scancodes from the host's keys** — the host's layout would be lost, and the '.' of a
  Turkish Q keyboard would type '/' everywhere, as it did on Flycast.
- **The homebrew adaptors** (a mouse with keys in its spare bits, ID 12h; the Spectrum emulator's
  E8h) — not Sony's, and read by no licensed software.
- **A socket or WebSocket service** — not the PS1's, and a browser cannot open a raw socket; HTTP
  through the i-mode adaptor works on every target, the browser included.
- **Plugging the devices into the game's own ports** for the games written for them — the devices
  are ready for SIO0; a per-game setting will do it (not yet).

## Consequences

- Mods speak bytes; a mouse or keyboard program for the PS1 would read these devices unchanged.
- A browser reaches only servers that allow its origin (CORS), and an https page https servers
  only; the page sends its own User-Agent.
- The Dreamcast needs a broadband or LAN adaptor (Flycast: its BBA emulation) for the internet.
- Online is not deterministic and not digested; a headless run's phone finds no network.
- Verified: conformance `Mouse` `8d7276ce`, `Keyboard` `89f31197` and `IMode` `df5df22f` on
  JavaScript and reflaxe.CPP; `check.sh` (46 ABI functions); Crash Bash headless — ONLINE, the
  address typed on the PS1 keyboard, DONE, libimode from AUTH_STARTING to AUTH_ENDED, "connected
  to 127.0.0.1" against a canned answer; the SDL2 sockets and the page's `fetch` against a local
  server (the raw response back whole; a closed port failing); in the browser the whole path —
  the pointer shown over the menu, ONLINE clicked, the address typed (a stray letter neither
  typed nor pressed), Enter, "CONNECTED TO 127.0.0.1" with the server logging the request, and
  with the server stopped "NO ANSWER FROM 127.0.0.1"; the Dreamcast code compiles.
