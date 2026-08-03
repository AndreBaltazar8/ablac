# Package imports

Abla package imports are compile-time source-provider expressions. The common
GitHub form is:

```abla
#import(github("AndreBaltazar8/abla-mvc"))
```

`github` does not fetch during parsing or an ordinary build. It is a pure
compile-time function that describes a Git source. `ablac package update`
resolves that mutable source to a commit and tree digest, writes `abla.lock`,
and transactionally populates the package cache. Normal builds consume only
the locked identity.

## Custom providers

Ordinary compile functions can implement source naming and policy. A provider
returns the descriptor made by `gitImportSource`:

```abla
compile fun companyMvc(): string = gitImportSource(
    "abla-mvc",
    "ssh://git@git.example.invalid/platform/abla-mvc.git",
    "tag",
    "v0.1.0"
)

#import(companyMvc())
```

The arguments are package name, Git source, selector kind, and selector.
Selector kinds are `rev`, `tag`, `branch`, and `head`. A provider may compute
these strings using ordinary pure compile-time Abla code. Provider evaluation
has no ambient effects: filesystem, process, environment, and network access
are denied. This keeps resolver network authority separate from compile-time
program authority while allowing libraries and organizations to define their
own conventions.

The fetched repository must contain `abla.toml`:

```toml
name = "abla-mvc"
version = "0.1.0"
entry = "src/abla-mvc.ab"
```

Its entry is a library module and does not need `main`. Relative imports stay
inside the checkout. Provider imports in dependency entries are discovered
transitively; incompatible duplicate names and cycles are rejected.

## Lock, cache, offline mode, and vendoring

Create or explicitly refresh the lock with:

```sh
ablac package update --project .
```

`abla.lock` records the provider selector, source URL, immutable 40-character
commit, Git tree digest, and package entry. Builds never update it. A changed
branch or remote HEAD is ignored until the next explicit update.

Resolved Git checkouts use `$ABLA_PACKAGE_CACHE` when set, then
`$XDG_CACHE_HOME/abla`, then `$HOME/.cache/abla`. Fetches are shallow, bounded
to 128 MiB, checked against the locked commit/tree, and published by rename
only after validation. Project-local materialization under ignored `.abla/`
is also transactional.

Use `--offline` to prohibit a cache fill:

```sh
ablac build --project . --offline
ablac run --project . --offline
```

An absent or corrupt locked checkout produces `E_PACKAGE_OFFLINE_MISS` with
the package, selector, revision, source, and cache path. It never falls back to
a newer revision.

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
source, requested capability, and root manifest. Import-provider functions
remain pure even when the root authorizes network for other compile-time code.

Legacy manifest `[dependencies]` entries using inline `git` plus exactly one
of `rev`, `tag`, or `branch` remain accepted and share the same lock graph.
Provider expressions are preferred because they are composable Abla code.
