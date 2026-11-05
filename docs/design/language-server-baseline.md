# Analysis service baseline before LSP changes

Measured 2026-11-05, before any code edits, on CPU 8 (one CPU), in the compiler
Nix shell. Three fresh service processes, each given a private fresh
ABLA_CACHE_DIR. Compiler: copied `ablac-cv-keep.bin`, stage 2 of `e597422f`;
lead confirms the only difference from Prepare `144a3c1f` is the compiler version
string. Sysroot: this `144a3c1f` worktree. No full suite or build ran for this
measurement. These are warm-filesystem, fresh-process runs, not an OS page-cache
flush. Other agents were active; treat wall numbers as loaded-machine samples.

Input: a frozen read-only-source copy of abla-one at `07190938d315fba40133a6d514fb80ddaec050ef`,
132 Abla files (999,643 bytes) plus manifests/lock files. Excluded the same
artifact directories the service ignores. No file in the original repo changed.
Entry overlay: `src/one.ab`; edit prepends one valid comment line.

Session: initialize with the project directory; analyze; analyze again without
changes; open the unchanged entry; change it to version 2 with the comment;
analyze; shutdown. A timer surrounds request write through full response read,
excluding Python JSON decoding.

| Request | Median seconds | Range seconds |
| --- | ---: | ---: |
| cold | 9.308 | 8.197–9.816 |
| unchanged | 9.001 | 8.327–9.271 |
| edit | 9.724 | 8.723–10.241 |

Cold startup through the first complete response: median 9.420 s.
Each snapshot has 132 documents, 7,049 diagnostics and 13,921,605 response bytes
(13,921,627 after the comment edit). The same-process unchanged request does
not avoid the parse/sema/serialization work.

The high diagnostic count is a correctness limitation, not abla-one failing a
build: the current analysis service scans all workspace files, connects only
locally present import edges, and does not load the build's full stdlib/package/
contract graph. These timings must not be compared as equivalent work to a CLI
build or used to promise subsecond full-project sema. The design's future
latency estimates remain unverified targets until graph-aware measurements exist.

Raw requests' responses, stderr, fixture file list and times:
`build/lsp-lab/{round-0,round-1,round-2,baseline.json,baseline.log,fixture.json}`.
Harness: `build/lsp-lab/baseline.py`. Compiler SHA256: `d09e7d58fe9055c97b9b61c58c5fb6ac75ee1d2cefae08898531fd0968a1d3e5`.

## One phase breakdown

A scratch `144a3c1f` compiler with monotonic timestamp probes (not production
changes) gives a 9.596 s cold session. Its analyze response is byte-identical to
round 0 above, SHA256 `a242bb33ae50700a000e40d2abb02ce77a3ab7182f0ac849ec09b6d7d6e968a1`. Stage intervals:

| Work | Seconds |
| --- | ---: |
| Source collection | 0.001 |
| Lex/parse all 132 files | 0.039 |
| Import components | 0.313 |
| Sema plus declaration/request gathering by component | 1.951 |
| Symbol export | 0.063 |
| Reference export | 6.719 |
| Diagnostic export | 0.242 |
| Final JSON encoding | 0.140 |

Reference export is ~70% of the full session (~72% of snapshot construction);
sema ~20%, import-component discovery ~3%, final JSON encoding ~1.5%. These are
wall intervals from one instrumented run; timings include scheduling/GC and
minor probe overhead. Do not sum the inclusive snapshot interval with its
children. Sema runs per import component, not separately per file. There were
11 components; the largest took 1.946 s.

`bootstrapAnalysisOccurrencesJson` scans declaration identities, resolved names
and typed calls again for every identifier token. This repeated export lookup
is the major avoidable cost; 13.9 MB JSON encoding itself is not. The LSP must
index semantic locations/identities once per snapshot and answer positional
queries without exporting all workspace occurrences. This does not remove the
separate missing-module-graph correctness gap.

Raw phase intervals and response:
`worktrees/ablac-lsp-profile/build/lsp-lab/{phases.json,phases.log,response.jsonl}`;
probe compiler and harness are in that scratch worktree only, not the refactor.
