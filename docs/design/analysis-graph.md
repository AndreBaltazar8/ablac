# Opt-in module-graph analysis

`abla-lsp` is the separate language server and refactoring client. The compiler
provides semantic facts over `ablac analyze --stdio`; it does not implement LSP.
The client at version 0.3.0 uses schema 1, numeric request IDs, full-text
open/change notifications, snapshots and `refactor/validate`. Its normalizer
converts compiler UTF-8 byte offsets to LSP UTF-16 offsets. No changes to that
project are required for existing protocol use.

## Compatibility and selection

The default schema-1 protocol is unchanged. A client opts in during initialization:

```json
{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":["/project"],"analysisMode":"graph-v1"}}
```

The envelope and `protocolVersion` remain 1. Added capabilities are
`module-graph-analysis-v1`, `no-eval-ct`, `pre-ct-types` and
`refactor-validation-complete-only`. Reinitialization in graph mode is rejected.
The client must explicitly select this capability; the existing abla-lsp client
has not been changed to opt in.

Each request analyzes one program entry. `entryPoints` at initialization, or
`roots` on `analyze`, selects a file or a directory with an `abla.toml` entry.
Otherwise `workspaceRoots` selects the project; a sole open file is the fallback.
Multiple entries produce an incomplete result with `E_ANALYSIS_SCOPE`, rather
than merging unrelated programs into one namespace. This first profile is the
native hosted runtime graph, not a cross-target project configuration service.

Snapshots retain `revision`, `documents`, symbols, occurrences and diagnostics.
Additional fields are `analysisMode`, `entry`, `complete` and `pending`.
A scope error uses `issues` and an empty document list. Ranges are UTF-8 byte
offsets in the returned original source, including UTF-8 comments and source
rewrites. Symbol identities come from compiler declaration/scope identities,
not cross-file spelling matches. Contract-only imports expose the projected
public signatures, not implementation locals or private declarations.

## Evaluation and package policy

The real compiler module graph resolves lexical imports, strict visibility,
aliases, contracts and existing package copies. Open source overlays replace
filesystem source without writing it. Closing an overlay reacquires disk source.
The serial process retains module discovery state; semantic analysis is rebuilt
for each request in this step. Changing the entry resets that state.

No staged parser, registration callback, compile-time expression, global, default
or package provider is executed. Sema still infers the operand of a compile-time
expression symbolically, using the compiler's existing inference. Such sites
are returned in `pending`; `complete` is false even when there are no diagnostics.
Generated declarations and custom parser syntax may therefore be unavailable.
This is a pre-evaluation view, not a claim that a full build succeeds. Grants in
source or `compileCapabilities` do not enable execution in this mode.

Literal `github`, `gitImportSource` and `importSubpath` descriptors can be decoded
as data using the compiler parser and pure descriptor constructors. Their root
lock must match, and their prepared or vendored copy must already be current.
There is no fetching, package update, resolver invocation, Git process or write.
Nonliteral or shadowed providers remain incomplete with `E_ANALYSIS_CT_REQUIRED`.

Workspace revisions compare exact observed source, manifest and lock contents,
including disk changes. `refactor/validate` checks the current revision again and
rejects incomplete baseline or prospective analysis; it cannot certify edits
whose correctness depends on an evaluation that was not performed.

## Gates

`tools/test-analysis-graph.sh` exercises JSON-lines sessions against fixture
projects: cross-file typing and overlays, private aliases, generic fields,
strict imports, lexical symlinks, contract surfaces, locked packages, blocked CT,
stale disk revisions and malformed protocol requests. Legacy protocol and normal
build parity are checked independently. Positional queries and the indexed
occurrence exporter are a subsequent step, not provided by this commit.

## Abla-one measurement

Three alternating fresh processes per arm, pinned to CPU 6, fresh compiler cache
per process, on the same frozen 132-file / 999,643-byte project as the original
baseline. The baseline payload is exactly master `4f71cc32` (the copied z stage 2).
The host was contended (load about 19 during the run); these are wall observations,
not an isolated speed guarantee. Raw timings and response counts are in
[analysis-graph-measurements.json](analysis-graph-measurements.json).

| Request | Legacy median (range), seconds | Graph-v1 median (range), seconds |
| --- | --- | --- |
| Cold analysis | 11.452 (10.571–11.603) | 3.848 (2.994–4.436) |
| Unchanged, same process | 11.992 (9.413–13.166) | 3.937 (3.250–4.281) |
| Prepended-comment edit | 12.527 (11.570–16.599) | 3.964 (3.461–5.114) |

The scopes differ: legacy scans 132 project files and returns 7,049 false
diagnostics without their real import context; graph-v1 follows the actual entry,
returning 26 modules including the runtime and **zero diagnostics**. Its three
pending compile-time sites remain explicit (two JSON parser registrations and the
compiler object initializer); it is not a complete post-CT validation. The reply
shrinks from 13,921,605 to 9,142,474 bytes. This step still rebuilds sema and exports
all occurrences; indexed queries and warm semantic reuse are the next step.

The graph fixtures pass, including rejection of prospective edits that introduce
unevaluated CT code. The existing abla-lsp 0.3.0 compiled `CompilerClient` was used
read-only against the opted-in compiler: capability negotiation, snapshot parsing
and UTF-16 normalization passed. Its repository was not modified.

Legacy full JSON replies for the frozen abla-one plus a UTF-8 overlay are
byte-identical to the baseline. Existing analysis-service and frontend-analysis
targets pass. Fib, nbody and JSON readers have exact LLVM IR and full executable
parity. A source build followed by two self-builds reaches an exact stage-2 /
stage-3 executable fixed point. The lead retains the full-suite gate; no full
suite or cross-platform execution is claimed here.
