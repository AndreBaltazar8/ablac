# The Xtensa LLVM from a release of the fork (docs/llvm-xtensa.md), so it isn't
# compiled for over an hour wherever it is needed. x86_64 Linux only.
#
# The archive holds the build's out, lib and dev outputs. These outputs have the
# same names, so their store paths are the same length: the old hashes are
# replaced in place, as a store rewrite would, and autoPatchelf points the
# binaries at this nixpkgs' libraries.
{ pkgs }:

let
  tag = "llvm-23.1.3-xtensa-2";
  archive = "${tag}-x86_64-linux";
  # Hash of these patches, in nix/llvm.nix's order, joined.
  patchesSha256 = "4f544721c71fb8acfeff47d66f541dbcdeefeff82cc59e503986306c7adb6ea2";
  patchNames = [
    "direct-calls"
    "extui"
    "text-section-literals"
    "rematerialize"
    "narrow-branches"
    "bit-tests"
    "scavenging-slot"
  ];
in
{
  matchesPatches = patchesSha256 == builtins.hashString "sha256" (builtins.concatStringsSep ""
    (map (name: builtins.readFile (./. + "/llvm-xtensa-${name}.patch")) patchNames));

  llvm = pkgs.stdenv.mkDerivation {
    name = "llvm-23.1.3";
    outputs = [ "out" "lib" "dev" ];
    src = pkgs.fetchurl {
      url = "https://github.com/AndreBaltazar8/llvm-project/releases/download/${tag}/${archive}.tar.xz";
      sha256 = "ac452ac71975498fcc54e928e8376f18f72fe871979e5220173d71c8dc9a9ca3";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [ stdenv.cc.cc.lib libffi libxml2 zlib ];
    # What the source-built LLVM's dev output propagates.
    propagatedBuildInputs = with pkgs; [ ncurses zlib ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;
    installPhase = ''
      runHook preInstall
      rewrites=()
      for output in out lib dev; do
        old=$(awk -v output="$output" '$1 == output { print $2 }' store-hashes)
        new=$(basename "''${!output}" | cut -d- -f1)
        rewrites+=(-e "s/$old/$new/g")
        mkdir -p "''${!output}"
        cp -a "$output"/. "''${!output}"/
      done
      find "$out" "$lib" "$dev" -type f -exec sed -i "''${rewrites[@]}" {} +
      mkdir -p "$out/share/licenses"
      cp LICENSE.TXT SOURCE "$out/share/licenses/"
      runHook postInstall
    '';
  };
}
