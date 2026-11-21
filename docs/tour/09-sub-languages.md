# JSON, HTML and sub-languages

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

[Previous](08-compile-time.md) · [Tour](README.md) · [Next](10-modules.md)
