# Projected graph analysis replies

Graph-v1 initialization advertises `analysis-fields-v1`. An `analyze` request may
select the document facts it needs:

```json
{"schema":1,"id":2,"method":"analyze","params":{"fields":["diagnostics","symbols"]}}
```

Allowed names are `diagnostics`, `symbols`, and `occurrences`. The array may be
empty; unknown names, duplicate names, nonstrings and nonarrays return
`invalid_params`. Document `uri`, `version`, and `text` are always included for
identity and byte-position conversion. All graph metadata (`revision`, `entry`,
`complete`, `pending`, `issues` when present) remains intact. The explicit view
adds a top-level `fields` array, echoing the selection.

Unrequested fact keys are **omitted**, not replaced with empty arrays. A client
must not mistake absent occurrences for evidence that a declaration has no
references. Request a full view when a feature requires all occurrences, or use
`query/definition`, `query/hover`, and `query/references`.

Omitting `fields` preserves the existing analyze response bytes exactly. Legacy
mode does not advertise this capability and retains its existing behavior.
Older clients/compilers need no changes. Only explicitly opted-in graph clients
should send the selection.

This is a projection of the existing immutable full internal snapshot. It skips
encoding and transferring unrequested facts, while retaining the complete query
index for subsequent positional queries. It does not skip initial sema or index
construction. Views of one graph have the same revision; changing a view is not
an edit. The no-evaluation policy and incomplete-refactor rejection are unchanged.

## Measurement

Same frozen abla-one input as the preceding analysis experiments, one new
compiler binary and sysroot for both views, CPU 6, three alternating rounds.
Fresh compiler/cache per round; unchanged and prepended-comment edit in the same
process. Contended host, load about 12–17 at the end. Raw data are in
[analysis-fields-measurements.json](analysis-fields-measurements.json).

The diagnostics+symbols reply is **3,779,226 bytes** versus **9,174,813 bytes** for
the full reply, a **58.8% transfer reduction**. Both contain 26 modules, zero
diagnostics and three pending CT sites. All selected facts and metadata match
the full reply.

| Compiler reply latency | Full median (range), seconds | Projected median (range), seconds |
| --- | --- | --- |
| Cold | 1.410 (1.381–1.503) | 1.695 (1.386–1.843) |
| Unchanged | 0.168 (0.165–0.200) | 0.149 (0.109–0.156) |
| Edit | 1.720 (1.522–1.920) | 1.727 (1.546–2.280) |

These timings include compiler encoding and pipe transfer, not client-side JSON
parsing/normalization. Cold/edit results show no consistent latency improvement;
the initial semantic work remains. The wire reduction is deterministic. Separate
instruction counts below cover one cold plus nine unchanged refreshes; no claim
of a cold-build speedup is made.

Three alternating instruction-counter pairs (one cold + nine unchanged replies)
measured **31.676 G** full versus **29.934 G** projected instructions,
a **5.50%** reduction, `cpu_core/instructions/u` at 100% event coverage.
This is the whole ten-refresh session, not a per-edit or isolated-sema result.

## Validation

Graph projection, invalid-selection, complete/pending preservation and subsequent
full-export/query fixtures pass through `build/ablac`. Existing analysis-service
fixtures pass through the same launcher. Full graph analyze replies match the
frozen aq compiler byte-for-byte; all legacy protocol reply lines match too.
The graph initialization adds only the new capability. Fib, nbody and JSON
readers retain exact emitted LLVM IR. Full suite validation belongs to the lead.
