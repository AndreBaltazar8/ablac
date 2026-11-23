# Internal scorecard inputs

Run `tools/readiness.sh` from any directory (Bash, coreutils, make, Git and jq;
all supplied by `nix-shell`). It writes `docs/readiness.md` atomically. It does
not build, run tests, contact services or change the README. Refresh each release
after saving evidence. `--out FILE`, `--data DIR` (default `build/readiness`), and
`--fuzz-notes FILE` override destinations and optional historical notes.
Use `--source CHECKOUT` to apply the current generator to a tagged checkout.
The checkout supplies the source and test inventory. Pass absolute output and
data paths to keep the capture beside the release evidence.
Absent evidence is missing, never a zero or a passing score. Invalid JSON fails
without replacing the previous report. Working tree counts can include edits.

The evidence directory is local and ignored by Git. Preserve the source revision,
command, timestamp and original logs alongside each saved result. The report
prints evidence hashes for traceability, not as proof of freshness.

- `releases.json`: an array of GitHub release objects (`tag_name`, `body`, optional
  `draft` and `prerelease`). To capture published release notes, use
  `gh api --paginate --slurp repos/AndreBaltazar8/ablac/releases | jq 'add' > build/readiness/releases.json`
  after creating the directory. Check the repository remote before capture.
  Migration/Breaking changes headings delimit sections; top-level list items
  approximate break counts. Missing sections are unknown; prose is not counted.
- `release.json`: the published GitHub release object for the checkout's tag,
  including the asset list. Save `gh api repos/AndreBaltazar8/ablac/releases/tags/TAG`.
  The local tag must resolve to the source commit to report the current assets.
- `ci.json`: save `gh run view RUN --json headSha,status,conclusion,jobs,url`
  for the checkout's commit. Jobs retain their individual outcomes. A saved
  result for another commit leaves the current run missing.
- `gate.log`: a completed `tools/gate.sh` log. Falls back to `build/gate/gate.log`.
  `gate-revision.txt` records the tested revision; no revision is inferred from
  the generator's current checkout. The fixed point, suite and exit are separate
  evidence; an unfinished log is explicitly unfinished.
- `release-check.log`: optional captured verification for the published
  assets, including any failed checks. Preserve the release and command beside
  the log.
- `fuzz.json`: a hand-recorded array of campaign summaries:
  `[{"revision":"<sha>","recordedAt":"<timestamp>","command":"tools/fuzz/run ...","agree":20,"disagree":0,"exitStatus":0}]`.
  Counts are seeds, not generated checks. Preserve stdout and the actual exit
  status. A timeout is 124 and does not complete the campaign. Fuzzer scratch
  directories are deliberately ignored. The shared fuzzer note is included as
  historical narrative when available; it is not parsed into a clean bill.
- `security.md`: dated audit/vulnerability/security-fuzz evidence, including
  revision, scope and limitations. Missing by default.
- `benchmarks.md`: the benchmark owner's report from `tools/bench-languages`,
  preserving host/toolchain/revision metadata. Missing until measured.
- `siblings.txt`: the `summary.txt` produced by `tools/test-siblings.sh`; falls
  back to `build/siblings/summary.txt`. `siblings-context.md` records compiler
  revision, invocation, scope and completion. A summary without provenance is
  presented as an unattributed saved result, never as current green.
- `coverage.json`: `ablac doc`'s schemaVersion 1 JSON, falling back to
  `build/docs/coverage.json`. `totals` has `documented`, `undocumented`, `total`;
  `modules` is an array. Counts refer to public declarations.

`deployments.tsv` in the evidence directory takes precedence over the
hand-kept list here. Each takes four tab-separated columns: deployment,
compiler revision/version, evidence, last verification.
Comment and blank lines are ignored. No deployment is inferred from sibling
test success. Use `deployments-context.md` for scope, health checks, or cases
that have yet to deploy. Keep this document and the generated scorecard internal; neither
is linked from the public README.
