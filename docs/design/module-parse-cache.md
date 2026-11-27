# A cache of parsed (and later typed) standard library modules (design)

Status: stopped after measuring stage 1 (see "Stage 1: outcome"); no code landed. Asked for by the lead after the host-intrinsic
fold (#811, compile speed): measure first, and design a cache only if parsing and checking the unchanged standard library is 20% or
more of a cold build.

## What was measured

Cold builds (`--no-cache`, fresh cache directory) of the compile-speed fixtures hello and JSON, release and `--fast`, by the
stage 2 compiler of master 773efa5dd on one efficiency core (CPU 25). The instructions of the build (compiler and the tools it
runs) were sampled with perf (`cpu_atom/instructions/u`, one sample every 200 000). Each sample was assigned to the compiler
phase it fell in, using the phase markers of `ABLA_COMPILER_MEMORY_TRACE=1`, stamped from the start of the build. The user code
is 2 lines (hello) and 18 lines (JSON) against 11 486 and 24 294 lines of standard library and runtime (13 and 30 files), so the
front-end phases are almost entirely standard library work. The compiler was a build tree's, not a release package, so the
standard library's discovery records were not shipped next to it: in a package the graph-load row is smaller.

A `--fast` cold build on master also runs a nested build of the precompiled fast runtime object when it misses (ablac-49's
`fastrt-ship-49` ships that object instead). The `--fast` figures are therefore given for the program's own build only.

Share of the build's instructions:

| Phase | hello release | JSON release | hello --fast | JSON --fast |
| --- | --- | --- | --- | --- |
| graph load (read, discovery parse, imports) | 3.6% | 2.6% | 10.6% | 8.5% |
| staged parse of every module (parse.begin to prepared) | 3.7% | 2.9% | 8.0% | 14.8% |
| rest of parse (aliases, interfaces, module scoping, normalize) | 3.8% | 2.6% | 6.5% | 7.8% |
| pre-semantic pipeline (generics, overloads, expected types, borrows) | 1.4% | 6.0% | 9.7% | 14.8% |
| sema | 5.9% | 8.6% | 16.5% | 12.9% |
| front end total, by the 20% test | 18.4% | 22.8% | 51.2% | 58.8% |
| lowering, LLVM IR, optimisation, code generation, link | the rest | the rest | the rest | the rest |

(The `--fast` columns are of the build without the nested runtime build. On master's cold cache that nested build is another 41%
(hello) and 24% (JSON) of the whole, about half of it parsing and checking the runtime.)

The totals sampled this way are about a quarter below what `perf stat` counts for the same builds (hello release 3.44 G
against 4.55 G); the shares are of the sampled total.

So the test is met for `--fast` by a wide margin and about met for release. But only the first two rows are per-module work that
a cache keyed on one module's source can serve today. The pre-semantic pipeline and sema are whole-program passes
(docs/design/incremental-sema.md, "What is computed today"): generics are instantiated per program, overloads and borrow
contracts are fixpoints over the call graph.

## Stage 1: a persistent staged-parse cache (per module)

What exists: the graph load's discovery parse is already cached on disk per file (`discovery-v1-<compiler image>` in the build
cache, and shipped for the standard library in release packages as `stdlib-discovery-v1`; src/module.ab `discover`, src/toolchain.ab
`bootstrapConfigureDiscoveryCache`). The staged parse that follows (`acquireParsed`, `bootstrapParseStagedRegistered`) parses
every module a second time and is cached only in memory, for `serve` and the editor.

Proposal:
- Record the staged parse of a module in the same way, next to its discovery record. Key: the compiler image identity (as
  discovery), the module's path and source fingerprint, and its dependency fingerprint (the `dependencyFingerprint` that
  `acquireParsed` already keys the in-memory cache on: it changes when a module whose subparsers or compile-time actions it
  uses changes).
- Only modules whose staged parse has no compile-time inputs: no `#` action reads files or the environment
  (`bootstrapCompileInputsCurrent` is the existing check), and no subparser from outside the standard library. A module that
  uses none of them parses to the same declarations every time.
- Ship the standard library's records in the release package, as `stdlib-discovery-v1` is shipped, so the first build after
  installing hits as well.
- Format: the discovery record's serializer extended to the full declaration tree. A record that does not decode, or whose
  fingerprints differ, is ignored and rewritten, exactly as discovery records are.

Saves the second row and part of the first where discovery is not shipped yet: about 4% (release) to 15% (JSON `--fast`) of a cold
build, less the cost of decoding. The decode must be measured against the parse: the staged parse costs about 11 000 instructions per
source line today (hello release: 126 M for 11 486 lines), so a record read has to be several times cheaper for the stage to pay.

Risks: a cache key that misses an input gives wrong declarations silently. The guard is the existing one for discovery: the
compiler image identity in the key (any compiler change invalidates every record) plus the source fingerprint, and a test
that builds every standard library module both ways and compares the declaration trees.

## Stage 1: outcome

Two measurements stopped this stage.

Decoding a record against parsing. Over the 30 files of the JSON build (24 547 lines), each parsed in full with its function
bodies and encoded with the discovery codec, best of five on CPU 25: parse 37.0 ms, decode 17.3 ms (46%; 36% for host.ab, up to 62%
for runtime/self/entry.ab). The records are 4.6 MB, about 2.4 times the source (a record holds the source, for its equality check),
and reading them is not in the 46%. A disk record recovers about half of the staged parse.

Reusing discovery's own parse instead (no disk). On a cold build the graph load already parses every file in full and drops the
bodies, and the staged parse parses it again; a prototype kept the first parse, keyed by path and source fingerprints, and handed
it to the staged parse of a module with no subparser, provider or compile-time input (checked equal under a debug switch). It
reused only small modules. Before the staged parse, `bootstrapRewriteModuleSource` (src/module.ab) rewrites a module's text: its
private names take the module's prefix, and so do names of modules imported under an alias elsewhere and shadowed names. The
staged parse reads that rewritten text, so its source fingerprints differ from discovery's for every module with private
declarations: host.ab, runtime/self/entry.ab, host_os.ab, simd-scan-x86.ab, abla/sys/linux and abla/sys/linux/io, about 10 600 of
the 11 500 lines of a hello build. The key turned all of them away (none was reused wrongly); the 900 lines left are well under 1%
of a cold build.

What would remain:
- Rewriting on the parse tree instead of the text (the same renaming with the same binder and shadowing rules, and every node's
  positions shifted to the rewritten offsets the source-rewrite mapping expects): a large correctness surface for at most the
  staged-parse row.
- Disk records of the staged parse keyed by the rewritten text: about half of that row, for builds with a warm cache only; shipping
  them is harder than shipping discovery records, as the prefix spells the module's installed path.

Neither was judged worth it against the whole-program part of the front end (the next section).

## Stage 2: typed results (after #1132)

The larger part (pre-semantic pipeline and sema, 7% to 28%) is whole-program. A persistent typed cache needs what
docs/design/incremental-sema.md designs for the editor (#1132, now owned by ablac-3f): typed results per declaration, reused when the
declaration's checking interface and its dependencies are unchanged. Once that exists in memory, writing its frozen results for
the standard library to disk, keyed like stage 1 plus the program-wide inputs it depends on (generic instantiations requested,
target), is the cache. Designing it before #1132 lands would duplicate that work, so it is left until then.

## Interaction with the prebuilt runtimes (ablac-49)

Neither the release collector object (6e72e0e04; it replaces LLVM optimisation and code generation of a runtime region, after
lowering) nor the fast runtime object (6409fa461, `fastrt-ship-49`; a program build parses and checks a reduced view of host.ab)
removes the front end of the standard library from a program's build. A parse cache stacks with both.

## Measuring a stage

Before and after, on the same fixtures: cold hello and JSON, release and `--fast`, instructions and wall on one pinned core, five
rounds, as the compile-speed tracker (#1204) does; plus the compiler's self-build. A stage lands only if the hello and JSON figures
drop and the self-build does not rise.
