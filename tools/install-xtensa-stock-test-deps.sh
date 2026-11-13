#!/usr/bin/env bash
# Disposable Ubuntu 24.04 container only. Does not compile LLVM.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && -f /.dockerenv ]] || { echo 'stock dependencies require a disposable CI container' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg nodejs gcc g++ make patchelf binutils binaryen git time
curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 https://apt.llvm.org/llvm-snapshot.gpg.key -o /tmp/llvm.asc
fingerprint=$(gpg --show-keys --with-colons /tmp/llvm.asc | awk -F: '$1 == "fpr" { print $10; exit }')
test "$fingerprint" = 6084F3CF814B57C1CF12EFD515CF4D18AF4F7421
gpg --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg /tmp/llvm.asc
echo 'deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-23 main' > /etc/apt/sources.list.d/llvm.list
apt-get update
apt-get install -y --no-install-recommends clang-23 llvm-23 llvm-23-dev lld-23 libssl-dev
