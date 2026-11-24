# Package imports

Abla package imports are typed compile-time source expressions. The concise
GitHub form is:

```abla fragment
import github("AndreBaltazar8/abla-mvc")
```

`github(...)` returns `ImportSource`; it is not a special import syntax and it
does not fetch while parsing or during an ordinary build. Libraries can return
the same type from their own compile functions, including providers that do not
use Git.

A longer path imports one module of the package, not its entry, the way
`abla/crypto/hosted` is one module of `abla/crypto`:

```abla fragment
import github("owner/abla-blockchain/evm")
import github("owner/abla-blockchain/bitcoin/script") as script
```

See [Subpaths](#subpaths). The surrounding import may bind any provider result to
a local namespace:

```abla fragment
import github("AndreBaltazar8/abla-mvc") as mvc
```

The alias affects source lookup only. Lock identity, vendoring, offline cache
keys, and canonical declarations continue to use the resolved package and
module identity.

## Inspecting a package
Run `ablac package search <words>` to find public libraries. Each word must
occur in the repository name, description, or keywords. Search can run
outside a project and fetches `https://abla.dev/packages.toml` with Abla’s
HTTPS client.

Run `ablac package info <name>` to look up a library by its repository name.
Names are case-insensitive, and you can omit the `abla-` prefix if there is no
exact match. If several repositories match, use the listed `owner/repo`.
You can also use `ablac package info owner/repo` directly for any public
GitHub repository. Online info reads the root `abla.toml` at the default
branch and lists the repository’s Git tags. It shows the manifest version
separately from the tags.

Search and name lookups save the latest valid catalog in the `index`
directory under the package cache. This is usually `$XDG_CACHE_HOME/abla`
or `$HOME/.cache/abla` and can be set with `ABLA_PACKAGE_CACHE`.
If a refresh fails, the command warns and uses the saved catalog. Pass
`--offline` to search or info to use the cache without network access.
Offline info shows the repository, catalog description, and keywords.
For local testing, `ABLA_PACKAGE_INDEX_URL=file:///absolute/path/packages.toml`
uses a separate snapshot for that file.

The optional top-level metadata keys are `description`, `license` (an SPDX
expression), and `compiler` (a maintainer-declared range such as
`">=0.2.60, <0.3.0"`). Use single-line quoted strings. Omitted fields are shown
as not declared. Reading the live manifest and tags needs Git and network
access.

To check a project’s locked dependencies, run `ablac package outdated
[--project <dir>]`. For Git packages, it shows the locked tag or commit and
newer tags on descendant commits, in Git version order. When the locked
commit has a tag, it reports tags that sort above it. Each compiler range
comes from the manifest at that tag. Non-Git providers are skipped. The
command reads `abla.lock` and uses temporary Git repositories. It does not
edit the lock or install packages.

To add a GitHub dependency in an existing project, run
`ablac package add <name>` for an indexed library or
`ablac package add owner/repo` directly. The command shows the selected
manifest, adds an import to the entry module, and pins that revision in
`abla.lock` along with any new transitive dependencies. Existing pins keep
their revisions. Use
`--tag <tag>` to select a release, `--project <dir>` to select another
project, or `--module src/example.ab` to put the import in an existing
module reached by the project entry. Commit the module and lockfile together.

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

```abla fragment
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

`importSubpath(source, path)` returns `source` naming one module inside it
([Subpaths](#subpaths)). `gitImportSource(name, url, selectorKind, selector)` is the Git implementation
of the same `ImportSource` type. Selector kinds are `rev`, `tag`, `branch`, and
`head`. `github("owner/repository")` is a convenience provider using `HEAD`.
For example:

```abla fragment
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

A package's modules are [strict](language.md#strict-imports) unless it says
otherwise: each sees only its own declarations and what it imports
(`visibility = "imports"` says so explicitly). `visibility = "flat"` (or the
older `"program"`) keeps every name visible program-wide, the opt-out for a
package not yet migrated; `--flat-imports` (on `ablac build`, `test` or `run`)
does the same for a package without the key (a package that says `visibility = "imports"` stays strict under the flag). A repository whose scripts call
the compiler many times sets `visibility = "flat"` in its abla.toml until its
imports are added: the manifest reaches every one of those calls. The
key belongs to the nearest manifest at or above a module, so a strict package
can depend on a flat one and the other way round.

Flat is deprecated and will be removed (decision #66). A build given
`--flat-imports`, or with a module flat because its manifest says
`visibility = "flat"` or `"program"`, prints one warning on standard error for
each place flat came from (the flag, or that abla.toml's path), however many
modules it covers:

```text
warning[W_FLAT_IMPORTS_DEPRECATED]: flat imports (visibility = "flat" in /src/app/abla.toml) are deprecated and will be removed
help: add the imports with tools/fix-imports.ab, then drop the flat setting (docs/packages.md); ABLA_ALLOW_FLAT_IMPORTS=1 silences this
```

The build is otherwise unchanged. To migrate, build with
`--visibility-report report.tsv`, run `ablac run tools/fix-imports.ab -- report.tsv`,
and remove the key or the flag (see [strict imports](language.md#strict-imports)).
CI that knowingly builds flat until then sets `ABLA_ALLOW_FLAT_IMPORTS=1`.

## Subpaths

`github("owner/repository/path")` is the package `owner/repository`, at the module
`path` inside it. Any provider's source can name one with
`importSubpath(source, "path")`:

```abla fragment
compile fun companyEvm(): ImportSource = importSubpath(companyChain(), "evm")

import companyEvm()
```

A subpath isn't a package of its own. The lock has one record for the package, with
one revision and one content digest, whichever subpaths are imported, and `package
vendor` copies the whole package. A module has one identity however it is reached:
through two subpaths, or a subpath and a relative import. Relative imports inside a
subpath's module work as anywhere in the package. Only what the program imports is
compiled: a subpath's import doesn't load the package's entry, or the other
subpaths. `package update` follows the provider imports of the entry and of every
subpath imported, so importing a new subpath that has its own provider imports
needs an update.

`path` resolves beside the package's entry: for `entry = "src/chain.ab"`, `evm` is
`src/evm/entry.ab`, then `src/evm.ab`. A package can instead list what is public, and
then only that can be imported:

```toml
[exports]
"evm" = "src/evm/entry.ab"
"bitcoin/script" = "src/btc/script.ab"
```

- `E_PACKAGE_SUBPATH_INVALID`: a path that is absolute, or has an empty, `.`, `..` or
  `.git` part, or goes through a symbolic link.
- `E_PACKAGE_SUBPATH_MISSING`: no such module; it says where it looked.
- `E_PACKAGE_SUBPATH_PRIVATE`: the package has `[exports]`, and this isn't in it.

## Import remaps

The root manifest (the `abla.toml` nearest above the program's entry) may
replace a module for the whole build:

```toml
[imports]
"abla/math" = "abla/math/v8"
```

Every module that imports `abla/math`, in the program or in anything it links
(a library with its own manifest, a dependency, the standard library), gets
`abla/math/v8` instead. This is how a program that uses one module links a
library written against another that stands in for it, when the two would
otherwise clash: their declarations are program-wide names, and the program
can't edit the library's imports. Rules:

- Both sides are written as imports are: a standard-library name, or a path
  relative to the manifest. A remap matches the module an import resolves to,
  whichever way the import is written.
- The target must declare everything the source declares publicly, with the
  same kind, name, type parameters, parameter types and result type as written
  (parameter names may differ), and a class the same methods. It may declare
  more. "Publicly" leaves out `private` declarations, names that start with
  `__` (an implementation's helpers) and bindings to compiler intrinsics or
  host hooks (an `extern` other than `extern:"c"`). Otherwise the build fails with `E_IMPORT_REMAP_MISMATCH`, which lists
  each declaration missing or different.
- A remap takes one step: a target can't itself be remapped. The target's own
  imports aren't remapped, so a target may import and wrap its source.
- Only the root manifest remaps. An `[imports]` table in any other manifest
  the build reaches is `E_IMPORT_REMAP_NOT_ROOT`: a library can't change what
  the program that links it imports.
- A module that imports the replaced module gets the target, and what it declares against it (a function or
  extension on the target's types) is the program's, however the program is named on the command line
  (`ablac build main.ab` from its directory, or an absolute path) and whether the module's package is strict or not.
  A shared module can therefore declare `fun Device.readWord()` against a stub that each program remaps to its backend.
- The manifest is part of the build cache's identity, so changing a remap
  rebuilds. A remap that no import reaches changes nothing in the output.

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
next explicit update. Commit `abla.lock`: a build installs what it locks.
`build`, `run` and `test`, for a project or a single file under one, put each
locked package under `.abla/packages/<package>` at its locked revision when it
isn't there (fetched into the cache if needed, never re-resolved), so a fresh
checkout builds what its lock says. `ablac package install [--project .]
[--offline]` does the same on its own, for CI.

Resolved content uses `$ABLA_PACKAGE_CACHE` when set, then
`$XDG_CACHE_HOME/abla`, then `$HOME/.cache/abla`. Git fetches are shallow and
content providers are materialized from their returned files. Both paths are
bounded to 128 MiB, indexed by a deterministic tree digest, validated against
the lock, and published by rename only after validation. A fetched tree is inspected before
it is checked out: it is refused (`E_PACKAGE_TREE`, `E_PACKAGE_SIZE`) with a submodule, an entry that is not a
regular file or symbolic link, a path of more than 1024 bytes or 64 levels or with a control character, more than
50,000 files or more than 128 MiB of blobs, and the fetch itself stops at 1 GiB received. The files are checked out as
the blobs the digest covers, whatever `.gitattributes` or the user's git settings say. A resolver's files may not
have a path with a control character, backslash or colon, a component of more than 255 bytes or that git, a
case-folding file system or Windows reads as `.git`, two paths that differ only in case, or more than 50,000 files.
`ABLA_PACKAGE_CHECKOUT_LIMIT_BYTES` and `ABLA_PACKAGE_GIT_MAX_BYTES` lower the 128 MiB and 1 GiB limits (tests use them). Project-local
materialization under ignored `.abla/` is also transactional.

The cache directory should be writable only by you, and may be shared by parallel builds. Each use revalidates an
entry (its files are hashed and must be the lock's tree digest; nothing inside the entry, its `.git` included, is
run) and the copy made for the build is hashed again, so a changed entry is refetched or refused; a directory others
can write is still one where they can make builds fail.

On Linux and macOS, Git reference lookups for `package update` and Git
fetches for locked checkouts each have a 120-second process deadline. Set
`ABLA_PACKAGE_GIT_TIMEOUT_SECONDS` to an integer from 1 to 3600 to override
it. `E_PACKAGE_GIT_TIMEOUT` identifies the operation, source and limit.

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

A single-file build (`ablac build path/to/program.ab`, no `--project`) installs
the locked packages of the project it is under (the nearest `abla.toml` with an
`abla.lock` beside it), except one vendored at its locked revision; then it
resolves each provider import from the importer's directory upward.
At each directory it uses the prepared copy under `.abla/packages/<package>`,
unless that directory's `abla.lock` locks the package at another revision (a
stale copy left behind after the lock moved), and otherwise, where `abla.lock`
locks the package, the checked-in `vendor/<package>` whose revision and digest
markers match the lock. The first directory whose lock names the package ends
the search. So a repository that commits `abla.toml`, `abla.lock`, and
`vendor/` builds every program under it offline, with no cache and no prepare
step, for example from a source archive in a container image:

```text
abla.toml         entry lists (or imports) the modules with provider imports
abla.lock         the locked graph
vendor/<package>  `ablac package vendor` output
tools/gen.ab      import github("owner/package") — resolves from vendor/
```

## Capability policy

Dependency manifests may list `compileCapabilities`, but only the root
project's `abla.toml` authorizes them. Preparation fails before compilation
with `E_PACKAGE_CAPABILITY_DENIED` naming the dependency, locked revision,
source identity, requested capability, and root manifest.

### Trusted and extern code in a dependency

The one line `fast-json = ["trusted.native"]` in the root's `[dependencyCompileCapabilities]` has two separate effects:

1. **Runtime code.** The dependency may define `trusted` functions and `extern` declarations (an `extern:"c"` declaration
   can be called from ordinary code, so it is the way to raw memory and system calls without `trusted`). Without the
   line, the build fails with `E_PACKAGE_TRUSTED_DENIED`, naming the dependency, the function, its file and line, and
   the line to add. This needs only the line and a digest in `abla.lock`; the root's own `compileCapabilities` need not
   list `trusted.native`. The root project and the standard library define such code freely. A dependency of a
   dependency needs a line of its own: the root names every package that defines it.
2. **Compile-time native code.** The dependency's `#` code may run native code only if the root also lists
   `trusted.native` in its own `compileCapabilities`, which bound every package
   ([compile-time.md](compile-time.md#grants-per-package)).

A library that only defines trusted code needs the first effect alone. A library that calls `abla/unsafe`'s raw-address
functions or raw constructors (`nativePointerAddress`, `NativeByteBuffer(address, ...)`, ...) does so from trusted
functions (a warning in v0.2.72, an error from v0.2.73: [language.md](language.md#trusted-native-implementations)), so
it needs this line too.

Legacy manifest `[dependencies]` entries using inline `git` plus exactly one
of `rev`, `tag`, or `branch` remain accepted and share the same lock graph.
Provider expressions are preferred because they are typed and composable Abla
code.
