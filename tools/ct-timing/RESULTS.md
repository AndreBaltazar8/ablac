# Native crypto timing results

2026-11-05, Linux x86-64, Intel Core i9-13900K, taskset CPU 6. Compiler is the
lead's frozen aq stage 2 of `a476110c`. This is one fixed-input-versus-random-input
experiment per listed primitive, not proof of constant time. No crypto source
was changed. See [method and limits](README.md).

Each row has **40,000 measurement observations**, plus 4,096 independent pilot
observations and 128 discarded warmups. All 40,000 were valid in every row.
The maximum is over eligible uncropped/cropped tests, each retaining at least
10,000 observations per class. Class counts below refer to the uncropped data;
the compact [JSON summary](results.json) also records strongest-crop counts.

| Primitive | Fixed / random N | Raw abs(t) | Max abs(t) | Observation |
| --- | ---: | ---: | ---: | --- |
| Control: early exit | 20017 / 19983 | 205.251 | 883.442 | Leak detected (required control) |
| aes-software | 20028 / 19972 | 1.343 | 2.115 | No leak detected at 40,000 samples |
| aes-hardware | 20014 / 19986 | 1.361 | 2.071 | No leak detected at 40,000 samples |
| compare | 19994 / 20006 | 2.300 | 2.300 | No leak detected at 40,000 samples |
| rsa-crt | 19967 / 20033 | 0.093 | 1.076 | No leak detected at 40,000 samples |
| bn-from-bytes | 20011 / 19989 | 0.664 | 1.722 | No leak detected at 40,000 samples |
| bn-to-bytes | 20042 / 19958 | 0.718 | 1.449 | No leak detected at 40,000 samples |
| bn-residue-square | 20015 / 19985 | 1.472 | 3.177 | No leak detected at 40,000 samples |
| bn-montgomery | 19975 / 20025 | 0.464 | 1.459 | No leak detected at 40,000 samples |
| bn-divide | 19997 / 20003 | 1.867 | 1.867 | No leak detected at 40,000 samples |
| bn-reduce | 20009 / 19991 | 0.375 | 1.239 | No leak detected at 40,000 samples |
| bn-exact | 20003 / 19997 | 1.308 | 1.419 | No leak detected at 40,000 samples |
| bn-divsteps | 20020 / 19980 | 0.897 | 2.022 | No leak detected at 40,000 samples |
| bn-gcd | 20000 / 20000 | 0.125 | 1.501 | No leak detected at 40,000 samples |
| bn-inverse | 19990 / 20010 | 2.026 | 2.026 | No leak detected at 40,000 samples |

P-256 and X25519: **explicitly unavailable**, with no implementation in the
current `abla/crypto`. The eight-limb inverse test uses a fixed odd modulus;
even-modulus and other-width distributions remain outside this timing campaign.

The uncropped control exceeds 10 as well as the cropped test. No crypto candidate
crossed 10, so no real candidate required a confirmation run. The confirmation
mechanism was separately tested using the deliberately leaky function as a
candidate: max abs(t) **619.445** on CPU 6, fresh-order confirmation **828.594** on
a different physical core (CPU 2), then the expected exit 1 and stop. Both raw
datasets remain in `build/ct-timing/runs/20261105T093307Z-3576147/`.

Two final smoke runs detected the control at 20,000 observations (max abs(t)
800.498 and 1020.807); the latter built through the symlinked **build/ablac**
launcher, preserving its invocation path. Driver bytes remained identical to
the measured full-run driver after build-cache provenance refinements:

```text
44d077e6e8a04f568442290eb6239ecb3f589104f9948349e9d68bed96e8ba2b
```

Seven deterministic unit tests cover Welch arithmetic, zero variance, class
symmetry/class-blind cropping, invalid records/insufficient counts and source
binding and clean unsupported-host exit. They are the only added default-suite test. The timing experiment
and even its smoke remain opt-in. The emitted C sampler assembly was inspected:
both boundaries contain MFENCE/LFENCE/RDTSCP/LFENCE; the conditional branch after
the end timestamp compares public CPU AUX values, not the input class.

Raw per-sample data, all crop contexts, hashes and stderr are retained in
`build/ct-timing/runs/20261105T092506Z-3535535/`.
The initial prototype campaign also completed all targets without a threshold
crossing, but is excluded from the table: public BN dispatch still fell inside
its clock interval. The final driver moves that dispatch outside.

Limits: fixed keys, specific operand distributions/lengths, first-order tests,
one machine/compiler and a finite sample budget. Timing noise, a passing static
assembly check and a nondetection do not establish absence of timing leakage.
