{ pkgs ? import ../../nix/nixpkgs.nix }:
let base = import ../../shell.nix { inherit pkgs; }; in
pkgs.mkShell {
  inputsFrom = [ base ];
  packages = with pkgs; [ gcc rustc go zig_0_14 time jq oha json_c pcre2 pkg-config ];
  shellHook = base.shellHook + ''
    export BENCH_NIX_PIN=6510408d147d8c5e6d76043e899e9251756f6a75
    export BENCH_TIME=${pkgs.time}/bin/time
    export BENCH_JSON_LIB=${pkgs.json_c}/lib
    export BENCH_PCRE_LIB=${pkgs.pcre2}/lib
    export BENCH_PCRE_INCLUDE=${pkgs.lib.getDev pkgs.pcre2}/include
    export BENCH_JSON_INCLUDE=${pkgs.lib.getDev pkgs.json_c}/include
  '';
}
