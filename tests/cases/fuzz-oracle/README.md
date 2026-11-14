# The fuzzer's JSON oracle fixture

`json.jsonl` holds 436 values with the strings Python's `json.dumps` and the Python fuzzer's Abla-literal function
computed for them when tools/fuzz-differential (Python) was the reference: the compact expectation
(`separators=(",", ":")`, `ensure_ascii=False`), the spaced source text with and without `ensure_ascii`, and the
Abla string literal of the compact text. 400 values come from that fuzzer's `json_check` value generator (seeds
0–399, depth 2 and, from seed 300, depth 3); the rest are its `yaml_check` trees and edge cases (DEL and other
control bytes, U+2028, astral code points, empty containers).

`tools/fuzz/run --selftest` (tools/fuzz/oracle.ab, `fuzzOracleSelftest`) checks that the Abla fuzzer's own serialiser
writes every one of these strings byte for byte. The JSON and YAML checks take their expectations from that
serialiser, never from abla/json or abla/yaml; abla/json only reads this file.
