#!/usr/bin/env python3
"""scripts/dc-issue-sim.py — time one path through SH-4 code with the cache model's own issue rules.

The cache model (scripts/dc-flycast-model.sh) charges every instruction its issue cycles unless it
pairs with the one before (Flycast's sh4_cycles.cpp: CO never pairs; two of one unit pair only if
both are MT), and makes it wait for operands that are not ready yet (rx_cache.cpp's scoreboard,
latencies from the opcode table: a load 2, `sts macl` 3, a multiply 4). This replays exactly those
two rules over one path through the code, without caches: what a sequence costs when its lines and
data are in the cache. It answers "is this form of the code faster" in seconds, where a build and a
model run take half an hour (docs/perf/dreamcast-ledger.md E-080: GCC's `cmdRtps` replayed here
gives 233 cycles, the model measured 232).

  scripts/dc-issue-sim.py <object or ELF> <symbol> --path tnnt...  [--trace]
      the path's conditional branches, in the order met: t taken, n not
  scripts/dc-issue-sim.py <model dir> <symbol substring> --counted [--trace]
      out/_x_<exp>/model of a run with RXCOUNT=1: the function in traced.elf along a call's
      average path — each branch going to the successor the run's execution counts owe more
      visits a call, so a loop runs its average number of times

Only the instructions the generated code, the runtime and hand-written GTE code use are known;
anything else stops the replay with its name.
"""
import os
import re
import subprocess
import sys

OD = os.path.expanduser('~/toolchains/dc/sh-elf/bin/sh-elf-objdump')
T, MAC, PR = 'T', 'MAC', 'PR'


def split_ops(ops):
    depth, cut = 0, -1
    for i, ch in enumerate(ops):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ',' and depth == 0:
            cut = i
    return (ops[:cut], ops[cut + 1:]) if cut >= 0 else (ops, '')


def regs(s):
    """The registers an operand names: r0-r15; fr/dr/xd/fv as the single-precision registers they
    cover (a double is its pair, a vector four); fpul."""
    out = ['r%d' % int(x) for x in re.findall(r'\br(\d+)\b', s)]
    out += ['f%d' % int(x) for x in re.findall(r'\bfr(\d+)\b', s)]
    for x in re.findall(r'\b(?:dr|xd)(\d+)\b', s):
        out += ['f%d' % int(x), 'f%d' % (int(x) + 1)]
    for x in re.findall(r'\bfv(\d+)\b', s):
        out += ['f%d' % (int(x) + k) for k in range(4)]
    if 'fpul' in s.lower():
        out.append('FPUL')
    return out


def info(mn, ops):
    """unit, issue cycles, latency, registers read, registers written, address register written
    a cycle later (a post-increment or pre-decrement), from Flycast's opcode table."""
    src, dst = split_ops(ops)
    if mn in ('mov.l', 'mov.w', 'mov.b'):
        if re.match(r'^[0-9a-f]+ <', ops) or ',pc)' in ops.replace(' ', '').lower():
            return 'LS', 1, 2, [], regs(dst), None
        if src.startswith('@'):
            return 'LS', 1, 2, regs(src), regs(dst), (regs(src)[0] if src.endswith('+') else None)
        return 'LS', 1, 1, regs(src) + regs(dst), [], (regs(dst)[0] if dst.startswith('@-') else None)
    if mn == 'mov':
        if src.startswith('#'):
            return 'EX', 1, 1, [], regs(dst), None
        return 'MT', 1, 0, regs(src), regs(dst), None
    if mn in ('add', 'sub', 'and', 'or', 'xor', 'shad', 'shld', 'xtrct'):
        return 'EX', 1, 1, (regs(dst) if src.startswith('#') else regs(src) + regs(dst)), regs(dst), None
    if mn in ('addv', 'subv'):
        return 'EX', 1, 1, regs(src) + regs(dst), regs(dst) + [T], None
    if mn in ('addc', 'subc', 'negc'):
        return 'EX', 1, 1, regs(src) + regs(dst) + [T], regs(dst) + [T], None
    if mn in ('not', 'neg', 'exts.w', 'extu.w', 'exts.b', 'extu.b', 'swap.w', 'swap.b'):
        return 'EX', 1, 1, regs(src), regs(dst), None
    if mn in ('shll', 'shlr', 'shal', 'shar', 'rotl', 'rotr', 'dt'):
        return 'EX', 1, 1, regs(ops), regs(ops) + [T], None
    if mn.startswith('shl') or mn.startswith('shr'):
        return 'EX', 1, 1, regs(ops), regs(ops), None
    if mn == 'movt':
        return 'EX', 1, 1, [T], regs(ops), None
    if mn == 'mova':
        return 'EX', 1, 1, [], ['r0'], None
    if mn == 'tst' or mn.startswith('cmp/'):
        return 'MT', 1, 1, regs(ops), [T], None
    if mn in ('clrt', 'sett'):
        return 'MT', 1, 1, [], [T], None
    if mn in ('bt', 'bf', 'bt.s', 'bf.s'):
        return 'BR', 1, 2, [T], [], None
    if mn == 'bra':
        return 'BR', 1, 2, [], [], None
    if mn in ('rts', 'jmp', 'jsr', 'braf', 'bsrf'):
        return 'CO', 2, 3, ([PR] if mn == 'rts' else regs(ops)), [], None
    if mn in ('mul.l', 'muls.w', 'mulu.w', 'dmuls.l', 'dmulu.l'):
        return 'CO', 2, 4, regs(ops), [MAC], None
    if mn in ('mac.w', 'mac.l'):
        return 'CO', 2, 4, regs(ops), [MAC], regs(ops)
    if mn == 'clrmac':
        return 'CO', 1, 3, [], [MAC], None
    if mn == 'sts' and 'mac' in src.lower():
        return 'CO', 1, 3, [MAC], regs(dst), None
    if mn == 'sts.l' and src.lower() == 'pr':
        return 'CO', 2, 2, ['r15'], [], 'r15'
    if mn == 'lds.l' and dst.lower() == 'pr':
        return 'CO', 2, 3, ['r15'], [PR], 'r15'
    if mn in ('pref', 'ocbwb', 'ocbi', 'ocbp'):
        return 'LS', 1, 1, regs(ops), [], None
    if mn == 'movca.l':
        return 'LS', 1, 4, regs(ops), [], None
    if mn == 'nop':
        return 'MT', 1, 0, [], [], None
    # The FPU, from the same table: moves and loads LS, arithmetic FE.
    if mn in ('fmov', 'fmov.s', 'fmov.d'):
        if src.startswith('@'):
            return 'LS', 1, 2, regs(src), regs(dst), (regs(src)[0] if src.endswith('+') else None)
        if dst.startswith('@'):
            return 'LS', 1, 1, regs(src) + regs(dst), [], (regs(dst)[0] if dst.startswith('@-') else None)
        return 'LS', 1, 0, regs(src), regs(dst), None
    if mn in ('flds', 'fsts', 'fneg', 'fabs', 'fldi0', 'fldi1'):
        return 'LS', 1, 0, (regs(src) if mn in ('flds', 'fsts') else regs(ops)), regs(dst or ops), None
    if mn == 'lds' and 'fpul' in dst.lower():
        return 'LS', 1, 1, regs(src), ['FPUL'], None
    if mn == 'sts' and 'fpul' in src.lower():
        return 'LS', 1, 3, ['FPUL'], regs(dst), None
    if mn == 'float':
        return 'FE', 1, 4, ['FPUL'], regs(dst), None
    if mn == 'ftrc':
        return 'FE', 1, 4, regs(src), ['FPUL'], None
    if mn in ('fadd', 'fsub', 'fmul', 'fmac', 'fcnvsd', 'fcnvds', 'fsca'):
        return 'FE', 1, 4, regs(ops), regs(dst), None
    if mn == 'fdiv':
        return 'FE', 1, 13, regs(ops), regs(dst), None
    if mn == 'fsqrt':
        return 'FE', 1, 23, regs(ops), regs(ops), None
    if mn == 'fsrra':
        return 'FE', 1, 1, regs(ops), regs(ops), None
    if mn == 'fipr':
        return 'FE', 1, 5, regs(ops), regs(dst)[3:4], None
    if mn == 'ftrv':
        return 'FE', 1, 8, regs(ops) + ['f%d' % k for k in range(16)], regs(dst), None
    if mn.startswith('fcmp/'):
        return 'FE', 1, 2, regs(ops), [T], None
    if mn in ('fschg', 'frchg'):
        return 'FE', 1, 4, [], [], None
    raise SystemExit('dc-issue-sim: unknown instruction %s %s' % (mn, ops))


def disassemble(path, want):
    """{address: (mnemonic, operands)} of the first symbol whose name contains `want`, and its start."""
    out = subprocess.run([OD, '-d', '--no-show-raw-insn', path], capture_output=True, text=True).stdout
    code, entry, inside = {}, None, False
    for line in out.split('\n'):
        m = re.match(r'^([0-9a-f]{8}) <(.*)>:$', line)
        if m:
            inside = (m.group(2) == want or (entry is None and want in m.group(2))) and entry is None
            if inside:
                entry = int(m.group(1), 16)
            continue
        m = re.match(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$', line)
        if m and inside:
            code[int(m.group(1), 16)] = (m.group(2), m.group(3).split('!')[0].strip())
    if entry is None:
        raise SystemExit('dc-issue-sim: no symbol like ' + want)
    return code, entry


def replay(code, entry, choose, trace):
    ready, now, last, n, pending, pc = {}, 0, 'CO', 0, None, entry
    while True:
        mn, ops = code[pc]
        unit, issue, lat, rd, wr, base = info(mn, ops)
        if last == 'CO' or unit == 'CO' or (last == unit and last != 'MT'):
            last, cyc = unit, issue
        else:
            last, cyc = 'CO', 0
        at = now
        for r in rd:
            at = max(at, ready.get(r, 0))
        for w in wr:
            ready[w] = at + lat
        for b in (base if isinstance(base, list) else ([base] if base else [])):
            ready[b] = at + 1
        if trace:
            print('%5d %d+%d %-2s %-8s %s' % (now, cyc, at - now, unit, mn, ops))
        now += cyc + (at - now)
        n += 1
        nxt = pc + 2
        if pending is not None:
            nxt, pending = pending, None
        elif mn == 'rts':
            pending = 'END'
        elif mn in ('bt', 'bf', 'bt.s', 'bf.s', 'bra'):
            target = int(ops.split()[0], 16)
            take = True if mn == 'bra' else choose(pc, mn, target)
            if mn.endswith('.s') or mn == 'bra':
                if take:
                    pending = target
            elif take:
                nxt = target
        if nxt == 'END':
            return n, now
        if n > 1000000:
            raise SystemExit('dc-issue-sim: no return after a million instructions')
        pc = nxt


def main():
    args = sys.argv[1:]
    trace = '--trace' in args
    if len(args) < 3 or not ('--path' in args or '--counted' in args):
        print(__doc__)
        sys.exit(2)
    if '--counted' in args:
        model = args[0]
        code, entry = disassemble(os.path.join(model, 'traced.elf'), args[1])
        counts = {}
        for line in open(os.path.join(model, 'prof.txt.cache.count')):
            a, c = line.split()
            counts[int(a, 16)] = int(c)
        calls = max(counts.get(entry, 0), 1)
        visits = {}

        # A call's average path: each successor is owed count / calls visits, and a branch goes to
        # the one owed more of them — so a loop's body comes round as often as it does on average,
        # and then the exit is taken.
        def choose(pc, mn, target):
            fall = pc + 4 if mn.endswith('.s') else pc + 2
            owed = lambda a: counts.get(a, 0) / calls - visits.get(a, 0)
            take = owed(target) > owed(fall)
            nxt = target if take else fall
            visits[nxt] = visits.get(nxt, 0) + 1
            return take
    else:
        code, entry = disassemble(args[0], args[1])
        decisions = args[args.index('--path') + 1]
        state = {'i': 0}

        def choose(pc, mn, target):
            if state['i'] >= len(decisions):
                raise SystemExit('dc-issue-sim: the path meets more branches than --path names')
            d = decisions[state['i']]
            state['i'] += 1
            return d == 't'
    n, cycles = replay(code, entry, choose, trace)
    print('%d instructions, %d cycles' % (n, cycles))


if __name__ == '__main__':
    main()
