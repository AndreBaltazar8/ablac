#!/usr/bin/env bash
# Test the installed-launcher and checkout paths without needing an install.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$root/tools/xtensa-test-tools.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/abla-xtensa-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/install/bin" "$tmp/install/libexec" "$tmp/install/share/abla/stdlib" "$tmp/shim"
cat > "$tmp/install/bin/ablac" <<'SCRIPT'
#!/usr/bin/env bash
# An installed launcher would put its LLVM before the caller's shim.
exit 97
SCRIPT
cat > "$tmp/install/libexec/ablac.bin" <<'SCRIPT'
#!/usr/bin/env bash
[[ $ABLA_SYSROOT == "$TEST_EXPECT_SYSROOT" && ${PATH%%:*} == "$TEST_EXPECT_SHIM" ]]
[[ $* == 'build source --emit object' ]]
SCRIPT
cat > "$tmp/checkout" <<'SCRIPT'
#!/usr/bin/env bash
[[ $ABLA_SYSROOT == "$TEST_EXPECT_SYSROOT" && ${PATH%%:*} == "$TEST_EXPECT_SHIM" ]]
[[ $* == 'build source --emit object' ]]
SCRIPT
chmod +x "$tmp/install/bin/ablac" "$tmp/install/libexec/ablac.bin" "$tmp/checkout"
ln -s "$tmp/install/bin/ablac" "$tmp/alias"
export TEST_EXPECT_SHIM="$tmp/shim"
export TEST_EXPECT_SYSROOT="$tmp/install/share/abla"
ABLA_SYSROOT=wrong abla_xtensa_test_build "$tmp/alias" "$tmp/shim" build source --emit object
export TEST_EXPECT_SYSROOT="$tmp/checkout-sysroot"
ABLA_SYSROOT=$TEST_EXPECT_SYSROOT abla_xtensa_test_build "$tmp/checkout" "$tmp/shim" build source --emit object
echo 'xtensa test tools: installed sysroot and checkout launcher passed'
