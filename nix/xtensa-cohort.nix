# Describe the already-selected patched LLVM; this never builds LLVM itself.
# Unlike portable archives, these symlinks point into immutable Nix outputs.
{ pkgs, llvmTools }:
pkgs.runCommand "abla-xtensa-llvm-cohort" {
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  mkdir -p "$out/bin" "$out/lib"
  export ABLA_COHORT_OUT="$out"
  export ABLA_COHORT_TOOLS="${llvmTools}/bin"
  export ABLA_COHORT_LIB="${pkgs.lib.getLib llvmTools}/lib"
  export ABLA_COHORT_HOST="${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"}-${if pkgs.stdenv.hostPlatform.isDarwin then "macos" else "linux"}"
  python3 - <<'PY'
import hashlib, json, os, re, subprocess
from pathlib import Path
root = Path(os.environ['ABLA_COHORT_OUT'])
tools = Path(os.environ['ABLA_COHORT_TOOLS'])
for name in ('opt', 'llc'):
    (root / 'bin' / name).symlink_to(tools / name)
for path in sorted(Path(os.environ['ABLA_COHORT_LIB']).glob('libLLVM*')):
    if path.is_file() and ('.so' in path.name or path.name.endswith('.dylib')):
        (root / 'lib' / path.name).symlink_to(path)
files = {}
for path in sorted(root.rglob('*')):
    if path.is_file():
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        files[str(path.relative_to(root))] = digest.hexdigest()
assert any(name.startswith('lib/libLLVM') for name in files)
version_text = subprocess.check_output([str(tools / 'opt'), '--version'], text=True)
version = re.search(r'LLVM version ([0-9]+\.[0-9]+\.[0-9]+)', version_text).group(1)
manifest = {'schema': 1, 'origin': 'nix-store',
            'version': 'abla-xtensa-llvm-nix-' + hashlib.sha256(str(tools).encode()).hexdigest(),
            'platform': os.environ['ABLA_COHORT_HOST'], 'llvmVersion': version, 'files': files}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
''
