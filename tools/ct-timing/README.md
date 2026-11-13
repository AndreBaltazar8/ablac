# Crypto timing experiments

Opt-in, Linux **x86-64 only**, requiring RDTSCP, `taskset`, and the repository's
Nix compiler environment. Other hosts print “unavailable” and exit successfully.
This complements `tools/test-ct.sh`; it is not a replacement or a constant-time
certification. A result below the threshold means **no leak detected at N samples**
for the recorded distributions, compiler, machine and experiment.

```sh
nix-shell shell.nix
ulimit -s 131072
# Choose two allowed physical cores, not SMT siblings (check lscpu -e).
taskset -c 0,2,6,14 tools/ct-timing/run --compiler build/ablac \
  --cpu 6 --confirm-cpu 2
# Longer statistical run; costs scale especially strongly for RSA.
taskset -c 0,2,6,14 tools/ct-timing/run --compiler build/ablac \
  --cpu 6 --confirm-cpu 2 --samples 1000000 --timeout 14400 --reuse
# Seconds: the deliberately leaky control only. No crypto pass is claimed.
tools/ct-timing/run --compiler build/ablac --cpu 6 --confirm-cpu 2 --smoke --reuse
tools/test-ct-timing-stats.sh build/ablac
# Expected exit 1: exercise the candidate-confirmation path with the known leak.
tools/ct-timing/run --compiler build/ablac --cpu 6 --confirm-cpu 2 \
  --targets leaky-compare --reuse
```

`--targets compare aes-software` selects a subset. Every run first requires the
negative control to exceed `|t| > 10` within a fixed 40,000 measurement samples
(20,000 in smoke) and at most 60 seconds. A failed control invalidates the run.
A candidate exceeding 10 is rerun **once** with a different randomized order on
the confirmation core. Both records are saved, then the tool stops, whether or
not the second run reproduces it. Exit 1 means a candidate crossed the threshold;
exit 2 means invalid input, insufficient observations, build/measurement failure
or control failure. No crypto code is automatically changed.

Default: 40,000 measurement samples per target, plus 128 warmup observations
and an independent 4,096-sample pilot. Each eligible test needs at least 10,000
observations **in each class** (smoke uses 1,000 for its control). The TSC measures
timestamp ticks, not frequency-dependent core cycles. The report records whether
the CPU advertises invariant TSC. It rejects samples whose RDTSCP AUX changes,
as well as invalid deltas. It cannot detect every scheduling interruption; use
a quiet physical core and inspect the retained uncropped result as well.

## What is timed

The release Abla driver calls the actual stdlib routines between external C
clock boundaries. The sampler uses MFENCE/LFENCE/RDTSCP/LFENCE and checks process
affinity. Buffer pointers and scalar results cross the opaque external boundary,
so the Abla optimizer must preserve the computations/stores. There is no LTO
between driver and sampler. Fences, call/return and argument overhead are included;
class generation, allocation of input batches, public mode dispatch, normalization,
key parsing, output consumption and statistics are outside the interval.

Inputs have fixed public sizes. Classes are a fixed all-zero operand versus
uniform pseudorandom bytes from a recorded xorshift seed; labels are balanced,
randomly shuffled, and stored outside the timed computation. The PRNG is for
repeatable test data, not cryptographic randomness. It runs for both classes
before measurement. Each observation has separate storage.

| Target | Timed production routine and distribution |
| --- | --- |
| `aes-software` | AES-128 `aesSoftBlocks`, one block, fixed expanded zero key, zero vs random plaintext |
| `aes-hardware` | AES-128 `aesBlocks`, one block, same fixed key; unavailable without AES CPU support |
| `compare` | `ctDifferenceAddress`, fixed 256-byte zero left operand, zero vs random right operand |
| `rsa-crt` | `rsaCrt`, a real fixed 2048-bit test key, zero vs random representative below 2^2047; limb import outside timing |
| `bn-from-bytes`, `bn-to-bytes` | 32-byte / eight-limb production conversions |
| `bn-residue-square` | `bnResidueSquare`, eight-limb odd modulus, high bit forced in both classes |
| `bn-montgomery` | `bnMontgomeryMultiply`, eight limbs, fixed p=2^255−19, operands below 2^254; inverse-word setup outside timing |
| `bn-divide`, `bn-reduce`, `bn-exact` | Fixed-step private secret cores, 16-limb numerator vs fixed eight-limb nonzero p; zero is an exact-division success, random values generally are not |
| `bn-divsteps`, `bn-gcd`, `bn-inverse` | Private secret cores, eight-limb fixed odd p and zero vs random value |
| `gcm-tag` | `aesGcmDecrypt` of a 64-byte TLS record (5-byte header as associated data, fixed key and nonce) whose tag is wrong in its last byte (zero class) or in nearly every byte (random class): both refused; the time must not say how much of the tag matched |
| `gcm-key` | `aesGcmDecrypt` of a fixed record under a zero vs random key: refused under both, after the key expansion, GHASH and the tag |
| `chacha-tag` | `chaCha20Poly1305Open`, as `gcm-tag` |
| `hkdf-expand` | `hkdfExpand` (HMAC-SHA256) of a TLS 1.3 key label from a zero vs random 32-byte PRK |
| `x25519` | `x25519` of a zero vs random scalar (clamped by the function) with a fixed peer share |
| `p256-ecdh` | `p256Ecdh` of a scalar whose top byte is 0x7f in both classes, with a fixed peer point |
| `leaky-compare` | Deliberately early-exiting 256-byte Abla comparison; mandatory detection control |

AES key expansion is outside these encryption tests. RSA CRT includes the
production function's internal allocation, modulus preparation and freeing;
it excludes outer API blinding, RNG, padding, parsing, signing/decryption framing
and fault verification. A public-exponent round-trip validates the CRT fixture
before timing; an AES known-answer test checks both available implementations.
These are operand-class tests with fixed keys, **not** tests of different secret
keys or all input distributions. Eight-limb bignum tests do not cover every
supported width or the inverse's even-modulus case. X25519 and P-256 ECDH are measured as TLS uses them; Ed25519 and P-256 signing are not measured here yet (the report
lists them).

Private cores are extracted verbatim from RSA's marked production source block
by the runner (`binding.ab`) for every driver build, as in the static CT fixtures. Public
routines are imported normally. No hand-maintained crypto implementation is used.
`--reuse` checks compiler-payload and all stdlib/driver source hashes before
reusing the binary. Build always uses `--no-cache`, including the native-library
manifest and `LIBRARY_PATH` setup. The runner preserves a supplied launcher path;
`build/ablac` is not resolved to its underlying script.

## Statistics and artifacts

[`dudect`](https://github.com/oreparaz/dudect/blob/master/src/dudect.h) provides the
model: first-order Welch tests on uncropped timings and multiple pooled-percentile
crops. This implementation uses its 100 exponential percentile choices
`1 - 0.5^(10*(i+1)/100)`, determined from the separate pilot without class labels.
Only measurement observations strictly below each threshold enter that cropped
test. All contexts and their per-class sample counts, means, variances and signed
t-values are reported; the largest eligible absolute t-value triggers detection.
Threshold 10 is a heuristic, not a multiple-testing-adjusted p-value. This tool
does not implement dudect's additional second-order test. A nondetection is not
a bound on leakage or proof of constant time.

The clock fences follow the ordering requirements described in
[Intel's instruction/architecture manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).
Always inspect the produced driver/disassembly when interpreting a finding.

Each invocation creates a new directory under `build/ct-timing/runs/`. `report.json`
contains machine, CPU, compiler/driver/source/statistics hashes, seeds, thresholds and every
test. Raw `.raw` observations remain beside it; SHA-256 binds them to the report.
The binary format is little-endian: eight bytes `ABLATSC1`, u64 record count,
then pairs of u64 TSC delta and class (0=fixed, 1=random, 2=migration-rejected).
Stderr and build logs are retained. Do not commit large raw sample files.

The timing experiment is not in `make test`. Deterministic statistical-unit tests
can run without affinity, RDTSCP, a compiler build or noisy timing assertions.
