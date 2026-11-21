#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/curl" <<'STUB'
#!/usr/bin/env bash
[[ ${!#} == https://abla.dev/packages.toml ]] || exit 1
[[ ${CATALOG_UNAVAILABLE:-0} != 1 ]] || exit 22
cat "$CATALOG_FIXTURE"
STUB
chmod +x "$work/curl"
export PATH="$work:$PATH" CATALOG_FIXTURE="$work/catalog"
cat > "$CATALOG_FIXTURE" <<'TOML'
# Search name, description and keywords.
[[package]]
repository = "owner/abla-web"
description = "HTTP server and middleware"
keywords = ["web", "service"]
[[package]]
repository = "owner/abla-redis"
description = "Native Redis client"
keywords = ["RESP", "cache"]
TOML

diff -u <(printf 'owner/abla-web\tHTTP server and middleware\n') <("$compiler" package search ABLA-WEB)
diff -u <(printf 'owner/abla-web\tHTTP server and middleware\n') <("$compiler" package search middleware)
diff -u <(printf 'owner/abla-redis\tNative Redis client\n') <("$compiler" package search '  RESP  ')
diff -u <(printf 'No packages found.\n') <("$compiler" package search absent)

if CATALOG_UNAVAILABLE=1 "$compiler" package search web > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F 'cannot fetch https://abla.dev/packages.toml' "$work/error"
[[ ! -s "$work/output" ]]

# A malformed record after a match must not produce partial results.
cat >> "$CATALOG_FIXTURE" <<'TOML'
[[package]]
repository = "OWNER/ABLA-WEB"
description = "Duplicate"
keywords = []
TOML
if "$compiler" package search web > "$work/output" 2> "$work/error"; then exit 1; fi
grep -F 'duplicate repository OWNER/ABLA-WEB' "$work/error"
[[ ! -s "$work/output" ]]
