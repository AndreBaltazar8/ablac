#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$project_root/build/package-provider.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

repository="$test_root/dependency"
leaf_repository="$test_root/leaf-dependency"
application="$test_root/application"
cache="$test_root/cache"
mkdir -p -- "$repository/src" "$leaf_repository/src" "$application/src"

git -C "$leaf_repository" init --quiet --initial-branch=main
git -C "$leaf_repository" config user.name 'Abla package test'
git -C "$leaf_repository" config user.email 'abla-package-test@example.invalid'
cat > "$leaf_repository/abla.toml" <<'EOF'
name = "provider-leaf"
version = "0.1.0"
entry = "src/provider-leaf.ab"
compileCapabilities = ["network"]
EOF
cat > "$leaf_repository/src/provider-leaf.ab" <<'EOF'
fun leafAnswer: int = 2
EOF
git -C "$leaf_repository" add abla.toml src/provider-leaf.ab
git -C "$leaf_repository" commit --quiet -m 'leaf dependency'

git -C "$repository" init --quiet --initial-branch=main
git -C "$repository" config user.name 'Abla package test'
git -C "$repository" config user.email 'abla-package-test@example.invalid'

cat > "$repository/abla.toml" <<'EOF'
name = "provider-dep"
version = "0.1.0"
entry = "src/provider-dep.ab"
EOF
cat > "$repository/src/leaf-provider.ab" <<EOF
compile fun leafDependency(): ImportSource = gitImportSource(
    "provider-leaf",
    "$leaf_repository",
    "branch",
    "main"
)
EOF
cat > "$repository/src/provider-dep.ab" <<'EOF'
import "leaf-provider.ab"
import "literal.ab"
import leafDependency()
fun dependencyAnswer: int = 38 + leafAnswer() + literalAnswer()
EOF
cat > "$repository/src/literal.ab" <<'EOF'
import "abla/json"
val literalBody = #$jsons {"answer": 42}
fun literalAnswer: int = if (literalBody == "{\"answer\":42}") 2 else 0
EOF
git -C "$repository" add abla.toml src/provider-dep.ab src/leaf-provider.ab \
    src/literal.ab
git -C "$repository" commit --quiet -m 'initial dependency'
first_revision=$(git -C "$repository" rev-parse HEAD)

cat > "$application/abla.toml" <<'EOF'
name = "provider-app"
version = "0.1.0"
entry = "src/main.ab"
EOF
cat > "$application/src/provider.ab" <<EOF
compile fun localDependency(): ImportSource = gitImportSource(
    "provider-dep",
    "$repository",
    "branch",
    "main"
)
EOF
cat > "$application/src/main.ab" <<'EOF'
import "provider.ab"
import localDependency()
fun main: int = dependencyAnswer()
EOF

set +e
missing_output=$(ABLA_PACKAGE_CACHE="$cache" "$compiler" build \
    --project "$application" --fast --no-cache --offline 2>&1)
missing_status=$?
set -e
[[ $missing_status -ne 0 ]]
[[ $missing_output == *'E_PACKAGE_LOCK_MISSING'* ]]

set +e
capability_output=$(ABLA_PACKAGE_CACHE="$cache" "$compiler" package update \
    --project "$application" 2>&1)
capability_status=$?
set -e
[[ $capability_status -ne 0 ]]
[[ $capability_output == *'E_PACKAGE_CAPABILITY_DENIED'* ]]
[[ $capability_output == *"dependency 'provider-leaf'"* ]]

cat >> "$application/abla.toml" <<'EOF'
compileCapabilities = ["network"]
EOF
ABLA_PACKAGE_CACHE="$cache" "$compiler" package update \
    --project "$application"
grep -q "revision = \"$first_revision\"" "$application/abla.lock"
grep -q 'selector-kind = "branch"' "$application/abla.lock"
grep -q 'name = "provider-leaf"' "$application/abla.lock"

ABLA_PACKAGE_CACHE="$cache" "$compiler" build --project "$application" \
    --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" "$application/build/provider-app"
first_status=$?
set -e
[[ $first_status -eq 42 ]]

cat > "$repository/src/provider-dep.ab" <<'EOF'
import "leaf-provider.ab"
import "literal.ab"
import leafDependency()
fun dependencyAnswer: int = 37 + leafAnswer() + literalAnswer()
EOF
git -C "$repository" add src/provider-dep.ab
git -C "$repository" commit --quiet -m 'move mutable branch'
second_revision=$(git -C "$repository" rev-parse HEAD)

rm -rf -- "$application/.abla"
ABLA_PACKAGE_CACHE="$cache" "$compiler" build --project "$application" \
    --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" "$application/build/provider-app"
locked_status=$?
set -e
[[ $locked_status -eq 42 ]]
grep -q "revision = \"$first_revision\"" "$application/abla.lock"

ABLA_PACKAGE_CACHE="$cache" "$compiler" package update \
    --project "$application"
grep -q "revision = \"$second_revision\"" "$application/abla.lock"
ABLA_PACKAGE_CACHE="$cache" "$compiler" package vendor \
    --project "$application"
rm -rf -- "$cache" "$application/.abla"
ABLA_PACKAGE_CACHE="$cache" "$compiler" build --project "$application" \
    --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" "$application/build/provider-app"
vendored_status=$?
set -e
[[ $vendored_status -eq 41 ]]

github_application="$test_root/github-application"
mkdir -p -- "$github_application/src"
cat > "$github_application/abla.toml" <<'EOF'
name = "github-provider-probe"
entry = "src/main.ab"
EOF
cat > "$github_application/src/main.ab" <<'EOF'
import github("AndreBaltazar8/abla-mvc")
fun main: int = 0
EOF
set +e
github_output=$(ABLA_PACKAGE_CACHE="$cache" "$compiler" build \
    --project "$github_application" --offline --fast --no-cache 2>&1)
github_status=$?
set -e
[[ $github_status -ne 0 ]]
[[ $github_output == *'E_PACKAGE_LOCK_MISSING'* ]]

generated_application="$test_root/generated-application"
generated_cache="$test_root/generated-cache"
mkdir -p -- "$generated_application/src"
cat > "$generated_application/abla.toml" <<'EOF'
name = "generated-provider-app"
entry = "src/main.ab"
EOF
cat > "$generated_application/src/provider.ab" <<'EOF'
import "abla/compiler"
compile fun resolveGenerated(): ResolvedImport {
    val revision = compilerEnvironment("ABLA_GENERATED_REVISION")
    resolvedImport(
        revision,
        "src/generated-dependency.ab",
        [
            importFile(
                "abla.toml",
                "name = \"generated-dependency\"\nentry = \"src/generated-dependency.ab\"\n"
            ),
            importFile(
                "src/generated-dependency.ab",
                "fun generatedAnswer: int = 42\n"
            )
        ]
    )
}

compile fun generatedDependency(): ImportSource = importSource(
    "generated-dependency",
    "generated:answer",
    "v1",
    resolveGenerated
)
EOF
cat > "$generated_application/src/main.ab" <<'EOF'
import "provider.ab"
import generatedDependency()
fun main: int = generatedAnswer()
EOF

set +e
generated_denied_output=$(ABLA_GENERATED_REVISION=generated-v1 \
    ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" package update \
    --project "$generated_application" 2>&1)
generated_denied_status=$?
set -e
[[ $generated_denied_status -ne 0 ]]
[[ $generated_denied_output == *'E_IMPORT_PROVIDER_EFFECT_DENIED'* ]]

cat >> "$generated_application/abla.toml" <<'EOF'
compileCapabilities = ["environment"]
EOF
ABLA_GENERATED_REVISION=generated-v1 \
    ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" package update \
    --project "$generated_application"
grep -q '^version = 2$' "$generated_application/abla.lock"
grep -q 'provider = "content"' "$generated_application/abla.lock"
grep -q 'identity = "generated:answer"' "$generated_application/abla.lock"
grep -q 'revision = "generated-v1"' "$generated_application/abla.lock"
ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" build \
    --project "$generated_application" --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" \
    "$generated_application/build/generated-provider-app"
generated_first_status=$?
set -e
[[ $generated_first_status -eq 42 ]]

# Changing the deferred resolver cannot move an existing lock during a build,
# and a build does not require the environment input used only by the resolver.
sed -i 's/generatedAnswer: int = 42/generatedAnswer: int = 41/' \
    "$generated_application/src/provider.ab"
rm -rf -- "$generated_application/.abla"
ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" build \
    --project "$generated_application" --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" \
    "$generated_application/build/generated-provider-app"
generated_locked_status=$?
set -e
[[ $generated_locked_status -eq 42 ]]
grep -q 'revision = "generated-v1"' "$generated_application/abla.lock"

ABLA_GENERATED_REVISION=generated-v2 \
    ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" package update \
    --project "$generated_application"
grep -q 'revision = "generated-v2"' "$generated_application/abla.lock"
ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" package vendor \
    --project "$generated_application"
rm -rf -- "$generated_cache" "$generated_application/.abla"
ABLA_PACKAGE_CACHE="$generated_cache" "$compiler" build \
    --project "$generated_application" --fast --no-cache --offline
set +e
"$project_root/tools/run-limited.sh" \
    "$generated_application/build/generated-provider-app"
generated_vendored_status=$?
set -e
[[ $generated_vendored_status -eq 41 ]]

printf '%s\n' \
    'package providers: typed Git and generated sources, immutable lock, offline cache, explicit update, and vendor fallback passed'
