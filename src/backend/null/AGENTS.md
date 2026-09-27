# Null backend — agent notes

Read this when the work touches `src/backend/null/`. The root `AGENTS.md` still applies in full.

- The smallest honest implementation of `backend_c_api.h`: no window, audio or input. Files
  are read through stdio, so a game runs headless here (`--headless-hash N`) — the desktop C++
  side of a game's cross-target digest. Everything else reports its absence. Every function in
  the header must exist here — `scripts/check.sh` counts them per backend directory.
- Used by `scripts/test.sh` and the conformance runs for the C++ side (`build-pc.sh --null`),
  where the digest is the whole output, and as the starting point of a new port: build against
  it, run headless, then replace functions one at a time.
- Nothing here may grow features; a capability a test needs belongs in the ABI and in the real
  backends, not in a stub that pretends.
