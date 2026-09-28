# ADR-0035: Online play is built per game — never netplay
Status: accepted   Date: 2026-09-28
Direction set by the project owner; builds on ADR-0033 (mods) and ADR-0034 (console settings, the
first of the HLE kernel's "PS1 Pro" features). The network is the PS1's own since ADR-0040: the
i-mode adaptor, its phone and centre played by the kernel, HTTP out to the host's network.

## Context

A recompiled game can be taught to play online, and the familiar way emulators do it is netplay:
every player runs the same emulated machine and only controller input crosses the network, in
lockstep or with rollback. This project is deliberately built on the opposite. Netplay's costs are
the ones this project exists to avoid:

- **Every player must run the identical machine**, bit for bit, from the same starting state —
  the same build, the same disc, the same settings — or the sessions desynchronise. Consoles,
  browsers and desktops at different speeds cannot share a session that waits for the slowest.
- **Input delay or rollback**: lockstep adds latency to every frame; rollback re-simulates frames,
  which a console with no headroom (the Dreamcast runs Crash Bash below full speed) cannot afford.
- **All-or-nothing sessions**: no joining a game in progress, no leaving it without stopping it,
  no server that owns the game's truth, no matchmaking beyond "start together".
- **The game never knows it is online**: there is nothing to design, only a cable emulated
  across the internet.

## Decision

Online play is an implementation **per game**, written for that game the way a port would add it:

- **A game-level protocol, not controller input.** Each game's online mod (ADR-0033) exchanges
  what the game means — players, positions, events, scores, the choices a lobby makes — and
  applies it to the game through hooks and state, as a port's netcode would. A remote player is a
  participant the local game hears about, not a second controller wired into a shared emulation.
- **A lobby per game**, in the game's own UI (its menus, its fonts — as the ONLINE entry and
  address keyboard in Crash Bash's Select Game Type already are), deciding who plays what before a
  match starts.
- **One network for every target: the PS1's own** (ADR-0040). A game's mod goes online through
  the i-mode adaptor (SCPH-10180) on a port of its own, as Japanese PS1 games did; the phone and
  the i-mode centre behind it are the HLE kernel's ("PS1 Pro", ADR-0034), and take its HTTP
  requests to the host's network behind the backend ABI (`bp_http_*`) — so the same game code and
  the same protocol run on consoles, in the browser and on the desktop, and cross-play is the
  default, not a feature.
- **A port per game, never typed.** A player enters only an address; the connection goes to the
  game's own port, a constant of its protocol kept in its mod (Crash Bash: 9457,
  `onlinemenu.Online.PORT`). Two games never answer each other by accident, and nobody has to
  know a number to play.
- **Never**: lockstep input exchange, rollback, savestate synchronisation, or any scheme that
  requires the players' machines to be identical.

## Alternatives

- **Netplay (lockstep or rollback)** — rejected for the reasons above; it is not deferred, it is
  out of scope for this project.
- **One generic online layer for all games** — rejected as the focus: what a game needs to share
  is particular to that game. What is shared across games is only the plumbing: the i-mode
  adaptor and libimode, the phone and its transports, settings (ADR-0034), and the mod host.

## Consequences

- Each game's online work starts with reverse engineering: which state and events make a match,
  where to read and write them, which hooks carry them — the same method as the menu mod.
- Each game needs an authority decision (a host player or a server) and a protocol version; the
  protocol lives in the game's mod, in portable Haxe, so every target speaks it identically.
- The network ABI must reach every target, and the browser cannot open raw sockets: the common
  transport has to be one a browser can speak. ADR-0040 settled it: HTTP, what the i-mode centre
  carried — sockets on the desktop and the Dreamcast, `fetch` in the browser (whose server must
  allow the page's origin). A game's server speaks HTTP/1.0 on the game's port; its protocol is
  requests and responses, the console asking and the server answering.
- Online sessions are not deterministic and are not digested; headless digest runs stay offline,
  as they already are for controllers and settings.
- Nothing in the runtime should be shaped for netplay; "replay-friendly" determinism (inputs
  latched per vblank) remains a testing property, not an online plan.
