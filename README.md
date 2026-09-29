# recompsx

recompsx statically recompiles PlayStation games to Haxe. A tool reads a game's executable and
disc, overlays included, disassembles the R3000A code and writes Haxe. That code runs on a
hand-written runtime that uses integers only: the kernel is emulated at a high level, the hardware
at register level.

The same generated code builds two ways:
- for JavaScript, the reference, which runs in a browser;
- through [reflaxe.CPP](https://github.com/SomeRanDev/reflaxe.CPP), as dependency-free C++17 for
  the desktop and for consoles, the Sega Dreamcast first.

Every PS1 game is the target. Crash Bash and Crash Bandicoot: Warped are the games whose failures
set the order of the work.

## Where things are

- [AGENTS.md](AGENTS.md): how the project works, its rules and its commands.
- [PROGRESS.md](PROGRESS.md): where it stands, what comes next, and the log.
- [docs/](docs/): the architecture, the specs, and the decisions (docs/decisions, one ADR each).

No game data and no BIOS is in this repository, and none ever will be. You need your own disc.

## Testing

- **chap3l** tests the Dreamcast builds on a real console:
  [youtube.com/@chap3l](https://www.youtube.com/@chap3l)
