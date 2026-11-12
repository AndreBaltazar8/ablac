#!/usr/bin/env python3
"""Run the native test normally and force failure after its fixture run."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
compiler = Path(os.path.abspath(sys.argv[1]))
out = root / 'build/xtensa-native-test'
test = root / 'tools/test-xtensa-native.sh'


def check_output(remove=True):
    assert (out / 'fixtures/good/lib/abla/xtensa-llvm/23.1.3-1').is_dir()
    for parent, dirs, files in os.walk(out, followlinks=False):
        for path in [Path(parent), *(Path(parent) / n for n in dirs + files)]:
            mode = path.lstat().st_mode
            if not stat.S_ISLNK(mode):
                assert mode & stat.S_IWUSR, f'not owner-writable: {path}'
    if remove:
        shutil.rmtree(out)


with tempfile.TemporaryDirectory(prefix='xtensa-native-cleanup-') as temp:
    wrapper = Path(temp) / 'python3'
    wrapper.write_text('''#!/usr/bin/env bash
"$REAL_PYTHON" "$@" || exit $?
case ${1-} in */tests/cases/xtensa-native/test.py) exit 99;; esac
''')
    wrapper.chmod(0o755)
    env = dict(os.environ, REAL_PYTHON=sys.executable, PATH=temp + os.pathsep + os.environ['PATH'])
    result = subprocess.run([test, compiler], cwd=root, env=env, check=False)
    assert result.returncode == 99, f'failure control returned {result.returncode}'
    check_output()
    subprocess.run([test, compiler], cwd=root, check=True)
    check_output(remove=False)
print('native cleanup: success and injected failure leave removable output')
