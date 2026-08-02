{ pkgs ? import (builtins.fetchTarball {
    name = "nixpkgs-5e2a59a5b1a82f89f2c7e598302a9cacebb72a67";
    url = "https://github.com/NixOS/nixpkgs/archive/5e2a59a5b1a82f89f2c7e598302a9cacebb72a67.tar.gz";
    sha256 = "02rf59xj2v1ml7v35x4j64ax1fb7xx96ld7va6rifyxazmwsr4rb";
  }) { config.android_sdk.accept_license = true; } }:

let
  baseShell = import ../../shell.nix { inherit pkgs; };
  android = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "36.0.0" ];
    includeNDK = true;
    ndkVersions = [ "28.2.13676358" ];
    includeCmake = true;
    cmakeVersions = [ "3.22.1" ];
  };
  androidSdk = android.androidsdk;
  androidGradle = pkgs.writeShellScriptBin "android-gradle" ''
    exec ${pkgs.gradle}/bin/gradle \
      "-Pandroid.aapt2FromMavenOverride=$ANDROID_SDK_ROOT/build-tools/36.0.0/aapt2" \
      "$@"
  '';
in
pkgs.mkShell {
  inputsFrom = [ baseShell ];
  packages = [
    androidSdk
    androidGradle
    pkgs.gradle
    pkgs.jdk17
  ];

  JAVA_HOME = pkgs.jdk17.home;
  ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
  ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
  ANDROID_NDK_ROOT = "${androidSdk}/libexec/android-sdk/ndk-bundle";

  shellHook = ''
    export ABLAC_DEV_SHELL=1
    android_build_tools_root="$(echo "$ANDROID_SDK_ROOT/build-tools/"*"/")"
    android_cmake_root="$(echo "$ANDROID_SDK_ROOT/cmake/"*"/")"
    export PATH="$android_build_tools_root:$android_cmake_root/bin:$PATH"
  '';
}
