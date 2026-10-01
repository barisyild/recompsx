/* scripts/dc-ocache-sim.c — the SH-4's operand cache over a trace, by the objects the data lives in.
 *
 * The cache model (scripts/dc-flycast-model.sh) with RXOTRACE=<n> writes <prof>.cache.otrace: every
 * operand access that reaches the operand cache while recording, as the physical address in the
 * low 29 bits and the kind of access in the top three (0 read, 1 write, 2 movca.l, 3 pref, 4 ocbi,
 * 5 ocbp, 6 ocbwb). Replayed against a 16 KB direct-mapped copy-back cache it gives the model's own
 * operand misses and write-backs, and, against a fully associative LRU cache of the same 512 lines
 * (reads and writes only, as the model counts it), the misses no placement of the data could
 * avoid. The difference is the conflicts: which objects evict which is decided by where the
 * linker, the heap and the stack put them.
 *
 *   dc-ocache-sim stat <otrace> <objects> [top] [counts]
 *       misses, write-backs and conflicts by object, the objects that evict each other most, and
 *       the busiest lines; with <counts>, every object's "accesses misses fa wb start size name"
 *   dc-ocache-sim stack <otrace> <objects> <stack-from> [events]
 *       misses and write-backs with the stack (every address from <stack-from>, hex, to the top of
 *       RAM that no object holds) moved down 0..511 lines: which start of the stack suits the rest
 *
 *   dc-ocache-sim dopt <items> <k> <rounds> <events> <out> <stack-from> <shift> <otrace> <objects> ...
 *       colours (line index mod 512) for the k most accessed of the objects named in <items> (one
 *       input section name per line, e.g. .bss.recompsx_gte), chosen together for every
 *       <otrace> <objects> pair given — games — each weighted by its own cost unplaced, with the
 *       stack at <stack-from>.. moved down <shift> lines; written to <out> as "colour name".
 *       A name may be followed by a constraint: "=c", the colour c (0..511) and no other — an
 *       object already placed, taking part only by being where it will be — or "~c", a colour
 *       that is c mod 256 — code whose place in the 8 KB instruction cache is decided, which then
 *       chooses only the 16 KB half its literal pools are read from
 *
 * <objects>: "start size name" per line (hex, hex, text), sorted by start and not overlapping —
 * every input section of the link (scripts/dc-layout.py objects <map>). An address in none of them
 * (the heap, the stacks) counts under its 4 KB page.
 *
 * Build: cc -O2 -o dc-ocache-sim scripts/dc-ocache-sim.c -lpthread
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE 32u
#define SETS 512u

enum { OT_READ, OT_WRITE, OT_MOVCA, OT_PREF, OT_OCBI, OT_OCBP, OT_OCBWB };

typedef struct { uint32_t start, size; char *name; } Obj;
static Obj *objs;
static int nobj;

static void loadObjects(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) { perror(path); exit(1); }
	int cap = 1 << 13;
	objs = malloc(cap * sizeof(Obj));
	char name[4096];
	unsigned s, n;
	while (fscanf(f, "%x %x %4095s", &s, &n, name) == 3) {
		if (nobj == cap) { cap *= 2; objs = realloc(objs, cap * sizeof(Obj)); }
		objs[nobj].start = s; objs[nobj].size = n; objs[nobj].name = strdup(name); nobj++;
	}
	fclose(f);
}

/* Objects are indexed 0..nobj-1; a page outside every object is nobj + its 4 KB page number in
 * the 16 MB of system RAM. */
#define PAGES 4096
static int objectOf(uint32_t addr)
{
	int lo = 0, hi = nobj - 1, k = -1;
	while (lo <= hi) {
		const int mid = (lo + hi) / 2;
		if (objs[mid].start <= addr) { k = mid; lo = mid + 1; } else hi = mid - 1;
	}
	if (k >= 0 && addr < objs[k].start + objs[k].size) return k;
	return nobj + (int)((addr & 0x00ffffffu) >> 12);
}

static void nameOf(int o, char *buf, size_t n)
{
	if (o < nobj) snprintf(buf, n, "%s", objs[o].name);
	else snprintf(buf, n, "[page %08x]", 0x8c000000u | ((uint32_t)(o - nobj) << 12));
}

/* A fully associative LRU cache of SETS lines, as the model's Lru<512>: an open-addressed table
 * from line to node and the nodes in recency order. True when the line was missing. */
#define HASH 4096u
static uint32_t lkey[SETS];
static int lprev[SETS], lnext[SETS], lslot[SETS], lhead = -1, ltail = -1, lused;
static int32_t ltable[HASH];
static uint32_t llast;

static void lruInit(void) { for (unsigned i = 0; i < HASH; i++) ltable[i] = -1; }
static void lruUnlink(int s)
{
	if (lprev[s] >= 0) lnext[lprev[s]] = lnext[s]; else lhead = lnext[s];
	if (lnext[s] >= 0) lprev[lnext[s]] = lprev[s]; else ltail = lprev[s];
}
static void lruFront(int s)
{
	lprev[s] = -1; lnext[s] = lhead;
	if (lhead >= 0) lprev[lhead] = s;
	lhead = s;
	if (ltail < 0) ltail = s;
}
static void lruRemoveKey(int node)
{
	uint32_t g = (uint32_t)lslot[node];
	ltable[g] = -1;
	uint32_t j = (g + 1) % HASH;
	while (ltable[j] >= 0) {
		const int n2 = ltable[j];
		ltable[j] = -1;
		uint32_t k2 = (lkey[n2] * 2654435761u) % HASH;
		while (ltable[k2] >= 0) k2 = (k2 + 1) % HASH;
		ltable[k2] = n2; lslot[n2] = (int)k2;
		j = (j + 1) % HASH;
	}
}
static int lruTouch(uint32_t line)
{
	if (line == llast) return 0;
	llast = line;
	uint32_t h = (line * 2654435761u) % HASH;
	while (ltable[h] >= 0) {
		const int node = ltable[h];
		if (lkey[node] == line) {
			if (node != lhead) { lruUnlink(node); lruFront(node); }
			return 0;
		}
		h = (h + 1) % HASH;
	}
	int node;
	if (lused < (int)SETS) node = lused++;
	else { node = ltail; lruUnlink(node); lruRemoveKey(node); }
	lkey[node] = line;
	uint32_t k2 = (line * 2654435761u) % HASH;
	while (ltable[k2] >= 0) k2 = (k2 + 1) % HASH;
	ltable[k2] = node; lslot[node] = (int)k2;
	lruFront(node);
	return 1;
}

typedef struct { uint64_t acc, miss, fa, wb; } Count;
typedef struct { uint64_t n; int in, out; } Pair;

static Count *countBase;
static int byMissIdx(const void *a, const void *b)
{
	const Count *x = &countBase[*(const int *)a], *y = &countBase[*(const int *)b];
	return x->miss < y->miss ? 1 : x->miss > y->miss ? -1 : 0;
}

/* ---- stack ---- */
static const uint32_t *gTrace;
static size_t gEvents;
static uint32_t gStackFrom;

/* Direct-mapped misses and write-backs over the first gEvents entries with the stack moved down
 * `shift` lines; the model's semantics for every kind of access. */
static void replayShift(uint32_t shift, uint64_t *misses, uint64_t *wbs)
{
	uint32_t tag[SETS];
	uint8_t dirty[SETS];
	memset(tag, 0, sizeof tag);
	memset(dirty, 0, sizeof dirty);
	uint64_t m = 0, w = 0;
	const uint32_t delta = shift * LINE;
	for (size_t k = 0; k < gEvents; k++) {
		const uint32_t e = gTrace[k], kind = e >> 29;
		uint32_t pa = e & 0x1fffffffu;
		if ((0x80000000u | pa) >= gStackFrom) pa -= delta;
		const uint32_t t = (pa & ~31u) | 1, set = (pa >> 5) & (SETS - 1);
		switch (kind) {
		case OT_READ: case OT_WRITE:
			if (tag[set] != t) { if (dirty[set]) w++; tag[set] = t; dirty[set] = 0; m++; }
			if (kind == OT_WRITE) dirty[set] = 1;
			break;
		case OT_MOVCA: case OT_PREF:
			if (tag[set] != t) { if (dirty[set]) w++; tag[set] = t; dirty[set] = 0; }
			break;
		case OT_OCBI: if (tag[set] == t) { tag[set] = 0; dirty[set] = 0; } break;
		case OT_OCBP: if (tag[set] == t) { if (dirty[set]) w++; tag[set] = 0; dirty[set] = 0; } break;
		case OT_OCBWB: if (tag[set] == t && dirty[set]) { w++; dirty[set] = 0; } break;
		}
	}
	*misses = m; *wbs = w;
}

typedef struct { uint32_t from, to; uint64_t *m, *w; } ShiftJob;
static void *shiftWorker(void *arg)
{
	ShiftJob *j = arg;
	for (uint32_t s = j->from; s < j->to; s++) replayShift(s, &j->m[s], &j->w[s]);
	return NULL;
}

static uint32_t *loadTrace(const char *path, size_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(1); }
	fseek(f, 0, SEEK_END);
	*n = (size_t)ftell(f) / 4;
	fseek(f, 0, SEEK_SET);
	uint32_t *tr = malloc(*n * 4);
	if (fread(tr, 4, *n, f) != *n) { fprintf(stderr, "short read\n"); exit(1); }
	fclose(f);
	return tr;
}

static int stackMode(int argc, char **argv)
{
	size_t n;
	gTrace = loadTrace(argv[2], &n);
	gStackFrom = (uint32_t)strtoul(argv[4], NULL, 16);
	gEvents = argc > 5 ? (size_t)strtoull(argv[5], NULL, 10) : n;
	if (gEvents > n) gEvents = n;
	enum { THREADS = 10 };
	uint64_t m[SETS], w[SETS];
	pthread_t th[THREADS];
	ShiftJob jobs[THREADS];
	for (int t = 0; t < THREADS; t++) {
		jobs[t] = (ShiftJob){ SETS * t / THREADS, SETS * (t + 1) / THREADS, m, w };
		pthread_create(&th[t], NULL, shiftWorker, &jobs[t]);
	}
	for (int t = 0; t < THREADS; t++) pthread_join(th[t], NULL);
	const double base = 24.0 * (double)m[0] + 12.0 * (double)w[0];
	printf("stack from %08x, %zu entries: shift 0 misses %llu write-backs %llu (%.1f M cycles)\n", gStackFrom,
	       gEvents, (unsigned long long)m[0], (unsigned long long)w[0], base / 1e6);
	int order[SETS];
	for (int i = 0; i < (int)SETS; i++) order[i] = i;
	for (int i = 0; i < (int)SETS; i++)
		for (int j = i + 1; j < (int)SETS; j++) {
			const double ci = 24.0 * (double)m[order[i]] + 12.0 * (double)w[order[i]];
			const double cj = 24.0 * (double)m[order[j]] + 12.0 * (double)w[order[j]];
			if (cj < ci) { int t = order[i]; order[i] = order[j]; order[j] = t; }
		}
	if (getenv("OSIM_ALL")) {
		for (int sft = 0; sft < (int)SETS; sft++)
			printf("all %d %llu %llu\n", sft, (unsigned long long)m[sft], (unsigned long long)w[sft]);
		return 0;
	}
	for (int i = 0; i < 12; i++) {
		const int sft = order[i];
		const double c = 24.0 * (double)m[sft] + 12.0 * (double)w[sft];
		printf("shift %3d lines (%5d bytes): misses %llu write-backs %llu  %+.1f M cycles\n", sft, sft * LINE,
		       (unsigned long long)m[sft], (unsigned long long)w[sft], (c - base) / 1e6);
	}
	return 0;
}

/* ---- dopt: colours for data objects, over several games at once ---- */
typedef struct {
	size_t n;
	int32_t *obj;        /* the object of every entry, -1 for none */
	uint32_t *off;       /* the offset into it, or the whole address */
	uint8_t *kind;
	uint8_t *stack;      /* 1 for an address in the stack */
	uint32_t *start;     /* each object's start, as linked */
	int nobj;
	int32_t *item;       /* each object's item, or -1 */
	double weight;
} Game;
static Game *games;
static int ngames;
static uint32_t gShiftBytes;

static void loadGame(Game *g, const char *trace, const char *objects, size_t most, uint32_t stackFrom)
{
	nobj = 0; objs = NULL;
	loadObjects(objects);
	size_t n;
	uint32_t *tr = loadTrace(trace, &n);
	if (most && n > most) n = most;
	g->n = n; g->nobj = nobj;
	g->obj = malloc(n * 4); g->off = malloc(n * 4); g->kind = malloc(n); g->stack = malloc(n);
	g->start = malloc((size_t)nobj * 4);
	for (int i = 0; i < nobj; i++) g->start[i] = objs[i].start;
	for (size_t k = 0; k < n; k++) {
		const uint32_t e = tr[k], a = 0x80000000u | (e & 0x1fffffffu);
		const int o = objectOf(a);
		g->kind[k] = (uint8_t)(e >> 29);
		g->stack[k] = a >= stackFrom && o >= nobj;
		if (o < nobj) { g->obj[k] = o; g->off[k] = a - objs[o].start; }
		else { g->obj[k] = -1; g->off[k] = a; }
	}
	free(tr);
}

/* Cost (24 a fill, 12 a write-back) of game g with each item at base[item] (0: where linked). */
static double replayGame(const Game *g, const uint32_t *base)
{
	uint32_t tag[SETS];
	uint8_t dirty[SETS];
	memset(tag, 0, sizeof tag);
	memset(dirty, 0, sizeof dirty);
	uint64_t m = 0, w = 0;
	for (size_t k = 0; k < g->n; k++) {
		uint32_t a;
		const int32_t o = g->obj[k];
		if (o >= 0) {
			const int32_t it = g->item[o];
			a = (it >= 0 && base[it]) ? base[it] + g->off[k] : g->start[o] + g->off[k];
		} else a = g->stack[k] ? g->off[k] - gShiftBytes : g->off[k];
		const uint32_t t = (a & ~31u) | 1, set = (a >> 5) & (SETS - 1);
		switch (g->kind[k]) {
		case OT_READ: case OT_WRITE:
			if (tag[set] != t) { if (dirty[set]) w++; tag[set] = t; dirty[set] = 0; m++; }
			if (g->kind[k] == OT_WRITE) dirty[set] = 1;
			break;
		case OT_MOVCA: case OT_PREF:
			if (tag[set] != t) { if (dirty[set]) w++; tag[set] = t; dirty[set] = 0; }
			break;
		case OT_OCBI: if (tag[set] == t) { tag[set] = 0; dirty[set] = 0; } break;
		case OT_OCBP: if (tag[set] == t) { if (dirty[set]) w++; tag[set] = 0; dirty[set] = 0; } break;
		case OT_OCBWB: if (tag[set] == t && dirty[set]) { w++; dirty[set] = 0; } break;
		}
	}
	return 24.0 * (double)m + 12.0 * (double)w;
}

static double replayAll(const uint32_t *base)
{
	double c = 0;
	for (int g = 0; g < ngames; g++) c += games[g].weight * replayGame(&games[g], base);
	return c;
}

static uint32_t itemBase(int item, int colour, uint32_t linkedStart)
{
	return 0xA0000000u + (uint32_t)item * 0x400000u + (uint32_t)colour * LINE + (linkedStart % LINE);
}

static int nitems;
static uint32_t *itemStart;   /* the linked start in the first game that has it, for its lead */
static int *itemFixed;        /* per item: -1 free, 0..511 that colour only, 1000+c c or c+256 */
typedef struct { const uint32_t *base; int item, from, to; double best; int bestColour; } DJob;
static void *dWorker(void *arg)
{
	DJob *j = arg;
	uint32_t *mine = malloc((size_t)nitems * 4);
	memcpy(mine, j->base, (size_t)nitems * 4);
	j->best = 1e300;
	const int fx = itemFixed[j->item];
	for (int c = j->from; c < j->to; c++) {
		if (fx >= 0 && fx < 1000 && c != fx) continue;
		if (fx >= 1000 && (c & 255) != fx - 1000) continue;
		mine[j->item] = itemBase(j->item, c, itemStart[j->item]);
		const double v = replayAll(mine);
		if (v < j->best) { j->best = v; j->bestColour = c; }
	}
	free(mine);
	return NULL;
}

static int doptMode(int argc, char **argv)
{
	/* dopt <items> <k> <rounds> <events> <out> <stack-from> <shift> (<otrace> <objects>)+ */
	const int k = atoi(argv[3]), rounds = atoi(argv[4]);
	const size_t events = (size_t)strtoull(argv[5], NULL, 10);
	const uint32_t stackFrom = (uint32_t)strtoul(argv[7], NULL, 16);
	gShiftBytes = (uint32_t)atoi(argv[8]) * LINE;
	ngames = (argc - 9) / 2;
	games = calloc((size_t)ngames, sizeof(Game));
	/* The item names. */
	char **names = malloc(4096 * sizeof(char *));
	int *fixedIn = malloc(4096 * sizeof(int));
	int nn = 0;
	FILE *f = fopen(argv[2], "r");
	if (!f) { perror(argv[2]); return 1; }
	char line[4096];
	while (fgets(line, sizeof line, f) && nn < 4096) {
		line[strcspn(line, "\r\n")] = 0;
		if (!line[0] || line[0] == '#') continue;
		fixedIn[nn] = -1;
		char *sp = strpbrk(line, " \t");
		if (sp) {
			*sp++ = 0;
			while (*sp == ' ' || *sp == '\t') sp++;
			if (*sp == '=') fixedIn[nn] = atoi(sp + 1) & (SETS - 1);
			else if (*sp == '~') fixedIn[nn] = 1000 + (atoi(sp + 1) & 255);
		}
		names[nn++] = strdup(line);
	}
	fclose(f);
	/* Accesses per item over all games, to rank them. */
	uint64_t *acc = calloc((size_t)nn, 8);
	itemStart = calloc((size_t)nn, 4);
	for (int g = 0; g < ngames; g++) {
		loadGame(&games[g], argv[9 + 2 * g], argv[10 + 2 * g], events, stackFrom);
		games[g].item = malloc((size_t)games[g].nobj * 4);
		for (int o = 0; o < games[g].nobj; o++) {
			games[g].item[o] = -1;
			const char *sec = strchr(objs[o].name, '|');
			if (!sec) continue;
			sec++;
			const size_t len = strcspn(sec, "|");
			for (int i = 0; i < nn; i++)
				if (strlen(names[i]) == len && !strncmp(names[i], sec, len)) {
					games[g].item[o] = i;
					if (!itemStart[i]) itemStart[i] = objs[o].start;
					break;
				}
		}
		for (size_t e = 0; e < games[g].n; e++)
			if (games[g].obj[e] >= 0 && games[g].item[games[g].obj[e]] >= 0) acc[games[g].item[games[g].obj[e]]]++;
	}
	/* Rank the items by accesses and keep the first k; the rest stay where they are linked. */
	int *order = malloc((size_t)nn * sizeof(int));
	for (int i = 0; i < nn; i++) order[i] = i;
	for (int i = 0; i < nn; i++)
		for (int j = i + 1; j < nn; j++)
			if (acc[order[j]] > acc[order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
	if (k < nn) nn = k;
	/* Renumber: item r is names[order[r]]. */
	int *rank = malloc(4096 * sizeof(int));
	for (int i = 0; i < 4096; i++) rank[i] = -1;
	for (int r = 0; r < nn; r++) rank[order[r]] = r;
	for (int g = 0; g < ngames; g++)
		for (int o = 0; o < games[g].nobj; o++)
			games[g].item[o] = games[g].item[o] >= 0 ? rank[games[g].item[o]] : -1;
	uint32_t *starts = calloc((size_t)nn, 4);
	for (int r = 0; r < nn; r++) starts[r] = itemStart[order[r]];
	itemStart = starts;
	itemFixed = malloc((size_t)nn * sizeof(int));
	for (int r = 0; r < nn; r++) itemFixed[r] = fixedIn[order[r]];
	nitems = nn;
	uint32_t *base = calloc((size_t)nn, 4);
	for (int g = 0; g < ngames; g++) {
		games[g].weight = 1.0;
		const double c0 = replayGame(&games[g], base);
		games[g].weight = 1.0 / c0;
		printf("game %d: %zu entries, cost as linked %.1f M cycles\n", g, games[g].n, c0 / 1e6);
	}
	/* Every item gets one colour for every game — a global layout re-lists .data and .bss, so none
	 * stays where one game linked it. Start each at its colour in the first game that has it. */
	for (int r = 0; r < nn; r++) {
		int c = (int)((itemStart[r] >> 5) & (SETS - 1));
		if (itemFixed[r] >= 0 && itemFixed[r] < 1000) c = itemFixed[r];
		else if (itemFixed[r] >= 1000) c = (itemFixed[r] - 1000) | (c & 256);
		base[r] = itemBase(r, c, itemStart[r]);
	}
	double current = replayAll(base);
	printf("start: %.4f (1.0 a game as linked; every item at the first game's colour)\n", current);
	enum { THREADS = 10 };
	for (int rd = 0; rd < rounds; rd++) {
		for (int it = 0; it < nn; it++) {
			pthread_t th[THREADS];
			DJob jobs[THREADS];
			for (int t = 0; t < THREADS; t++) {
				jobs[t] = (DJob){ base, it, (int)(SETS * t / THREADS), (int)(SETS * (t + 1) / THREADS), 0, 0 };
				pthread_create(&th[t], NULL, dWorker, &jobs[t]);
			}
			double best = 1e300;
			int bestColour = 0;
			for (int t = 0; t < THREADS; t++) {
				pthread_join(th[t], NULL);
				if (jobs[t].best < best) { best = jobs[t].best; bestColour = jobs[t].bestColour; }
			}
			if (best < current) { base[it] = itemBase(it, bestColour, itemStart[it]); current = best; }
		}
		printf("round %d: %.4f\n", rd + 1, current);
		fflush(stdout);
	}
	for (int g = 0; g < ngames; g++)
		printf("game %d: %.4f of its cost as linked\n", g, games[g].weight * replayGame(&games[g], base));
	FILE *o = fopen(argv[6], "w");
	for (int r = 0; r < nn; r++) fprintf(o, "%u %s\n", (base[r] / LINE) % SETS, names[order[r]]);
	fclose(o);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 11 && !strcmp(argv[1], "dopt")) return doptMode(argc, argv);
	if (argc >= 5 && !strcmp(argv[1], "stack")) { loadObjects(argv[3]); return stackMode(argc, argv); }
	if (argc < 4 || strcmp(argv[1], "stat")) { fprintf(stderr, "usage: see the header of scripts/dc-ocache-sim.c\n"); return 2; }
	const int top = argc > 4 ? atoi(argv[4]) : 30;
	loadObjects(argv[3]);
	size_t n;
	uint32_t *tr = loadTrace(argv[2], &n);

	const int nid = nobj + PAGES;
	Count *c = calloc(nid, sizeof(Count));
	/* Conflict misses by (incoming object, victim object): a hash of pairs. */
	const size_t PH = 1u << 20;
	Pair *pairs = calloc(PH, sizeof(Pair));
	/* Busiest lines: per line of the 16 MB, misses. */
	uint32_t *lineMiss = calloc(1u << 19, 4), *lineConf = calloc(1u << 19, 4);

	uint32_t tag[SETS];
	int dirty[SETS], owner[SETS];
	memset(tag, 0, sizeof tag);
	memset(dirty, 0, sizeof dirty);
	for (unsigned i = 0; i < SETS; i++) owner[i] = -1;
	lruInit();
	uint64_t nMiss = 0, nWb = 0, nFa = 0, nConf = 0, kinds[8] = {0};

	for (size_t k = 0; k < n; k++) {
		const uint32_t e = tr[k], kind = e >> 29, pa = e & 0x1fffffffu, line = pa & ~31u;
		const uint32_t addr = 0x80000000u | pa;
		const uint32_t set = (line >> 5) & (SETS - 1);
		const uint32_t t = line | 1;
		const int o = objectOf(addr);
		kinds[kind & 7]++;
		c[o].acc++;
		int faMiss = 0;
		if (kind == OT_READ || kind == OT_WRITE) { faMiss = lruTouch(t); if (faMiss) { c[o].fa++; nFa++; } }
		switch (kind) {
		case OT_READ: case OT_WRITE:
			if (tag[set] != t) {
				if (dirty[set]) { nWb++; if (owner[set] >= 0) c[owner[set]].wb++; }
				const int victim = owner[set];
				tag[set] = t; dirty[set] = 0; owner[set] = o;
				nMiss++; c[o].miss++;
				lineMiss[(line & 0x00ffffffu) >> 5]++;
				if (!faMiss && victim >= 0) {
					nConf++;
					lineConf[(line & 0x00ffffffu) >> 5]++;
					size_t h = ((size_t)o * 1000003u + (size_t)victim) & (PH - 1);
					while (pairs[h].n && (pairs[h].in != o || pairs[h].out != victim)) h = (h + 1) & (PH - 1);
					pairs[h].in = o; pairs[h].out = victim; pairs[h].n++;
				}
			}
			if (kind == OT_WRITE) dirty[set] = 1;
			break;
		case OT_MOVCA:
			if (tag[set] != t) {
				if (dirty[set]) { nWb++; if (owner[set] >= 0) c[owner[set]].wb++; }
				tag[set] = t; dirty[set] = 0; owner[set] = o;
			}
			break;
		case OT_PREF:
			if (tag[set] != t) {
				if (dirty[set]) { nWb++; if (owner[set] >= 0) c[owner[set]].wb++; }
				tag[set] = t; dirty[set] = 0; owner[set] = o;
			}
			break;
		case OT_OCBI:
			if (tag[set] == t) { tag[set] = 0; dirty[set] = 0; owner[set] = -1; }
			break;
		case OT_OCBP:
			if (tag[set] == t) {
				if (dirty[set]) { nWb++; c[o].wb++; }
				tag[set] = 0; dirty[set] = 0; owner[set] = -1;
			}
			break;
		case OT_OCBWB:
			if (tag[set] == t && dirty[set]) { nWb++; c[o].wb++; dirty[set] = 0; }
			break;
		}
	}
	printf("entries %zu (read %llu write %llu movca %llu pref %llu ocb %llu)\n", n,
	       (unsigned long long)kinds[0], (unsigned long long)kinds[1], (unsigned long long)kinds[2],
	       (unsigned long long)kinds[3], (unsigned long long)(kinds[4] + kinds[5] + kinds[6]));
	printf("direct-mapped misses %llu  write-backs %llu  fully associative misses %llu  conflicts %llu (%.1f %%)\n",
	       (unsigned long long)nMiss, (unsigned long long)nWb, (unsigned long long)nFa,
	       (unsigned long long)(nMiss > nFa ? nMiss - nFa : 0), nMiss ? 100.0 * (double)(nMiss - nFa) / (double)nMiss : 0.0);
	printf("cycles at 24 a fill and 12 a write-back: %.1f M, of which conflicts %.1f M\n\n",
	       (24.0 * (double)nMiss + 12.0 * (double)nWb) / 1e6, 24.0 * (double)(nMiss > nFa ? nMiss - nFa : 0) / 1e6);

	int *idx = malloc(nid * sizeof(int));
	int m = 0;
	for (int i = 0; i < nid; i++) if (c[i].acc) idx[m++] = i;
	countBase = c;
	qsort(idx, m, sizeof(int), byMissIdx);
	printf("%10s %10s %10s %10s %10s  %s\n", "entries", "misses", "fa", "conflicts", "wb", "object");
	char nm[4200];
	for (int i = 0; i < m && i < top; i++) {
		const Count *x = &c[idx[i]];
		nameOf(idx[i], nm, sizeof nm);
		printf("%10llu %10llu %10llu %10lld %10llu  %s\n", (unsigned long long)x->acc, (unsigned long long)x->miss,
		       (unsigned long long)x->fa, (long long)x->miss - (long long)x->fa, (unsigned long long)x->wb, nm);
	}
	if (argc > 5) {
		FILE *cf = fopen(argv[5], "w");
		if (!cf) { perror(argv[5]); return 1; }
		for (int i = 0; i < m; i++) {
			const Count *x = &c[idx[i]];
			nameOf(idx[i], nm, sizeof nm);
			const uint32_t st = idx[i] < nobj ? objs[idx[i]].start : 0x8c000000u | ((uint32_t)(idx[i] - nobj) << 12);
			const uint32_t sz = idx[i] < nobj ? objs[idx[i]].size : 4096u;
			fprintf(cf, "%llu %llu %llu %llu %08x %x %s\n", (unsigned long long)x->acc, (unsigned long long)x->miss,
			        (unsigned long long)x->fa, (unsigned long long)x->wb, st, sz, nm);
		}
		fclose(cf);
	}
	/* The pairs that evict each other most. */
	Pair *pl = malloc(PH * sizeof(Pair));
	size_t np = 0;
	for (size_t i = 0; i < PH; i++) if (pairs[i].n) pl[np++] = pairs[i];
	for (size_t i = 0; i < np && i < (size_t)top; i++)
		for (size_t j = i + 1; j < np; j++)
			if (pl[j].n > pl[i].n) { Pair t = pl[i]; pl[i] = pl[j]; pl[j] = t; }
	printf("\nconflict misses by (incoming, evicted), %llu in all:\n", (unsigned long long)nConf);
	for (size_t i = 0; i < np && i < (size_t)top; i++) {
		char a[4200], b[4200];
		nameOf(pl[i].in, a, sizeof a);
		nameOf(pl[i].out, b, sizeof b);
		printf("%10llu  %s  <-  %s\n", (unsigned long long)pl[i].n, a, b);
	}
	/* The lines with the most conflict misses. */
	printf("\nlines with the most conflict misses:\n");
	for (int r = 0; r < top; r++) {
		uint32_t best = 0, bi = 0;
		for (uint32_t i = 0; i < (1u << 19); i++) if (lineConf[i] > best) { best = lineConf[i]; bi = i; }
		if (!best) break;
		const uint32_t a = 0x8c000000u | (bi << 5);
		nameOf(objectOf(a), nm, sizeof nm);
		printf("%08x set %3u  conflicts %8u  misses %8u  %s\n", a, (a >> 5) & (SETS - 1), best, lineMiss[bi], nm);
		lineConf[bi] = 0;
	}
	return 0;
}
