#!/usr/bin/env python3
"""Opt-in real published-toolchain installation probe; no LLVM source builds."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

sys.dont_write_bytecode = True
import xtensa_companions as companions


def run(*args):
    print('+', *map(str, args), flush=True)
    return subprocess.run(list(map(str, args)), check=True, timeout=120)


def snapshot(root):
    result = {}
    for path in root.rglob('*'):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = ('link', str(path.readlink()))
        elif path.is_file():
            result[name] = ('file', companions.file_sha256(path), path.stat().st_mode)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--unpublished-fixture', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--native', action='store_true', help='test the separately packaged native installer')
    parser.add_argument('--native-package', type=Path, help='candidate toolchain archive built with the pinned compiler')
    args = parser.parse_args()
    if args.native != bool(args.native_package):
        parser.error('--native and --native-package must be supplied together')
    if bool(args.unpublished_fixture) != bool(args.archive):
        parser.error('--unpublished-fixture and --archive must be used together')
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    catalog_args = []
    if args.unpublished_fixture:
        fixture = json.loads(args.unpublished_fixture.read_text())
        if fixture.get('status') != 'UNPUBLISHED_TEST_FIXTURE':
            raise ValueError('not an explicitly UNPUBLISHED test fixture')
        print('UNPUBLISHED TEST FIXTURE: offline dry-run archive; not a published companion', flush=True)
        local_catalog = output / 'UNPUBLISHED-test-catalog.json'
        local_catalog.write_text(json.dumps(fixture['catalog'], indent=2) + '\n')
        catalog = companions.load_catalog(local_catalog)
        catalog['integrationToolchain'] = json.loads(companions.CATALOG.read_text())['integrationToolchain']
        catalog_args = ['--catalog', str(local_catalog)]
    else:
        catalog = companions.load_catalog()
    host = companions.host_platform()
    fixture = catalog['integrationToolchain']
    base = fixture['platforms'][host]
    archive = output / 'parent.tar.gz'
    with urllib.request.urlopen(base['url'], timeout=30) as stream:
        companions._copy_archive(stream, archive, base['sha256'])
    # The published parent has legitimate launcher symlinks. Its complete archive
    # is hash-pinned before the native tar reads it into an empty owned directory.
    unpacked = output / 'parent'
    unpacked.mkdir()
    run('tar', '-xzf', archive, '-C', unpacked)
    roots = list(unpacked.iterdir())
    if len(roots) != 1 or not (roots[0] / 'libexec/ablac.bin').is_file():
        raise ValueError('unexpected parent toolchain layout')
    root = output / 'relocated Abla toolchain'
    roots[0].rename(root)
    originals = snapshot(root)
    run('bash', Path(__file__).with_name('package-xtensa-installer.sh'), root)
    if args.native:
        candidate = output / 'native-package'
        candidate.mkdir()
        run('tar', '-xzf', args.native_package.absolute(), '-C', candidate)
        candidates = list(candidate.iterdir())
        if len(candidates) != 1 or not (candidates[0] / 'bin/abla-install-xtensa-native').is_file():
            raise ValueError('unexpected candidate package layout')
        installer = candidates[0] / 'bin/abla-install-xtensa-native'
        command = [str(installer), '--toolchain-root', str(root)]
    else:
        installer = root / 'bin/abla-install-xtensa'
        command = [sys.executable, str(installer)]
    version = '23.1.3-1'
    archive_args = ['--archive', str(args.archive.absolute())] if args.archive else []
    run(*command, *catalog_args, '--version', version, *archive_args)
    run(*command, *catalog_args, '--verify')
    run(*command, *catalog_args, '--version', version, *archive_args)
    after = snapshot(root)
    for name, value in originals.items():
        if after.get(name) != value:
            raise ValueError('installer modified parent file: ' + name)
    tree = companions.verify_installed(root, catalog, version)
    llc, opt = tree / 'bin/llc', tree / 'bin/opt'
    fixture_ir = tree / 'patches.ll'
    options = ['-mcpu=esp32', '-relocation-model=static', '-O2']
    run(llc, *options, '-xtensa-direct-calls', '-xtensa-narrow-branches',
        '-xtensa-text-section-literals', fixture_ir, '-o', output / 'patches.s')
    run(llc, *options, '-filetype=obj', fixture_ir, '-o', output / 'patches.o')
    run(opt, '-passes=default<O2>,globaldce', '-S', fixture_ir, '-o', output / 'optimized.ll')
    run(llc, *options, '-filetype=obj', output / 'optimized.ll', '-o', output / 'optimized.o')
    expected = {
        'patches.s': 'b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791',
        'patches.o': '528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1',
        'optimized.o': '8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672'}
    actual = {name: companions.file_sha256(output / name) for name in expected}
    if actual != expected:
        raise ValueError('installed code generation differs from Nix: ' + repr(actual))
    # Exercise the actual DSO as well as the offline fake-file control. Restore
    # it in finally, so even a failed negative leaves this owned prefix usable.
    library = next((tree / 'lib').glob('libLLVM*'))
    info = library.stat()
    original = None
    try:
        library.chmod(0o644)
        with library.open('r+b') as stream:
            stream.seek(4096)
            original = stream.read(1)
            if len(original) != 1:
                raise ValueError('unexpectedly short LLVM library')
            stream.seek(4096)
            stream.write(bytes([original[0] ^ 1]))
        os.utime(library, ns=(info.st_atime_ns, info.st_mtime_ns))
        assert library.stat().st_size == info.st_size
        assert library.stat().st_mtime_ns == info.st_mtime_ns
        negative = subprocess.run([*command, *catalog_args, '--verify'],
                                  capture_output=True, text=True, timeout=120)
        expected_error = 'file_hash' if args.native else 'file SHA-256 mismatch'
        if negative.returncode != 1 or expected_error not in negative.stderr:
            raise ValueError('stat-preserved DSO corruption was not rejected: ' + repr(negative))
        (output / 'tamper-negative.txt').write_text(negative.stderr)
    finally:
        if original:
            with library.open('r+b') as stream:
                stream.seek(4096)
                stream.write(original)
        os.utime(library, ns=(info.st_atime_ns, info.st_mtime_ns))
        library.chmod(info.st_mode & 0o777)
    run(*command, *catalog_args, '--verify')
    if any(root.rglob('__pycache__')):
        raise ValueError('installer wrote Python caches into the toolchain')
    report = {'installer': 'native' if args.native else 'python',
              'nativePackageSha256': companions.file_sha256(args.native_package) if args.native else None,
              'platform': host, 'parentVersion': fixture['version'], 'version': version,
              'unchangedParentFiles': len(originals), 'statPreservedDsoTamperRejected': True,
              'codegen': actual, 'status': 'passed', 'unpublishedTestFixture': bool(args.unpublished_fixture)}
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
