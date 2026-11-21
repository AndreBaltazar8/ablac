# Checked PostgreSQL statements

```abla
import "abla/sql"
val statement = $sql("SELECT id FROM users WHERE id=${id}::uuid AND active=${true}::boolean")
```

The compiler checks one PostgreSQL statement from the supported subset. Each
`${expression}` becomes a numbered placeholder and a separate text-format
parameter. The original Abla string interpolation never runs. Expressions run
once, from left to right, when the statement is constructed. This also applies
to interpolated literal strings such as `${"hello"}`.

Every value hole requires an immediate `::type` cast (whitespace is permitted).
Identifiers and SQL syntax must be constant text. Handwritten `$1` parameters
and holes inside SQL strings, identifiers, dollar quotes or comments fail.
Use ordinary Abla string escapes for SQL double quotes, newlines and literal
dollar signs: `$sql("SELECT \$json\${\"n\":1}\$json\$::jsonb")`.

| PostgreSQL cast | Accepted Abla values, also nullable |
| --- | --- |
| `text` (also `varchar`, `character varying`, `char`, `character`), `uuid` | `string` |
| `smallint` / `int2`, `integer` / `int` / `int4` | 8–64-bit signed or unsigned integers |
| `bigint` / `int8` | integers or `sqlInt8Text(string)` |
| `boolean` / `bool` | `bool` |
| `real` / `float4`, `double precision` / `float8` | `f32`, `f64` |
| `jsonb` | `Json` or `sqlJsonText(string)` |

Literal `null` is accepted for every supported cast. Integer values retain their
full text representation; the server checks the cast's range. UUID spelling,
JSON text validity, schema names, overload resolution, constraints and privileges
are checked by PostgreSQL. Compile-time checks do not connect to a database.

Supported syntax includes SELECT expressions, aliases, joins, subqueries,
WHERE, GROUP BY, HAVING, ORDER BY, LIMIT/OFFSET; INSERT VALUES with ON CONFLICT;
UPDATE FROM; DELETE USING; RETURNING; casts, CASE and common SQL operators.
Nested comments, standard strings and dollar-quoted strings are recognized.
E strings support escaped quotes, backslashes and b/f/n/r/t controls; other E
escapes are outside the subset. Standard strings assume PostgreSQL
`standard_conforming_strings=on` (its default).
The parser deliberately rejects unsupported forms including CTEs, UNION,
DDL, COPY, arrays and SQL functions with special grammars such as EXTRACT.
It limits templates to 65536 bytes, 32768 tokens, 1024 holes and nesting 64.
This is a bounded subset checker, not PostgreSQL's complete grammar.

`SqlStatement` contains `text` and `parameters: array<SqlParameter>`. A parameter
has `kind`, `value` and `isNull`; null and empty text differ. The types are neutral
stdlib values and need no database dependency. Import `src/sql.ab` from
abla-postgres to use statement overloads of client/pool `query` and `execute`,
`pgSqlQuery`, `pgSqlExecute` and `pgSqlSessionQuery`. The adapter uses the existing
extended-query protocol and prepared-statement cache with separate bindings.
Statements can also be constructed manually; their public constructor does not
certify arbitrary text. Typed rows and schema declarations are deferred.

The provider is pure compile-time Abla. Editor analysis expands it as a trusted
stdlib provider, reports syntax/type errors and types the resulting statement.
Compiler-only parser code is removed from runtime programs. Brace-form SQL is
deferred until generic raw-provider lexical isolation is available.
