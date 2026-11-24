// Regenerates vectors.txt: node tests/cases/bignum-checked/generate.mjs > tests/cases/bignum-checked/vectors.txt
// Lines: `r <hex of 1 to 2 * width bytes> <hex of that mod m>` (reduce), `m <hex>` starts a modulus (odd, width bytes); `v <a> <b> <exponent> <a+b> <a-b> <a*b> <a*a> <a^e> <bits of a: index:bit ...>` follow, all hex of the width
// (the exponent 32 bytes), values below the modulus. The oracle is JavaScript's BigInt.
let seed = 0x9e3779b97f4a7c15n
function next() {
  seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n)
  return seed >> 11n
}
function random(bytes) { let v = 0n; for (let i = 0; i < bytes; i++) v = (v << 8n) | (next() & 255n); return v }
const hex = (v, bytes) => v.toString(16).padStart(bytes * 2, "0")
function pow(base, exponent, m) { let r = 1n % m; base %= m; while (exponent > 0n) { if (exponent & 1n) r = (r * base) % m; base = (base * base) % m; exponent >>= 1n } return r }
const out = []
for (const width of [4, 8, 32, 64, 512]) {
  let m = random(width) | 1n | (1n << BigInt(width * 8 - 1))
  if (width === 32) m = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn
  out.push(`m ${hex(m, width)}`)
  const values = [0n, 1n, m - 1n, m - 2n, (m - 1n) / 2n]
  for (let i = 0; i < 24; i++) values.push(random(width) % m)
  for (const length of [1, width - 1, width, width + 1, width * 2 - 1, width * 2]) {
    if (length < 1) continue
    for (let i = 0; i < 3; i++) {
      const wide = i === 0 ? (1n << BigInt(length * 8)) - 1n : random(length)
      out.push(`r ${hex(wide, length)} ${hex(wide % m, width)}`)
    }
  }
  for (let i = 0; i < values.length; i++) {
    const a = values[i], b = values[(i * 7 + 3) % values.length]
    const e = random(32)
    const bits = [0, 1, width * 8 - 1, Math.floor(width * 4)].map(k => `${k}:${(a >> BigInt(k)) & 1n}`).join(" ")
    out.push(`v ${hex(a, width)} ${hex(b, width)} ${hex(e, 32)} ${hex((a + b) % m, width)} ${hex(((a - b) % m + m) % m, width)} ${hex((a * b) % m, width)} ${hex((a * a) % m, width)} ${hex(pow(a, e, m), width)} ${bits}`)
  }
}

console.log(out.join("\n"))
