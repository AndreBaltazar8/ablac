# Modules, packages and the lockfile

A file is a module. Import the declarations you use, and optionally give the
module an alias. The main file below imports its sibling `pricing.ab` and calls
`pricing.withTax`. Copy both files into the same directory to try it.

A package uses the same import model, with a source provider such as
`github("owner/repository")`. In a package project, keep `abla.toml` and commit
`abla.lock`: the lock records immutable dependency revisions. `ablac package
install` materializes those locked packages; `ablac package update` deliberately
changes the resolution. Builds install already locked packages automatically.
An offline build cannot fetch an uncached revision. The local two-file example
needs no network dependency and no lockfile.

To add a GitHub dependency with a compiler that supports the package
commands, run `ablac package add owner/repo` in your project. It adds an
import to the entry module and updates the lock while retaining existing
pins. Use `--tag <tag>` for a specific release. Commit the import and the
lockfile together. Run `ablac package outdated` to see newer tags for
locked Git dependencies before deciding whether to update. These commands
use Git and network access for ordinary GitHub repositories.

See [modules](../language.md#modules-and-imports) and [packages](../packages.md)
for manifests, resolving the initial lock, vendoring and offline builds.

[Runnable source](../../tests/cases/tour/10-modules.ab):

Save this helper beside the main file as `pricing.ab`. To run this example,
save both files and use `ablac run main.ab` from their directory. The
one-file playground editor only sends the entry file.

```abla file=pricing.ab source=../../tests/cases/tour/pricing.ab
fun withTax(price: int, percent: int): int = price + price * percent / 100
```

Then run the main file:

```abla run source=../../tests/cases/tour/10-modules.ab
import "abla/io"
import "pricing.ab" as pricing

fun main {
    println("${pricing.withTax(200, 20)}")
}
// output:
// 240
```

[Previous](09-sub-languages.md) · [Tour](README.md) · [Next](11-concurrency.md)
