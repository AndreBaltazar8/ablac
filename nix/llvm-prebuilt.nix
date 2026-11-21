# The Xtensa LLVM from a release of the fork (docs/llvm-xtensa.md), so it isn't
# compiled for over an hour wherever it is needed. x86_64 Linux only.
#
# The archive holds the build's out, lib and dev outputs. These outputs have the
# same names, so their store paths are the same length: the old hashes are
# replaced in place, as a store rewrite would, and autoPatchelf points the
# binaries at this nixpkgs' libraries.
{ pkgs }:

let
  tag = "llvm-23.1.3-xtensa-3";
  archive = "${tag}-x86_64-linux";
  staticArchive = "${tag}-static-x86_64-linux";
  release = "https://github.com/AndreBaltazar8/llvm-project/releases/download/${tag}";
  # Hash of these patches, in nix/llvm.nix's order, joined.
  patchesSha256 = "c9c83b6e7ac6c02a74c51abe28ecc899d59f0c743e75330ac03a707fbd7e206a";
  patchFiles = [
    "llvm-xtensa-direct-calls.patch"
    "llvm-xtensa-extui.patch"
    "llvm-xtensa-text-section-literals.patch"
    "llvm-xtensa-rematerialize.patch"
    "llvm-xtensa-narrow-branches.patch"
    "llvm-xtensa-bit-tests.patch"
    "llvm-xtensa-scavenging-slot.patch"
    "llvm-instcombine-fdiv-zero.patch"
  ];
in
rec {
  matchesPatches = patchesSha256 == builtins.hashString "sha256" (builtins.concatStringsSep ""
    (map (name: builtins.readFile (./. + "/${name}")) patchFiles));

  # The same build's libLLVM*.a, for the statically linked compiler (tools/static-llvm-env.sh).
  staticLibs = pkgs.stdenv.mkDerivation {
    name = "llvm-23.1.3-static-libs";
    src = pkgs.fetchurl {
      url = "${release}/${staticArchive}.tar.xz";
      sha256 = "bfa1c29a930e2fb2cfaa89e5e360396fa9843ae0fa18c61a7522b373dc37e015";
    };
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = "mkdir -p $out/lib && cp lib/libLLVM*.a $out/lib/";
  };

  llvm = pkgs.stdenv.mkDerivation {
    name = "llvm-23.1.3";
    outputs = [ "out" "lib" "dev" ];
    src = pkgs.fetchurl {
      url = "${release}/${archive}.tar.xz";
      sha256 = "4ec153479d61e504495410c515c889c48024ed6d6bbb0d32fcc260aa24805200";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [ stdenv.cc.cc.lib libffi libxml2 zlib ];
    # What the source-built LLVM's dev output propagates.
    propagatedBuildInputs = with pkgs; [ ncurses zlib ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;
    # $out/clang/bin/clang-23 finds libclang-cpp next to it: clangUnwrapped sets that run path.
    autoPatchelfIgnoreMissingDeps = [ "libclang-cpp.so.23.1" ];
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
      mkdir -p "$out/clang" && cp -a clang/. "$out/clang/"
      find "$out" "$lib" "$dev" -type f -exec sed -i "''${rewrites[@]}" {} +
      mkdir -p "$out/share/licenses"
      cp LICENSE.TXT SOURCE "$out/share/licenses/"
      runHook postInstall
    '';
  };

  # nixpkgs' clang-unwrapped with the driver binary and libclang-cpp of the fork build (linked to this LLVM): `clang -O2 -flto -c` is the
  # pre-link step of a Wasm and of a non-whole-program ELF LTO build, and it optimizes with the LLVM inside clang. Everything else (the resource
  # directory with its headers, the other tools, passthru, outputs) is nixpkgs' own, so its wrapper takes this as `cc`:
  # llvm.clang.override { cc = clangUnwrapped; }. A symlink farm, not a copy: the lib output holds a gigabyte of static archives.
  clangUnwrapped =
    let stock = pkgs.llvmPackages_23.clang-unwrapped; in
    pkgs.runCommand "clang-23.1.3-fdiv"
      {
        outputs = [ "out" "lib" "dev" "python" ];
        nativeBuildInputs = [ pkgs.patchelf ];
        inherit (stock) version meta pname;
        passthru = stock.passthru;
      }
      ''
        patched=${llvm}/clang
        # out: nixpkgs' tree, its bin with the driver and its copies under other names (clang++, clang-cl, clang-cpp) replaced.
        mkdir -p $out/bin
        for entry in ${stock}/*; do
          [ "$(basename "$entry")" = bin ] || ln -s "$entry" "$out/$(basename "$entry")"
        done
        for entry in ${stock}/bin/*; do
          if [ -L "$entry" ]; then cp -P "$entry" $out/bin/
          elif cmp -s "$entry" ${stock}/bin/clang-23; then cp $patched/bin/clang-23 "$out/bin/$(basename "$entry")"
          else ln -s "$entry" "$out/bin/$(basename "$entry")"; fi
        done
        # lib: nixpkgs' lib output (the resource directory, a gigabyte of archives) with libclang-cpp replaced.
        mkdir -p $lib/lib
        for entry in ${stock.lib}/*; do
          [ "$(basename "$entry")" = lib ] || ln -s "$entry" "$lib/$(basename "$entry")"
        done
        for entry in ${stock.lib}/lib/*; do
          case "$(basename "$entry")" in libclang-cpp.so*) ;; *) ln -s "$entry" "$lib/lib/$(basename "$entry")" ;; esac
        done
        cp $patched/lib/libclang-cpp.so.23.1 $lib/lib/libclang-cpp.so.23.1
        ln -s libclang-cpp.so.23.1 $lib/lib/libclang-cpp.so
        # Run paths: this clang-cpp and this LLVM first, then what nixpkgs' clang had (glibc, libstdc++).
        rest=$(patchelf --print-rpath ${stock}/bin/clang-23 | tr : '\n' | grep -v 'llvm-23\|clang-23' | tr '\n' :)
        for f in $out/bin/clang-23 $lib/lib/libclang-cpp.so.23.1; do
          chmod u+w "$f"
          patchelf --set-rpath "$lib/lib:${llvm.lib}/lib:$rest" "$f"
        done
        ln -s ${stock.dev} $dev
        ln -s ${stock.python} $python
      '';
}
