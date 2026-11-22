#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fixture="$work/catalog"
export ABLA_PACKAGE_INDEX_URL="file://$fixture" ABLA_PACKAGE_CACHE="$work/cache"
cat > "$fixture" <<'TOML'
# Search name, description and keywords.
[[package]]
repository = "owner/abla-web"
description = "HTTP server and middleware"
keywords = ["web", "service"]
[[package]]
repository = "owner/abla-redis"
description = "Native Redis client"
keywords = ["RESP", "cache"]
[[package]]
repository = "owner/redis"
description = "Redis tools"
keywords = []
[[package]]
repository = "another/abla-web"
description = "Web widgets"
keywords = ["widget"]
TOML

redis=$(printf 'owner/abla-redis\tNative Redis client')
web=$(printf 'owner/abla-web\tHTTP server and middleware')
[[ $("$compiler" package search ABLA-WEB middleware) == "$web" ]]
[[ $("$compiler" package search $'  CACHE\tRESP  ') == "$redis" ]]
[[ $("$compiler" package search middleware cache) == 'No packages found.' ]]

snapshots=("$ABLA_PACKAGE_CACHE"/index/*.toml)
[[ ${#snapshots[@]} == 1 ]]
[[ ${snapshots[0]##*/} =~ ^file-[0-9]+-[0-9a-f]{16}-[0-9a-f]{16}\.toml$ ]]
cmp "$fixture" "${snapshots[0]}"
mv "$fixture" "$work/catalog.saved"
[[ $("$compiler" package search --offline RESP 2> "$work/error") == "$redis" ]]
[[ ! -s "$work/error" ]]
[[ $("$compiler" package search RESP 2> "$work/error") == "$redis" ]]
grep -F 'Using the cached package index' "$work/error"

# A separate index URL cannot borrow this fixture's cache.
if ABLA_PACKAGE_INDEX_URL="file://$work/other" "$compiler" package search RESP --offline > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F 'no usable cached package index' "$work/error"
[[ ! -s "$work/output" ]]

"$compiler" package info --offline ReDiS > "$work/output" 2> "$work/error"
grep -Fx 'Repository: owner/redis' "$work/output"
grep -Fx 'Catalog description: Redis tools' "$work/output"
grep -Fx 'Keywords: (none)' "$work/output"
[[ ! -s "$work/error" ]]
"$compiler" package info OWNER/ABLA-REDIS --offline > "$work/output"
grep -Fx 'Repository: owner/abla-redis' "$work/output"
grep -Fx 'Keywords: RESP, cache' "$work/output"
if "$compiler" package info web --offline > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F "package 'web' is ambiguous. Use owner/abla-web or another/abla-web." "$work/error"
[[ ! -s "$work/output" ]]
if "$compiler" package info missing --offline > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F "package 'missing' is not in the index" "$work/error"
[[ ! -s "$work/output" ]]

# A malformed record after a match must neither replace the cache nor
# produce partial results when there is no valid snapshot.
cp "$work/catalog.saved" "$fixture"
cat >> "$fixture" <<'TOML'
[[package]]
repository = "OWNER/ABLA-WEB"
description = "Duplicate"
keywords = []
TOML
[[ $("$compiler" package search RESP 2> "$work/error") == "$redis" ]]
grep -F 'duplicate repository OWNER/ABLA-WEB. Using the cached package index.' "$work/error"
cmp "$work/catalog.saved" "${snapshots[0]}"
if ABLA_PACKAGE_CACHE="$work/empty" "$compiler" package search middleware > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F 'duplicate repository OWNER/ABLA-WEB' "$work/error"
[[ ! -s "$work/output" && ! -e "$work/empty" ]]

# A later valid refresh replaces the old snapshot for offline callers.
sed 's/Native Redis client/Redis protocol client/' "$work/catalog.saved" > "$fixture"
updated=$(printf 'owner/abla-redis\tRedis protocol client')
[[ $("$compiler" package search RESP 2> "$work/error") == "$updated" ]]
[[ ! -s "$work/error" ]]
cmp "$fixture" "${snapshots[0]}"
[[ $("$compiler" package search RESP --offline) == "$updated" ]]

# Use a toolchain-local helper fixture for the online path without network.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$work/toolchain/runtime"
ln -s "$root/stdlib" "$work/toolchain/stdlib"
for file in "$root/runtime/"*; do
    [[ ${file##*/} == package-index-fetch.ab ]] || ln -s "$file" "$work/toolchain/runtime/"
done
cat > "$work/toolchain/runtime/package-index-fetch.ab" <<'ABLA'
import "abla/sys/linux/io"

fun main(): int {
    linuxPrintStandardOutput("200\n[[package]]\nrepository = \"owner/abla-helper\"\ndescription = \"Helper fixture\"\nkeywords = []\n")
    return 0
}
ABLA

search_with_helper() {
    env -u ABLA_PACKAGE_INDEX_URL ABLA_SYSROOT="$work/toolchain" \
        ABLA_PACKAGE_CACHE="$work/helper-index" ABLA_JIT_CACHE_TRACE=1 \
        "$compiler" package search helper 2> "$work/helper-error"
}

helper_result=$(printf 'owner/abla-helper\tHelper fixture')
[[ $(search_with_helper) == "$helper_result" ]]
grep -Fx 'Building the package search helper...' "$work/helper-error"
grep -F '[jit-cache] stored ' "$work/helper-error"
[[ $(search_with_helper) == "$helper_result" ]]
if grep -Fx 'Building the package search helper...' "$work/helper-error"; then exit 1; fi
grep -F '[jit-cache] hit ' "$work/helper-error"

# A record without its object must rebuild, and a partial record can likewise
# be ignored. The result remains available on the first retry.
records=("$work"/helper-index/index-helper/run-*.record)
[[ ${#records[@]} == 1 ]]
record=${records[0]}
object=$(sed -n '2p' "$record")
[[ -f "$object" ]]
rm -- "$object"
[[ $(search_with_helper) == "$helper_result" ]]
grep -Fx 'Building the package search helper...' "$work/helper-error"
grep -F '[jit-cache] miss ' "$work/helper-error"
grep -F '[jit-cache] stored ' "$work/helper-error"
object=$(sed -n '2p' "$record")
printf 'incomplete object\n' > "$object"
[[ $(search_with_helper) == "$helper_result" ]]
grep -F '[jit-cache] stored ' "$work/helper-error"
printf 'abla-run-object-v5\n' > "$record"
[[ $(search_with_helper) == "$helper_result" ]]
grep -F '[jit-cache] miss ' "$work/helper-error"
grep -F '[jit-cache] stored ' "$work/helper-error"
