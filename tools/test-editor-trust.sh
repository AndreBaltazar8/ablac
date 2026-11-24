#!/usr/bin/env bash
# Opening and editing a hostile project in an editor runs nothing, fetches nothing and writes nothing (#1139 programme; docs/design/language-server.md: the editor
# policy is no evaluation at all). tools/fuzz/editor-trust/hostile.mjs drives `ablac analyze --stdio` as abla-lsp does on generated workspaces whose compile-time
# code, subparsers, import providers, git config and native libraries each try to create a canary file or run git, and checks the canaries. A positive control
# first builds the same projects and requires the canary: a site that does nothing in a build proves nothing in an editor. The resource cases that take long
# (a 64 MiB file, thousands of modules) are left to running hostile.mjs by hand.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
command -v node > /dev/null || { echo "editor trust: no node; skipped"; exit 0; }
export ABLA_SYSROOT=$project_root
mkdir -p build
live=(ct-expression ct-action-grant ct-default-argument subparser import-provider self-trusting-project)
editor=("${live[@]}" github-import git-dependency-unlocked prepared-copy-with-hostile-git-config native-library hostile-build-dir initialize-trust-flags initialize-without-mode
    import-cycle symlink-loop fifo-import dev-zero-import import-outside-root workspace-is-root-link)
control=$(EDITOR_TRUST_CONTROL=1 node tools/fuzz/editor-trust/hostile.mjs "$compiler" "${live[@]}")
printf '%s\n' "$control" | grep -c 'canary CREATED' | { read -r created; [ "$created" = "${#live[@]}" ]; } || { printf 'editor trust: a hostile site does not act in a build, so the editor check proves nothing for it:\n%s\n' "$control" >&2; exit 1; }
node tools/fuzz/editor-trust/hostile.mjs "$compiler" "${editor[@]}"
