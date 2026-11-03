#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/wrapper-demand"
mkdir -p "$out"
"$compiler" --emit-llvm tests/cases/wrapper-demand/main.ab > "$out/main.ll"
python3 - "$out/main.ll" <<'PY'
import re, sys
ir = open(sys.argv[1]).read()
attrs = dict(re.findall(r'attributes #(\d+) = .*?"abla.source"="([^"]+)"', ir))
for line in ir.splitlines():
    if not line.startswith('define '):
        continue
    match = re.search(r'@(abla_fn_\d+_\d+)_direct\([^\n]*#(\d+)\s*\{', line)
    if match and attrs.get(match.group(2)) == 'Counter_unused':
        wrapper = match.group(1)
        if re.search(r'^define .*@' + wrapper + r'\(', ir, re.M):
            raise SystemExit('unused boxed wrapper was emitted')
        break
else:
    raise SystemExit('fixture did not lower its unused method')
PY
"$compiler" build tests/cases/wrapper-demand/main.ab -o "$out/main" --fast --no-cache
"$out/main"
"$compiler" build tests/cases/internal-function.ab -o "$out/internal" --fast --no-cache
"$out/internal"
echo 'only demanded boxed wrappers are emitted; callback chain and retained entries work'
