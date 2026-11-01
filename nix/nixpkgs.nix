# The nixpkgs every Linux toolchain piece comes from.
import (builtins.fetchTarball {
  name = "nixpkgs-6510408d147d8c5e6d76043e899e9251756f6a75";
  url = "https://github.com/NixOS/nixpkgs/archive/6510408d147d8c5e6d76043e899e9251756f6a75.tar.gz";
  sha256 = "012w2z2w4k0c3kg9hcy9cpd7qgxgrpxvf0735vy014r7x9qhmbjw";
}) { }
