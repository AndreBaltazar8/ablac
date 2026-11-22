# Learn Abla

This path is for someone who has programmed before and wants to write their
first Abla program. Read the chapters in order; each introduces one small idea
and points to the reference when you need more detail.

This tour follows the development compiler. In particular, v0.2.65 can run
the basic examples and the JSON buffer example. For the newer project and
package commands, regex/XML/SQL literals, REPL loading and debugger variables,
use a current source build as described in the installation chapter.

1. [Install and choose your compiler](00-install.md)
2. [Hello, Abla](01-hello.md)
3. [Values and types](02-values.md)
4. [Functions and control flow](03-functions.md)
5. [Classes and interfaces](04-classes.md)
6. [Ownership and resources](05-ownership.md)
7. [Handling expected failures](06-errors.md)
8. [Arrays and maps](07-collections.md)
9. [Running code during compilation](08-compile-time.md)
10. [Sub-languages for regex, JSON, XML and SQL](09-sub-languages.md)
11. [Modules, packages and the lockfile](10-modules.md)
12. [Tasks and threads](11-concurrency.md)
13. [Building for targets](12-targets.md)
14. [Trying ideas in the REPL](13-repl.md)
15. [Debug an Abla program](14-debugging.md)

Each Abla block links to a real [source file](../../tests/cases/tour/01-hello.ab).
The suite compiles and runs the examples and checks the `// output:` comments.
`tools/test-tour.sh` checks that the displayed blocks match those files byte
for byte, including the helper module, and checks the REPL session. Shell
installation steps depend on your host and are setup instructions, not Abla
examples. Run examples from a directory you own; repository commands below
assume the repository root.

For an API, start at the [stdlib module index](../standard-library.md), then
follow its curated module pages. The generated declaration reference, when
you build it with `build/ablac doc`, lives in `build/docs/index.md`; it is
separate from these checked-in explanations. The [language reference](../language.md)
describes the full rules. The existing [compact guide](../guide.md) offers a
single-page refresher.

To check the tour while editing, run `tools/test-tour.sh build/ablac`, then
`tools/test-doc-examples.sh build/ablac docs/tour/*.md` inside the development
shell. Both checks are part of the normal suite.
