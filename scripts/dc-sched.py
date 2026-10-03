#!/usr/bin/env python3
"""scripts/dc-sched.py — list-schedules SH-4 assembly for the cache model's issue rules.

    scripts/dc-sched.py <in.blk> <out.s>
    scripts/dc-sched.py --into <file.hx> [--guard MACRO] <a.blk> [<b.blk> ...]

The rules are the cache model's (scripts/dc-issue-sim.py): two instructions issue together when
neither is CO and their units differ (or both are MT), the multiplier's CO instructions alone, and an
instruction waits for its operands' latencies. The first form writes the scheduled assembly; the
second puts every block file's scheduled form, as one C++ top-level `__asm__` for the SH-4 only,
into the `@:cppFileCode` between `// <dc-sched` and `// </dc-sched>` in a Haxe file (the GTE's RTPS
core, ADR-0046; the GPU's polygon core, ADR-0047), so that the assembly in the runtime is always this
tool's output of the block files in scripts/sh4/ — never edited by hand. `--guard` names the macro
that leaves the assembly out (RECOMPSX_GTE_NO_ASM unless it says otherwise).

A block file is assembly with blocks. Lines between `@block NAME` and `@end` are scheduled, anything
else is copied as it is. The block's own order must be a correct program: the scheduler only moves
instructions within their dependencies (registers including T, MACH:MACL and FPUL; the register
file's words; the stack). A line may carry tags after `;;`:
  exit      a conditional branch out of the block (the core declining): exits keep their order, and
            a store not tagged `free` or `undo` stays below every exit
  free      a store that may move above exits: a value the declined path writes again (MAC1-3 and
            IR1-3, which the C form writes before it reads)
  undo      a store of the group the undo stub takes back (the SZ FIFO's push): the group stays whole
            between two exits, and every exit after it goes to UNDO instead of DECLINE
  keep      a store every later exit follows: what the exit's target counts on having been written
  word=N    the register-file word a load or store touches
  table     a load from a constant table (no dependency)
  stack     a push or a pop (they keep their order, every exit follows every push before it, and
            every pop after an exit stays after it: the exit's target pops for itself)
  last      the branch that ends the block
  use=r8,.. registers an exit's target reads: their values at the exit are the block's own order's
            (no later write moves above it, no earlier one below)
An exit names its target in capitals, NAME, and becomes whichever of `.Lname0` (before the entry) and
`.Lname1` (after the code) is nearer and in reach of a conditional branch (256 bytes either way):
DECLINE and UNDO are the stubs; others are code that finishes the vertex another way (the core's
wide path).
"""
import importlib.util, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('sim', os.path.join(HERE, 'dc-issue-sim.py'))
sim = importlib.util.module_from_spec(spec); spec.loader.exec_module(sim)

def parse(line):
    code, _, tags = line.partition(';;')
    code = code.split('!')[0].strip()
    mn, _, ops = code.partition('\t') if '\t' in code else code.partition(' ')
    return mn.strip(), ops.strip(), tags.split()

def info(mn, ops):
    if re.search(r'^\.L\w+,', ops):      # a PC-relative constant in source form
        return 'LS', 1, 2, [], sim.regs(ops.split(',')[1]), None
    if mn in ('bt', 'bf', 'bt/s', 'bf/s', 'bra'):
        return 'BR', 1, 2, (['T'] if mn != 'bra' else []), [], None
    return sim.info(mn, ops)

def schedule(lines):
    items = []
    for text in lines:
        mn, ops, tags = parse(text)
        unit, issue, lat, rd, wr, base = info(mn, ops)
        store = mn.startswith('mov') and ',' in ops and sim.split_ops(ops)[1].strip().startswith('@')
        word = next((int(t[5:]) for t in tags if t.startswith('word=')), None)
        bases = set(base) if isinstance(base, list) else ({base} if base else set())
        use = set(r for t in tags if t.startswith('use=') for r in t[4:].split(','))
        items.append(dict(text=text.split(';;')[0].rstrip(), unit=unit, issue=issue, lat=lat,
                          rd=set(rd) | use, wr=set(wr) | bases, tags=tags, store=store, word=word))
    n = len(items)
    preds = [dict() for _ in range(n)]      # predecessor -> cycles from its issue
    def dep(a, b, d):
        preds[b][a] = max(preds[b].get(a, 0), d)
    for b in range(n):
        B = items[b]
        for a in range(b):
            A = items[a]
            if A['wr'] & B['rd']: dep(a, b, A['lat'])
            if A['rd'] & B['wr']: dep(a, b, 0)
            if A['wr'] & B['wr']: dep(a, b, 1)
            if A['word'] is not None and A['word'] == B['word'] and (A['store'] or B['store']):
                dep(a, b, 1 if A['store'] else 0)
            if 'stack' in A['tags'] and 'stack' in B['tags']: dep(a, b, 1)
            if 'exit' in A['tags'] and 'exit' in B['tags']: dep(a, b, 1)
            if 'exit' in A['tags'] and B['store'] and 'free' not in B['tags']: dep(a, b, 1)
            if ('undo' in A['tags'] or 'keep' in A['tags']) and 'exit' in B['tags']: dep(a, b, 1)
            if 'stack' in A['tags'] and 'exit' in B['tags']: dep(a, b, 1)
            if 'exit' in A['tags'] and 'stack' in B['tags']: dep(a, b, 1)
            if 'last' in B['tags']: dep(a, b, 0)
            if A['unit'] == 'CO' and B['unit'] == 'CO' and ('MAC' in A['wr'] | A['rd']) \
                    and ('MAC' in B['wr'] | B['rd']):
                dep(a, b, 0)
    prio = [0] * n                          # the longest latency path to the end
    for b in range(n - 1, -1, -1):
        succ = [prio[c] + preds[c][b] for c in range(b + 1, n) if b in preds[c]]
        prio[b] = max(succ + [0]) + items[b]['issue']
    done, order, now = [None] * n, [], 0
    remaining = set(range(n))
    def ready_at(i):
        t = 0
        for a, d in preds[i].items():
            if done[a] is None: return None
            t = max(t, done[a] + d)
        return t
    def pairs(u1, u2):
        return not (u1 == 'CO' or u2 == 'CO' or (u1 == u2 and u1 != 'MT'))
    while remaining:
        cands = [(i, ready_at(i)) for i in remaining]
        cands = [(i, t) for i, t in cands if t is not None]
        # the leader: what can start soonest, the longest path first; then its partner, if any
        i, t = min(cands, key=lambda c: (max(now, c[1]), -prio[c[0]], c[0]))
        start = max(now, t)
        done[i] = start; order.append(i); remaining.discard(i)
        now = start + items[i]['issue']
        if items[i]['unit'] != 'CO':
            best = None
            for j in remaining:
                tj = ready_at(j)
                if tj is None or tj > start or not pairs(items[i]['unit'], items[j]['unit']): continue
                if best is None or (-prio[j], j) < (-prio[best], best): best = j
            if best is not None:
                done[best] = start; order.append(best); remaining.discard(best)
    return [items[i] for i in order]

def assemble(src):
    out, block = [], None
    for line in open(src):
        s = line.rstrip('\n')
        if s.strip().startswith('@block'):
            block = []; continue
        if s.strip() == '@end':
            undo = False
            for it in schedule(block):
                text = it['text']
                if 'undo' in it['tags']: undo = True
                if 'exit' in it['tags'] and undo: text = text.replace('DECLINE', 'UNDO')
                out.append(text)
            block = None; continue
        if block is not None:
            if s.strip() and not s.strip().startswith('!'): block.append(s)
            continue
        out.append(s)
    # each exit to its target's label in reach, an instruction two bytes
    pos, labels, at = {}, {}, 0
    for k, l in enumerate(out):
        code = l.split('!')[0].strip()
        pos[k] = at
        name, _, rest = code.partition(':')
        if code.endswith(':'): labels[code[:-1]] = at
        elif code.startswith('.align'): at = (at + 3) & ~3 if code.split()[1] == '2' else at
        elif re.search(r'(^|:)\s*\.word\b', code): labels[name] = at; at += 2
        elif re.search(r'(^|:)\s*\.long\b', code): labels[name] = at; at += 4
        elif code and not code.startswith('.') and not code.startswith('@'): at += 2
    for k, l in enumerate(out):
        m = re.match(r'^(\s*b[tf](?:/s)?\s+)([A-Z][A-Z0-9_]*)\b', l)
        if not m: continue
        best = None
        for c in ('.L%s0' % m.group(2).lower(), '.L%s1' % m.group(2).lower()):
            disp = labels[c] - (pos[k] + 4) if c in labels else None
            if disp is not None and -256 <= disp <= 254 and (best is None or abs(disp) < abs(best[1])):
                best = (c, disp)
        if best is None:
            sys.exit('dc-sched: %s (byte %d) has no %s in reach' % (l.strip(), pos[k], m.group(2)))
        out[k] = l[:m.start(2)] + best[0] + l[m.end(2):]
    return out

def main():
    args = sys.argv[1:]
    if args and args[0] == '--into':
        target, blocks, guard = args[1], args[2:], 'RECOMPSX_GTE_NO_ASM'
        if blocks and blocks[0] == '--guard': guard, blocks = blocks[1], blocks[2:]
        asm = []
        for b in blocks:
            # each file's local labels its own: `.Lx` becomes `.L<stem>_x`
            stem = os.path.splitext(os.path.basename(b))[0]
            asm += [re.sub(r'\.L(\w+)', r'.L%s_\1' % stem, l)
                    for l in assemble(b) if l.strip() and not l.strip().startswith('!')]
        body = '\n'.join(asm).replace('"', '\\"')
        names = ' '.join(os.path.relpath(b, os.path.dirname(HERE)) for b in blocks)
        code = ('// <dc-sched %s> written by scripts/dc-sched.py --into: never edit by hand\n'
                '@:cppFileCode("#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(%s)\n'
                '__asm__(R\\"ASM(\n%s\n)ASM\\");\n#endif")\n// </dc-sched>' % (names, guard, body))
        s = open(target).read()
        a, b = s.index('// <dc-sched'), s.index('// </dc-sched>') + len('// </dc-sched>')
        open(target, 'w').write(s[:a] + code + s[b:])
        return
    if len(args) != 2:
        print(__doc__); sys.exit(2)
    open(args[1], 'w').write('\n'.join(assemble(args[0])) + '\n')

if __name__ == '__main__':
    main()
