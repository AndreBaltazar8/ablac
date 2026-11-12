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

Regenerating or extending without Python: put the new source in
corpus/NAME.yaml and add NAME to corpus.list; run `probe corpus/NAME.yaml`
and, after checking the line against the upstream event stream (or write
`error` for a case that must be rejected), insert it at the same position of
expected.txt. For an edit case add edit/NNN.json (`{"name","source","ops"}`,
one line, in the name order) and take its expected line(s) from
`edit-probe edit/NNN.json` (add `value` as the second argument for a
`NNN-value.json` case). Implementation goldens, not derived from upstream or
from a stated text: every line for the `-value` specs (60: full text and
value) and the two plain cases with no expected text (flow-comment-insert,
root-empty-anchor). The other edit lines (text and rollback cases) are the
text that the former fixtures stated. Check any regenerated line by hand
before committing it.
