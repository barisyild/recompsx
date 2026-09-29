/* scripts/dc-icache-sim.c — the SH-4's instruction cache over a trace, under a placement of the code.
 *
 * The cache model (scripts/dc-flycast-model.sh) with RXTRACE=<n> writes <prof>.cache.itrace: the
 * address of every instruction that entered a new cache line while recording. A direct-mapped cache
 * misses exactly on the entries whose line is not the one its set holds, so the trace replayed
 * against another placement of the same code says what that placement would miss, in milliseconds
 * rather than in a twenty-minute model run. scripts/dc-layout.py writes the sections file and reads
 * the colours back.
 *
 *   dc-icache-sim sim <trace> <sections>
 *       misses of the 8 KB direct-mapped cache with every section at its new address, and of a
 *       fully associative LRU cache of the same size, which no placement changes
 *   dc-icache-sim opt <trace> <sections> <k> <rounds> <events> <out>
 *       colours (line index mod 256) for the k most fetched sections, each in turn set to the
 *       colour that misses least with the others where they are, `rounds` times over the first
 *       `events` entries of the trace; written to <out> as "index colour" lines
 *
 * <sections>: one line per .text input section of the traced link, "oldstart size newstart" in
 * hex, sorted by oldstart; the index of a line is the section's number in <out>. A section keeps
 * its offset into its first line (oldstart mod 32) wherever it goes.
 *
 * Build: cc -O2 -o dc-icache-sim scripts/dc-icache-sim.c -lpthread
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE 32u
#define SETS 256u

static uint32_t *oldStart, *size, *newStart;
static int nsec;
static int32_t *evSec;
static uint32_t *evOff;
static size_t nev;

static void loadSections(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) { perror(path); exit(1); }
	int cap = 1 << 14;
	oldStart = malloc(cap * 4); size = malloc(cap * 4); newStart = malloc(cap * 4);
	unsigned a, s, n;
	while (fscanf(f, "%x %x %x", &a, &s, &n) == 3) {
		if (nsec == cap) {
			cap *= 2;
			oldStart = realloc(oldStart, cap * 4); size = realloc(size, cap * 4); newStart = realloc(newStart, cap * 4);
		}
		oldStart[nsec] = a; size[nsec] = s; newStart[nsec] = n; nsec++;
	}
	fclose(f);
}

/* Every entry as (section, offset into it); -1 for an address outside every section. */
static void loadTrace(const char *path, size_t most)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(1); }
	fseek(f, 0, SEEK_END);
	size_t n = (size_t)ftell(f) / 4;
	fseek(f, 0, SEEK_SET);
	if (most && n > most) n = most;
	uint32_t *pc = malloc(n * 4);
	if (fread(pc, 4, n, f) != n) { fprintf(stderr, "short read\n"); exit(1); }
	fclose(f);
	evSec = malloc(n * 4);
	evOff = malloc(n * 4);
	for (size_t i = 0; i < n; i++) {
		int lo = 0, hi = nsec - 1, k = -1;
		while (lo <= hi) {
			int mid = (lo + hi) / 2;
			if (oldStart[mid] <= pc[i]) { k = mid; lo = mid + 1; } else hi = mid - 1;
		}
		if (k >= 0 && pc[i] < oldStart[k] + size[k]) { evSec[i] = k; evOff[i] = pc[i] - oldStart[k]; }
		else { evSec[i] = -1; evOff[i] = pc[i]; }
	}
	free(pc);
	nev = n;
}

/* Direct-mapped misses over the first `n` entries with each section based at base[]. */
static size_t simulate(const uint32_t *base, size_t n)
{
	uint32_t tag[SETS];
	memset(tag, 0xff, sizeof tag);
	size_t miss = 0;
	for (size_t i = 0; i < n; i++) {
		const int32_t s = evSec[i];
		const uint32_t line = (s >= 0 ? base[s] + evOff[i] : evOff[i]) / LINE;
		const uint32_t set = line % SETS;
		if (tag[set] != line) { tag[set] = line; miss++; }
	}
	return miss;
}

/* A fully associative LRU cache of SETS lines over the whole trace: what placement cannot change.
 * An open-addressed table from line to node, and the nodes in recency order. */
#define HASH 4096u
static size_t simulateLru(const uint32_t *base)
{
	uint32_t key[SETS];
	int prev[SETS], next[SETS], slotOf[SETS];
	int32_t table[HASH];
	for (unsigned i = 0; i < HASH; i++) table[i] = -1;
	int head = -1, tail = -1, used = 0;
	size_t miss = 0;
	for (size_t i = 0; i < nev; i++) {
		const int32_t s = evSec[i];
		const uint32_t line = (s >= 0 ? base[s] + evOff[i] : evOff[i]) / LINE;
		uint32_t h = (line * 2654435761u) % HASH;
		int node = -1;
		while (table[h] >= 0) {
			if (key[table[h]] == line) { node = table[h]; break; }
			h = (h + 1) % HASH;
		}
		if (node < 0) {
			miss++;
			if (used < (int)SETS) node = used++;
			else {
				node = tail;
				/* out of the table: remove, then re-insert the probe run after it */
				uint32_t g = (uint32_t)slotOf[node];
				table[g] = -1;
				uint32_t j = (g + 1) % HASH;
				while (table[j] >= 0) {
					const int n2 = table[j];
					table[j] = -1;
					uint32_t k2 = (key[n2] * 2654435761u) % HASH;
					while (table[k2] >= 0) k2 = (k2 + 1) % HASH;
					table[k2] = n2; slotOf[n2] = (int)k2;
					j = (j + 1) % HASH;
				}
				tail = prev[node];
				if (tail >= 0) next[tail] = -1; else head = -1;
			}
			key[node] = line;
			uint32_t k2 = (line * 2654435761u) % HASH;
			while (table[k2] >= 0) k2 = (k2 + 1) % HASH;
			table[k2] = node; slotOf[node] = (int)k2;
			prev[node] = -1; next[node] = head;
			if (head >= 0) prev[head] = node;
			head = node;
			if (tail < 0) tail = node;
		} else if (node != head) {
			if (prev[node] >= 0) next[prev[node]] = next[node];
			if (next[node] >= 0) prev[next[node]] = prev[node]; else tail = prev[node];
			prev[node] = -1; next[node] = head;
			prev[head] = node;
			head = node;
		}
	}
	return miss;
}

/* ---- opt ---- */
typedef struct { const uint32_t *base; int sec, rank; int from, to; size_t n; size_t best; int bestColour; } Job;

/* A moved section's address with colour `c`: its own megabyte far from the real code, so that no
 * two sections ever share a line by accident, at `c` lines plus its offset into its first line. */
static uint32_t placed(int rank, int sec, int c)
{
	return 0xA0000000u + (uint32_t)rank * 0x100000u + (uint32_t)c * LINE + oldStart[sec] % LINE;
}

static void *tryColours(void *arg)
{
	Job *j = arg;
	uint32_t *mine = malloc(nsec * 4);
	memcpy(mine, j->base, nsec * 4);
	j->best = (size_t)-1;
	for (int c = j->from; c < j->to; c++) {
		mine[j->sec] = placed(j->rank, j->sec, c);
		const size_t m = simulate(mine, j->n);
		if (m < j->best) { j->best = m; j->bestColour = c; }
	}
	free(mine);
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc < 4) { fprintf(stderr, "usage: see the header of scripts/dc-icache-sim.c\n"); return 2; }
	loadSections(argv[3]);
	if (!strcmp(argv[1], "sim")) {
		loadTrace(argv[2], 0);
		const size_t dm = simulate(newStart, nev);
		const size_t lru = simulateLru(newStart);
		printf("entries %zu  direct-mapped misses %zu  fully associative LRU %zu  conflicts %zu\n",
		       nev, dm, lru, dm > lru ? dm - lru : 0);
		return 0;
	}
	if (strcmp(argv[1], "opt") || argc < 8) { fprintf(stderr, "usage: see the header\n"); return 2; }
	const int k = atoi(argv[4]), rounds = atoi(argv[5]);
	loadTrace(argv[2], (size_t)strtoull(argv[6], NULL, 10));
	/* The k sections with the most entries, most first. */
	size_t *count = calloc(nsec, sizeof(size_t));
	for (size_t i = 0; i < nev; i++) if (evSec[i] >= 0) count[evSec[i]]++;
	int *order = malloc(nsec * sizeof(int));
	for (int i = 0; i < nsec; i++) order[i] = i;
	for (int i = 0; i < nsec; i++)
		for (int j = i + 1; j < nsec; j++)
			if (count[order[j]] > count[order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
	uint32_t *base = malloc(nsec * 4);
	memcpy(base, newStart, nsec * 4);
	size_t current = simulate(base, nev);
	printf("start: %zu misses over %zu entries\n", current, nev);
	enum { THREADS = 10 };
	for (int r = 0; r < rounds; r++) {
		for (int q = 0; q < k && q < nsec; q++) {
			const int s = order[q];
			if (!count[s]) break;
			pthread_t th[THREADS];
			Job jobs[THREADS];
			for (int t = 0; t < THREADS; t++) {
				jobs[t] = (Job){ base, s, q, (int)(SETS * t / THREADS), (int)(SETS * (t + 1) / THREADS), nev, 0, 0 };
				pthread_create(&th[t], NULL, tryColours, &jobs[t]);
			}
			size_t best = (size_t)-1;
			int bestColour = 0;
			for (int t = 0; t < THREADS; t++) {
				pthread_join(th[t], NULL);
				if (jobs[t].best < best) { best = jobs[t].best; bestColour = jobs[t].bestColour; }
			}
			if (best < current) {
				base[s] = placed(q, s, bestColour);
				current = best;
			}
		}
		printf("round %d: %zu misses\n", r + 1, current);
		fflush(stdout);
	}
	FILE *o = fopen(argv[7], "w");
	for (int q = 0; q < k && q < nsec; q++) {
		const int s = order[q];
		if (!count[s]) break;
		fprintf(o, "%d %u\n", s, (base[s] / LINE) % SETS);
	}
	fclose(o);
	return 0;
}
