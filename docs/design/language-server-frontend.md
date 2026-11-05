# Shared frontend extraction for the language server

This is the first implementation step of the [LSP design](language-server.md),
before the separate abla-lsp project was identified. No native LSP adapter is
planned in ablac; the next compiler step is [opt-in graph analysis](analysis-graph.md).
The [pre-change baseline](language-server-baseline.md)
records the current service's measured behavior and phase breakdown.

## API boundary

- `frontend.ab` owns the existing `bootstrapPreSemanticPipeline`, now called by
  LLVM compilation and the legacy analysis service. It retains the rewrite order
  and uses sema directly; there is no additional inferencer.
- `bootstrapFrontendLoadProject(entry, state, policy)` uses ModuleGraph's import,
  visibility, lexical identity and contract rules. ModuleState accepts source
  overlays at their original paths, including never-saved imports. Closing an
  overlay forces disk reacquisition even if size/revision happen to match.
- `BootstrapFrontendPolicy(false)` means no evaluation, including import-provider
  expressions, registration handlers and staged parsing. It does not reuse or
  publish staged parse-cache entries, or run named-overload probes while parsing.
  Compile globals, expressions, defaults and actions are reported as blocked
  original-file spans. A caller cannot get a sema result through the guarded
  project API while those sites or parser/import errors remain.
- `bootstrapFrontendAnalyzeProject` returns the normalized parse **and** its
  semantic result. Typed declaration handles belong to that normalized parse;
  clients must not index the pre-normalization declarations with them. Requested
  spans use that parse's coordinates. Reuse `source_rewrite.ab` for conversion
  between original file positions and compiler module-rewrite positions, and
  snapshot those mappings before processing another project revision.
- `frontend_diagnostics.ab` exports typed code/message/source/begin/end records
  using exactly the legacy located-diagnostic interpretation. The JSON-lines
  adapter retains its previous field ordering and contents. Producer-side related
  locations and richer partial-analysis recovery are not claimed by this refactor.

Ordinary compilation keeps its staged policy. Schema-1 `ablac analyze --stdio`
keeps its old behavior; it is not retroactively presented as the safe editor entry.
The future adapter must use the no-evaluation project entry. Bounded pure CT and
explicitly authorized read-only CT need their own additional policy work before
being enabled. `BootstrapFrontendPolicy(true)` is the existing compiler policy,
not a user-facing editor trust toggle or sandbox.

## Validation

All builds and targeted checks use at most four CPUs/jobs. No full suite runs in
this worktree; that gate belongs to the lead. The exact Prepare baseline compiler
is copied read-only from the release worktree (SHA256
`f78f21fc12d606dd333222e9f2b356be370d196807d4e36f32cc57c359772c44`).

The validation covers:

- Generations built by the baseline and by the refactored compiler; stage 2 must
  equal stage 3 byte for byte.
- Exact LLVM text and complete release executables for fib, nbody and JSON readers.
- Byte-for-byte legacy JSON-lines replies for the frozen abla-one workspace plus
  an unsaved UTF-8/call fixture, and `test-analysis-service.sh` independently.
- `test-frontend-analysis.sh`: overlay/disk restoration with matching metadata,
  never-saved dependency, typed query plus its normalized AST, no-evaluation CT
  and provider handling, compile globals/defaults, original private-module spans,
  and structured diagnostic range clamping. The staged-handler negative control
  deliberately divides by zero: normal policy invokes it and reports an evaluator
  location; no-evaluation policy does not invoke it.
- Existing strict-import, import-alias and contract-import targeted scripts.

Raw builds, parity replies, hashes and logs are under `build/lsp-lab/` in the
`ablac-lsp-design` worktree. Final build/parity results are recorded in the commit
message after these gates finish. The adapter and its scripted LSP sessions are
still a separate implementation step.

Final targeted results (2026-11-05): stage 1, stage 2 and stage 3 are all SHA256
`ef5dd1fa06a5bfbadfb0296812ba8e2aaa1a2dd4eb57e61088996869d3d596f3`.
Stage 1 was built by the exact Prepare baseline. Thus both compilers also produce
identical compiler output from the refactored source. All three programs' LLVM
text and complete executables compare equal; every targeted script above passes.
The legacy full-response replay includes the frozen 132-file workspace plus an
unsaved UTF-8/call document; all replies compare byte for byte. A final replay on
CPU 6 took 10.691 s old / 10.539 s new, one loaded pair, not a speedup claim.

Compiler ELF size is 7,974,056 bytes versus baseline 7,963,880 (+10,176, +0.13%);
this is changed compiler source, not a change in the programs it emits. No full
suite, macOS execution or public LSP implementation is claimed. Final raw logs:
`validation-final.log` (bootstrap/API tests), `validation-tail.log` and
`native-parity-final.log`; the tail was rerun on CPU 6 after the first replay
failed to start because CPU 12 was offline.

For editor use, create a fresh ModuleState with its default disabled disk
discovery cache; unsaved and editor-policy data should remain memory-local.
Persistent CLI discovery-cache configuration is not an editor initialization
option. Bound/discard session states as described in the main design.
