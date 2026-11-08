# Regular expressions

`abla/regex` is a regular-expression engine in the style of RE2: a pattern is
compiled to a small program and run by a Pike VM that follows every possible
path in lock step. Matching takes **O(text size × pattern size)** time and never
backtracks, so no pattern, however nested, can take exponential time:
`(a*)*b` against a hundred thousand `a`s is as quick as `a*b`.

```abla
import "abla/io"
import "abla/regex"

fun main {
    val compiled = regexCompile("(\\d+)-(\\d+)")
    if (!compiled.succeeded) {
        println("${compiled.error.message} at ${compiled.error.offset}")
        return
    }
    val re = compiled.regex
    val m = re.find("pages 12-48")
    if (m != null) println("${m.group(1) ?? ""} to ${m.group(2) ?? ""}")
    println(re.replace("3-4 and 5-6", "$2-$1"))
}
// output:
// 12 to 48
// 4-3 and 6-5
```

## API

| Call | Result |
|---|---|
| `regexCompile(pattern)` | `RegexCompileResult`: `succeeded`, `regex`, and on failure `error` (`message`, byte `offset` into the pattern) |
| `re.matches(text)` | `bool`: the whole text matches |
| `re.matchFull(text)` | `RegexMatch?` for a whole-text match, with groups |
| `re.find(text, start = 0)` | `RegexMatch?`: the leftmost match starting at or after byte `start` |
| `re.findAll(text)` | `array<RegexMatch>`, non-overlapping, left to right |
| `re.replace(text, replacement)` | `string` with every match replaced |
| `re.groupCount` | number of capturing groups |
| `m.start()`, `m.end()`, `m.text0()` | span and text of the whole match |
| `m.group(i)`, `m.groupStart(i)`, `m.groupEnd(i)`, `m.hasGroup(i)`, `m.groupCount()` | group `i` (0 is the whole match); `null`/`-1` when it did not take part |

`regexCompile` returns an error, never a panic, for any invalid pattern.

## Syntax

| Form | Meaning |
|---|---|
| `a`, `é`, `😀` | a literal code point |
| `\n \r \t \f \v`, `\xHH`, `\uHHHH` | control characters and code points by number |
| `\.` and any other escaped non-alphanumeric | that character |
| `.` | any code point except `\n` |
| `[abc] [a-z] [^a-z]` | a class; `]` first is literal, `-` first or last is literal; `\d \w \s \D \W \S` work inside |
| `\d \D \w \W \s \S` | ASCII digits, `[A-Za-z0-9_]`, `[ \t\n\r\f\v]` and their negations |
| `^`, `$` | start and end of the **text** (never of a line; `$` does not match before a final newline) |
| `\b`, `\B` | ASCII word boundary and its negation |
| `(…)`, `(?:…)` | capturing and non-capturing group |
| `a|b` | alternation (leftmost alternative that leads to a match wins) |
| `* + ? {m} {m,} {m,n} {,n}` | greedy repetition (`{,n}` is `{0,n}`, as in Python); add `?` (`*?`, `{2,5}?`) for lazy |

Repeat counts go up to 1000; a pattern whose expansion exceeds 100 000
instructions (`((a{1000}){1000}){1000}`) or that nests groups deeper than 200
levels is rejected. A `{` that does not start a valid repeat is a literal.

**Rejected at compile time:** backreferences (`\1`) and octal escapes, lookahead
and lookbehind (`(?=`, `(?!`, `(?<=`, `(?<!`), every other `(?` form including
named groups, unknown letter escapes, `\b` inside a class, quantifiers with
nothing to repeat (`*a`, `^*`), stacked quantifiers (`a**`, `a*+`), `{m,n}` with
`n < m`, unterminated groups and classes, and patterns that are not valid UTF-8.

## Text model

Patterns and texts are UTF-8. Literals, `.` and classes match whole **code
points**, so `.` matches `😀` as one unit and `[é-ü]` is a range of code points.
All spans are **byte offsets**, ready for `text.slice(start, end)`. A byte that
is not part of valid UTF-8 in the *text* reads as U+FFFD, one byte wide, so
matching never fails on malformed input. `\d`, `\w`, `\s` and `\b` are
ASCII-only; spell Unicode ranges out in a class.

## Semantics

The match is *leftmost-first*, as in Perl, Python and RE2 (not
leftmost-longest): of the matches starting at the leftmost position, the one a
backtracking engine would find first. Captures follow the same priority.

`findAll` and `replace` use the rule of Python 3.7+: after a match the search
resumes at its end, and an empty match may not repeat at the position where the
previous match ended, though it can follow a non-empty match (`a*` over `baac`
finds `""`, `aa`, `""`, `""`).

In `replace`, `$0` is the whole match, `$N` any group (all following digits are
the number), `${N}` the same with braces, `$$` a dollar sign. A group that did
not take part, or does not exist, is empty; any other `$` stays literal.

**Difference from Python:** when a loop's body can match the empty string, an
empty last iteration does not reset the group (`(a*)*` over `aa` captures `aa`
where Python captures the empty string). Whole-match spans are identical.

On a release build a search with a few alternatives and classes runs at about
3 to 4 MB/s (1 MB of text, 20 000 matches in 0.28 s); the cost per byte grows
with the number of instructions in the pattern, not with its nesting.

## Testing

`tools/test-regex.sh` (part of `make test`) runs unit cases, the
pathological-pattern cases (100 000-character inputs against `(a*)*b`,
`(a|aa)+$`, `(x+x+)+y`) in fast and release builds, the release build under GC
stress, and a short differential run. `tools/fuzz-regex` generates random
patterns from the supported subset and random texts (including multi-byte
characters and newlines), runs Python's `re` in ASCII mode and the Abla engine on
them, and compares `find` spans and groups, `findAll`, whole-text match and
`replace`. Loops over nullable bodies are not generated (see the difference
above).
