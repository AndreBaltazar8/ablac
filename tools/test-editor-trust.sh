#!/usr/bin/env bash
# Opening and editing a hostile project in an editor runs nothing, fetches nothing and writes nothing (#1139 programme; docs/design/language-server.md: the editor
# policy is no evaluation at all). tools/fuzz/editor-trust/hostile.mjs drives `ablac analyze --stdio` as abla-lsp does. One workspace holds a compile-time
# expression, action and default argument, a subparser, an import provider, github() and git imports, native libraries, a hostile build/, self-trusting settings
# files and initialize flags, import cycles, a symlink loop, a FIFO, /dev/zero and paths outside the root, each trying to create its own canary or run git; a second
# holds a prepared dependency copy whose .git/config sets core.fsmonitor. Positive controls build two of the sites (an expression and a provider) and require their
# canaries: a site that does nothing in a build proves nothing in an editor. The rest of the cases (the control for every site, resource bounds such as a 64 MiB
# file or thousands of modules) are for running hostile.mjs by hand with no case names.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
command -v node > /dev/null || { echo "editor trust: no node; skipped"; exit 0; }
export ABLA_SYSROOT=$project_root
mkdir -p build
control=$(EDITOR_TRUST_CONTROL=1 node tools/fuzz/editor-trust/hostile.mjs "$compiler" ct-expression import-provider)
created=$(printf '%s\n' "$control" | grep -c 'canary CREATED' || true)
[ "$created" = 2 ] || { printf 'editor trust: a hostile site does not act in a build, so the editor check proves nothing for it:\n%s\n' "$control" >&2; exit 1; }
node tools/fuzz/editor-trust/hostile.mjs "$compiler" combined prepared-copy-with-hostile-git-config initialize-without-mode workspace-is-root-link stdlib-literals \
    stdlib-literals-build-link
