#!/usr/bin/env bash
# Rebuild the browser bundle from the generic generator and current runtime sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/env.sh
[ $# -eq 1 ] || { echo "usage: scripts/build-web.sh <game-id | games/id/game.json>" >&2; exit 2; }
CONFIG="$1"
if [[ "$CONFIG" != *.json ]]; then CONFIG="games/$CONFIG/game.json"; fi
mkdir -p out/_web/gen web
./scripts/recompsx.sh gen "$CONFIG" --out out/_web/gen
haxe build/game-web.hxml
python3 - "$CONFIG" <<'PY'
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
root = Path.cwd()
bundle = root / 'out/_web/game.js'
digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
config = json.loads(Path(sys.argv[1]).read_text())
source = hashlib.sha256()
inputs = [p for directory in ('tools/recomp/src', 'src/runtime', 'src/shims/js', 'shared')
          for p in (root / directory).rglob('*.hx')]
inputs += [root / p for p in ('build/common.hxml', 'build/game-web.hxml',
                              'tests/spike/GenMain.hx', sys.argv[1])]
for p in sorted(set(inputs)):
    source.update(p.relative_to(root).as_posix().encode() + b'\0' + p.read_bytes())
git = lambda *args: subprocess.check_output(['git', *args], text=True).strip()

manifest = {'version': digest[:12], 'sha256': digest, 'title': config.get('title', 'recompsx'),
            'cooperative': True, 'regions': True, 'bytes': bundle.stat().st_size,
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
print('browser build ' + manifest['version'] + ' — current IR/regions, cooperative main thread')
PY
