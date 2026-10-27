# Testing: `abla/test` and `ablac test`

A test program is an ordinary program whose `main` makes checks and returns
`testsPassed()`. `ablac test` builds and runs any number of them and
summarizes the results.

```abla
import "abla/test"
import "abla/text"

fun main: int {
    expectEqual(1 + 1, 2, "addition")
    expectEqual("rocket".slice(0, 3), "roc", "slice")
    expect("rocket".startsWith("roc"), "startsWith")
    testsPassed()
}
// output:
// 3 checks, 0 failed
```

| Function | Effect |
|---|---|
| `expect(condition, label)` | a check that `condition` holds; prints `FAIL <label>` when it doesn't |
| `expectEqual(actual, expected, label)` | a check that the values are equal, for `int`, `string`, `bool` and `f64`; prints `FAIL <label>: expected <expected>, got <actual>` |
| `testsPassed()` | prints `<n> checks, <m> failed` and returns `0` when every check held, else `1` |

Each check returns whether it held, and a failing check doesn't stop the
program, so one run reports every failure.

Run test programs with `ablac test`:

```text
$ ablac test tests/math.ab tests/text.ab
3 checks, 0 failed
PASS tests/math.ab
FAIL addition: expected 3, got 2
3 checks, 1 failed
FAIL tests/text.ab (exit 1)
1 passed, 1 failed
```

`ablac test` builds each file (into `build/abla-test/`), runs it, prints
`PASS <file>` or `FAIL <file> (exit <status>)`, and ends with a summary. Its
exit status is 1 when any program failed. It accepts `--no-cache` and
`--cache-dir <dir>` like `ablac build`. A directory names its files ending in
`test.ab`.

Several files build as few programs as possible, so the modules they share
are compiled once rather than once per test. A generated program imports each
file under an alias (so files may reuse names such as `main` or a helper's)
and runs the test its argument numbers, each test in a process of its own:
its globals start fresh and its crash or exit status is its own, exactly as
when it is built alone. Files that declare the same extension member,
`extend` conformance or extern go to separate programs. A file whose build
fails (or whose imports do) is built and run on its own, which reports its
errors; the others still share their program. `--each` builds every file on
its own; `-v` lists which files share a program.
