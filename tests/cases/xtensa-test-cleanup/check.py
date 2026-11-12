#!/usr/bin/env python3
"""Run the offline test normally and with failure after its first installation."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
compiler = Path(os.path.abspath(sys.argv[1]))
out = root / 'build/xtensa-companion-offline'
test = root / 'tools/test-xtensa-companion-offline.sh'


def check_output(remove=True):
    assert (out / 'target/23.1.3-1').is_dir(), 'fixture was not installed'
    for parent, dirs, files in os.walk(out, followlinks=False):
        for path in [Path(parent), *(Path(parent) / n for n in dirs + files)]:
            mode = path.lstat().st_mode
            if not stat.S_ISLNK(mode):
                assert mode & stat.S_IWUSR, f'not owner-writable: {path}'
    if remove:
        shutil.rmtree(out)


with tempfile.TemporaryDirectory(prefix='xtensa-cleanup-') as temp:
    wrapper = Path(temp) / 'compiler'
    wrapper.write_text('''#!/usr/bin/env bash
set -euo pipefail
"$REAL_COMPILER" "$@"
while [[ $# -gt 0 ]]; do
    if [[ $1 == -o ]]; then output=$2; break; fi
    shift
done
mv "$output" "$output.real"
cat > "$output" <<'EOF'
#!/bin/sh
"$0.real" "$@" || exit $?
exit 99
EOF
chmod +x "$output"
''')
    wrapper.chmod(0o755)
    env = dict(os.environ, REAL_COMPILER=str(compiler))
    result = subprocess.run([test, wrapper], cwd=root, env=env, check=False)
    assert result.returncode == 99, f'failure control returned {result.returncode}'
    check_output()
    subprocess.run([test, compiler], cwd=root, check=True)
    check_output(remove=False)
print('xtensa cleanup: success and injected failure leave removable output')
