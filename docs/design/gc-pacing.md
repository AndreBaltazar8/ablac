# Adaptive collection pacing: what the budget really is, and why retuning it is a lottery

The hosted collector's adaptive pacing (`__ablaRuntimeHostFinishAdaptiveGc` in
`stdlib/abla/runtime/platform/host.ab`) sets the next collection at `working + growth`. Here `working` is
the tracked footprint right after a collection. `growth` is three times a smoothed estimate of it,
clamped to `[GcFloor, GcCap]` = [8 MiB, 128 MiB] ([standard-library.md](../standard-library.md)). Two
consequences decide the peak memory of most programs. Both were measured in the #1204 runtime series
(perf counters, one E-core, user instructions and GNU time's peak RSS).

## Above about 45 MB kept, the budget is a flat 128 MiB of headroom

Once the estimate reaches `GcCap / 3` (about 44.7 MB), `growth` is the cap. A program that keeps more
than that may leave up to 128 MiB of garbage, whatever the factor. `perf/sieve.ab` keeps one 64 MiB
array (5M integers, capacity 8M) and drops it each round. It peaks at live + 128 MiB, about 148 MB
resident.

## The sample is a phase of the program, not its working set

`working` is whatever is live at the moment a collection happens to run. In a periodic workload that
moment drifts with every change that moves allocation volume. Each case below changed the sample, not
the program:

- **perf-sieve RSS 78 → 148 MB from v0.2.65 to v0.2.70.** v0.2.70 added an early collection at 8 MiB.
  Later collections then sampled the array right after it grew to 64 MiB, not at 32 MiB, so next was
  201 MB instead of 100 MB. Pacing and array growth were otherwise identical.
- **Factor 2 instead of 3, for everything.** Sieve 148 → 78 MB, perf-trees 169 → 126 MB, json 34 →
  24 MB. But instructions rose on binary-trees (+8.6%), json-readers (+7.2%), json (+17%) and perf-trees
  (+4.7%), because more collections trace their small objects.
- **Charging large raw-byte blocks (dense array values, string data over 128 KiB) 50% extra.** Sieve
  148 → 78 MB at 0% instructions. But json-megabyte RSS rose 263 → 330 MB: one of the moved collections
  ran where nearly nothing was dead (118 MB kept). The next budget then let the small-object heap grow to
  276 MB mapped, against 191 MB.
- **Charging every allocation over 128 KiB.** perf-maps +7% instructions, because its hash tables are
  large and full of references.

Smoothing the estimate (the quarter-step average, or a max or median of recent samples) cannot fix
this. Above the cap the estimate is not used at all, and the jump comes from the `working` term itself.

## Before retuning

A change to the factor, the floor, the cap, or what counts as pressure moves which collection sees which
phase. It needs the whole runtime series (19 programs) and a compiler self-build, on instructions and
peak RSS, with two runs each for json, json-megabyte and perf-maps, which vary up to 8% between runs.
One bench's win is no evidence. A real improvement has to make the budget independent of phase, for
example by charging garbage by its age or measuring what a collection frees. Shifting the sample will
not do it.
