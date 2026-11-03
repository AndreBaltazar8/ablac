# Arrays

The `array<T>` type, indexing, `append`, `truncate` and `clear` are built into
the language ([arrays](../language.md#arrays)). Import `abla/array` for the
following additional helper:

| Function | Result |
|---|---|
| `values.removeLast()` | Removes and returns the last element. An empty array panics with an index-out-of-bounds error. |

`removeLast()` works for non-affine element types, at runtime and compile time.
Arrays owning resources cannot use it: removing a resource without dropping it
requires a move-out operation that arrays do not yet provide.

```abla
import "abla/array"
val values = [10, 20]
val last = values.removeLast() // 20; values now contains [10]
```
