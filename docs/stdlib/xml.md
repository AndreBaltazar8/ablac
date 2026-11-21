# XML literals

Import `abla/xml` to construct an `XmlElement` from XML markup.

```abla
import "abla/xml"

fun item(id: int, title: string): XmlElement =
    $xml <catalog:item xmlns:catalog="urn:catalog" id={id}>{title}</catalog:item>
```

The compiler checks element and attribute names, closing tags, namespace
bindings, duplicate attributes and character references. Namespace declarations
are quoted literals. A default namespace applies to elements. Unprefixed
attributes have no namespace. Text and attribute values follow XML 1.0
newline, whitespace and entity rules. The literal supports predefined and
numeric references, comments, CDATA and processing instructions within its root.

An expression in braces in element content supplies text. An attribute may
take an entire expression with `name={expression}`. Both accept strings,
integers and booleans. Values are stored as text and escaped when written.
Use `{node expression}` or `{nodes expression}` to insert typed XML nodes.
Write a literal opening brace in text as `&#123;`. XML declarations belong
to the document writer, and DTDs and external entity references are rejected.

Use `xmlDocument(root)` to wrap an element in an `XmlDocument`, or
`#$xml <root/>` to freeze a static element at compile time. The abla-xml
package supplies the parser, serializers and streaming writers for these
same value types.

The grammar follows [XML 1.0](https://www.w3.org/TR/xml/) and
[Namespaces in XML 1.0](https://www.w3.org/TR/REC-xml-names/).
