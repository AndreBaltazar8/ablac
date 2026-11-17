# A heap the collector skips: freezing a long-lived cache

Status: design for review (ablac-4e, 2026-11-17), for ablac-74 and ablac-89. Nothing here is built.

## The cost

ablac-89 measured the editor's analysis service on the compiler's own source: about 541 MB of module parse and symbol
cache, snapshots and query index stay live between analyses. One edit analysis runs 4 collections, and each re-marks and
re-sweeps that same unchanged 541 MB (67% of all marked bytes). Mark and sweep are 45 to 50% of the CPU: about 4 s of a
13 s edit. If a collection never touched the unchanged part, the ceiling is about 0.67 x 0.475 = 32% of the CPU of an edit
(a little less: roots, the changed modules and the new answer still cost).

How the collector works today (`stdlib/abla/runtime/platform/host.ab`): it stops the threads, marks from each thread's
shadow-stack frames (exact roots) and the global roots through a worklist, then sweeps the whole registry (one 8-byte entry per
allocation, in allocation order) freeing every unmarked block and compacting the registry. A mark is a bit in the block's
header word (layout + 16). Raw blocks (layout 0) are scanned conservatively word by word; every other layout is traced
exactly. Nothing is moved. So an "old" part that mark and sweep both skip needs: a way to recognise an old block when a
pointer reaches it, a registry the sweep does not walk, and a guarantee that no old block points at a young one.

## Option 0: collect less (no runtime change)

The growth rule sets the next threshold at live + max(live / 2, growth). With 541 MB live the threshold is already
270 MB or more above it, yet an edit collects 4 times because it allocates over 1 GB. `memorySetCollectionGrowth(1 GiB)`
for the service would turn 4 collections into 1 or 2, at +0.5 to 1 GB of RSS between collections. Cheap to measure, so it comes
first: it is the baseline any option below has to beat on RSS as well as CPU.

## Option A (recommended): frozen groups, copied into read-only memory

`memoryFreeze(value: T): T` (abla/memory) deep-copies the value's whole reachable graph into a *group*: pages carved from one
reserved virtual window, filled by a bump pointer, then `mprotect`ed read-only. It returns the copy; the original dies by
the ordinary rules when its last reference does.

- **Soundness of old -> young.** A frozen object can only point at frozen objects (everything reachable was copied, or was
  already in an earlier group and is shared) or at non-heap memory (static data, literals). There is no young pointer to
  miss, and no write barrier. A later store into a frozen object is a fault at the first store (a read-only page), reported as
  "write to a frozen object" and exiting like a panic; it is never silent corruption. This is the property the
  "immutable after creation, rebuilt whole per changed module" rule needs, enforced by the hardware instead of by convention.
- **Mark.** `__ablaRuntimeHostMarkPointer` first checks the pointer against the window (two compares; one window, so no
  search). A hit marks the pointer's *group* live (a per-group bit; the group is found by binary search over a few dozen
  group ranges) and does not push it. A frozen block is never traced and its header is never written (read-only).
- **Groups reference groups.** A freeze that meets an object of an earlier group records the edge. After mark, liveness
  propagates over group edges to a fixpoint (tens of groups: microseconds).
- **Sweep and reclamation.** Frozen blocks are not in the registry, so the sweep does not walk them. A group no mark reached
  is unmapped whole (`munmap`): that is how replaced module results are returned, with no per-object work. `memoryHeapStat`
  and live-byte accounting count a group's bytes, so the growth rule still sees them.
- **What can be frozen.** Layouts the tracer knows exactly: instances (descriptor-driven), arrays (boxed and dense), maps
  (arrays inside arrays), strings and boxed values. A raw block (layout 0) is frozen only if none of its words is a candidate
  pointer into the heap (a byte buffer); otherwise `memoryFreeze` fails with a panic naming the object's class, so a cache
  that cannot be frozen says so at the call, not at the first collection. Weak, task, thread, generator, mutex and cell blocks
  (layouts 6, 7, 11 and the like) are refused for the same reason. Sharing and cycles are kept (a forwarding table during the
  copy).
- **Roots on the stack.** Frames hold values the shadow stack describes exactly; they keep pointing at the originals until the
  code stores the copy. Nothing is conservative about the stack here, so there is nothing to pin. The copy itself runs under
  the heap lock with the other threads stopped (the same stop a collection uses), so it sees one consistent graph, and
  no thread holds a pointer into a half-built group.
- **Stop-the-world and threads.** Groups are immutable once sealed and the group table is written only under the stop and the
  heap lock, so threads read frozen objects without synchronisation. A freeze inside a `region` is refused (region pages are
  reclaimed as a unit); a freeze while a collection is abandoned waits like an explicit `memoryCollect()`.
- **fork.** The child inherits the mappings and the group table. Read-only pages need no copy-on-write bookkeeping, so the
  fork tests (`test-fork-heap.sh`, `test-fork-stop.sh`) only need a case that collects in the child with a live group.
- **Opt-in.** Only a program that calls `memoryFreeze` gets any of it: the window is reserved on the first call, the mark's
  extra range check reads one global (a program that never froze leaves it 0: one predictable branch), and the sweep and the
  registry are unchanged. For the editor, the service freezes each module's parse and symbol result when it stores it in the
  cache, and its query index and snapshots when they are complete.
- **Costs.** Copying a module result costs about one mark of it, paid once instead of once per collection; the frozen copy is
  compact (no free-list holes, no per-block header words beyond the 32 the layout needs). Peak RSS rises during the freeze
  (original plus copy, per module result, not for the whole cache). Mutation of the cache after the freeze, if the editor does
  any, faults at once: finding out is the first task of the build (see below).
- **Risks.** (1) The editor's cache may mutate objects after construction (lazy fields, memo tables, index appends). Those
  objects stay young (not frozen) and their frozen parents can only reference them if the parent was built after them and
  frozen with them, which copies them: the design forces the question at the freeze call. (2) Anything that writes to a block
  it only reads (a hash cache in a string, a counter) faults; the first run finds these, and the fix is to stop writing. (3)
  Dense arrays inside groups that the program appends to: not allowed (a fault), by design.

## Option B: an old bit in place, plus a write barrier

Mark old blocks with a header bit, split their registry entries off, and keep a remembered set of old blocks that were
stored into since the last collection (marked by a barrier on every reference store: field stores in LLVM output, array set,
append, insert, map set, cell set). Mark traces the remembered old blocks, not all old ones. No copying, mutation allowed.
Costs: a load and a branch on the header at every reference store (compiled in only when the program calls
`memoryPromote`), and every store path in the compiler and the runtime must be found (the narrowing work just showed
`append`, `Map.set` and `Cell.set` as separate paths for one rule). A missed path is silent corruption: a young object
freed under an old one. That is the property that makes this larger and riskier than A for the same payoff.

## Option C: an old bit in place, immutability by contract

Option B without the barrier, relying on the cache never being mutated. Smallest code, not sound: a violation is a dangling
pointer, found (at best) by a debug mode that checks old -> young edges under `ABLA_GC_STRESS`. Not recommended.

## Smallest sound version to build

Option A, as: `memoryFreeze` for the layouts above, the window and group table, mark's range test, group liveness and unmap,
live-byte accounting, a panic on an unfreezable object, and the fault report. Tests: unit programs (a graph with sharing and
a cycle survives 10,000 collections, a write faults with the message, an unfreezable object is named, group reclaimed after
its last reference dies, two groups referencing each other), `test-gc-threads.sh` and the fork tests with a live group,
`ABLA_GC_STRESS=1` over all of it. Measured on ablac-89's edit loop (`tools/test-analysis-memory.sh`'s service and edit
sequence), against option 0, for CPU (instructions and wall) and peak RSS.

Order of work: (1) measure option 0 and, with ablac-89's help, find out what the cache mutates after construction (a write
counter on a read-only mapping answers it); (2) build A in the runtime and test it standalone; (3) have the service
freeze its caches and measure; (4) only if (1) shows the cache is mutated pervasively, revisit B.
