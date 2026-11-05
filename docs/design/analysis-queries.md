# Indexed analysis and positional queries

This extends [graph-v1](analysis-graph.md), without changing default protocol-1
requests or snapshot bytes. The separate abla-lsp project has not been updated.
Clients opt in with `analysisMode: "graph-v1"` and check `analysis-queries-v1`.

## Queries

The JSON-lines schema-1 envelope is unchanged. New methods:

| Method | Result `value` |
| --- | --- |
| `query/definition` | The declaration's existing symbol record, or null |
| `query/hover` | `{range, type, symbol}` at an identifier, or null |
| `query/references` | `{uri, range}` locations, including the declaration |

Parameters are a local absolute file `uri`, a nonnegative integer UTF-8 byte
`offset`, and optionally the last observed `revision` string. Ranges are half
open. An offset in whitespace, a comment or at end-of-file has no identifier.
A hover's type may be empty when sema did not export a type at that token; its
symbol detail retains the compiler's declaration description. Unknown targets
return null or an empty reference array, never a guessed cross-file name match.

```json
{"schema":1,"id":2,"method":"query/definition","params":{"uri":"file:///project/main.ab","offset":85,"revision":"1"}}
```

The result is `{revision, complete, pending, value}`. The same pre-CT limitations
as graph-v1 apply: a known target can be queried while `complete` is false.
`stale_revision` rejects a supplied revision after source or configuration changes;
`document_not_analyzed` rejects a file outside the selected program graph.
Offsets outside the file and invalid URI/number forms use `invalid_params`.
Legacy mode continues to reject these methods with `method_not_found`.

## Indexing and invalidation

Reference export previously scanned every declaration, resolved name and typed
call for every identifier. It now builds one semantic-group index of resolved
name spans, per-source calls and declaration handles. Declaration selections use
an exact span map; call spans use a binary search into the source tokens, visiting
only tokens within each call. The original precedence and first-success ordering
remain unchanged. This optimization also serves legacy schema-1 export.

Graph mode retains one immutable exported snapshot plus indexes by document path,
declaration ID and reference target. A positional query binary-searches the
selected document's occurrences. It does not encode or transmit a full snapshot.
There is no edit history or retained semantic AST in this cache.

Every request still loads and validates the module graph. Before reusing a
snapshot it compares exact source, manifest and lock contents and graph diagnostics,
and checks the overlay revision. This deliberately avoids stat-only validation.
An unchanged request reuses the exported snapshot; an edit rebuilds sema and
replaces the current generation. Changing the entry resets module state. This
is bounded snapshot reuse, not incremental function-level type inference.

`tools/test-analysis-graph.sh` covers positional UTF-8 offsets, cross-file
references/definition/type queries, empty and invalid positions, stale revisions,
overlay changes/close, disk changes, incomplete CT and legacy method rejection.

## Measurement

Three alternating rounds on CPU 6, fresh cache per process, same frozen abla-one
entry graph as [the graph baseline](analysis-graph.md). The comparison is the
`77673baa` stage-3 compiler against the indexed compiler. Host load reached about
37; all samples, including a 9.76 s baseline outlier, are retained in
[analysis-query-measurements.json](analysis-query-measurements.json).

| Request | Graph baseline median (range), seconds | Indexed median (range), seconds |
| --- | --- | --- |
| Cold | 4.438 (4.392–9.763) | 2.294 (2.144–2.591) |
| Unchanged snapshot | 5.107 (4.953–6.290) | 0.284 (0.278–0.333) |
| Prepended-comment edit | 4.707 (4.519–6.128) | 2.515 (2.412–3.254) |

All nine paired snapshot replies are byte-identical: 26 modules, zero diagnostics,
three pending CT sites, 9,142,474 bytes before the comment edit. For a typed
identifier in a reached project module, warm definition/hover/reference queries
had medians 0.155 / 0.094 / 0.152 s and replies 1,293 / 1,349 / 1,332 bytes. These
include graph/input validation; they do not claim incremental semantic analysis.

## Validation

Based on `1db99b32`, including its launcher-path correction. The baseline compiler
is byte-identical to the lead's frozen ag stage 2. The new graph/query and legacy
analysis-service scripts pass through **build/ablac**, the symlinked limited
launcher used by the suite. The frontend-analysis target also passes.

Full default-protocol replies for abla-one plus a UTF-8 overlay are byte-identical
to frozen master. Fib, nbody and JSON readers retain exact LLVM IR and executable
bytes. Two self-builds produce byte-identical stage 2 and stage 3 executables
(SHA-256 `0fbe77aaa3a6b29c7a96ebe6bb3677c74b607ee4a51444b4edcab18ab6a252b6`).
The full suite remains the lead's gate; no abla-lsp repository edits or public
protocol-client release are included.
