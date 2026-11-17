# Opt-in module-graph analysis

The subsequent [indexed-query extension](analysis-queries.md) adds warm snapshot
reuse and positional requests. Measurements below describe the initial graph step.

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

The envelope and `protocolVersion` remain 1 (`analysisMode: "graph-v2"` selects stable ids, see below). Added capabilities are
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

An occurrence names the declaration it means (`declarationId`) in three ways: sema records the names it looks a value up by (functions, methods,
fields, locals, variables); a type written as text (`s: Square`, `Square(2)`, `: Shape`, `Box<Item>`) names the one class, interface, enum or
type of that name in the program (two declarations of one name, such as two modules' private classes, are told apart by neither, so both stay
unnamed, and a type parameter of the same name is not the type); and a name qualified by the alias of an `import "…" as geo` (`geo.area`,
`geo.Square`) names the declaration of that name in the module the alias imports (an overloaded name stays unnamed). A client that renames or
finds references therefore sees every use of a class or of an aliased function; an occurrence that stays unnamed is one the service could not
tell, and a client must not guess it.

The language's built-in types and members (`bool`, `int`, `string`, `array`, `Map`, `void`; `size`, `append`, `get`, `slice`, ...) have no
declaration in any program: sema knows them itself. The answer therefore carries one more document, `stdlib/abla/builtins/declarations.ab`, which
declares each of them (classes and methods without bodies, each with a doc comment) and is parsed for its symbols and never typed. The built-in
types and members are named from it like any other declaration (go-to-definition opens it, hover shows the declaration, find-references on
its `append` finds the calls), and a program that declares a type of the same name owns that name in its own code. sema marks the members it
handles by itself (`bootstrapBuiltinMemberKey`) and the service translates them to the module's declarations, in graph-v1 and graph-v2 alike.
`tools/test-builtin-docs.sh` keeps the module and the compiler in step: a member sema accepts on a built-in receiver and the module does not
declare, a declaration the compiler rejects, and a type the table of types in docs/language.md lists and the module does not declare each fail it.
Additional fields are `analysisMode`, `entry`, `complete` and `pending`.
A scope error uses `issues` and an empty document list. Ranges are UTF-8 byte
offsets in the returned original source, including UTF-8 comments and source
rewrites. Symbol identities come from compiler declaration/scope identities,
not cross-file spelling matches. Contract-only imports expose the projected
public signatures, not implementation locals or private declarations.

## Stable declaration ids (graph-v2)

`analysisMode: "graph-v2"` is `graph-v1` with stable symbol ids (capability `stable-declaration-ids-v1`; snapshots say `"analysisMode":"graph-v2"`).
A client that asks for `graph-v1` gets what it always got, ids that carry the declaration's byte offset
(`abla:<path>:<offset>:<name>`), so no client has to change on a flag day; the envelope and `protocolVersion` stay 1.
In graph-v1 an edit that moves offsets changes the id of every later declaration of the file, and so the `declarationId` of
every reference to it in other files, however unrelated the edit.

In graph-v2 an id is made of names, never offsets. Ids are opaque to clients (compare them, do not parse them), but this is how
they are made:

| symbol | id |
|---|---|
| top-level declaration | `abla:<module path>#<name>`, a function with its parameter types: `abla:/p/util.ab#scale(int)`; an extension is named by its owner (`Owner.name`) |
| method | its class's id, `.`, the name and the parameter types: `abla:/p/model.ab#Model.twice(int)` |
| parameter, field | the declaration's id and `/param:<name>` or `/field:<name>` |
| local, loop variable, lambda parameter | the declaration's id and `/local:<name>`, `/for:<name>` or `/lambda:<name>` |

A second symbol that would get the same id (duplicate declarations, a name declared twice in one function) is numbered:
`...~2`, `...~3`, in source order. An id changes only with its declaration's own module, name or parameter types (a local's also
with its ordinal among the same-named ones of its declaration), so the other documents of a graph keep their exports through an
edit that only moves offsets or adds, removes or edits other declarations. `containerId` and every occurrence's `declarationId`
use the same ids. On the compiler's own source (134 documents), adding a statement to a body changes the export of 5 documents in
graph-v1 and 1 in graph-v2, a comment on top of a module 17 and 1, and a changed parameter type 8 and 13 (its callers now name the
new signature: they have to change).

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
