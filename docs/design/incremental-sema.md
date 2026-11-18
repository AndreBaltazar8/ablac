# Incremental semantic analysis for the editor service (design)

Status: design only, no code. Written for the decision whether to start; the numbers are measurements on the compiler's own
source (137 modules, 6.8 MB, `ablac analyze --stdio`, graph-v2 with `since`), taken with the instrumented builds named in
"Measurements". Everything else is read from `src/` at the commit this file is in.

## The problem

An edit to one module costs about 10.5 s of CPU on `src/` (a cold analysis costs 8 to 11 s: nothing is incremental except the
per-module parse and symbols cache, `graphParsed`). André edits the compiler in the editor; the editor feels the whole figure.
Where it goes (CPU, one-line edit of a leaf module, after `editor-load-cache` and `editor-growth`):

| Phase | CPU | Of which is the runtime's collector and allocator |
| --- | --- | --- |
| project load (graph.load, graph.parse of the prepared sources, compile-time sites) | 2.4 s | about two thirds |
| typing: named arguments, the pre-semantic pipeline, sema | 5.0 s | about half |
| semantic conversion and occurrence index | 0.5 s | |
| answer: occurrence sets and text for 137 documents | 2.0 s | |
| rest | 0.6 s | |

Inside typing (a cold analysis at low machine load, so wall is close to CPU: 4.7 s): named arguments 0.1 s; the receiver, generics,
expected-type and overload stages 0.9 s, of which the probe analyses they run 0.7 s; the analyzer's whole-program summaries
(mutable receivers, affine types, region calls, compile effects) 0.7 s; sema's own pass over every declaration 1.9 s; the rest is
publication of signatures and registries. The compiler's own passes are each 1 to 3% of the samples: there is no hot spot, the cost is
breadth (every pass walks every expression of 137 modules) and the allocation that goes with it.

An edit to one module changes that module's text. Almost everything the analysis computes about the other 136 modules is the same
as before, and is computed again.

## What is computed today, in order

1. `bootstrapNormalizeNamedArguments` over the whole program (named_arguments.ab): named arguments become positional.
2. `bootstrapPreSemanticPipeline` (frontend.ab), each stage a function from the whole program to a whole program:
   receiver names (`this.` made explicit; receiver_names.ab), generics (monomorphization: one copy of a generic per set of type
   arguments used anywhere in the program, named by them; generics.ab), expected types for array literals (expected_types.ab),
   overloads (distinct names per overload set, then a probe analysis types the calls that may name one; overload.ab), delegated
   properties (a probe analysis, then accesses rewritten into calls of the delegate; delegated_properties.ab), inferred borrow
   contracts (a fixpoint over return paths through the call graph; borrow_inference.ab).
3. `bootstrapAnalyzer`: whole-program summaries built before any body is looked at: affine type names, mutable-receiver summary
   (a method mutates its receiver: a fixpoint, a body is walked again when a method it calls joins the summary), region call summary
   (which functions may retain or store module values: a fixpoint), compile-effect summary (which functions may do which effects:
   transitive over callees), subparser registry, indexes of functions, types and methods.
4. `analyze`: signatures of every declaration are published, results of functions without a declared result type are inferred on
   demand from their bodies (and become `inferredResults`), then every declaration's body is typed in program order, then the
   actions. Global initializers are ordered by their dependencies across modules (`initEdges`).
5. The service converts the result into per-document occurrence sets and the answer.

Results are keyed by place: a resolved name or typed call is (source identity, begin, end). A typed call's `target` is an index
into the normalized program's declaration array; the service turns it into a declaration id (`handles`).

## What an edit can change outside its module

A module's analysis reads other modules through the channels below. An incremental analysis re-analyses a module only when one
of the channels it consulted changed, so each channel needs a fingerprint (the module's *interface*) that the edited module's new
analysis can be compared on.

1. **Signatures.** Names, parameter and result types, the kinds of parameters (`own`, `var`, `val`), defaults, type parameters
   with their bounds, extension owners, annotations (`inline`, `noinline`, `export`, `trusted`, `noescape`, `private`, `sealed`),
   interface member lists, class fields and conformances. This is what a call, a constructor call or a field access in another
   module consults.
2. **Inferred result types.** A function with no written result type has the type of its body. A body edit can change it, and
   then every caller's types change: the result type of such a function is part of its module's interface.
3. **Body-derived summaries** (step 3 above). Whether a method mutates its receiver, whether a function may retain a value past
   a region, which effects a function may perform (transitively), and the inferred borrow contract of a result all depend on
   bodies and on callees' bodies, across modules. Callers' diagnostics (borrow conflicts, region retention, compile-effect
   hermeticity) depend on them, so each function's summary row is part of the interface.
4. **Generics.** The body of a generic is instantiated in the module that uses it, with the type arguments written there: a
   generic's body is part of its interface, and the set of instances (which live as declarations of the generic's module under
   generated source identities) changes when any module starts or stops using one.
5. **Overload sets.** The distinct names are per overload set across the program, and a probe analysis picks the candidate: adding,
   removing or retyping an overload changes how calls in other modules resolve.
6. **Strict-import visibility and aliases.** What a module may name depends on its imports and on `export import` of the
   modules it imports; aliased imports rename the target's names with a module prefix, and a module imported plainly here but
   aliased elsewhere carries the prefix everywhere (`bootstrapRewriteModuleSource`). An edit to an import line is an edit to this
   table.
7. **Global initialization order and duplicate symbols.** Initializer cycles and `symbol.duplicate` are program-wide checks over
   the declarations of every module.
8. **Program-wide counters and registries** that make results depend on order: symbol numbering, the subparser registry (a
   module may register handlers the later modules see), the strict-import findings, `clashesExplained`.

A body-only edit with an unchanged interface (channels 1 to 5 equal to what they were) changes only the edited module's own
results and diagnostics. Most editing is of this kind.

## The unit of invalidation

The unit of re-analysis is the **module**, and the unit of dependency is the **declaration**.

- Results are kept per module: its resolved names, typed calls, diagnostics, inferred results and summary rows, with the source
  they were computed from. An edited module is analysed again as a whole. That avoids the offset problem below, and a module is
  small (the median of the compiler's own modules is 315 lines, 90% are under 2,200) next to the program.
- Each module records the declarations of other modules it consulted (a name resolved to a declaration, a type used, a call
  target, an instance of a generic). When a module is re-analysed its new interface is compared declaration by declaration with
  the old one, and only the modules that consulted a declaration whose interface row changed are re-analysed in turn. A
  declaration added or removed changes the rows of the modules that consulted (or could now resolve) its name: the dependency
  record includes the names that were looked up and *not* found, and the overload sets and imports consulted.

A finer unit (re-type one function body) would save the rest of the module, but needs result-keyed reuse inside a module with
shifted offsets; it is not worth its complexity before the module-granular slice is measured.

## How results keyed by source offsets survive edits elsewhere

Offsets are per source identity (per file), so an edit in module M moves no offset of any other module: their results stay valid
verbatim. Inside M every offset after the edit moves, and M is re-analysed whole: its results are replaced, not shifted.

Two things name places across modules and must not use positions or indexes:

- the typed call's `target` is an index into the normalized program's declaration array, which changes whenever any module adds
  or removes a declaration (or an instance). The incremental result must hold **declaration ids** (`abla:<source>:<begin>:<name>`
  today; the service's stable ids in graph-v2) instead, translated back to an index only where a consumer still wants one. The
  service already translates through `handles`; the change is to keep the id, not the index, in the cached rows;
- `declarationIdentity` of resolved names already is an id (a source key, a begin offset and a name); it names the offset of the
  *declaration*, which moves when a declaration's module is edited above it. The cached rows of an unchanged consumer therefore
  go through the same translation the service applies today (`aliases` from offset-based to stable ids): the consumer's rows stay,
  the id they point to is re-resolved. In graph-v2 the ids are already offset-free and need no re-resolution.

## The stages, one by one

| Stage | Locality today | What the incremental version needs |
| --- | --- | --- |
| named arguments | per call, needs the callee's parameter list (any module) | per module over the cached signatures of its dependencies |
| receiver names | per module, needs the class and extension member tables | per module; the member tables are interface rows |
| generics | global: the instance set is a function of every use | the instance set kept as a table of (generic, type arguments) with the modules that use each; a module's re-analysis diffs its uses; a changed instance set changes the generic's module |
| expected types | per module (syntax to syntax) | per module |
| overloads + probe | global names, probe types the calls | the overload set rows as interface; probe per module |
| delegated properties + probe | per module plus the class's property table | per module |
| borrow contracts | fixpoint over return paths through the call graph | per-function contract rows as interface, recomputed for the edited module and propagated to callers only if a row changes |
| analyzer summaries | whole-program fixpoints | per-function rows, recomputed for the edited module, propagated by the same worklist the fixpoints use now (they are already worklist-driven: a body is walked again only when a method it calls joins the summary) |
| sema signatures, bodies, actions | one pass over the program, in program order | per module; order matters only for diagnostics order, initializer ordering and symbol numbering, which are rebuilt from per-module rows |

A first slice does not make every stage incremental: it keeps the stages that are cheap or genuinely global as they are and
caches the expensive per-module work; see below.

## What would break it

- State kept in globals by sema and its stages (`bootstrapFloatDemandSource`, `bootstrapIdentityInterned`, the symbol index, the
  source key map, `inferredResults.settled`, the probe tables) is assumed to be per run. The incremental pass either resets what it
  must per module or the state is moved into the analyzer; this is the bulk of the mechanical work.
- Diagnostics must come out in the same order and with the same text as a cold analysis: the service compares them byte for byte
  (`edit_sequence` in tests/analysis-graph/session.mjs compares an edited service with a fresh one after every edit).
- A module analysed in isolation with a stale interface of a dependency gives wrong answers silently. The mitigation is the
  differential check below, run in the suite.

## Correctness oracle

The existing fixtures already compare an incrementally edited service with a fresh one after each edit of a small program
(`edit_sequence`, both modes). The slice adds a differential mode, `ABLA_ANALYSIS_CHECK=1`, in which the service runs the
incremental analysis, then a cold one, and fails on any difference in the answer (documents, symbols, occurrences, diagnostics,
`since` fingerprints). The suite then runs a randomised edit loop over `src/` and over `abla-one` under it: body edits, signature
edits, new and removed declarations, import edits, generic and overload edits, in random modules, each checked. Fallback to a full
analysis is always allowed (and is the default for any edit the slice does not recognise), so the check is also a check of the
fallback conditions.

## Slices, safest first

**Slice 1: an edit to function bodies whose interface rows are unchanged.** After the edit the service re-parses the module
(already cached per module), runs the pipeline stages and sema over **that module's declarations only**, against the cached
interface rows of every other module, computes the module's new interface rows and compares them with the old ones. Equal: the
module's results replace the old ones, the other modules' results are kept, and the answer is rebuilt for that one document. Not
equal (or anything unrecognised: an import line, a generic or overload set, a declaration added or removed, a module that
registers a subparser): full analysis, today's path. Entry conditions are checked from the old and new parses of the module.

**Slice 2: interface-changing edits, dependency-driven.** The re-analysis follows the declaration-level dependency records to
the modules that consulted a changed row, and only those are re-analysed (in dependency order, to a fixpoint on the rows).
Declarations added or removed, and signature edits, fall here.

**Slice 3: generics, overload sets and import edits** with the instance and overload tables above.

## Estimated saving on `src/`

CPU per analysis after an edit, from the phase table above (10.5 s today). Estimates, not measurements: the whole-program
summaries and stages that remain per analysis in slice 1 are assumed to cost a fixed 0.3 to 0.5 s of merging and fingerprinting.

| Edit | Today | Slice 1 | Slice 1 plus per-module load caches (after the frozen heap) |
| --- | --- | --- | --- |
| a function body in a leaf module (`sourcemap.ab`), same inferred types and summaries | 10.5 s | about 3.3 s: typing 5.0 to 0.5, conversion 0.5 to 0.1, answer 2.0 to 0.2, load 2.4 unchanged | about 1.2 s |
| a function body in a hub module (`module_paths.ab`, 14 importers), interface unchanged | 10.5 s | about 3.3 s (the importers' rows are unchanged, so none is re-analysed) | about 1.2 s |
| a body edit that changes an inferred result type or a summary row used by k modules | 10.5 s | full analysis (falls back); slice 2: about 3.3 s plus k modules at 0.04 s each | |
| a new function or a signature change used by k modules | 10.5 s | full analysis; slice 2: about 3.5 s plus k modules | |
| a field added to a core class imported everywhere (60 to 100 modules) | 10.5 s | full analysis | no gain: it is a whole-program change |
| an edit of an import line, a generic, an overload set | 10.5 s | full analysis; slice 3 | |

Most keystrokes of an editing session are in the first two rows, so the session average falls from 10.5 s to about 3 to 4 s with
slice 1 alone, and the saving also lowers the allocation that drives the collections (fewer collections, each over a heap that
does not grow with the program the edit did not touch).

The slice-1 figure is bounded by what stays whole-program: the project load (2.4 s, which needs the per-module caches that only
pay once the long-lived heap is not re-marked: see `frozen-heap.md` on ablac-4e's branch) and the fixed cost of keeping the
program-wide tables consistent.

## Cost and risk

Slice 1 is a refactoring of sema's entry (`bootstrapAnalyzer`, `analyze`) and the stages of the pipeline so that they can be run
for one module against cached tables of the rest, plus the interface rows and their comparison, plus the differential harness.
The sema file alone is 17,500 lines, and the global state listed above is the main risk: a stale or forgotten global gives a wrong
answer, not a crash, so slice 1 should not land without the differential check running in the gate. I would estimate it as the
largest single change to the analysis since the module graph itself. It is separable: nothing in it changes how a build analyses
a program, only how the editor service reuses results, and the fallback is today's path.

## Measurements

- Phase split of an edit: frontend trace points with timestamps (the existing `bootstrapFrontendTraceMemory` with the time added),
  phase timers in the answer loop, perf with symbolized profiles (debug-info build) of a cold analysis, of an edit and of an
  analysis with nothing changed: the collector and the allocator are 45 to 66% of the CPU of each.
- Typing split: marks around each stage of the pipeline and around the analyzer's constructor, the signature publication, the body
  pass and the actions, in one cold and two edit analyses (cold, at a machine load of 20, wall 13.6 s and CPU 10.7 s): see the table
  at the top.
- Held set: a counter of the bytes the collector marks, per collection: the service holds 541 MB between analyses (80 bytes per
  byte of source), two thirds of what an edit's collections mark.

## Checklist: the per-analysis global tables, rebuilt or kept by slice 1

Every `var` (and the `val` maps that are written to) at file scope of the files an analysis runs through, with what slice 1 does
with it when it re-analyses one module against cached rows of the rest. "Reset" means the incremental run puts the table in its
state at the start of a cold analysis before the module's run; "rebuild" means it is recomputed for the whole program from
per-module rows (cheap, a pass over the rows, not over bodies); "keep" means it is process configuration or a dedupe table that
must outlive the analysis. A table not listed here is not written by an analysis (checked by grepping `^var` and `^val .*Map` in
sema.ab, generics.ab, overload.ab, receiver_names.ab, expected_types.ab, delegated_properties.ab, borrow_inference.ab,
named_arguments.ab, module.ab, module_paths.ab, parser.ab, lexer.ab, staged_parser.ab, frontend.ab, source_rewrite.ab,
generic_types.ab, call_targets.ab, named_overload.ab, analysis_service.ab, analysis_graph.ab).

| Table | Where | What it is | Slice 1 |
| --- | --- | --- | --- |
| `bootstrapSemanticRecordNames` | sema.ab | on around an editor analysis | keep (set on for the module run, as `bootstrapFrontendTypeProject` does) |
| `bootstrapIdentityInterned` | sema.ab | one string object per distinct identity of a resolved name; emptied by each analysis so that edits leave no old identities | reset per analysis; rows of cached modules keep their own string objects (more memory, no wrong answer) |
| `bootstrapSourceKeys` | sema.ab | path to short key, used when names are not recorded | keep (the editor path records names and does not use it) |
| `bootstrapPathIds` | sema.ab | path to `p<n>` in first-use order, for the occurrence index's keys | keep; the keys only tell sources apart within one analysis, so a gap in the numbering is harmless |
| `bootstrapFloatDemandOrigin/Text/Active/Names/Source` | sema.ab | per-run flags and a count of floats that reach `any`, which decide lowering, not editor output | reset per module run, result ignored |
| `bootstrapCompileEffectReading`, `...LastReader`, `...EdgeReaders`, `...EdgeReads` | sema.ab | scratch of the compile-effect summary builder, empty outside it | reset before each summary run |
| `bootstrapSimdCurrentFeatures`, `bootstrapRuntimeModulePrefix`, `bootstrapStandardLibraryModulePrefix`, `bootstrapSemanticTargetsWasm`, `bootstrapSemanticWasmUnwinds` | sema.ab | target and library configuration | keep |
| `bootstrapSourceRewrites` | source_rewrite.ab | the rewrite of each module's source (aliased names, private names), recorded by the graph's parse and replayed on a cache hit (`bootstrapAnalysisGraphReuse`); the editor maps ranges back through it | rebuild per analysis from the per-module cache entries: the edited module's new rewrite replaces its entry, the others are replayed |
| `bootstrapGenericMethods` | generic_types.ab | "Class.method" of the generic methods of the program, for diagnostics | rebuild per analysis from the generic table |
| `bootstrapModuleImportsCurrent` | module_paths.ab | the import table of the graph parsed last, the analyzer's default | rebuild per parse (cheap); an edit of an import line falls back to a full analysis anyway |
| `bootstrapStrictVisibilityTable`, `bootstrapStrictIdentityModules` | module_paths.ab | the strict-import visibility table of a graph, and a memo from source identities to modules, emptied with each new table | reset per parse; unchanged import edges leave the table as is |
| `bootstrapModuleIdentityRoot`, `...Stdlib`, `...Prefixes` | module_paths.ab | what turns a path into a module identity; set by each graph parse | keep while the entry is the same |
| `bootstrapWorkingDirectory`, `bootstrapStrictImportsRequested`, `bootstrapStrictImportsWarn`, `bootstrapVisibilityReportPath`, `bootstrapVisibilityReportStarted` | module_paths.ab, module.ab | configuration of the process | keep |
| `bootstrapStandardLibraryVisibilityRoot/Value` | module.ab | the standard library's `visibility`, read once per root | keep |
| `bootstrapStrictImportWarningsShown`, `bootstrapVisibilityReportMemberLines` | module_paths.ab | once-per-process dedupe of warnings and report lines | keep: the incremental run must not print a warning again that a cold analysis printed once |
| `bootstrapLexMemoActive/Memo/Bytes` | lexer.ab | token memo of a build, off in the editor | none (inactive) |
| `bootstrapExpectedIndexCheckValue`, `bootstrapModuleIndexCheckValue` | expected_types.ab, module.ab | debug-check switches read once | keep |
| `bootstrapAnalysisGraphActiveEntry`, `bootstrapAnalysisGraphModules` | analysis_graph.ab | the entry the service holds and its module state (snapshots by path, acquisition counters, overlays) | keep; the snapshot of the edited module is replaced, as today |
| `bootstrapFrontendSiteCache` | frontend.ab | a module's compile-time sites by source (the editor-load-cache branch) | keep, entry replaced per edited module |
| the service's `graphParsed`, `graphQueryIndex`, `graphGenerations`, `graphReferences` | analysis_service.ab | the per-module parse and symbols cache; the current answer's index; the last eight generations' fingerprints; the references memo (filled on the first query of a revision) | `graphParsed` keep (it is the model of what slice 1 adds for sema); the others are replaced per analysis as today, `graphReferences` refilled lazily |

Not tables but the same kind of state, **inside** `BootstrapAnalyzer`, which slice 1 must build from per-module rows instead of
from a walk over every declaration: the symbol table and its index (symbol numbering follows program order), the overload and
generic probe tables, `inferredResults` (and its `settled` flag), the subparser registry, the compile-effect, mutable-receiver,
affine and region summaries, `initEdges` (global initialization order), `clashesExplained`, the stack-depth-stopped sources.

## Results (2026-11-18): the first slice, measured

Everything below is on the compiler's own source (137 modules), a hub module's body edited, graph-v2 service, an edit's CPU taken as
(a session of three analyses less a session of one) / 2, user+sys, three or four alternating rounds. The 10.5 s of the estimate above is
gone: the service's collection step and the frozen heap landed first, and an edit costs about 6.7 s of CPU today.

- **Where an edit goes** (a symbolized perf profile of an edit, 2,400 samples): the allocator and the collector are 46% (the free-list work
  of `HeapAllocate`, `HeapConsolidate`, `HeapFromBins` and `HeapMerge` is 27%, sweep and marking 14%); nothing else is above 2%
  (`bootstrapExpressionUsesStm` 1.9, `GenericRewriteExpression` 1.8, lexing 1.5, `GenericMayResolve` 1.5, ...). The profile is flat: no
  stage is worth a rewrite by itself, and the 3.3 s the table above estimated for slice 1 assumed every stage per module.
- **Typing the bodies** is about 1.3 s of an edit (`fun-bodies` 1.2 s, `method-bodies` 0.13 s of the final analysis, 0.3 s more in the probe
  analyses). A switch that skipped the bodies of every module but the edited one took an edit from 6.8 to 4.3 s, but it also left the answer
  without the rows of those bodies, so it overstated what replaying them saves.
- **The effect log is sound.** After a body edit in a hub module, what each of the 36,788 bodies of the other modules appended to 15 of the
  analyzer's accumulators (typed calls, resolved names, diagnostics, init edges, ...) was identical, in the same order. A demand inference
  rolls everything back except the result type it sets (`ct_infer.ab`), so the bodies do not contaminate each other.
- **A replay was built and checked** (src/body_replay.ab on the branch incremental-sema-1, wip commits): each body's effect recorded with a
  hash of its prepared tree, put back when the hash and a fingerprint of everything outside the bodies (signatures, symbol types, summaries)
  are unchanged, ids of moved declarations rewritten, a changed inferred result type falling back to the full analysis. ABLA_ANALYSIS_CHECK
  agreed with a cold analysis on a hub edit (5,989 and 6,005 of 6,019 bodies put back). Held as ordinary objects the rows cost +460 MB of
  peak and all the saving (the collector marks them at every collection); frozen per module (the frozen heap) an edit costs 6.15 s against
  6.70 s (-8%), the cold analysis 1.6 s more (the copy), the peak 50-100 MB more. Not worth its risk: the branch is a reference.
- **What did pay**: the collection step at 1.5 times what the service holds, up to 768 MB (editor-growth-768): an edit 6.8 -> 5.2 s (-24%),
  peak 2.25 -> 2.45-2.65 GB (2.87-2.98 GB in the memory test's loop of four); and the allocator's merge-and-split churn (~20% of an edit,
  and of builds) is the next item, in the runtime.
- **The oracle** (ABLA_ANALYSIS_CHECK, tools/test-analysis-check.sh) landed with the first slice and stays: any later incremental work
  (per-module pipeline stages, summaries) has a differential check ready.
