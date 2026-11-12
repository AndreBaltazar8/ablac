The sources in corpus/ and the expected event values in expected.txt are selected from
https://github.com/yaml/yaml-test-suite, data branch, commit
6ad3d2c62885d82fc349026c136ef560838fdf3d (MIT; see UPSTREAM-LICENSE).
Fixture names are upstream test IDs. Scalars in the upstream event stream are
resolved using the YAML 1.2 Core schema. Maps retain their event order; aliases
resolve to their most recent preceding anchor. Numeric identities use exact
decimal coefficient/exponent strings, not binary floating-point arithmetic.

This is a selected subset, not a claim of full YAML conformance. Cases involving
our deliberately rejected features are expected errors. No network or external
YAML implementation is used by the repository test.

Layout: corpus/NAME.yaml is the source of upstream case NAME (the order is
corpus.list); expected.txt holds, in that order, the probe's canonical
one-line event value, or `error` for a case that must be rejected. These were
converted once from the former fixtures.json (a JSON array of
{name, source, expected|error}); check.sh compares bytes with diff and does not
parse any JSON. edit/NNN.json are the editing specs and edit-expected.txt the
canonical output of each (text and rollback cases from the former
edit-fixtures.json; the `-value` cases and two plain ones also pin the output
of the current editor).
