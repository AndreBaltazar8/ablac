# The Linux CI inputs for the Android link and bionic execution checks.
{ pkgs ? import ./nixpkgs.nix }:

let
  androidPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = { android_sdk.accept_license = true; allowUnfree = true; };
  };
  android = androidPkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
    ndkVersions = [ "27.2.12479018" ]; # r27c, matching CI
  };
  image = pkgs.fetchurl {
    url = "https://dl.google.com/android/repository/sys-img/android/arm64-v8a-36_r02.zip";
    sha1 = "62ad6714df790f89c8a8ad32552ffe20bb16fe87";
  };
  bionic = pkgs.runCommand "abla-bionic-android-36-r02" {
    nativeBuildInputs = [ pkgs.unzip pkgs.e2fsprogs ];
  } ''
    bash ${../tools/prepare-bionic-sysroot.sh} "$out" ${image}
  '';
in
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
pkgs.runCommand "abla-android-test-inputs" { } ''
  mkdir -p "$out"
  ln -s ${android.ndk-bundle}/libexec/android-sdk/ndk-bundle "$out/ndk"
  ln -s ${bionic} "$out/bionic"
  test -x "$out/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
  test -x "$out/bionic/system/bin/bootstrap/linker64"
''
