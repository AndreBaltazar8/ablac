# Formatting Abla source

`ablac fmt file.ab` formats a file in place. Give several files or directories
to format them in stable path order. Directory traversal selects `.ab` files,
skips hidden directories, and does not follow symbolic links. A `build`
directory is treated as generated output unless it contains a module `entry.ab`
or is an explicit operand; this keeps modules such as `abla/build` included.
An explicit symbolic-link operand is rejected rather than replacing the link.

```sh
ablac fmt src/ stdlib/
ablac fmt --check src/ stdlib/
ablac fmt - < input.ab > formatted.ab
```

`--check` never writes. It prints a unified diff and exits 1 when formatting is
needed, 0 when every input is clean, or 2 on invalid input, a preservation-check
failure, an unknown option or an I/O error. `-` reads stdin and writes formatted
source to stdout; it cannot be combined with file operands. With `--check -`,
stdout contains the diff instead.

## Style

The style follows the compiler and standard library: four spaces per block,
spaces around binary operators and after commas/type colons, no spaces inside
parentheses or brackets, same-line opening braces, and compact guards and
expression-bodied functions. Existing punctuation and literal spellings stay:
the formatter does not add braces, remove semicolons, change numeric bases,
reorder imports or rewrite calls. Parser-ambiguous type/operator adjacency is
kept rather than interpreted by another grammar.

Intentional line breaks and aligned continuations remain. Blank-line runs are
collapsed to one empty line; trailing whitespace is removed outside verbatim
regions. Line endings outside those regions become LF, with a final newline
for nonempty files. The spacing/indentation implementation accepts `--width`
(40–240, default 100); width-driven breaking is a separate following change.

## Preservation checks

Formatting uses the compiler's own lexer and parser. Before writing, it requires
unchanged significant tokens, full parsed syntax equality modulo positions,
unchanged comment bytes and attachment, and a byte-identical second formatting
pass. A failure leaves the original file untouched. All inputs are validated
before the first write; each changed file is published atomically with its
existing permission mode. An I/O failure midway through publication is not a
transaction across all files.

Trailing comments stay trailing, documentation comments stay before the same
syntax, and inline/dangling comments retain their token boundary. Their text
is never wrapped or rewritten, including spaces inside block comments.

Strings and interpolation bodies, raw text blocks, custom subparser invocations
and declaration-block source payloads stay verbatim. Raw-string indentation is
part of the literal and is preserved. The formatter neither loads imports nor
executes compile-time code or subparser providers. If the preliminary parser
cannot safely parse/bound a construct, the command refuses that input rather
than guessing. Syntax errors are reported; type checking is not required.
