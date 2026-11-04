# Arrays

The `array<T>` type, indexing, `append`, `truncate`, `clear` and `takeAt` are built into
the language ([arrays](../language.md#arrays)). Import `abla/array` for
`removeLast` and `removeAt`.

| Function | Result |
|---|---|
| `values.takeAt(index)` | The move-out primitive: removes and returns the owned element at `index`, preserving the remaining order and capacity. |
| `values.removeAt(index)` | A helper for `takeAt(index)`. |
| `values.removeLast()` | Removes and returns the last element in O(1). |

These operations work for ordinary and resource elements, at runtime and compile
time. They remove the slot before returning the value, without dropping or closing
it. The caller owns the result: it can move it elsewhere or let its normal scope
cleanup drop it. Array cleanup drops only the elements still in the array.
A discarded resource result is also dropped normally.

An invalid index panics before changing the array. An empty `removeLast()` panics
with `index -1 out of bounds for array of size 0`. Removing the last element is
O(1); removing an earlier element shifts the following elements and takes O(n).
Successful removals keep capacity and do not allocate storage. Mutating a shared receiver,
or removing while its resource element is borrowed, is rejected.

```abla
import "abla/array"
val values = [10, 20, 30]
val middle = values.takeAt(1) // 20; values now contains [10, 30]
val last = values.removeLast() // 30; values now contains [10]
```
