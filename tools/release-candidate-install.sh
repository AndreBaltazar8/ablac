#!/usr/bin/env bash
# A scratch install of a release candidate, for the downstream checks before tagging (NovaKind,
# abla-embedded): the stage-2 binary with this tree's runtime and stdlib, wrapped like a release.
#
#   tools/release-candidate-install.sh <stage2-binary> <out-dir> [default.nix]
#
# Builds <out-dir>/installed (bin/ablac, libexec/ablac.bin, share/abla) with nix-build, and prints
# the installed compiler's version. Point ABLAC at <out-dir>/installed/bin/ablac to use it.
# default.nix is the install recipe of a published release (default: the previous release under
# ~/.local/share/abla/<tag>/default.nix, set ABLA_DEFAULT_NIX or pass it); it names the build
# `abla-candidate`. The tree's nix/ gives the LLVM it links, tools/xtensa-companions.json the
# companion table. Run it from a checkout whose Prepare commit is the candidate's.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary=$(realpath "$1")
out=$2
recipe=${3:-${ABLA_DEFAULT_NIX:-}}
if [[ -z $recipe ]]; then
    recipe=$(ls -d "$HOME"/.local/share/abla/v*/default.nix 2>/dev/null | sort -V | tail -1 || true)
fi
[[ -f $recipe ]] || { echo "no default.nix recipe: pass one or set ABLA_DEFAULT_NIX" >&2; exit 2; }
[[ -f $binary ]] || { echo "no such binary: $binary" >&2; exit 2; }

mkdir -p "$out/abla-toolchain-x86_64-linux/share/abla"
cp -r "$project_root/nix" "$out/nix"
cp "$recipe" "$out/default.nix"
chmod u+w "$out/default.nix"
for part in runtime stdlib; do
    cp -r "$project_root/$part" "$out/abla-toolchain-x86_64-linux/share/abla/$part"
done
cp "$project_root/tools/xtensa-companions.json" "$out/abla-toolchain-x86_64-linux/share/abla/"
(
    cd "$out"
    tar -czf abla-toolchain-x86_64-linux.tar.gz abla-toolchain-x86_64-linux
    cp "$binary" ablac-x86_64-linux
    sed -Ei 's/"abla-[0-9][0-9.]*(-candidate)?"/"abla-candidate"/' default.nix
    nix-build default.nix -o installed
)
"$out/installed/bin/ablac" --version
