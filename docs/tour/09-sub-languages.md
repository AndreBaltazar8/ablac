# Sub-languages for regex, JSON, XML and SQL

Importing a provider registers its `$name` syntax. The provider parses that
syntax during compilation and returns a typed Abla expression. The expression
it returns can still run at runtime: parsing the syntax early does not mean
all values embedded in it are compile-time constants.

`$json` constructs a JSON value. `$html` constructs an HTML data model value;
its braces can contain ordinary Abla expressions such as `count + 1`.
`#$jsons` evaluates the JSON string result at compile time. This example reads
the HTML element's tag; it does not start a web server or render a page.

See [JSON](../json.md), [subparsers](../subparsers.md), and the
[stdlib module index](../standard-library.md) for `abla/html`.

[Runnable source](../../tests/cases/tour/09-sub-languages.ab):

```abla run source=../../tests/cases/tour/09-sub-languages.ab
import "abla/io"
import "abla/json"
import "abla/html"

fun main {
    val count = 2
    val document = $json {"answer": 42}
    val view = $html <div>{count + 1}</div>
    val encoded = #$jsons {"enabled": true}
    println("answer ${document.getInt("answer")}, tag ${view.tag}")
    println(encoded)
}
// output:
// answer 42, tag div
// {"enabled":true}
```

## Links and handlers in HTML

`$html` escapes every value that comes from Abla. A URL attribute such as
`href` or `src` takes a value from Abla only when it is a safe URL: a
`javascript:`, `vbscript:` or `data:` value, however its scheme is spelled,
becomes `about:invalid#abla-unsafe-url`. An event handler such as `onclick`
is written in the template, never filled from Abla; pass data to it through
a `data-` attribute. These checks need v0.2.80 or a current source build.
See [URLs and event handlers](../subparsers.md#urls-and-event-handlers).

[Runnable source](../../tests/cases/tour/html-links.ab):

```abla run source=../../tests/cases/tour/html-links.ab
import "abla/html"
import "abla/io"

fun link(target: string, label: string): Html = $html <a href={target}>{label}</a>

fun main {
    println(link("/books?id=7", "Book 7").render())
    println(link("JavaScript:alert(1)", "Click").render())
    val id = "7"
    val button = $html <button data-id={id} onclick="pick(this.dataset.id)">Pick</button>
    println(button.render())
}
// output:
// <a href="/books?id=7">Book 7</a>
// <a href="about:invalid#abla-unsafe-url">Click</a>
// <button data-id="7" onclick="pick(this.dataset.id)">Pick</button>
```

## Match text with named captures

A `$regex("pattern")` literal checks the pattern during compilation. A named
capture that always participates becomes a string field on the match. A
capture that can be absent has type `string?`. The match itself can be null
when the input does not match. For patterns supplied at runtime, use
`regexCompile` from [abla/regex](../stdlib/regex.md).

[Runnable source](../../tests/cases/tour/regex.ab).

```abla run source=../../tests/cases/tour/regex.ab
import "abla/io"
import "abla/regex"

fun main {
    val release = $regex("v(?<major>[0-9]+)\\.(?<minor>[0-9]+)")
    val match = release.matchFull("v2.14")
    if (match != null) {
        println("major ${match.major}, minor ${match.minor}")
    }
}
// output:
// major 2, minor 14
```

## Write JSON into an existing buffer

Use `$json` to build a JSON tree. To send that value as text, pass it to
`jsonStringify`. See [replacing parallel key and value arrays](../json.md#replace-parallel-key-and-value-arrays).
With `$jsonw(buffer)`, the literal appends one encoded value to your `ByteBuffer`.
Interpolated strings go through JSON escaping. For larger examples, see
[writing directly to a buffer](../json.md#writing-directly-to-a-buffer).
To spot manual JSON construction, build with `--warn-json-construction` and
look for `W_JSON_CONSTRUCTION` suggestions.

[Runnable source](../../tests/cases/tour/json-buffer.ab).

```abla run source=../../tests/cases/tour/json-buffer.ab
import "abla/bytes"
import "abla/io"
import "abla/json"

fun main {
    val name = "A & B"
    val out = byteBuffer()
    $jsonw(out) {"label": name, "inStock": true}
    println(out.toText())
}
// output:
// {"label":"A & B","inStock":true}
```

## Build an XML element

The `$xml` parser checks tag names, nesting and namespace declarations. A
braced expression in element content supplies text. The literal stores that
text as a value, which a serializer can escape for markup. If you are
already writing a document with the `abla-xml` package, its `XmlWriter`
accepts `$xmlw(writer)` to stream an element directly. See
[XML literals](../stdlib/xml.md) for both forms.

[Runnable source](../../tests/cases/tour/xml-literal.ab).

```abla run source=../../tests/cases/tour/xml-literal.ab
import "abla/io"
import "abla/xml"

fun main {
    val title = "A & B"
    val item = $xml <item id={7}>{title}</item>
    println(item.text())
}
// output:
// A & B
```

## Bind values in an SQL statement

The `$sql("...")` literal accepts a supported PostgreSQL grammar. Give each
Abla expression a PostgreSQL cast so the compiler can check the parameter
type. The generated statement contains a numbered placeholder and a separate
parameter value. Here we inspect both in a program that needs no database.
You can pass the statement to a compatible PostgreSQL adapter to execute it.

[Runnable source](../../tests/cases/tour/sql-statement.ab).

```abla run source=../../tests/cases/tour/sql-statement.ab
import "abla/io"
import "abla/sql"
import "abla/text"

fun main {
    val author = "O'Neil"
    val query = $sql("SELECT id FROM books WHERE author = ${author}::text")
    println("has placeholder: ${query.text.contains("\$1::text")}")
    println("bound author: ${query.parameters[0].value}")
}
// output:
// has placeholder: true
// bound author: O'Neil
```

[Previous](08-compile-time.md) · [Tour](README.md) · [Next](10-modules.md)
