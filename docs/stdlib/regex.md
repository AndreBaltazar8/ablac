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

For a fixed pattern, `$regex("pattern")` checks the pattern during compilation
and embeds a constant `Regex`, including its compiled VM program. Importing
`abla/regex` registers the syntax; no extra `#` is required:

```abla
import "abla/io"
import "abla/regex"

fun main {
    val pages = $regex(
        "(\\d+)-(\\d+)"
    )
    val match = pages.find("pages 12-48")
    if (match != null) println(match.group(1) ?? "")
    val matched = $regex("[a-z]+").matches("hello")
    println("$matched")
}
// output:
// 12
// true
```

The argument must be a plain Abla string literal; it uses Abla string escaping,
so write `\\d` for the regex escape `\d`. Interpolation, variables and other
expressions are rejected. Invalid patterns produce `E_SUBPARSER_FAILURE` at
the literal site, for example `invalid $regex at pattern byte 0: missing ]`.
The byte offset refers to the decoded pattern, starting at zero. Pattern
syntax, size limits and numbered capture slots are identical to `regexCompile`.
Use `regexCompile` for patterns known only at run time. Small capture-free
literals can use direct byte searches and deterministic transition tables.
The Pike VM handles captures and other general patterns. Literal compilation
follows the compiler's normal compile-time evaluation limits. A module-level
`val` lets repeated calls share a matcher and its compiled tables.

The manual `tools/bench-regex-literals.sh` compares repeated compile-and-match,
literal reuse and reuse of a runtime-compiled matcher, checking identical match
counts before reporting timings. It is a measurement, not a timing test.
The [recorded local comparison](regex-literals-benchmark.md) includes the inputs,
compiler identity and individual timings.

| Call | Result |
|---|---|
| `regexCompile(pattern)` | `RegexCompileResult`: `succeeded`, `regex`, and on failure `error` (`message`, byte `offset` into the pattern) |
| `re.matches(text)` | `bool`: the whole text matches |
| `re.matchFull(text)` | `RegexMatch?` for a whole-text match, with groups |
| `re.find(text, start = 0)` | `RegexMatch?`: the leftmost match starting at or after byte `start` |
| `re.findStart(text, start = 0)` | Byte offset of the leftmost match, or `-1` |
| `re.matchPrefixEnd(text)` | Exclusive end byte offset of a match starting at byte zero, or `-1` |
| `re.findAll(text)` | `array<RegexMatch>`, non-overlapping, left to right |
| `re.replace(text, replacement)` | `string` with every match replaced |
| `re.groupCount` | number of capturing groups |
| `m.start()`, `m.end()`, `m.text0()` | span and text of the whole match |
| `m.group(i)`, `m.groupStart(i)`, `m.groupEnd(i)`, `m.hasGroup(i)`, `m.groupCount()` | group `i` (0 is the whole match); `null`/`-1` when it did not take part |

`regexCompile` returns an error, never a panic, for any invalid pattern.

## Named captures

A literal with `(?<name>...)` returns a typed matcher with one capture
field per name:

```abla
import "abla/io"
import "abla/regex"

fun main {
    val date = $regex("(?<year>\\d{4})-(?<month>\\d{2})(?:-(?<day>\\d{2}))?")
    val match = date.matchFull("2026-11") ?? return
    val year: string = match.year
    val month: string = match.month
    val day: string? = match.day
    println("$year-$month ${day ?? "no day"}")
}
// output:
// 2026-11 no day
```

`find` and `matchFull` return the literal's capture type or null.
`findAll` returns an array of that type. A capture is `string` when it
participates on every successful path. It is `string?` when it can be
skipped, including by an alternative or a repeat with a zero minimum. An
empty match of a participating group yields an empty string.

A named literal wraps its precompiled `Regex` in a
`NamedRegex<Captures>`. Use `matches` and `replace` as usual. Use
`.regex` for numbered matches, byte spans or an API that takes a
`Regex`. Runtime `regexCompile` accepts named groups and keeps its
numbered match API. Groups retain their opening-parenthesis order, and
replacement still uses numbered references.

Names use ASCII identifier characters, start with a letter or underscore,
and are unique within the pattern. Abla keywords, a lone underscore, and
names starting with two underscores are reserved. Each literal site has
its own inferred nominal capture type. The editor can type-check capture
fields and reject misspellings.

## Cost

There is no backtracking, so no pattern takes exponential time: `(a+)+$`, `(a|a)*b`,
`(a|aa)*c`, `(a*)*b`, `(x+x+)+y` and `(a|b|ab)*c` over a hundred thousand `a`s and a
non-matching end take 4 to 21 ms. A single search (`matches`, `matchFull`, `find`)
takes at most 2 × (text size + 1) × (program size) VM steps whatever the pattern;
`re.findWork(text)` counts them, and `tests/cases/regex/work.ab` checks the bound on
those shapes by step count, not by time. The program size grows with counted repeats:
`(a{1,30}){1,30}b` is 1,863 instructions and takes 3.1 s over 100,000 characters.

`findAll` and `replace` (and a loop of `find(text, start)`) search again from the end
of each match. When a longer alternative keeps running after a shorter one has matched
(`a+b|a`, `(?:a+b)?a`, `a*b|a` over `aaaa…`), each search runs to the end of the text
before it can give the short match, and the whole takes quadratic time: 5,000
characters 0.5 s, 10,000 2.1 s, 20,000 10 s, 40,000 38 s. `re.findAllWork(text)` counts
the steps. RE2 and Rust's `regex` have the same limit. For untrusted text, bound the
text's size, or avoid patterns whose alternatives can be prefixes of one another's
continuations.

A search costs at most 2 × (text size + 1) × instructions steps (about 12 ns each), so at the limit of
100,000 instructions a megabyte of text could take many minutes. Nested counted repeats multiply: `(a{1,30}){1,30}` is
1,863 instructions. For patterns from an untrusted source use `regexCompileWithin(pattern, maximumInstructions)`, which
refuses a larger program with the same error (it never allows more than 100,000). It bounds the size of the pattern, not the time of a
search: the cost is the pattern's instructions times the text's length, so `(?:a*){1000}b` (about 3,000 instructions) over 3,000
characters is up to 18 million steps (about 0.2 s in a release build, 10 times that in a `--fast` build), and the same pattern over
a megabyte of text would be a few minutes. Bound the text's size as well when the pattern is not yours.

Use `re.findWithin(text, maximumSteps, start = 0)` to limit a single search.
Its sealed result has three cases.

- `RegexSearchMatch` contains the completed leftmost match in `.matched`.
- `RegexSearchMiss` means the search finished without a match or the start offset was out of range.
- `RegexSearchExhausted` means another step was needed. It carries no tentative match.

Each step is a VM position visit, an instruction reached in a closure, a thread
advance, or a character-class range check. The bounded search runs the general VM
so those charges also apply to patterns with an ordinary literal or fixed-width
fast path. Nonpositive limits exhaust a valid search before running it.
The budget counts search steps. VM initialization, the cost of copying capture
slots within a step, and pattern compilation have their own costs. Use
`regexCompileWithin` to limit compiled program size.

### Inspecting a bounded result

```abla
import "abla/io"
import "abla/regex"

fun main {
    val colour = regexCompile("red|green").regex
    val result = colour.findWithin("light green", 200)
    val message = when (result) {
        is RegexSearchMatch -> result.matched.text0()
        is RegexSearchMiss -> "no colour"
        is RegexSearchExhausted -> "search budget exhausted"
    }
    println(message)
}
// output:
// green
```

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
| `(…)`, `(?<name>…)`, `(?:…)` | numbered, named and non-capturing group |
| `a|b` | alternation (leftmost alternative that leads to a match wins) |
| `* + ? {m} {m,} {m,n} {,n}` | greedy repetition (`{,n}` is `{0,n}`, as in Python); add `?` (`*?`, `{2,5}?`) for lazy |

Repeat counts go up to 1000; a pattern whose expansion exceeds 100 000
instructions (`((a{1000}){1000}){1000}`; the error says "the pattern is too large: its program has more than 100000 instructions") or whose instructions times capture slots exceed 2 000 000, or that has more
than 500 groups or nests groups deeper than 200 levels, is rejected ("too large",
"too many groups"), which bounds the memory a search needs. A `{` that does not start a valid repeat is a literal.

**Rejected at compile time:** backreferences (`\1`) and octal escapes, lookahead
and lookbehind (`(?=`, `(?!`, `(?<=`, `(?<!`), other `(?` forms such as Python-style `(?P<n>a)` and inline flags such as `(?i)`, unknown letter escapes, `\b` inside a class, quantifiers with
nothing to repeat (`*a`, `^*`), stacked quantifiers (`a**`, possessive `a*+`), `{m,n}` with
`n < m`, a class range that starts at a shorthand (`[\w-z]`), unterminated groups and classes, and patterns that are not valid UTF-8.

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
stress, and `tests/cases/regex/corpus.ab`: 6000 random pattern and text pairs
(multi-byte characters and newlines included; a third of the patterns mutated)
whose `find` spans and groups, `findAll`, whole-text match and `replace` results
were recorded from Python's `re` in ASCII mode (`corpus.tsv.gz`). Abla must refuse
every pattern Python refuses, and refuse one Python accepts only with a reason
listed in this document. Loops over nullable bodies are not in the corpus (see
the difference above).

Random coverage comes from `tools/fuzz/run --regex --seeds 100000-100099 --cases 2000`
(a short fixed-seed run is part of `tools/test-fuzz-abla.sh`). Its oracle,
`tools/fuzz/regex_oracle.ab`, does not share the engine's algorithm: instead of a
compiled program run by a Pike VM it asks, for each syntax-tree node and start
position, which end positions the node can reach in priority order (a greedy repeat
lists its longer runs first, a lazy one stops first, an alternation lists its first
branch first), and takes the first end for the smallest start with any. It has its
own parser for the same syntax and imports nothing from `abla/regex`. Each path
also carries the groups that completed on it, a later one overriding an earlier
(a group keeps its value from the last round of a loop, as in Python), and the
search for all matches follows Python 3.7's empty-match rule. Patterns are
generated as trees and written as text, so the engine's parser is exercised too;
for each pair the four answers of the corpus (find with its groups, `findAll`, the
whole-text match with its groups, `replace` with `[$0]`) and the find from a later
start must agree. A disagreement is shrunk (tree and text) and printed with a
`corpus:` line; `tools/regex-corpus-add.sh` adds such lines to `corpus.tsv.gz`.
The oracle is checked against the recorded Python results
(`tools/fuzz/run --regex-corpus`: every one it can read, groups, `findAll` and
`replace` included), and a planted fault in it must be found (`--control-regex`).
It has no loops over nullable bodies, where Python's group rule differs from
this engine's (above).
