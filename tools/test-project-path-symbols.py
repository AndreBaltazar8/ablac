#!/usr/bin/env python3
"""Project-private names survive checkout relocation and entry path aliases."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
compiler = Path(sys.argv[1] if len(sys.argv) > 1 else root / 'build/ablac').absolute()
work = Path(tempfile.mkdtemp(prefix='project-path-symbols-', dir=root / 'build'))
env = dict(os.environ, ABLA_SYSROOT=os.environ.get('ABLA_SYSROOT', str(root)))
for key in ('ABLA_KEEP_LLVM_TEXT', 'ABLA_LLVM_OUT_OF_PROCESS'):
    env.pop(key, None)


def invoke(label, cwd, args, missing_sdk=False):
    result = subprocess.run([str(compiler), *args], cwd=cwd,
                            env=dict(env, ABLA_CACHE_DIR=str(work / 'cache' / label)),
                            capture_output=True)
    (work / (label + '.log')).write_bytes(result.stderr)
    if missing_sdk:
        assert result.returncode == 159 and b'error[E_MACOS_SDK]' in result.stderr, (label, result.returncode, result.stderr.decode())
    else:
        assert result.returncode == 0, (label, result.returncode, result.stderr.decode())
    return result.stdout


try:
    reference = {}
    for number, checkout in enumerate((work / 's', work / 'a-much-longer-checkout-directory')):
        source = checkout / 'src'
        source.mkdir(parents=True)
        (checkout / 'abla.toml').write_text('name = "project-path-symbols"\nentry = "src/main.ab"\n')
        for name, value in (('left', 190001), ('right', 230003)):
            (source / (name + '.ab')).write_text(
                f'private fun secret(): int = {value}\n'
                'fun read(): int {\n    val callback: () -> int = secret\n    callback()\n}\n')
        (source / 'main.ab').write_text(
            'import "left.ab" as left\nimport "right.ab" as right\n'
            'private fun secret(): int = 0\n'
            'fun main: int {\n'
            '    val callback: () -> int = { left.read() + right.read() + secret() }\n'
            '    if (callback() == 420004) 42 else 1\n}\n')
        link = checkout / 'entry-link.ab'
        link.symlink_to('src/main.ab')
        paths = ('src/main.ab', str(source / 'main.ab'), './src/./main.ab', str(link))
        for spelling, entry in enumerate(paths):
            label = f'{number}-{spelling}'
            ir = invoke(label + '-ir', checkout, ['--emit-llvm', entry])
            (work / (label + '.ll')).write_bytes(ir)
            # Same spelling/signature in two different modules remains distinct.
            private = {190001: set(), 230003: set()}
            for symbol, body in re.findall(rb'define[^@]*@(abla_fn_[^(]+)\([^\n]*\).*?\{(.*?)\n\}', ir, re.S):
                value = re.search(rb'\bret i64 (190001|230003)\b', body)
                if value:
                    private[int(value[1])].add(symbol)
            assert all(private.values()) and private[190001].isdisjoint(private[230003]), (label, private)
            artifacts = {'ir': ir}
            targets = [('native', []), ('fast', ['--fast', '--no-debug']),
                       ('macos', ['--target', 'arm64-macos'])]
            for target, flags in targets:
                output = work / 'program.o'
                missing_sdk = target == 'macos' and sys.platform != 'darwin' and not env.get('ABLA_MACOS_SDK')
                text = Path(str(output) + '.ll')
                text.unlink(missing_ok=True)
                invoke(label + '-' + target, checkout,
                       ['build', entry, '-o', str(output), '--emit', 'object', '--no-cache', *flags], missing_sdk=missing_sdk)
                if target == 'macos':
                    artifacts['macos-ir'] = text.read_bytes()
                    assert b'arm64-apple-macosx' in artifacts['macos-ir']
                    (work / (label + '-macos.ll')).write_bytes(artifacts['macos-ir'])
                if not missing_sdk:
                    artifacts[target] = output.read_bytes()
                    (work / (label + '-' + target + '.o')).write_bytes(artifacts[target])
            if not reference:
                reference = artifacts
            else:
                for kind, data in artifacts.items():
                    assert data == reference[kind], (label, kind, 'differs')
        output = work / 'program'
        invoke(f'{number}-run', checkout,
               ['build', str(source / 'main.ab'), '-o', str(output), '--fast', '--no-cache'])
        assert subprocess.run([str(output)], cwd=checkout).returncode == 42
except BaseException:
    print('project path symbols: artifacts and logs:', work, file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
    print('project path symbols: exact IR, native release/fast-no-debug objects and arm64-macOS IR at two checkout lengths, '
          'relative/absolute/./symlink entries; distinct private symbols and runtime passed'
          + (' (published Mach-O objects skipped: no SDK)' if sys.platform != 'darwin' and not env.get('ABLA_MACOS_SDK') else ''))
