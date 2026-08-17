# Package imports

Abla package imports are typed compile-time source expressions. The concise
GitHub form is:

```abla
import github("AndreBaltazar8/abla-mvc")
```

`github(...)` returns `ImportSource`; it is not a special import syntax and it
does not fetch while parsing or during an ordinary build. Libraries can return
the same type from their own compile functions, including providers that do not
use Git.

The surrounding import may bind any provider result to a local namespace:

```abla
import github("AndreBaltazar8/abla-mvc") as mvc
```

The alias affects source lookup only. Lock identity, vendoring, offline cache
keys, and canonical declarations continue to use the resolved package and
module identity.

## The source protocol

The provider-facing structures are:

```text
ImportSource
  stable package name
  provider identity and selector
  deferred () -> ResolvedImport resolver

ResolvedImport
  immutable revision
  package entry path
  array<ImportFile>

ImportFile
  relative path
  contents
```

Construct a content provider with `importSource(name, identity, selector,
resolver)`. The resolver is a compile-time function returning
`resolvedImport(revision, entry, files)`, and each file is made with
`importFile(path, contents)`:

```abla
compile fun resolveGeneratedMvc(): ResolvedImport = resolvedImport(
    "schema-v3",
    "src/generated-mvc.ab",
    [
        importFile(
            "abla.toml",
            "name = \"generated-mvc\"\nentry = \"src/generated-mvc.ab\"\n"
        ),
        importFile(
            "src/generated-mvc.ab",
            "fun mvcRevision: int = 3\n"
        )
    ]
)

compile fun generatedMvc(): ImportSource = importSource(
    "generated-mvc",
    "company-schema:checkout-ui",
    "v3",
    resolveGeneratedMvc
)

import generatedMvc()
```

This protocol can represent generated code, an internal registry, an archive,
a database snapshot, or another source mechanism. The resolver decides how to
produce files; the package layer only validates and locks its result. File
paths must be relative and contained, the result must include `abla.toml` and
the declared entry, and total content is bounded to 128 MiB.

`gitImportSource(name, url, selectorKind, selector)` is the Git implementation
of the same `ImportSource` type. Selector kinds are `rev`, `tag`, `branch`, and
`head`. `github("owner/repository")` is a convenience provider using `HEAD`.
For example:

```abla
compile fun companyMvc(): ImportSource = gitImportSource(
    "abla-mvc",
    "ssh://git@git.example.invalid/platform/abla-mvc.git",
    "tag",
    "v0.1.0"
)

import companyMvc()
```

Provider expressions may compute names, identities, and selectors using pure
compile-time Abla. Their deferred resolver is invoked only by an explicit
`package update`; an ordinary build evaluates the stable `ImportSource`, reads
the lock, and never calls the resolver. This separation prevents a build from
silently moving or regenerating a dependency. Resolver filesystem, process,
environment, network, clock, random, or native effects must also be explicitly
listed in the root manifest's `compileCapabilities`; the update otherwise
reports `E_IMPORT_PROVIDER_EFFECT_DENIED`.

Every resolved package contains `abla.toml`:

```toml
name = "abla-mvc"
version = "0.1.0"
entry = "src/abla-mvc.ab"
```

The entry is a library module and does not need `main`. Relative imports stay
inside the materialized package. Provider imports in dependency entries are
discovered transitively; incompatible duplicate names and cycles are rejected.

## Hosted system libraries

A hosted root program may explicitly request installed system/driver libraries:

```toml
name = "vulkan-application"
version = "0.1.0"
entry = "src/main.ab"
nativeLibraries = ["vulkan"]
```

Each distinct name becomes one separate `-l<name>` linker argument. The nearest
ancestor root manifest may list at most 32 names of at most 128 ASCII letters,
digits, `+`, `-`, `.`, or `_`. Malformed arrays, duplicate names, paths, empty
entries, and non-hosted targets are rejected with a specific diagnostic. The
complete manifest is already part of the native cache identity, so changing the
list cannot reuse an artifact linked under another contract.

This surface is for specification/system boundaries whose entry declarations
remain ordinary Abla `extern:"c"` declarations, such as an installed Vulkan
loader. It does not compile foreign project source or introduce implicit
libraries from source inspection. The root application chooses and audits its
native dependencies; dependency manifests do not silently add linker inputs.

## Lock, cache, offline mode, and vendoring

Create or explicitly refresh the lock with:

```sh
ablac package update --project .
```

Lock format version 2 records the provider kind, stable identity, selector,
immutable revision, content-tree digest, and package entry. Git records also
include their URL and selector kind. Builds never update the lock. Changing a
branch, remote HEAD, generator, or registry response has no effect until the
next explicit update.

Resolved content uses `$ABLA_PACKAGE_CACHE` when set, then
`$XDG_CACHE_HOME/abla`, then `$HOME/.cache/abla`. Git fetches are shallow and
content providers are materialized from their returned files. Both paths are
bounded to 128 MiB, indexed by a deterministic tree digest, validated against
the lock, and published by rename only after validation. Project-local
materialization under ignored `.abla/` is also transactional.

Use `--offline` to prohibit a Git cache fill:

```sh
ablac build --project . --offline
ablac run --project . --offline
```

An absent or corrupt locked checkout produces `E_PACKAGE_OFFLINE_MISS`. A
non-Git cache miss in an online ordinary build produces `E_PACKAGE_CACHE_MISS`
and instructs the user to run `package update`; ordinary builds never invoke a
custom resolver as an implicit cache-recovery mechanism.

For a checked-in, air-gapped graph:

```sh
ablac package vendor --project .
```

This publishes `vendor/<package>` with revision/digest markers. Offline builds
prefer a matching vendor tree when the external cache is unavailable.

## Capability policy

Dependency manifests may list `compileCapabilities`, but only the root
project's `abla.toml` authorizes them. Preparation fails before compilation
with `E_PACKAGE_CAPABILITY_DENIED` naming the dependency, locked revision,
source identity, requested capability, and root manifest.

Legacy manifest `[dependencies]` entries using inline `git` plus exactly one
of `rev`, `tag`, or `branch` remain accepted and share the same lock graph.
Provider expressions are preferred because they are typed and composable Abla
code.
