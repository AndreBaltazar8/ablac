# `ablac lsp`: first implementation proposal

Status: **the native transport proposal below is superseded.**
`abla-lsp` 0.3.0 already owns LSP and transactional refactoring as a deliberately
separate project. Task #457 now extends only `ablac analyze`: opt-in graph-aware
snapshots and indexed positional queries, preserving schema 1. No native
`ablac lsp` command and no Node dependency will be added to ablac. The existing
adapter design is retained below as review history; transport/UI belong to
abla-lsp, and formatting belongs to the separate `ablac fmt` stack.

Source audit: compiler checkout `144a3c1f` (v0.2.45 preparation). The pending
formatter commits `0ec220f0` and `0abf3343` are a dependency. The ongoing
contract-loading regression fix must land before editor/build parity is gated.
This implements the parser/type API requirement in
[reliability-roadmap.md §8](../reliability-roadmap.md#8-production-usability).

## Existing APIs and gaps

The implementation should extend the compiler analysis layer and put a protocol
adapter around it. It must not implement type inference, import visibility or
language syntax in the adapter.

| Existing implementation | What can be reused | Gap before the first useful LSP slice |
| --- | --- | --- |
| [analysis_service.ab](../../src/analysis_service.ab), `BootstrapAnalysisService` | Persistent process; full-text open/change/close overlays; document versions and workspace revision; schema-1 JSON-lines protocol | This is not LSP or JSON-RPC 2.0. No framing, notification lifecycle, real cancellation or latest-result scheduler. `cancel` is currently a no-op. |
| `documents()`, `snapshot()`, `bootstrapAnalysisComponentIds` | Workspace enumeration, independent import components, source text plus diagnostics/symbols/occurrences | Every snapshot walks the workspace, reparses each document and reanalyzes every component. There is no persistent analysis-result cache. The import-component scan ignores provider edges and does not supply the build's complete module graph or prelude/dependency policy. |
| `bootstrapAnalysisSymbolsJson`, `bootstrapAnalysisOccurrencesJson` | Byte ranges, declaration IDs, container IDs, local/parameter symbols, semantic reference links, some inferred types | Types are optional; typed requests currently cover calls/member calls, not arbitrary expressions. Declaration detail is not a complete inferred signature. Definition targets need one indexed ID-to-source lookup and generated-to-source origins. IDs include byte positions and are snapshot-local, not stable across edits. Current reference export repeatedly scans semantic records per token (6.72 s of a 9.60 s measured session); cache/index positional results, not a full JSON export per request. |
| `bootstrapAnalysisSemanticGroup` | Compiler receiver-name, generic, expected-type, overload, delegated-property and borrow rewrites; `bootstrapAnalyzeRequestedSourceSpans` from [sema.ab](../../src/sema.ab) | This hand-selected sequence must be reconciled with the build pipeline, including named/default wrappers and extension processing. Raw per-file parsing does not give build-equivalent strict imports, contract twins, staged subparsers or compile-time declarations. Nor does sema alone promise every later IR/ownership diagnostic. |
| `bootstrapAnalysisDiagnosticsJson` | Located parser and semantic errors | Diagnostics are extracted from formatted text; some extension failures fall back to byte 0. Structured related locations, severity, generated-source origins and partial-analysis status are missing. |
| [module.ab](../../src/module.ab), `BootstrapModuleState.acquire/acquireParsed`, `BootstrapModuleGraph` | Source/discovery snapshots, dependency-sensitive staged parse reuse, strict-import and contract validation, registered subparsers, compile-input revalidation | The analysis service does not use this state. It needs an overlay source provider, an explicit editor execution policy and a reusable frontend entry that stops before codegen. Mutable compiler state is not safe for concurrent analyses. |
| [discovery_cache.ab](../../src/discovery_cache.ab) | Bounded, versioned discovery records, source/compiler identity checks and eligibility rules | Discovery records are not semantic snapshots. Unsaved text, blocked extensions and failed analyses must not be published as ordinary build-cache entries. |
| Pending `formatter.ab`, `bootstrapFormat(source, width)` | Compiler parser, exact comments/opaque regions, full AST check and second-pass idempotence check | Expose its validated text result as LSP edits. Do not invoke the CLI's file writer or reimplement layout. |
| [test-analysis-service.sh](../../tools/test-analysis-service.sh) | Overlay/stale-version, UTF-8 byte-span, reference, local identity, diagnostics and rewrite regressions | No LSP framing/position tests, policy/contract parity tests, incremental invalidation or editor latency measurements. |

Keep `ablac analyze --stdio` schema 1 working. The shared service gains typed
internal results; the old JSON exporter remains an adapter. Any new wire fields
or worker methods use an explicitly negotiated schema 2, not a silent change to
schema 1. Keep `refactor/validate` available to existing clients; rename and
code actions are outside the initial LSP capability set.

## First useful slice and CLI

Command: `ablac lsp --stdio` (also accept `ablac lsp` as the stdio default).
No network listener, background daemon installation or automatic package update.
Linux and Darwin use the same compiler service; unsupported hosted platforms
are not implied by the protocol.

| LSP method | First behavior |
| --- | --- |
| `initialize`, `initialized`, `shutdown`, `exit` | Negotiate the capabilities below, workspace folders and server version. Enforce lifecycle; shutdown answers with null and exit terminates. EOF or parent death drains the worker and exits. |
| `textDocument/didOpen`, `didChange`, `didSave`, `didClose` | Versioned unsaved overlays, incremental range edits and full-text replacement support. Closing restores disk state and clears that document's published diagnostics; recheck affected open dependents. Saving does not override a newer overlay. |
| `textDocument/publishDiagnostics` | Publish parser diagnostics after open/change, then replace them with merged parser/import/semantic diagnostics at the same version. Publish empty arrays when errors disappear. Report diagnostics for open documents and reachable dependency failures, with related locations when supported. Do not publish errors for every unrelated example/test under the root. |
| `textDocument/hover` | Exact occurrence type/signature from sema, including local names and resolved calls. Query the smallest enclosing supported expression span when needed through the existing analyzer; no spelling-based guessing. Use a declaration's declared signature when appropriate. Return null for unresolved/ambiguous/blocked results. Include the occurrence range. |
| `textDocument/definition` | Resolve semantic declaration identity to source selection range. Return the contract declaration for a contract-only import; use origin mappings for generated wrappers. Return null when no real source target exists. Never pick the first global with the same name. |
| `textDocument/documentSymbol` | Classes/interfaces/enums, methods, fields and top-level declarations with compiler ranges. Convert container IDs to hierarchy, or flat SymbolInformation for clients lacking hierarchy support. Exclude locals from the outline; retain them in the reference index. |
| `textDocument/formatting` | Call the same formatter at configured width (default 100). Return validated TextEdits, never write files. Refuse formatting on syntax/AST/comment/idempotence failure. Preserve the formatter's verbatim regions. No range/on-type formatting in this slice. |

Advertise incremental text synchronization, open/close and save notifications,
hover, definitions, document symbols and document formatting only. No completion,
semantic tokens, rename, workspace symbols, inlay hints or pull diagnostics yet.
Use plaintext hover by default; when Markdown is negotiated, escape source text
and fence signatures without emitting executable links or raw HTML.

Initialization options: project entry selection per workspace folder, strict
imports override only where the CLI permits it, format width, and CT policy.
Read project settings through the compiler's manifest APIs. Prefer the project's
normal entry; absent an entry, analyze the open document and its reachable imports.
Do not merge independent test/example entry points into one semantic namespace.
An open dependency can belong to multiple entry graphs; retain per-entry answers
and return multiple genuine definition locations or a reported ambiguity, rather
than mixing incompatible visibility contexts. No guessed build target execution
from opening a build script.

## Transport and process ownership

Use the deliberately bounded **LSP 3.17** feature set, over
[JSON-RPC 2.0](https://www.jsonrpc.org/specification), following Microsoft's
[base protocol](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/specification.md#base-protocol).
The compiler's existing JSON-lines envelope is an internal protocol only.

- Stdin/stdout carry `Content-Length` framed UTF-8 JSON bodies with ASCII headers
  terminated by CRLF and a CRLF blank line. Length counts bytes, not characters.
  Handle partial reads and several frames in one read. Serialize all stdout writes;
  logs, compiler traces and CT output must never enter this channel.
- Preserve string/integer request IDs. Answer requests exactly once, do not answer
  notifications, and use protocol errors for invalid requests/unknown methods.
  Bound headers (8 KiB) and bodies (16 MiB initially); reject invalid lengths
  without allocating from them. Close on framing that cannot be resynchronized.
- Implement UTF-16 positions first, including surrogate pairs, line-end clamping
  and CRLF. Internal spans stay UTF-8 byte offsets. Maintain per-version line and
  conversion indexes; do not reuse offsets across versions. See the official
  [position definition](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/position.md).
- Apply edits in notification/array order as specified by
  [didChange](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/textDocument/didChange.md).
  Reject stale versions internally without changing text; log malformed
  notifications rather than returning a notification response. A range splitting
  a UTF-16 surrogate pair is invalid; require a full-text resync instead of
  silently editing the wrong bytes.
- Parse/encode file URIs with percent escaping, authority checks and Unicode;
  keep lexical import paths and symlink spellings. Do not `realpath` documents
  and recreate the symlink-import regression. Support unsaved `untitled:` syntax
  and formatting without inventing a filesystem import base.

Use one coordinator and one persistent compiler-analysis worker initially. The
coordinator handles frames, overlays, requests and debounce; the worker runs one
compiler frontend revision at a time, in its own process. This preserves existing
compiler global-state assumptions and keeps cancellation/typing responsive during
sema or bounded CT. No parallel inference in one process. Add structured worker
requests/results to the shared analysis service, not another compiler executable
or front end. Reuse the existing process/pipe APIs.

Coalesce change notifications for 150 ms, but apply their text immediately.
Tag every work item with project configuration, graph generation and document
versions. Discard obsolete diagnostic publications. Service cached hover/outline
queries against the requested current snapshot; defer a cache miss until current
analysis, with a cancellable request. Never present an old type as current.
`$/cancelRequest` marks queued/in-flight request work; return RequestCancelled
when detected. Do not use ContentModified just because newer edits are queued.
After shutdown, admit no new analysis. A hung worker is killed and replaced,
replaying current overlays/configuration; there is never an unbounded worker pool.
Handle blocked stdout/backpressure without building an unbounded response queue.

## Incremental analysis using the compiler caches

Incremental here means **file parsing and project/component analysis reuse**,
not a new incremental parser or a promise of function-level incremental sema.

1. Add a source-provider hook to `BootstrapModuleState`: open overlays win over
   disk snapshots; overlay version/content identity replaces stat identity for
   that file. The graph uses the same hook for imports, entry re-exports,
   generated-source lookups and strict validation. No temporary shadow workspace
   with different import paths. Track disk file identity and use the existing
   acquisition/revalidation rules for unopened files.
2. Keep compiler source/discovery and staged-parse caches in the worker. Invalidate
   by content, lexical module identity, dependency fingerprints, registered
   subparser/transform inputs and compile-input journals, as the compiler does.
   A plain-file parse needs no new language-specific cache format. Never mutate
   cached ASTs during sema; use the compiler's owned-copy/pure-rewrite contract,
   or clone where a rewrite mutates. Prove that a failed/cancelled revision cannot
   poison the next analysis or a CLI build.
3. Replace whole-root recursive `documents()` analysis with the compiler module
   graph for each entry/open loose document. Load locked dependencies offline;
   use shared import scans to maintain reverse dependencies. Reparse the changed
   file, recompute edges, and invalidate affected entry/components. If a public
   declaration, generic, extension, contract, manifest, lock or CT input changes,
   conservatively invalidate all graph consumers. Do not assume a body-only edit
   is local: inferred results/effects/borrow contracts can change callers.
4. Cache completed semantic snapshots and byte-span lookup indexes by the entire
   input generation. Unchanged graphs answer navigation without reanalysis. The
   first implementation reruns sema for an affected component; finer function
   reuse needs a separate compiler design. Existing ModuleState caches reuse
   reads/parses, not a sema dependency database.
5. Watch relevant files, manifests, lock, package directories, stdlib identity
   and new/deleted import candidates; revalidate on save and before a semantic
   cache miss too. Watcher events are hints, not cache correctness proofs. Changes
   in watched dependencies recheck open consumers. Missing/deleted files discard
   their old exports. A compiler/sysroot/configuration/trust change resets the
   appropriate state; capability reduction discards CT results immediately.
6. Retain only current and in-flight project generations plus bounded reusable
   module snapshots. Drop superseded ASTs and JSON strings. Start with one active
   project worker; switch/reload inactive roots rather than keeping an LLVM-sized
   heap per workspace folder. Track memory explicitly before choosing cache caps.

Do not enable the build object/JIT caches just to answer editor queries. Discovery
cache reuse must retain compiler identity and existing eligibility checks; overlays
and editor-policy results stay memory-local. If a later disk semantic cache is
proposed, it needs its own schema and full compiler/stdlib/dependency/policy keys.
Schema-2 worker replies should send changed document results, not full workspace
text and every token occurrence for each keystroke.

## Strict imports, contracts and compile-time code

The editor must use the build's lexical import resolver, lock/provider mapping,
visibility checks, contract twins and staged extension registry. In particular,
`BootstrapModuleGraph.parse()` validates aliases/strict imports and prepares
contract snapshots; bypassing it with a concatenated workspace is not acceptable.
Extract a reusable frontend operation that accepts overlays and an **explicit
analysis execution policy**, and stops before LLVM, linking or running `main`.
The default build policy remains unchanged. The LSP adapter cannot fake contract
implementations or use global name availability to bypass strict imports.

Opening a workspace is not permission to execute its build hooks:

- Default editor mode permits ordinary parsing and semantic checking, with
  bounded, effect-free compiler evaluation only where the existing evaluator can
  enforce that policy before execution. If that cannot be guaranteed for a path,
  do not execute it. No arbitrary provider resolution, process, network, native
  trusted code, writes or build-program actions run automatically.
- A trusted-project, explicit opt-in may enable read-only CT required by a
  project. Effective rights are the intersection of editor policy, the **root
  project's own `compileCapabilities`**, the dependency subset rule and source
  `#compilerGrant` requests, checked by the compiler's transitive effect analysis.
  Do not add grants, copy authorization from a different root, or treat an LSP
  initialization option as manifest authority. Details of the existing two-part
  authorization are in [compile-time.md](../compile-time.md#capabilities-files-environment-processes-network).
- For the first slice, effectful CT beyond that read-only mode is deferred to an
  explicit CLI build. There is no general sandbox claim. Native code cannot be
  made safe merely by putting it in a subprocess. Even pure CT needs CPU, memory
  and recursion limits; kill/restart a timed-out worker and surface the reason.
- Unsaved manifests cannot increase authorization. Saved capability expansion
  requires renewed explicit project opt-in. Revocation stops current evaluation
  and invalidates its cached outputs. Each workspace root is authorized separately.
- Revalidate CT read journals and deterministic inputs before result reuse. Never
  reuse staged generated declarations produced under broader rights. Project
  manifest grants alone do not cause package fetch/update or filesystem writes.

Blocked/missing CT or unavailable custom syntax produces a located
“analysis incomplete: compile-time capability/input required” diagnostic and an
explicit partial result. Map dependents of blocked declarations to unavailable
rather than cascading guessed unknown-name errors. Independent declarations can
still have syntax diagnostics, outlines and supported semantic results. The service
must carry partial-result/tainted-origin information; this is a compiler API gap,
not something the LSP adapter infers from error-message text. Generated definitions
navigate to a recorded user origin, or have no definition; no fabricated offsets.

Report parser/import/sema findings as such. Until the frontend entry also invokes
all relevant IR ownership/region verification without emission, say explicitly
that analysis is not a full build check. Never show a successful full-build status
just because the supported editor passes have no diagnostics.

## Latency expectations and measurement

The [pre-change analysis baseline](language-server-baseline.md) measures today's
service: cold median **9.308 s**, same-process unchanged **9.001 s**, and one
comment edit **9.724 s**, across 132 documents and 13.9 MB replies. Its 7,049
diagnostics expose missing build-graph context; this is not equivalent to a CLI
build. There is **no measured incremental LSP latency yet**. Existing `analyze` retains
overlays but rebuilds snapshots; it cannot substantiate a millisecond edit-loop
claim. The following are engineering estimates/budgets for an abla-one-sized
project on a warm local machine, not benchmark results or release promises:

| Operation | Initial expectation / budget |
| --- | --- |
| Cold entry/dependency analysis | Seconds: plan for 1–5 s, with progress; no LLVM/codegen/link |
| Warm edit, syntax diagnostics | 150 ms debounce plus roughly 20–100 ms for an ordinary file |
| Warm edit, affected component sema | Roughly 0.3–1.5 s after debounce; a large connected graph or CT can exceed this |
| Hover/definition/outline from current indexes | Under 20 ms service work; no reparse on a cache hit |
| Whole-document formatting | File-size-dependent parser/formatter work; target under 100 ms for an ordinary file, measure long files separately |

A body edit can still invalidate most of abla-one. If warm semantic latency
misses the budget, report the phase breakdown first; do not add a parallel
inferencer or claim full incremental sema. Fast syntax feedback and warm indexed
navigation are useful even while the complete semantic pass takes a second.

Before implementation is accepted, measure a frozen abla-one entry and dependency
lock: cold startup, repeated no-op query, body edit, public-signature edit, import
edit, manifest/CT-input edit and an invalid edit followed by repair. Use at least
20 warm edits and report p50/p95 wall, instructions, worker peak RSS, reparsed
modules and sema reruns. Separate debounce/queue time from compiler time and JSON
serialization. Compare the same input against `ablac analyze` and CLI frontend
analysis; do not compare an editor partial result with a full build. Use a scratch
copy/read-only originals, max four CPUs and targeted tests during the release.

## Scripted JSON-RPC test plan

A Python session driver starts `ablac lsp --stdio`, sends actual framed bytes and
asserts responses/notifications from fixture projects. Use per-session private
caches and deterministic event barriers, not arbitrary sleeps. Reuse the analysis
service and formatter fixtures and retain their independent tests.

1. Lifecycle/framing: fragmented headers/body, concatenated frames, Unicode byte
   lengths, string IDs, null results, unknown requests, notification silence,
   initialize/shutdown/exit, malformed/oversized input, EOF and parent death.
2. Text: open unsaved text, multi-edit changes, stale versions, full resync,
   emoji/surrogate pairs, combining characters, CRLF, URI escapes, symlinked entry
   and dependency directories, close-to-disk restoration and disk edits while an
   overlay is open. Check every returned range against exact source bytes.
3. Diagnostics: parser and semantic errors appear/disappear at the right version;
   related generic-call/helper locations; slow v1 followed by v2 cannot publish v1;
   two unrelated fixture roots with repeated names do not contaminate each other.
4. Navigation: parameter/local shadowing, inferred values, overloaded named calls,
   generic instances, receiver methods, extension methods, aliases/re-exports and
   source-generated wrappers. Unsupported/ambiguous expressions return null, never
   a guessed definition. Verify the document-symbol hierarchy and flat fallback.
5. Import/contract parity: strict and legacy modes, illegal transitive access,
   contract-only versus full import, both import orders from the v0.2.45 regression,
   package locks/offline misses and no runtime implementation leaked into contract
   views. Compare codes/origins with the CLI frontend on the same overlays/inputs.
6. CT boundaries: default denial, explicit allowed read with both manifest and
   source grant, missing either grant, dependency requesting more than root,
   unsaved capability escalation, revocation, changed read input, generated source,
   timeout/worker restart. Negative controls try writes/process/network/native
   calls and check sentinel files/servers are untouched. A granted CLI build must
   still work; editor restrictions must not leak into it.
7. Cache correctness: import creation/deletion, inferred result/effect changes,
   changed extension registry, compiler/sysroot/lock identity and CT journals;
   cancelled/failing revision followed by repair. Warm unaffected graphs reuse
   snapshots; affected graphs match a fresh process's semantic result.
8. Formatting: exact CLI result at width 100 and another width, unchanged source
   gives no edits, AST/comment/opaque/idempotence negative controls refuse edits,
   unsaved buffers work, source on disk is untouched, stale requests do not apply
   edits on behalf of the client. Indentation/newline options cannot bypass the
   formatter's fixed style and validation rules.
9. Responsiveness/resources: cancellation during analysis, worker timeout/crash,
   many rapid edits and unopened roots, output backpressure and repeated close;
   no orphan child, unbounded generation retention or stdout log contamination.

Gate each advertised capability on its scripted tests; run Linux and Darwin
transport/lifecycle smoke tests. Add a cold/warm latency report, source/build
parity and the relevant analysis/formatter tests. Full-suite and self-build gates
for shared frontend changes remain the lead's merge validation.

## Proposed implementation order after approval

1. Shared frontend/overlay/policy API and structured diagnostics/origins; preserve
   schema-1 behavior and prove strict/contract/CT parity first.
2. LSP framing/lifecycle, UTF-16 sync, serial worker scheduling, diagnostics and
   document symbols, with scripted sessions.
3. Hover/definition indexes and missing sema expression/signature exports;
   formatter adapter after the formatter commits land.
4. Reuse/invalidation, bounds and abla-one measurements; advertise the complete
   first-slice capability set only once its gates pass.

No repository reformat, package updates, editor extension or code implementation
is included in this design change. Wait for lead approval before these steps.

## Shared-frontend extraction boundary

The first refactor moves the existing pre-semantic pipeline into `frontend.ab`,
with a typed requested-span entry reused by the legacy service. It adds lexical
source overlays at ModuleState acquisition, structured records for the existing
located-diagnostic interpretation, and an explicit graph execution policy.
Ordinary builds and schema-1 analysis retain their existing behavior.

The initial editor policy is deliberately **no evaluation at all**, narrower
than the eventual bounded-pure/read-only modes above. It bypasses staged parse
caches, registration-handler execution and named-overload probes during parsing;
it also rejects import-provider expression evaluation during graph load. It
reports blocked compile expressions, compile globals, defaults and actions, and
the guarded project analysis entry returns no sema result for those projects.
No setting in the first adapter may enable broader CT implicitly. Existing
schema-1 analysis is preserved for compatibility, not advertised as the safe
editor-policy entry.

A blocked custom subparser can leave ordinary parser errors; broader partial
recovery, authorized read-only CT and producer-side structured related locations
remain explicit follow-up work. The new diagnostic records preserve the current
textual diagnostic interpretation; this is not a claim that all compiler error
producers have already been rewritten to emit structured records.

See [the extracted API and its validation](language-server-frontend.md) for the first implementation boundary.
