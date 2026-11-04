The sources and expected event values in fixtures.json are selected from
https://github.com/yaml/yaml-test-suite, data branch, commit
6ad3d2c62885d82fc349026c136ef560838fdf3d (MIT; see UPSTREAM-LICENSE).
Fixture names are upstream test IDs. Scalars in the upstream event stream are
resolved using the YAML 1.2 Core schema. Maps retain their event order; aliases
resolve to their most recent preceding anchor. Numeric identities use exact
decimal coefficient/exponent strings, not binary floating-point arithmetic.

This is a selected subset, not a claim of full YAML conformance. Cases involving
our deliberately rejected features are expected errors. No network or external
YAML implementation is used by the repository test.
