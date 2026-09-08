#!/usr/bin/env bash
# Regenerate both emitter modes and compare the same MIPS workload on both shipped targets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env.sh
OUT=out/_codegen_bench
mkdir -p "$OUT"
haxe build/common.hxml -cp tools/recomp/src -cp tools/recomp/test -main TestCodegen --interp
haxe build/common.hxml -cp tests/bench -cp out/_codegen/fixtures -cp src/runtime \
  -cp src/shims/js -main CodegenBench -js "$OUT/bench.js" -D js-es=6 -dce full
haxe build/common.hxml build/reflaxe-cpp.hxml -cp tests/bench -cp out/_codegen/fixtures \
  -cp src/runtime -cp src/shims/cxx -D mainClass=CodegenBench -main CodegenBench \
  -D "cpp-output=$OUT/cpp" -dce full > "$OUT/cpp.log" 2>&1
./scripts/build-pc.sh _codegen_bench --null > "$OUT/native.log" 2>&1

# Host timing is kept outside guest state. Alternate order, discard one warm-up per mode,
# compare complete output, and report five-sample medians instead of a best-case run.
python3 - <<'PY'
import json, platform, statistics, subprocess, time
from pathlib import Path
root = Path('out/_codegen_bench')
results = {'host': platform.platform(), 'iterations_per_run': 50000000}
oracle = None
for target, command in [('js', ['node', str(root / 'bench.js')]),
                        ('cpp', [str(root / 'build/recompsx')])]:
    timings = {mode: [] for mode in ('reference', 'optimized')}
    output = None
    for sample in range(6):
        order = ('reference', 'optimized') if sample % 2 == 0 else ('optimized', 'reference')
        for mode in order:
            start = time.perf_counter()
            run = subprocess.run(command + [mode], capture_output=True, text=True, check=True)
            elapsed = time.perf_counter() - start
            if output is not None and run.stdout != output:
                raise SystemExit('benchmark outputs disagree: ' + run.stdout + ' vs ' + output)
            if oracle is not None and run.stdout != oracle:
                raise SystemExit('benchmark targets disagree: ' + run.stdout + ' vs ' + oracle)
            output = run.stdout
            oracle = run.stdout
            if sample:
                timings[mode].append(elapsed)
    medians = {mode: statistics.median(values) for mode, values in timings.items()}
    results[target] = {'seconds': medians, 'samples': timings,
                       'speedup': medians['reference'] / medians['optimized'],
                       'output': output.strip()}
    print(target + ': ' + json.dumps(results[target]), flush=True)
(root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
PY
