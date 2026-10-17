Differential compile-time parity probes, run by `tools/test-compile-time-parity.sh`.

Each probe is `<name>.ab` (or `<name>/main.ab`, with its own `abla.toml` and data). It
defines `parityValue(): T` and, unless `T` is `string`, `parityShow(value: T): string`.
The harness builds it twice and byte-compares what the programs print:

- runtime: `print(parityShow(parityValue()))`;
- compile time: `val staged = #parityValue()` and `print(parityShow(staged))`.

A probe may import what it needs; the harness adds `import "abla/io"`.
