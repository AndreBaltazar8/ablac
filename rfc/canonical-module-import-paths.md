# Bug RFC: Canonicalize Module Paths Before Graph Identity and Deduplication

- Status: Implemented baseline (lexical identity, graph/cache/watch regression gate)
- Affects: self-hosted module loader and watched builds
- Discovered by: Abla MVC modularization

## Summary

The self-hosted module loader currently uses unresolved textual paths as module
identities. Two import paths that lexically identify the same file can therefore
load and bundle that file twice, producing duplicate declarations and
inconsistent graph, cache, watch, and cycle behavior.

For example, these graph edges can refer to the same file:

```text
mvc/html.ab
controllers/../mvc/html.ab
views/../mvc/html.ab
```

They are currently treated as three different module keys.

The language contract already states that imports are canonicalized and cached.
The self-hosted implementation should normalize every resolved import path
before using it for graph identity, deduplication, snapshots, dependency
fingerprints, cycle detection, diagnostics, or file watching.

## Reproduction

Create this source tree:

```text
app.ab
mvc/
  html.ab
controllers/
  home.ab
views/
  home.ab
```

`mvc/html.ab`:

```abla
class Html(val body: string)
```

`controllers/home.ab`:

```abla
#import("../mvc/html.ab")

fun controllerHtml(): Html = Html("controller")
```

`views/home.ab`:

```abla
#import("../mvc/html.ab")

fun viewHtml(): Html = Html("view")
```

`app.ab`:

```abla
#import("mvc/html.ab")
#import("controllers/home.ab")
#import("views/home.ab")

fun main: int = 0
```

Compile from the parent of the source tree:

```sh
build/ablac build ../abla-mvc/app.ab -o ../abla-mvc/build/app --no-cache
```

Observed diagnostics in the MVC project included:

```text
symbol.duplicate:MvcHtmlAttribute
symbol.duplicate:MvcHtml
symbol.duplicate:mvcHtmlAttribute
symbol.duplicate:mvcHtmlElement
```

The declarations were not duplicated in source. The same module was bundled
under multiple textual paths.

## Root cause

`bootstrapResolveImport` currently constructs a path by joining the importing
module's parent path and the requested path:

```abla
fun bootstrapResolveImport(importer: string, requested: string): string {
    var result = Path(importer).parent().child(requested).text
    if (requested.size > 0 && requested[0] == 47) result = requested
    if (requested.size >= 5 && requested.slice(0, 5) == "abla/") {
        result = "stdlib/$requested/entry.ab"
    }
    result
}
```

The resulting string is not normalized. `BootstrapModuleGraph.contains` then
compares module path strings directly:

```abla
if (this.modules[index].path == modulePath) found = true
```

Consequently, `mvc/html.ab` and `controllers/../mvc/html.ab` do not compare
equal even though lexical dot-segment removal identifies the same path.

The same raw string also flows into module snapshots and watch paths, so this is
not only a duplicate-symbol diagnostic issue.

## Expected behavior

All resolved source paths should receive one deterministic canonical module
identity before entering the graph.

At minimum, canonicalization must:

- remove `.` segments;
- resolve `..` segments lexically;
- collapse repeated `/` separators;
- preserve a leading `/` for absolute paths;
- prevent `..` from walking above an absolute root;
- define how relative paths above the compilation root are represented;
- use one stable separator spelling; and
- canonicalize standard-library resolutions through the same identity path.

Given:

```text
views/../mvc/./html.ab
mvc//html.ab
mvc/html.ab
```

all three imports should produce the same module identity:

```text
mvc/html.ab
```

## Lexical canonicalization versus filesystem identity

The first fix should be deterministic lexical normalization. It must not require
the target file to exist and should not silently introduce host-dependent
`realpath` or symlink behavior into reproducible compilation.

Whether symlink aliases identify one module is a separate package/filesystem
policy question. If symlink resolution is later required, it should be explicit,
capability-controlled, and included in build inputs. This bug can be fixed
without resolving symlinks.

## Proposed implementation

Add one path-normalization function in the phase-safe path layer or module
loader, for example:

```abla
fun bootstrapNormalizeModulePath(value: string): string
```

Apply it after resolving the requested import and before every graph operation:

```abla
fun bootstrapResolveImport(importer: string, requested: string): string {
    var result = Path(importer).parent().child(requested).text
    if (requested.size > 0 && requested[0] == 47) result = requested
    if (requested.size >= 5 && requested.slice(0, 5) == "abla/") {
        result = "stdlib/$requested/entry.ab"
    }
    bootstrapNormalizeModulePath(result)
}
```

The graph should defensively normalize its root path as well. Correctness must
not depend on every caller remembering to normalize before calling `load`.

One canonical identity should be used consistently for:

- `BootstrapModule.path`;
- `BootstrapModuleSnapshot.path`;
- graph membership and cycle detection;
- dependency edges and fingerprints;
- frontend snapshot keys;
- native object cache source ordering;
- `serve` watch paths; and
- module-path diagnostics.

Display paths may retain a user-friendly spelling separately if desired, but
display spelling must not be graph identity.

## Cycle detection impact

Alternate path spellings can currently obscure import cycles. For example:

```text
a.ab -> directory/b.ab
directory/b.ab -> ../a.ab
```

Without canonical identity, `a.ab` and `directory/../a.ab` may be considered
different modules. Canonicalization must happen before cycle checking so this
cycle is diagnosed once and deterministically.

## Incremental and `serve` impact

Watched compilation derives its watch set from loaded module paths. Alias paths
can currently cause duplicate watches, duplicate snapshots, or a changed file
to be associated with only one spelling of the same source.

After this fix:

- one physical lexical source path has one snapshot;
- changed import edges use normalized identities;
- the watch set contains one canonical entry per module;
- refresh/reuse counts do not count aliases as separate modules; and
- cache fingerprints do not vary solely because an equivalent relative import
  spelling was used.

## Diagnostics

Diagnostics should continue to point to the original import source span. For
missing files, a diagnostic may include both:

- the requested import spelling; and
- the normalized resolved path.

Example:

```text
controllers/home.ab:1:1: cannot load '../mvc/missing.ab'
resolved module path: mvc/missing.ab
```

## Compatibility

Programs that intentionally import the same lexical file through multiple
dot-segment aliases and expect duplicate declarations are relying on accidental
behavior and should change. Deduplicating those imports matches the documented
module contract.

The fix must not merge distinct case-sensitive paths on platforms where the
filesystem treats them as distinct. Case folding is not part of lexical
canonicalization.

## Regression tests

Add positive tests for:

1. direct and `../` imports of the same module;
2. `./` segments;
3. repeated separators;
4. nested dot-segment elimination;
5. equivalent standard-library resolution;
6. one declaration set after alias imports;
7. deterministic module ordering and emitted output;
8. one snapshot and one watch entry per normalized module;
9. reuse of an unchanged aliased dependency under `serve`; and
10. changed import edges using canonical identities.

Add negative tests for:

1. cycles expressed through alternate path spellings;
2. attempts to walk above an absolute root;
3. missing modules after normalization;
4. empty paths and paths consisting only of dot segments; and
5. paths that remain genuinely distinct after normalization.

The central regression fixture should import one provider through all of these
spellings and prove it is loaded once:

```text
shared/value.ab
./shared/value.ab
feature/../shared/value.ab
shared//value.ab
```

## Acceptance criteria

This bug is fixed when:

- every module receives one deterministic normalized identity before graph
  insertion;
- equivalent dot-segment imports are loaded and bundled once;
- duplicate declarations no longer result from equivalent import spellings;
- cycles through alias paths are diagnosed;
- snapshots, dependency fingerprints, caches, and watches use the canonical
  identity;
- diagnostics retain useful import provenance; and
- repeated builds produce identical module ordering and compiler output.

## Current workaround

Until canonicalization is implemented, applications can use a single
composition root that imports every module through one root-relative spelling.
Leaf modules must avoid importing shared dependencies through `../` paths.

This workaround is being used by the Abla MVC prototype, but it weakens normal
module encapsulation and should not be required of user programs.
