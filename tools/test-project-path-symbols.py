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


def check_artifacts(label, cwd, entry, reference):
    ir = invoke(label + '-ir', cwd, ['--emit-llvm', entry])
    (work / (label + '.ll')).write_bytes(ir)
    artifacts = {'ir': ir}
    targets = [('native', []), ('fast', ['--fast', '--no-debug']),
               ('macos', ['--target', 'arm64-macos'])]
    for target, flags in targets:
        output = work / 'program.o'
        missing_sdk = target == 'macos' and sys.platform != 'darwin' and not env.get('ABLA_MACOS_SDK')
        text = Path(str(output) + '.ll')
        text.unlink(missing_ok=True)
        invoke(label + '-' + target, cwd,
               ['build', entry, '-o', str(output), '--emit', 'object', '--no-cache', *flags], missing_sdk=missing_sdk)
        if target == 'macos':
            artifacts['macos-ir'] = text.read_bytes()
            assert b'arm64-apple-macosx' in artifacts['macos-ir']
            (work / (label + '-macos.ll')).write_bytes(artifacts['macos-ir'])
        if not missing_sdk:
            artifacts[target] = output.read_bytes()
            (work / (label + '-' + target + '.o')).write_bytes(artifacts[target])
    if not reference:
        reference.update(artifacts)
    else:
        for kind, data in artifacts.items():
            assert data == reference[kind], (label, kind, 'differs')

    return ir


def run_entry(label, cwd, entry, status=42):
    output = work / 'program'
    invoke(label, cwd, ['build', entry, '-o', str(output), '--fast', '--no-cache'])
    actual = subprocess.run([str(output)], cwd=cwd).returncode
    assert actual == status, (label, 'wrong lexical sibling', actual, status)


try:
    reference = {}
    lexical_references = {}
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
        # A directory alias preserves the lexical package structure. A file
        # alias beside src/ would intentionally have a different import base.
        link = work / f'checkout-link-{number}'
        link.symlink_to(checkout, target_is_directory=True)
        paths = ('src/main.ab', str(source / 'main.ab'), './src/./main.ab', str(link / 'src/main.ab'))
        for spelling, entry in enumerate(paths):
            label = f'{number}-{spelling}'
            ir = check_artifacts(label, checkout, entry, reference)
            # Same spelling/signature in two different modules remains distinct.
            private = {190001: set(), 230003: set()}
            for symbol, body in re.findall(rb'define[^@]*@(abla_fn_[^(]+)\([^\n]*\).*?\{(.*?)\n\}', ir, re.S):
                value = re.search(rb'\bret i64 (190001|230003)\b', body)
                if value:
                    private[int(value[1])].add(symbol)
            assert all(private.values()) and private[190001].isdisjoint(private[230003]), (label, private)
        output = work / 'program'
        invoke(f'{number}-run', checkout,
               ['build', str(source / 'main.ab'), '-o', str(output), '--fast', '--no-cache'])
        assert subprocess.run([str(output)], cwd=checkout).returncode == 42
        for scenario in ('entry-directory', 'dependency-directory', 'entry-manifest'):
            # Keep manifest-less layouts outside the normal fixture package;
            # otherwise an unrelated ancestor abla.toml changes their identity root.
            case = work / 'lexical' / checkout.name / scenario
            tree = case / 'tree'
            real = case / 'real'
            for directory in (tree / 'app', tree / 'lib', real / 'app/server',
                              real / 'app/deps', real / 'lib'):
                directory.mkdir(parents=True)
            for directory, value in ((tree / 'lib', 42), (real / 'lib', 13)):
                (directory / 'lib.ab').write_text(
                    f'private fun secret(): int = {value}\nfun read(): int = secret()\n')
            if scenario == 'dependency-directory':
                (real / 'app/deps/dependency.ab').write_text(
                    'import "../../lib/lib.ab" as sibling\nfun read(): int = sibling.read()\n')
                (tree / 'app/deps').symlink_to(real / 'app/deps', target_is_directory=True)
                (tree / 'app/main.ab').write_text(
                    'import "deps/dependency.ab" as dependency\nfun main: int = dependency.read()\n')
                relative = 'main.ab'
            else:
                (real / 'app/server/main.ab').write_text(
                    'import "../../lib/lib.ab" as sibling\nfun main: int = sibling.read()\n')
                (tree / 'app/server').symlink_to(real / 'app/server', target_is_directory=True)
                relative = 'server/main.ab'
            if scenario == 'entry-manifest':
                # Only the lexical root is valid. Looking up the physical
                # manifest must fail independently of import-base selection.
                (tree / 'app/abla.toml').write_text('name = "lexical-root"\n')
                (real / 'app/abla.toml').write_text(
                    'name = "physical-root"\n[imports]\n"./absent.ab" = "./also-absent.ab"\n')
            cwd = tree / 'app'
            tree_link = work / f'tree-link-{number}-{scenario}'
            tree_link.symlink_to(tree, target_is_directory=True)
            entries = (relative, str(cwd / relative), './' + relative,
                       str(tree_link / 'app' / relative))
            ref = lexical_references.setdefault(scenario, {})
            for spelling, entry in enumerate(entries):
                label = f'{number}-{scenario}-{spelling}'
                run_entry(label + '-run', cwd, entry)
                check_artifacts(label, cwd, entry, ref)
except BaseException:
    print('project path symbols: artifacts and logs:', work, file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
    print('project path symbols: exact IR, native release/fast-no-debug objects and arm64-macOS IR at two checkout lengths, '
          'relative/absolute/./directory-alias entries; distinct private symbols, lexical entry/dependency symlinks and root manifest selection passed'
          + (' (published Mach-O objects skipped: no SDK)' if sys.platform != 'darwin' and not env.get('ABLA_MACOS_SDK') else ''))
