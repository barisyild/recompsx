#!/usr/bin/env bash
# Rebuild the browser bundle from the generic generator and current runtime sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env.sh
usage() { echo "usage: scripts/build-web.sh <SERIAL | games/SERIAL/game.json> [--mods <id,id | all>]" >&2; exit 2; }
[ $# -ge 1 ] || usage
CONFIG="$1"; shift
MODS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mods) [ $# -ge 2 ] || usage; MODS="$2"; shift 2 ;;
    *) usage ;;
  esac
done
if [[ "$CONFIG" != *.json ]]; then CONFIG="games/$CONFIG/game.json"; fi
mkdir -p out/_web/gen web
# Mods (ADR-0033): their hooks go into the generated code, their sources beside it, and the
# launcher installs them only under -D recompsx_mods.
GEN_MODS=(); HAXE_MODS=()
if [ -n "$MODS" ]; then GEN_MODS=(--mods "$MODS"); HAXE_MODS=(-D recompsx_mods); fi
./scripts/recompsx.sh gen "$CONFIG" --out out/_web/gen ${GEN_MODS[@]+"${GEN_MODS[@]}"}
haxe build/game-web.hxml ${HAXE_MODS[@]+"${HAXE_MODS[@]}"}
# Keep the direct Haxe output for diagnostics and compile the served bundle separately. SIMPLE
# preserves the generated static class ABI; ADVANCED is unsafe because the page host is a JS ABI.
mv out/_web/game.js out/_web/game.raw.js
./scripts/closure-web.sh out/_web/game.raw.js out/_web/game.js
python3 - "$CONFIG" "$MODS" <<'PY'
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
root = Path.cwd()
bundle = root / 'out/_web/game.js'
raw_bundle = root / 'out/_web/game.raw.js'
digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
config = json.loads(Path(sys.argv[1]).read_text())
source = hashlib.sha256()
inputs = [p for directory in ('tools/recomp/src', 'src/runtime', 'src/shims/js', 'shared')
          for p in (root / directory).rglob('*.hx')]
mods = [m for m in sys.argv[2].split(',') if m] if len(sys.argv) > 2 else []
mods_dir = root / Path(sys.argv[1]).parent / 'mods'
if mods and mods_dir.exists():
    inputs += [p for p in mods_dir.rglob('*') if p.is_file() and p.suffix in ('.hx', '.json')]
inputs += [root / p for p in ('build/common.hxml', 'build/game-web.hxml',
                              'tests/spike/GenMain.hx', 'package.json', 'package-lock.json',
                              'scripts/closure-web.sh', sys.argv[1])]
for p in sorted(set(inputs)):
    source.update(p.relative_to(root).as_posix().encode() + b'\0' + p.read_bytes())
git = lambda *args: subprocess.check_output(['git', *args], text=True).strip()

# The page loads the WebGL renderer under this, so a changed renderer is never served from cache.
renderer = hashlib.sha256((root / 'web/gpu-webgl.js').read_bytes()).hexdigest()[:12]
manifest = {'version': digest[:12], 'sha256': digest, 'renderer': renderer,
            'title': config.get('title', 'recompsx'),
            'cooperative': True, 'regions': True, 'mods': mods, 'bytes': bundle.stat().st_size,
            'rawBytes': raw_bundle.stat().st_size, 'closure': True,
            'branch': git('branch', '--show-current'), 'revision': git('rev-parse', 'HEAD'),
            'sourceSha256': source.hexdigest(),
            'dirty': bool(git('status', '--porcelain', '--untracked-files=normal'))}
(root / 'out/_web/build.json').write_text(json.dumps(manifest, indent=2) + '\n')
for name in ('game.js', 'build.json'):
    served = root / 'web' / name
    if served.exists() and not served.is_symlink():
        backup = root / 'out/_web' / ('previous-' + name)
        if not backup.exists(): shutil.copy2(served, backup)
    temporary = root / 'web' / ('.' + name + '.next')
    temporary.unlink(missing_ok=True)
    temporary.symlink_to('../out/_web/' + name)
    os.replace(temporary, served)
print('browser build ' + manifest['version'] + ' — current IR/regions, cooperative main thread'
      + (', mods: ' + ','.join(mods) if mods else ''))
PY
