# ADR-0052: The DualShock — analog sticks and vibration on every backend
Status: accepted   Date: 2026-10-04
Direction set by the project owner: "DC analog stick, vibration — add both to every backend."
Extends ADR-0042 (the multitap): analog pads in its slots, and rumble to a slot addressed directly.

## Context

The backend ABI has had `bp_pad_type` (none, digital, analog) and `bp_pad_axis` (four sticks,
0..255) since version 1, and the desktop and Dreamcast backends read sticks. The machine never used
them: SIO0 had only digital pads (SCPH-1080), and the Dreamcast reported its pads digital on purpose.
Nothing carried vibration. Crash Bandicoot: Warped and Crash Bash both support the DualShock
(SCPH-1200): two sticks and two motors.

The DualShock's protocol is in nocash's psx-spx ("Controllers - Standard Digital/Analog
Controllers", "- Configuration Commands", "- Vibration/Rumble Control"). In short:

- It powers on in digital mode. It then answers a read (01h 42h) as a digital pad does, ID 5A41h and
  two bytes of buttons, with L3 and R3 not reported. Its ANALOG button switches analog mode on:
  ID 5A73h and nine bytes, the buttons followed by the sticks RX RY LX LY.
- Command 43h with 01h in its fourth byte enters configuration mode: ID 5AF3h, nine bytes for every
  command. There 44h sets the mode and can lock it against the button; 45h, 46h, 47h, 48h and 4Ch
  answer the pad's constants; 4Dh says which bytes of a read drive which motor, answering with the
  mapping it replaces.
- Back in normal mode, the mapped bytes of a read drive the motors: the small (right) motor on bit 0
  of its byte, the large (left) one at its byte's speed. A pad never configured has the old method:
  the small motor runs while the fourth byte is 40h..7Fh and the fifth is odd.

## Decision

**The machine has DualShocks** (`sio.DualShock`), byte for byte as psx-spx describes them. A host
pad with sticks (`bp_pad_type` BP_PAD_ANALOG) is a DualShock; any other pad that is connected (a
keyboard alone, an arcade stick) is a digital pad, unchanged. A pad that appears, or changes kind,
is a controller just plugged in, in its power-on state. It powers on in digital mode, as the real
one does. Each byte is answered from the pad's state before that byte, and a transfer keeps the form
its command byte found. In normal mode it takes 42h and 43h only, in configuration mode 40h-4Fh; any
other command gets the ID (already on the wire) and no acknowledge, so the transfer ends there.
psx-spx lists only 42h and 43h for normal mode; ending the transfer is what DuckStation's analog
controller does with the rest (stenzek/duckstation, src/core/analog_controller.cpp, read
2026-10-04 for behaviour only), though it sends FFh for the ID.

Port 2, the multitap's slots addressed directly (02h-04h) and slot A through the tap reach the
DualShock in full. **In the tap's long read each slot's eight bytes are a transfer of its own**: the
host's bytes in that window (a command, its TAP byte, six more) go to the slot's controller after
the address the tap gives it, and its answers come back in the *next* long read (amended
2026-10-05, ADR-0042's amendment). libpad's multitap code configures DualShocks and drives their
motors this way: Crash Bash sends 43h 00h 01h to slot A and 42h to slots B-D inside long reads.
ADR-0042 did not model these bytes, which a digital pad ignores. DuckStation forwards them the same
way, returns each slot's answers one long read later, from a buffer, and has no garbage alternation
(src/core/multitap.cpp). This ADR first kept psx-spx's table and answered at once, which carried
Crash Bash's menus but not its Adventure hub ("CONTROLLER 1-A IS UNPLUGGED"); the hardware answers a
read later (BlueRetro's logs), and so does the tap now, with psx-spx's garbage alternation kept. The
garbage read's last byte is slot A's ID. The BIOS's pad handler (`kernel.KPads`) writes what the
DualShock answers a read with.

**Two additions to the ABI**:

- `BP_PAD_ANALOG_BUTTON`, bit 16 of `bp_pad_buttons`, is the DualShock's ANALOG button. The pad keeps
  it to itself: a press toggles analog mode unless the game has locked the mode. As on the pad, a
  press also leaves configuration mode and stops and unmaps the motors.
- `bp_pad_rumble(pad, small, large)` gives the motors as the game drives them: small 0/1, large
  0..255. Large is already 0 where the real motor would not turn: it starts from rest at about 50h
  and keeps turning down to about 38h (psx-spx). The runtime calls it right after `bp_input_poll`,
  once a vblank, when they change. It is output only, like audio.

**Each backend**:

| backend | sticks | ANALOG | motors |
|---|---|---|---|
| Dreamcast | the maple pad's stick, a second stick where the pad has one | Start + full right trigger (Start + full left is Select); Z is R3 | a Puru Puru pack in the pad's slot: one motor, continuous effects of the stronger of the two, sent on change, stopped before the BIOS menu |
| SDL2 | `SDL_GameController` both sticks | the centre (Guide) button | `SDL_GameControllerRumble`: large on the low-frequency motor, small on the high one, 500 ms effects renewed every 250 ms |
| browser | Gamepad API axes 0-3 (standard mapping) | button 16, the centre button | `vibrationActuator` "dual-rumble", 500 ms renewed every 4 polls; `hapticActuators` pulse where that is all there is |
| null, JVM, Node | none | — | ignored |

**Determinism is unchanged.** A headless run has no pads. A scripted pad (`--pad-script`) is a
digital pad unless `--pad-dualshock` asks for a DualShock. Its entries may then give the sticks
(`F:BUTTONS/LX.LY.RX.RY`, hex) and press ANALOG. `--log-rumble` logs the motors as they change.

**Not modelled** (psx-spx): the watchdog that resets a pad left unread for a second after
configuration mode; the 00h a configured pad sends in place of 5Ah once the player has pressed
ANALOG; and the longer digital read a motor mapped past the fifth byte makes.

## Alternatives

- **Power on in analog mode.** Rejected. A game that knows only digital pads refuses ID 5A73h, which
  is why the real pad starts digital and has a button. A game that wants analog switches the pad
  itself; Crash 3 does, at vblank 275.
- **A DualShock for every pad, the keyboard's too.** Rejected. Without sticks or motors it would be
  a digital pad that games can switch into a mode with nothing in it.
- **Report the motors every vblank.** Rejected. A browser effect or a maple frame per vblank is
  traffic for nothing. Hosts whose effects expire renew them from `bp_input_poll`.
- **Model the watchdog and the 00h quirk.** Deferred. Nothing observed depends on them, and the
  watchdog would reset pads during long loads that the BIOS's own handler keeps reading.

## Consequences

- Conformance `DualShockSio` (new, `0def6b4f` on JS and reflaxe.CPP) covers digital mode, the old
  rumble, ANALOG, every configuration command, the mapping, the lock, the motor thresholds, port 2,
  the tap's long and garbage reads, the BIOS handler and replugging. `PadSio 47a7a665`,
  `MultitapSio 644b488d`, `PadBios 42a146e6` and `Mouse 8d7276ce` are unchanged, and so is the whole
  JS suite. Crash 3's headless digest at 5000 is still `47853ef7`.
- **Crash 3 (libpad)** detects the DualShock (43h, 45h, 4Ch, 47h, 46h), switches it to analog itself
  (44h 01h 00h, vblank 275) and maps the motors (4Dh 00h 01h FFh...). Its stick drives Crash. In the
  warp room, run 15300 with the left stick up walks him forward as the d-pad does, and stick right
  runs him to the right. Rumble: with the game's rumble timers (80068E98h + 1F0h/1F4h) written in the
  warp room, the game's own motor bytes reach the pad and `bp_pad_rumble` reports small 1, large C0h
  at vblank 15106.
- **Crash 3 reads a DualShock only every fourth vblank.** Its pad routine (80015798h) calls
  `PadSetActAlign` on every frame on which `PadGetState` is stable (80015864h). libpad accepts the
  request whenever it is idle (8004B190h: state FFh), so it repeats 43h 01h, 4Dh, 43h 00h without end.
  One transfer goes to a port each vblank, so a read comes every fourth one. libpad keeps the last
  read in the game's buffer meanwhile. Buttons and sticks arrive 0-3 vblanks late, sampled at 15 Hz;
  with a digital pad they came every vblank. By the code this happens on a PS1 as well. The owner
  noticed it in play ("jumps less") and chose the PS1's behaviour over a mod that skips the repeat:
  compatibility in general, not a game's own fix.
- **Crash Bash (libpad, multitap)** finds the DualShock through slot A (43h 01h, 45h, 4Ch, 47h),
  configures it inside long reads, and takes its input there. With a scripted DualShock it reaches
  Select Game Type as the digital pad does, START pressed through the tap. In the menus it keeps
  sending 45h in normal mode every third long read; it does this whether the pad answers it, refuses
  it, or answers a read later. It sets neither analog mode nor the motors there.
- The Dreamcast keeps its Select gesture and gains ANALOG on the other trigger. A pad without a
  stick stays digital. The Puru Puru mapping (power 1-7, frequency 26 for the large motor and 50 for
  the small one) is a first guess for the hardware tester.
