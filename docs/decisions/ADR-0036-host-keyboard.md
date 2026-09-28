# ADR-0036: The host's keyboard as text — an HLE device the PS1 never had
Status: accepted; its kernel service superseded-by-0040   Date: 2026-09-28
Direction set by the project owner; the second "PS1 Pro" kernel feature after console settings
(ADR-0034), first used by Crash Bash's address keyboard (ADR-0033's `onlinemenu`).

**Since ADR-0040** the keyboard a mod reads is the machine's own — a PS/2 keyboard on a controller
port of the mod's, speaking the protocol of the Lightspan Online Connection CD (ID 96h, PS/2 Scan
Code Set 2) — and `ModHost.textEntry`/`typed` and the kernel's queue are gone. The backend ABI
below stays: the kernel turns text entry on while that keyboard is polled, and sends what was
typed on as the key presses that type it on a US keyboard.

## Context

The address keyboard for ONLINE is on-screen, driven by the pad, like the game's own ENTER NAME
screen. The owner's direction: add a physical keyboard to the HLE kernel, handled like the
controllers, working wherever the target machine has a keyboard; it types every character the
host's operating system can type, and a game ignores those it cannot show — on the address
screen, the digits and '.' are typed from the keyboard.

Two facts shaped it. The PS1 had no keyboard, so there is no hardware to emulate: this is a
kernel service, as settings are. And on the desktop and in the browser the keyboard already *is*
pad 0 (arrows, X S Z A, Enter as Start): typing `s` into a field would also press square, which
on the address keyboard deletes a character — the opposite of "ignored".

## Decision

The backend ABI gains a keyboard-as-text group: `bp_key_text(on)` starts or ends text entry,
`bp_key_next()` returns the next thing typed — a Unicode code point as the host's own layout and
input method made it, or `BP_KEY_BACKSPACE`/`ENTER`/`ESCAPE` — or -1. While text entry is on, a
backend's keyboard types rather than plays: of the keys it maps onto a pad only the arrows still
press, the desktop's Escape cancels instead of quitting, and a key held when entry ends becomes a
button only when pressed again. Nothing is queued while it is off.

The HLE kernel's `kernel.KKeyboard` drains it once per vblank, right after the pads are latched,
into a 64-entry queue, dropping anything that is not a character or one of the three keys, so
every reader gets clean input. Readers (mods, through `ModHost.textEntry`/`typed`) turn entry on
while a field is open and decide which characters their game can show. A headless digest run
never drains it, as it never samples the pads.

Backends: SDL2 decodes `SDL_TEXTINPUT`'s UTF-8 (and calls `SDL_Start/StopTextInput`); the browser
takes `KeyboardEvent.key` (one code point; AltGr still types, Ctrl/Meta shortcuts do not); the
Dreamcast pops a maple keyboard's KallistiOS queue untranslated and turns each key into a code
point by the keyboard's region (KallistiOS's maps, ISO-8859-1, which is Unicode's first 256 code
points), the keypad the same under every region; null, JVM and Node type nothing.

A Dreamcast keyboard's region is its layout, and the host of an emulator has its own: Flycast
passes the host's keys on by position and reports the host's layout only when it recognises it,
US otherwise — so on a Turkish Q keyboard the '.' key, where US has '/', types '/', and '.' is the
key where US has it (Turkish Q's Ç) or the keypad's. A setting naming the layout was built and
dropped the same day: the owner wants the automatic default, the keyboard's own region, and
nothing to configure.

## Alternatives

- **Keys as extra pad buttons** (digits mapped to buttons). Layout-blind, limited to what fits a
  pad, and cannot type what the player's language has (ş, é, @ behind AltGr).
- **Raw key codes, translated in the kernel.** Every layout, dead key and input method would
  have to be reimplemented in portable Haxe; the host has already done it, correctly.
- **A browser text field.** The owner ruled out anything HTML-specific: online and its UI live in
  the HLE and reach the consoles.
- **Always queuing, no text-entry mode.** Typing would still press buttons wherever the keyboard
  is a pad, and a field would have to guess which of its inputs were letters.

## Consequences

- The ABI grows by two functions; `scripts/check.sh` holds every backend to it (39 functions).
- Typed input is host input: like buttons, it reaches emulated state only through a vblank latch,
  and never in a digest run.
- Input methods that compose outside a focused text field (CJK IMEs in a browser) are not
  reached by keydown events; a browser backend that wants them needs a hidden editable element.
  Latin layouts, dead keys and AltGr work.
- A field that holds the keyboard for a long time must mind the game's own idle logic: Crash
  Bash counts frames without *pad* input (80051604h) and plays its demo past 900 of them, so its
  address keyboard holds that count at zero while it is open.
- Verified: conformance `Keyboard` (queue, filtering, text entry) digests identically on JS and
  reflaxe.CPP; the SDL2 and Dreamcast input code compile clean; in the browser, typing an address
  among unsupported letters took the digits and '.' only, and Backspace deleted.
