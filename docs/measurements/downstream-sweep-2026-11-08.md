# Downstream sweep, 2026-11-08

Every `abla-*` checkout's own CI steps, each at its `origin/HEAD`, run with a master compiler built
from `174d1d46` (stages 1 and 2 from v0.2.49; the main checkout's `build/ablac` is the v0.2.50
release and was not used). A repo's steps are its CI workflow's `make` targets, run where no credentials are
needed; a step that needs a service is noted in its cell. "Pin" is the `setup-abla` version in its workflows.

| Repo | Tested at | CI pin | Result |
|---|---|---|---|
| abla-blockchain | 92c6f83 | 0.2.32 | test ok; test-ct ok |
| abla-cli | 20cc9f1 | 0.2.50 | test ok |
| abla-compare | baed16d | none | server build ok |
| abla-embedded | ea90137 | none | check ok |
| abla-food | 08a3397 | none | test ok (against a throwaway PostgreSQL 16 on 127.0.0.1:15432, db `mimo`; without a database it fails with "Mimo could not reach its kitchen database") |
| abla-graphics | 34786d5 | none | test-core ok |
| abla-mcp | af7e95d | none | check ok |
| abla-mjml | 0bdd5ea | 0.2.50 | test ok |
| abla-mobile | 8c0df8e | 0.2.48 | tools/test-file-exports.sh ok; tools/test-android-build-config.sh ok; tools/test-mobile-template.sh ok |
| abla-mvc | a21baba | none | test-library ok |
| abla-nats | 0bd19ea | none | check ok |
| abla-one | 9b0ee3f | 0.2.48 | test FAIL(2): 42 tests pass; `tests/backends/android_tree.ab` and `ios_tree.ab` fail with E_PACKAGE_IMPORT for the locked `abla-mobile` (identical on v0.2.50) |
| abla-pdf | 68982d9 | 0.2.45 | test-in-shell ok |
| abla-postgres | b56c87a | none | check ok |
| abla-printers | 7f4f7b1 | 0.2.45,0.2.48 | test-in-shell ok |
| abla-qr | 4fdc564 | 0.2.50 | test-in-shell ok; interop ok |
| abla-redis | 9f66e87 | none | check ok |
| abla-s3 | b884bc4 | 0.2.45 | test-in-shell ok |
| abla-saft | 3eadffc | 0.2.50 | test-in-shell ok; programs-in-shell ok |
| abla-smtp | 094110f | none | test ok |
| abla-soap | 326cf4a | 0.2.32 | test ok; at ok |
| abla-stripe | f5d220c | none | check ok |
| abla-testrunner | 4a79746 | none | check ok |
| abla-web | 224870e | none | check ok |
| abla-xml | fea4622 | 0.2.29 | unit ok; conformance ok; fuzz ok |
| abla-lsp | origin/HEAD | 0.2.46 | `npm test` with `ABLA_COMPILER` set to the master compiler: 61 pass, 0 fail (66 tests) |
| abla-tmlanguage | origin/HEAD | none | `npm test`: 3 pass (no Abla compiler involved) |
| abla-web3d | ca5320d | none | no test suite; `examples/characters` builds to a 647,518-byte Wasm module |

No ablac regression was found.

- `abla-food`: its integration test needs a PostgreSQL; against a throwaway PostgreSQL 16 started from nix it passes.
- `abla-xml` `make written` needs `xmllint`; with libxml2 from nix, `xmllint --noout` and `tools/check-written.py`
  pass (2,000 documents, 0 failures). It is not in the table's steps.
- `abla-embedded` `make check` passes at `origin/master`. A checkout 3 commits behind fails with 71
  `call.target`/`region.noescape-effect` errors that v0.2.49 gives too.
- Not run: `abla-doom` (needs xvfb and a GPU), `abla-site` (a deploy, dirty checkout), `abla-tmlanguage` (Node only), `abla-original` (an archive
  of the old tree).
- Local checkouts behind origin when the sweep began: abla-mobile 51, abla-web3d 87, abla-one 47, abla-mvc 4,
  abla-compare 3, abla-embedded 3.
- Pins older than 0.2.50 (the repos still pass with master's compiler): 0.2.29 abla-xml; 0.2.32 abla-blockchain,
  abla-soap; 0.2.45 abla-pdf, abla-printers, abla-s3; 0.2.48 abla-printers, abla-mobile, abla-one. abla-cli,
  abla-mjml, abla-qr and abla-saft are at 0.2.50.
