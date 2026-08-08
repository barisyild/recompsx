# ADR-0005: Time, scheduling and interrupt delivery
Status: accepted   Date: 2026-08-08

## Context

Crash Bash gets through its startup and then stops, waiting for a VBlank that nothing delivers.
The trace both targets now produce says what it is waiting with: `OpenEvent`, `EnableEvent`,
`WaitEvent`, `SysEnqIntRP`, `ChangeClearRCnt`. Those are not five features. They are one
mechanism — the game arms an event, installs a handler on an interrupt chain, says what the
kernel should acknowledge, and waits. Implementing any one of them alone moves the hang without
removing it.

Three facts about the code as it stands shape what follows:

- **No pump points are emitted.** The emitter writes `ctx.cycles += N` before every control
  transfer, and nothing ever reads it. Time accumulates and is never observed.
- **There is no I/O dispatch.** Everything in the 0x1F801000 page reads 0 and writes vanish, so
  `I_STAT`/`I_MASK` have nowhere to live yet.
- `ctx.nextEvent` exists and is always 0.

The first of those is the expensive one. Pump points are *generated code*: they are compiled into
861 functions, and changing their shape later means regenerating and re-verifying everything. The
contract has to be right the first time, which makes this an architectural decision rather than an
implementation detail.

## Decision

### 1. Time is a pure function of `cycles`. The scheduler fires only edges.

Anything a game can *read* — the current scanline, the field bit, `GPUSTAT` bit 31, a timer's
value — is computed from `ctx.cycles` at the moment of the read, analytically, in integer
arithmetic. None of it is stepped forward by the scheduler.

The alternative, updating counters as events fire, is wrong for a reason that only shows up in
real games: a game polling `GPUSTAT` between two events would read a value that stopped moving.
Polling loops are one of the three ways PS1 games wait for vblank, so that is not a corner case.
Computing on read also means the scheduler needs far fewer slots — it schedules the vblank
*edges*, not every line.

`TimeBase` is therefore stateless beyond region constants, and is exactly the kind of pure
integer function this project can pin with a conformance test on both targets before anything
depends on it.

### 2. The pump contract, which is generated-code ABI

At each pump point the emitter writes exactly:

```haxe
if (ctx.cycles - ctx.nextEvent >= 0) Runtime.pump(ctx);
```

One subtraction and one branch on the common path; a call only when something is actually due.
Deliberately a single statement in the `if` body, with no `else` — see the note under
Consequences.

Pump points go in exactly two places:

- **function entry**, once, before the block dispatch;
- **every back-edge**, after the `cycles` increment — that is, any transfer whose target block
  starts at or below the source block's address, including switch-table edges.

Straight-line code carries no pump. The rule guarantees forward progress: an idle `b .` loop is a
back-edge, so time advances and events fire.

Back-edges and function entries are also the only points where the emulated CPU state is
*consistent* — no half-executed delay slot, no latched branch condition in flight. Since
delivering an interrupt means calling a recompiled function, delivery can only happen where the
state is whole. The pump points are not merely a convenient place to check the clock; they are
the only correct place to re-enter generated code.

### 3. An idle wait advances to the next deadline, not by a constant

`WaitEvent` cannot block: there is no thread to suspend. It runs a loop that advances emulated
time until the event becomes ready. That loop sets `ctx.cycles = ctx.nextEvent` and runs the
scheduler — it jumps straight to the next deadline rather than stepping by a fixed amount.

An arbitrary step (the earlier draft of the runtime spec said `+= 64`) is a free parameter with no
justification, and it makes delivery time depend on how that number happens to divide into event
deadlines. Jumping to the deadline is exact, has nothing to tune, and turns an idle wait from
O(cycles) into O(events). This only applies while the CPU is idle inside the kernel; game code
polling in its own loop advances time by its own real instruction counts, which is correct.

A wait that has advanced more than five emulated seconds without its event reports once, names
the event class and spec it was waiting for, and returns. Reporting rather than hanging is the
same choice made everywhere else in this runtime: a bring-up session needs to see the next
problem, not the first one forever.

### 4. Interrupt handlers get a saved and restored register snapshot

`SysEnqIntRP` installs a *recompiled game function* as a handler. Calling it means re-entering
generated code from the scheduler, on the same `CpuState`, and that function will freely clobber
registers the interrupted code was using. On hardware the BIOS saves and restores them; under HLE
nothing does unless we do.

So `Irq` keeps one preallocated snapshot buffer, copies the general registers into it before
calling a handler chain and back afterwards. One buffer, not a stack of them, because delivery is
inhibited while inside a handler:

- `ctx.critDepth != 0` — the game is in a critical section;
- or we are already inside a handler.

The second is not just an optimisation. Without it, a handler's own back-edges would pump, deliver
again, and recurse until the host stack died — with the cause looking like anything but an
interrupt. Nesting is what the depth counter of ADR-0004's critical sections already models, and
this is the same idea applied to the handler itself.

### 5. Fixed slots, no allocation, ties broken by index

The scheduler is a fixed array of `{due:Int, active:Bool}` — `VBLANK_START`, `VBLANK_END`,
`TIMER0/1/2`, `SPU_BATCH`, `CD_EVENT`, `SIO_BYTE`, `DMA_IRQ`, `MEMCARD_OP` — with a cached
`minDue` recomputed on schedule and cancel. At a dozen slots a linear scan beats a heap, and it
allocates nothing, which the portable subset requires anyway.

Two events due at the same cycle fire in slot-index order. Not "whichever the container yields":
an arbitrary order is a divergence waiting to happen between two targets, and this project's whole
guarantee is that they agree.

**One event is always armed.** Vblank is rescheduled as soon as it fires, so `nextEvent` is always
a real deadline and pump never has to special-case an empty table.

### 6. Built bottom-up, with a conformance test before each layer is depended on

`TimeBase` → `Scheduler` → I/O dispatch with `I_STAT`/`I_MASK` → the event table → the interrupt
chains → pump emission. The pieces are coupled at run time but not in construction, and each of
the first four is pure integer behaviour that can be pinned across both targets before the next
one leans on it.

This is slower to write and it is the only way the cross-target guarantee survives contact with a
subsystem this stateful. Every divergence this project has found came from a layer that had been
verified on one target and assumed on the other.

## Alternatives

- **Step counters on every event instead of computing on read.** Simpler scheduler, but a game
  polling `GPUSTAT` between events reads a frozen value, and that is one of the three standard
  vblank idioms. Rejected on correctness, not cost.
- **Pump on a cycle count only, ignoring block boundaries.** Cheaper to emit, but it can land
  mid-delay-slot where the CPU state is not consistent, and delivering an interrupt there would
  corrupt it. Rejected outright.
- **Unconditional `Runtime.pump(ctx)` at every pump point, testing inside.** One call per loop
  iteration in every hot loop in the game. Rejected on cost.
- **A real priority queue for events.** Correct, but allocates or needs a heap implementation, and
  at N ≤ 12 the scan is faster. Revisit only if the slot count grows past about 32.
- **Suspending the host thread in `WaitEvent`.** There is no thread, and introducing one would put
  host scheduling inside emulated state — the one thing determinism forbids.

## Consequences

- **The emitter changes, so everything regenerates.** Pump points land in all 861 functions of the
  bring-up game. The `if` body is a single statement on purpose: an `if` with no `else` and more
  than one statement was silently deleted by reflaxe.CPP (upstream defect 8, fixed in our fork,
  patch 0002), and generated code should not depend on that fix being present. `scripts/spike.sh`
  covers the shape.
- **Pump costs a subtraction and a branch per back-edge.** Measurable, and worth measuring once
  the emitter change lands, because it lands in the hottest code in the program.
- **`Memory.slowRead32`/`slowWrite32` stop returning 0 for the I/O page**, which is the first time
  writes to hardware registers will have an effect. Anything that was accidentally working because
  registers read as zero will stop.
- **A watchdog fires on a wait that never completes**, naming the event. That message is expected
  to be the main diagnostic for the rest of M2.
- `docs/specs/runtime.md` §2 is superseded on two points: the wait-loop step constant, and the
  statement that timing counters are advanced by the scheduler. Both are corrected there.
