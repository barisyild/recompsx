#!/usr/bin/env python3
"""scripts/sh4/islands.py <in.s> <out.s> [--stats]

Far-branch islands for GCC's SH-4 assembly: the jumps GCC places in the middle of hot code to reach
a cold block out of a conditional branch's range, moved to a point in reach where nothing falls
through.

A conditional branch on the SH-4 reaches 256 bytes. GCC lays cold blocks out at the end of a
function, and for each branch to one it emits the far jump right after the branch, the condition
inverted to jump around it:

        bt/s    .Lskip              bf/s    .Lisle
        <slot>                      <slot>
        bra     .Lcold       ->   .Lskip: ...
        nop                         ...
    .Lskip:                         bra     .Lsomewhere      (a barrier: nothing falls through)
                                    <slot>
                                  .Lisle:
                                    bra     .Lcold
                                    nop

(and the same with `mov.w .Lw,rN; braf rN; <slot>; .Lw: .word .Lcold-.Lw` for a block more than
4 KB away). The hot path jumps over four or eight bytes of cold code at every such branch — in
Crash 3's gameplay 11 % of the slots of the instruction-cache lines its generated code fills, and
63,000 taken branches a frame. Moved to an island after the nearest barrier in reach, the hot path
falls through instead.

**Not part of the build** (docs/perf/dreamcast-ledger.md, E-115): exact, but the cache model measured
no gain — the islands land in lines the hot path fills anyway, so the lines are no denser, and the
taken branches it removes are not something the model charges. Kept for a console A/B, opt-in:
`DC_EXTRA_FLAGS="-dA -B$PWD/scripts/sh4/as-islands/"` (GCC's -dA block counts choose the sites; it
does not change the code, verified on a shard).

Every move keeps what runs: the branch's condition is inverted and retargeted, its delay slot stays
where it was, and the island holds the jump and its slot as they were. Islands go only after `bra`,
`rts` and `jmp` and their delay slots. The layout is computed here — every instruction two bytes,
`.align` as the assembler pads it — and every PC-relative reference of the section (branches,
`mov.w`/`mov.l`/`mova` from a literal pool, `.word` and `.byte` label differences: casesi tables
too) is checked against its range after the moves; a move that would put one out of reach is not
made. A section entered more than once, or holding anything this cannot size, is left as it is.
"""
import re
import sys

COND = {'bt': 'bf', 'bf': 'bt', 'bt/s': 'bf/s', 'bf/s': 'bt/s', 'bt.s': 'bf.s', 'bf.s': 'bt.s'}
DELAYED = {'bt/s', 'bf/s', 'bt.s', 'bf.s', 'bra', 'bsr', 'braf', 'bsrf', 'jmp', 'jsr', 'rts', 'rte'}
BARRIER = {'bra', 'rts', 'jmp'}

BLOCK = re.compile(r'^!\s*BLOCK\s+\d+,\s*count:(\d+)')
LABEL = re.compile(r'^([.\w$@]+):\s*(?:[!].*)?$')
INSN = re.compile(r'^\s+([a-z][a-z0-9./]*)(?:\s+(.*?))?\s*(?:[!].*)?$')
DIRECTIVE = re.compile(r'^\s*(\.[\w.]+)\b(.*)$')


class Item:
    __slots__ = ('kind', 'text', 'op', 'args', 'size', 'align', 'label', 'off', 'count', 'orig')

    def __init__(self, kind, text, op=None, args='', size=0, align=0, label=None, count=None):
        self.kind = kind      # 'insn', 'data', 'align', 'label', 'other'
        self.text = text
        self.op = op
        self.args = args
        self.size = size
        self.align = align
        self.label = label
        self.off = 0
        self.count = count    # a `! BLOCK n, count:N` comment's N (GCC's -dA): the block that starts here
        self.orig = None      # a label difference's values as first laid out (check)


def data_size(d, args):
    n = len([a for a in split_args(args) if a.strip()])
    if d in ('.long', '.4byte', '.int'):
        return 4 * n
    if d in ('.word', '.short', '.2byte', '.hword', '.uaword'):
        return 2 * n
    if d == '.byte':
        return n
    return None


def split_args(args):
    out, depth, cur = [], 0, ''
    for ch in args:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    return out


SIZELESS = {'.loc', '.type', '.size', '.global', '.globl', '.weak', '.hidden', '.local', '.file',
            '.ident', '.set', '.equ', '.loc_mark_labels', '.protected', '.internal', '.local'}


def parse_line(line):
    """An Item for a line of a .text section, or None when it cannot be sized."""
    s = line.rstrip('\n')
    st = s.strip()
    if st == '' or st.startswith('!') or st.startswith('#'):
        m = BLOCK.match(st)
        return Item('other', line, count=int(m.group(1)) if m else None)
    m = LABEL.match(s)
    if m:
        return Item('label', line, label=m.group(1))
    m = DIRECTIVE.match(s)
    if m:
        d, args = m.group(1), m.group(2).split('!')[0].strip()
        if d in ('.align', '.p2align'):
            a = split_args(args)[0].strip()
            if not a.isdigit():
                return None
            return Item('align', line, align=1 << int(a))
        if d == '.balign':
            a = split_args(args)[0].strip()
            if not a.isdigit():
                return None
            return Item('align', line, align=int(a))
        n = data_size(d, args)
        if n is not None:
            return Item('data', line, op=d, args=args, size=n)
        if d in SIZELESS or d.startswith('.cfi_'):
            return Item('other', line)
        return None
    m = INSN.match(s)
    if m:
        return Item('insn', line, op=m.group(1), args=(m.group(2) or '').strip(), size=2)
    return None


def layout(items):
    off = 0
    for it in items:
        if it.kind == 'align':
            off = (off + it.align - 1) & ~(it.align - 1)
        it.off = off
        off += it.size
    return off


def target_of(it):
    """The label a PC-relative instruction names, and its kind, or (None, None)."""
    if it.kind != 'insn':
        return None, None
    op, a = it.op, it.args
    if op in COND or op in ('bra', 'bsr'):
        return a.strip(), op
    if op in ('mov.w', 'mov.l', 'mova'):
        src = split_args(a)[0].strip()
        if re.match(r'^[.\w$]+$', src) and not re.match(r'^r\d+$', src) and not src.startswith('@'):
            return src, op
    return None, None


def check(items, labels_at):
    """The indices of items whose PC-relative reference is out of range; None if a target is
    not in this section."""
    bad = []
    for i, it in enumerate(items):
        if it.kind == 'insn':
            t, kind = target_of(it)
            if t is None:
                continue
            if t not in labels_at:
                return None
            tgt = items[labels_at[t]].off
            a = it.off
            if kind in COND:
                d = tgt - (a + 4)
                if d % 2 or not -256 <= d <= 254:
                    bad.append(i)
            elif kind in ('bra', 'bsr'):
                d = tgt - (a + 4)
                if d % 2 or not -4096 <= d <= 4094:
                    bad.append(i)
            elif kind == 'mov.w':
                d = tgt - (a + 4)
                if d % 2 or not 0 <= d <= 510:
                    bad.append(i)
            else:   # mov.l, mova
                d = tgt - ((a & ~3) + 4)
                if tgt % 4 or not 0 <= d <= 1020:
                    bad.append(i)
        elif it.kind == 'data' and it.op in ('.word', '.short', '.2byte', '.hword', '.byte'):
            # A label difference in a field of 16 or 8 bits: a casesi table's entries (GCC picks
            # the field from the distances) and braf's. Each keeps the class it had as laid out
            # first — negative, positive as a signed field, or above it — whichever way the code
            # reading it extends it.
            bits = 8 if it.op == '.byte' else 16
            vals = []
            for v in split_args(it.args):
                m = re.match(r'^\s*([.\w$]+)\s*-\s*([.\w$]+)\s*$', v)
                if m and m.group(1) in labels_at and m.group(2) in labels_at:
                    vals.append(items[labels_at[m.group(1)]].off - items[labels_at[m.group(2)]].off)
                else:
                    vals.append(None)
            if it.orig is None:
                it.orig = vals
            half = 1 << (bits - 1)
            cls = lambda d: 0 if d < 0 else (1 if d < half else 2)
            for d, o in zip(vals, it.orig):
                if d is None:
                    continue
                if not -half <= d < 2 * half or (o is not None and cls(d) != cls(o)):
                    bad.append(i)
                    break
    return bad


def next_bytes(items, i, refs):
    """The index of the first item from i that emits bytes (or aligns), and the labels before it
    that this section's code or data names (the rest — .LVL, .LM, .LBB — are debug information's)."""
    labels = []
    while i < len(items) and items[i].kind in ('label', 'other'):
        if items[i].kind == 'label' and refs.get(items[i].label, 0):
            labels.append(items[i].label)
        i += 1
    return i, labels


def find_trampolines(items, refs):
    """[(branch index, slot index or None, first moved index, last moved index, skip label)]"""
    out = []
    n = len(items)
    for i, it in enumerate(items):
        if it.kind != 'insn' or it.op not in COND:
            continue
        skip = it.args.strip()
        j = i + 1
        slot = None
        if it.op in DELAYED:
            j, labs = next_bytes(items, j, refs)
            if labs or j >= n or items[j].kind != 'insn' or items[j].op in DELAYED:
                continue
            slot = j
            j += 1
        j, labs = next_bytes(items, j, refs)
        if labs or j >= n or items[j].kind != 'insn':
            continue
        first = j
        if items[j].op == 'bra':
            k, labs = next_bytes(items, j + 1, refs)
            if labs or k >= n or items[k].kind != 'insn' or items[k].op in DELAYED:
                continue
            last = k
        elif items[j].op == 'mov.w':
            w = split_args(items[j].args)
            if len(w) != 2:
                continue
            wl, reg = w[0].strip(), w[1].strip()
            k, labs = next_bytes(items, j + 1, refs)
            if labs or k >= n or items[k].kind != 'insn' or items[k].op != 'braf' or items[k].args != reg:
                continue
            k2, labs = next_bytes(items, k + 1, refs)
            if labs or k2 >= n or items[k2].kind != 'insn' or items[k2].op in DELAYED:
                continue
            k3, labs = next_bytes(items, k2 + 1, refs)
            if labs != [wl] or k3 >= n or items[k3].kind != 'data' or items[k3].op != '.word':
                continue
            if not re.match(r'^\s*[.\w$]+\s*-\s*' + re.escape(wl) + r'\s*$', items[k3].args):
                continue
            if refs.get(wl, 0) != 2:      # the mov.w and the .word, nothing else
                continue
            last = k3
        else:
            continue
        # The skip label, perhaps after GCC's alignment of a jump target that follows a barrier
        # (sh.cc barrier_align): reached by falling through once the jump has gone, it is dropped.
        k = last + 1
        aligns, labs = [], []
        while k < n and items[k].kind in ('label', 'other', 'align'):
            if items[k].kind == 'align':
                aligns.append(k)
            elif items[k].kind == 'label' and refs.get(items[k].label, 0):
                labs.append(items[k].label)
            k += 1
        if skip not in labs or k >= n or items[k].kind != 'insn':
            continue
        out.append((i, slot, first, last, skip, tuple(aligns)))
    return out


def find_sites(items, moved, refs):
    """[(index after which an island may go, the estimated count of the block after it or None)]:
    the delay slots of the bra, rts and jmp not moved."""
    sites = []
    n = len(items)
    for i, it in enumerate(items):
        if it.kind == 'insn' and it.op in BARRIER and i not in moved:
            j, labs = next_bytes(items, i + 1, refs)
            if labs or j >= n or items[j].kind != 'insn' or j in moved:
                continue
            # After a literal pool GCC put there too, if it did: the pool's loads are all before it
            # (a load reaches forward only), and an island before the pool would push it from them.
            site = j
            count = None
            k = j + 1
            while k < n and items[k].kind != 'insn':
                if items[k].kind == 'data':
                    site = k
                elif items[k].count is not None and count is None:
                    count = items[k].count
                k += 1
            sites.append((site, count))
    return sites


def transform(items, stats):
    labels_at = {}
    refs = {}
    for i, it in enumerate(items):
        if it.kind == 'label':
            if it.label in labels_at:
                return items
            labels_at[it.label] = i
    for it in items:
        if it.kind == 'insn':
            t, _ = target_of(it)
            if t:
                refs[t] = refs.get(t, 0) + 1
        elif it.kind == 'data':
            for tok in re.findall(r'[.\w$]+', it.args):
                if tok in labels_at:
                    refs[tok] = refs.get(tok, 0) + 1
    layout(items)
    if check(items, labels_at) != []:
        stats['skipped sections'] += 1
        return items
    tramps = find_trampolines(items, refs)
    if not tramps:
        return items
    moved = set()
    for t in tramps:
        for k in range(t[2], t[3] + 1):
            moved.add(k)
    sites = find_sites(items, moved, refs)
    if not sites:
        return items
    # The estimated count of the block each item is in: the last `! BLOCK` comment before it.
    cur, bcount = None, []
    for it in items:
        if it.count is not None:
            cur = it.count
        bcount.append(cur)
    # Each jump to the coldest site in reach (GCC's own estimate of the block after it), the
    # nearest of those; the margin leaves room for what the moves shift.
    plan = {}
    for t in tramps:
        b = t[0]
        a = items[b].off
        cands = []
        for (st, cnt) in sites:
            d = items[st].off + 2 - (a + 4)
            if -200 <= d <= 200:
                cands.append((cnt if cnt is not None else 1 << 62, abs(d), st))
        if cands:
            cands.sort()
            hot = bcount[b]
            # Only into colder code than the branch's own, by GCC's estimate: an island in a line the
            # hot path fills anyway takes that line's room instead (measured: E-115).
            if cands[0][0] < (1 << 62) and hot is not None and cands[0][0] * 4 <= hot:
                plan[t] = cands[0][2]
                stats['to colder'] += 1
    stats['trampolines'] += len(tramps)
    active = dict(plan)
    for _ in range(50):
        new, nlabels = build(items, active, stats)
        layout(new)
        bad = check(new, nlabels)
        if bad == []:
            stats['moved'] += len(active)
            return new
        if bad is None:
            return items
        # Drop every move whose branch, trampoline or island lies within a failing reference's span.
        drop = set()
        for i in bad:
            it = new[i]
            t, _ = target_of(it)
            if t is not None and t in nlabels:
                lo, hi = sorted((it.off, new[nlabels[t]].off))
            elif it.kind == 'data':
                offs = [it.off] + [new[nlabels[x]].off for x in re.findall(r'[.\w$]+', it.args) if x in nlabels]
                lo, hi = min(offs), max(offs)
            else:
                lo, hi = 0, 1 << 30
            for tr, s in active.items():
                pos = [items[tr[0]].off, items[s].off]
                if any(lo - 16 <= p <= hi + 16 for p in pos):
                    drop.add(tr)
        if not drop:
            return items
        for tr in drop:
            del active[tr]
        stats['dropped'] += len(drop)
        if not active:
            return items
    return items


def build(items, active, stats):
    """The section with the moves in `active` made: (items, labels)."""
    by_site = {}
    removed = set()
    retarget = {}
    serial = build.serial
    for (b, slot, first, last, skip, aligns), s in sorted(active.items(), key=lambda kv: kv[0][0]):
        removed.update(aligns)
        body = tuple(items[k].text for k in range(first, last + 1) if items[k].kind in ('insn', 'data', 'label'))
        key = (s, body)
        lab = by_site.setdefault(s, {}).get(key)
        if lab is None:
            serial += 1
            lab = '.Lisle%d' % serial
            by_site[s][key] = lab
        retarget[b] = lab
        for k in range(first, last + 1):
            if items[k].kind in ('insn', 'data') or (items[k].kind == 'label' and k > first):
                removed.add(k)
    build.serial = serial
    out = []
    for i, it in enumerate(items):
        if i in removed:
            continue
        if i in retarget:
            inv = COND[it.op]
            indent = re.match(r'^(\s*)', it.text).group(1) or '\t'
            out.append(Item('insn', '%s%s\t%s\n' % (indent, inv, retarget[i]), op=inv, args=retarget[i], size=2))
        else:
            out.append(it)
        if i in by_site:
            for (s, body), lab in by_site[i].items():
                out.append(Item('label', '%s:\n' % lab, label=lab))
                for line in body:
                    p = parse_line(line)
                    out.append(p)
    labels = {}
    for i, it in enumerate(out):
        if it.kind == 'label':
            labels[it.label] = i
    return out, labels


build.serial = 0


SECTION = re.compile(r'^\s*\.(section|pushsection)\s+([^\s,]+)')


def main():
    src, dst = sys.argv[1], sys.argv[2]
    lines = open(src, errors='surrogateescape').readlines()
    # Runs of lines by section.
    runs = []
    cur, start = '.text', 0
    stack = []
    prev = '.text'

    def switch(name, i):
        nonlocal cur, start
        runs.append((cur, start, i))
        cur, start = name, i + 1

    for i, line in enumerate(lines):
        st = line.strip()
        if not st.startswith('.'):
            continue
        m = SECTION.match(line)
        if m:
            if m.group(1) == 'pushsection':
                stack.append(cur)
            prev = cur
            switch(m.group(2), i)
        elif st == '.text' or st.startswith('.text '):
            prev = cur
            switch('.text', i)
        elif st.startswith('.data') or st.startswith('.bss'):
            prev = cur
            switch(st.split()[0], i)
        elif st.startswith('.popsection'):
            switch(stack.pop() if stack else '.text', i)
        elif st.startswith('.previous'):
            p = prev
            prev = cur
            switch(p, i)
    runs.append((cur, start, len(lines)))
    count = {}
    for name, a, b in runs:
        if b > a:
            count[name] = count.get(name, 0) + 1
    stats = {'trampolines': 0, 'moved': 0, 'dropped': 0, 'skipped sections': 0, 'sections': 0, 'to colder': 0}
    out = []
    pos = 0
    for name, a, b in runs:
        if b <= a:
            continue
        if not name.startswith('.text') or name.startswith('.text.recompsx_') or count[name] != 1:
            continue
        items = []
        ok = True
        for line in lines[a:b]:
            it = parse_line(line)
            if it is None:
                ok = False
                break
            items.append(it)
        if not ok:
            stats['skipped sections'] += 1
            continue
        stats['sections'] += 1
        new = transform(items, stats)
        if new is items:
            continue
        out.extend(lines[pos:a])
        out.extend(it.text for it in new)
        pos = b
    out.extend(lines[pos:])
    with open(dst, 'w', errors='surrogateescape') as f:
        f.writelines(out)
    if '--stats' in sys.argv:
        sys.stderr.write('islands: %(sections)d sections, %(trampolines)d far jumps, %(moved)d moved, '
                         '%(dropped)d dropped (%(to colder)d planned to a colder block), %(skipped sections)d sections left as they were\n' % stats)


if __name__ == '__main__':
    main()
