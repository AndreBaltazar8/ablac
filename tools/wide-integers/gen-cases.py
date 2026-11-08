#!/usr/bin/env python3
"""Cases for abla/uint256, int256, uint128 and int128, worked out with Python's integers: edge values
against each other, then random ones of every length. tests/cases/wide-integers/checks*.ab run them on each target.

gen-cases.py SEED COUNT [--type T]            lines of `operation a b expected`, in hex unless noted
gen-cases.py SEED COUNT [--type T] --abla     the same as an Abla module holding them in WIDE_CASES
gen-cases.py SEED COUNT [--type T] --decimal-abla  compile-time decimal formatting against Python

A value is shown as its two's complement in BITS bits (`ff..ff` is -1 for a signed type); a signed
type's decimal and hex text carry a minus.
"""
import random
import sys

TYPE = "uint256"
if "--type" in sys.argv:
    TYPE = sys.argv[sys.argv.index("--type") + 1]
SIGNED = TYPE.startswith("int")
BITS = int(TYPE[-3:])
BYTES = BITS // 8
M = 1 << BITS
TOP = M - 1
LOW, HIGH = (-(M >> 1), (M >> 1) - 1) if SIGNED else (0, TOP)


def wrap(value):
    value %= M
    return value - M if SIGNED and value > HIGH else value


def hexed(value):
    return f"{value % M:x}"


def fits(value, low=LOW, high=HIGH):
    return low <= value <= high


def checked(value):
    return hexed(value) if fits(value) else "n"


def narrowed(value, low, high):
    return hexed(value) if low <= value <= high else "n"


def divide(a, b):
    """Truncating, the way an Abla signed type does; the one quotient too large wraps."""
    quotient = abs(a) // abs(b)
    return wrap(-quotient if (a < 0) != (b < 0) else quotient)


def remainder(a, b):
    return a - divide(a, b) * b if not (SIGNED and a == LOW and b == -1) else 0


def text_hex(value):
    return f"-0x{-value:x}" if value < 0 else f"0x{value:x}"


_edges = {0, 1, 2, 3, 5, 9, 10, 255, 256, TOP, TOP - 1, TOP // 2, TOP // 2 + 1, TOP // 10, TOP // 10 + 1,
          10 ** 9, 10 ** 18, 10 ** 19, 10 ** 38, 1 << (BITS // 2), (1 << (BITS // 2)) - 1, (1 << (BITS // 2)) + 1,
          0xFFFFFFFF, 0xFFFFFFFF << (BITS - 32), int("AA" * BYTES, 16), int("55" * BYTES, 16),
          int("0123456789abcdef" * (BITS // 64), 16), 2 ** 63 - 1, 2 ** 63, 2 ** 64 - 1, 2 ** 64, 2 ** 32,
          2 ** 16, 2 ** 8, 2 ** 31, 2 ** 31 - 1, 2 ** 15, 2 ** 15 - 1, 2 ** 7, 2 ** 7 - 1,
          (M >> 1) - 1, M >> 1, (M >> 1) + 1} | {1 << k for k in range(32, BITS, 32)} | {
              (1 << k) - 1 for k in range(32, BITS, 32)}
if BITS == 256:
    _edges |= {10 ** 77}
EDGES = sorted({wrap(v) for v in _edges} | ({wrap(-v) for v in _edges} if SIGNED else set()))
SHIFTS = [0, 1, 4, 31, 32, 33, 63, 64, 65, 127, 128, 129, 200, 255, 256, 257, 1000]
BAD_DECIMAL = ["", "-", "+1", " 1", "1 ", "1.5", "1e3", "0x10", "a", "--1", "-+1", str(M), str(M + 5),
               str(10 ** 78), "9" * 100, str(HIGH + 1), str(LOW - 1)]
if not SIGNED:
    BAD_DECIMAL.append("-1")
BAD_HEX = ["", "0x", "0X", "g", "0xg", " 0x1", "0x 1", "0x" + "1" + "0" * BYTES * 2, "F" * (BYTES * 2 + 1),
           "-", "-0x", "0x-1", "--1", "+1", f"{HIGH + 1:x}", f"0x{HIGH + 1:x}", f"-0x{-LOW + 1:x}"]
if not SIGNED:
    BAD_HEX.append("-1")


def pair_lines(a, b):
    x, y = hexed(a), hexed(b)
    yield f"add {x} {y} {hexed(a + b)}"
    yield f"sub {x} {y} {hexed(a - b)}"
    yield f"mul {x} {y} {hexed(a * b)}"
    if b:
        yield f"div {x} {y} {hexed(divide(a, b))}"
        yield f"rem {x} {y} {hexed(remainder(a, b))}"
    yield f"and {x} {y} {hexed(a & b)}"
    yield f"or {x} {y} {hexed(a | b)}"
    yield f"xor {x} {y} {hexed(a ^ b)}"
    yield f"lt {x} {y} {int(a < b)}"
    yield f"le {x} {y} {int(a <= b)}"
    yield f"gt {x} {y} {int(a > b)}"
    yield f"ge {x} {y} {int(a >= b)}"
    yield f"eq {x} {y} {int(a == b)}"
    yield f"ne {x} {y} {int(a != b)}"
    yield f"addc {x} {y} {checked(a + b)}"
    yield f"subc {x} {y} {checked(a - b)}"
    yield f"mulc {x} {y} {checked(a * b)}"


def one_lines(a, rng):
    x = hexed(a)
    pattern = a % M
    yield f"not {x} 0 {hexed(~a)}"
    yield f"neg {x} 0 {hexed(-a)}"
    yield f"dec {x} 0 {a}"
    yield f"decp {a} 0 {x}"
    if a >= 0:
        yield f"decp {'0' * rng.randrange(4)}{a} 0 {x}"
    else:
        yield f"decp -{'0' * rng.randrange(4)}{-a} 0 {x}"
    if SIGNED:
        yield f"hexs {x} 0 {text_hex(a)}"
        yield f"hexp {text_hex(a)} 0 {x}"
        yield f"hexp {text_hex(a).upper().replace('0X', '0x')} 0 {x}"
        if a < 0:
            yield f"hexp -{-a:x} 0 {x}"
        else:
            yield f"hexp {a:x} 0 {x}"
    else:
        yield f"hexs {x} 0 0x{x}"
        yield f"hexp 0x{x} 0 {x}"
        yield f"hexp {x.upper()} 0 {x}"
    yield f"lowc {x} 0 1"
    yield f"bytes {x} 0 {pattern.to_bytes(BYTES, 'big').hex()}"
    yield f"bytesle {x} 0 {pattern.to_bytes(BYTES, 'little').hex()}"
    if SIGNED:
        minimal = 0 if a == 0 else ((a.bit_length() if a > 0 else (~a).bit_length()) + 1 + 7) // 8
        length = rng.randrange(minimal, BYTES + 1)
        if length:
            yield f"bytesp {a.to_bytes(length, 'big', signed=True).hex()} 0 {x}"
            yield f"bytesple {a.to_bytes(length, 'little', signed=True).hex()} 0 {x}"
        yield f"sign {x} 0 {(a > 0) - (a < 0) + 1}"
        yield f"abs {x} 0 {hexed(abs(a))}"
    else:
        length = rng.randrange((a.bit_length() + 7) // 8, BYTES + 1) if a else rng.randrange(BYTES + 1)
        if length:
            yield f"bytesp {a.to_bytes(length, 'big').hex()} 0 {x}"
            yield f"bytesple {a.to_bytes(length, 'little').hex()} 0 {x}"
        yield f"bits {x} 0 {a.bit_length()}"
    index = rng.randrange(BITS)
    yield f"bit {x} {index:x} {(pattern >> index) & 1}"
    yield f"u64n {x} 0 {narrowed(a, 0, 2 ** 64 - 1)}"
    yield f"intn {x} 0 {narrowed(a, -2 ** 63 if SIGNED else 0, 2 ** 63 - 1)}"
    yield f"u32n {x} 0 {narrowed(a, 0, 2 ** 32 - 1)}"
    yield f"u16n {x} 0 {narrowed(a, 0, 2 ** 16 - 1)}"
    yield f"u8n {x} 0 {narrowed(a, 0, 2 ** 8 - 1)}"
    if SIGNED:
        yield f"i32n {x} 0 {narrowed(a, -2 ** 31, 2 ** 31 - 1)}"
    yield f"u64 {x} 0 {hexed(pattern & (2 ** 64 - 1))}"
    yield f"u32 {x} 0 {hexed(pattern & (2 ** 32 - 1))}"
    yield f"u16 {x} 0 {hexed(pattern & 65535)}"
    yield f"u8 {x} 0 {hexed(pattern & 255)}"
    low = pattern & (2 ** 64 - 1)
    yield f"sext {hexed(low)} 0 {hexed(low if low < 2 ** 63 else low - 2 ** 64)}"
    yield f"zext {hexed(low)} 0 {hexed(low)}"


def shift_lines(a, count):
    x = hexed(a)
    pattern = a % M
    yield f"shl {x} {count:x} {hexed(a << count) if count < BITS else '0'}"
    yield f"shr {x} {count:x} {hexed(a >> count) if count < BITS else '0'}"
    if SIGNED:
        yield f"ushr {x} {count:x} {hexed(pattern >> count) if count < BITS else '0'}"
    else:
        yield f"shlw {x} {count:x} {hexed(a << count) if count < BITS else '0'}"
        yield f"shrw {x} {count:x} {hexed(a >> count) if count < BITS else '0'}"


def random_value(rng):
    value = wrap(rng.getrandbits(rng.randrange(BITS + 1)))
    return wrap(-value) if SIGNED and rng.randrange(2) else value


def lines(seed, count):
    rng = random.Random(seed)
    out = []
    for text in BAD_DECIMAL:
        out.append(f"decp {text.replace(' ', '_') or '_'} 0 n")
    for text in BAD_HEX:
        out.append(f"hexp {text.replace(' ', '_') or '_'} 0 n")
    out.append("bytesp " + "01" * (BYTES + 1) + " 0 n")
    out.append("bytesple " + "01" * (BYTES + 1) + " 0 n")
    if SIGNED:
        out.append("decp -0 0 0")
    for a in EDGES:
        out.extend(one_lines(a, rng))
        for count_ in SHIFTS:
            out.extend(shift_lines(a, count_))
    for a in EDGES:
        for b in rng.sample(EDGES, min(4 if SIGNED else 9, len(EDGES))):
            out.extend(pair_lines(a, b))
    corners = sorted({wrap(v) for v in (LOW, LOW + 1, -1, 0, 1, 2, HIGH - 1, HIGH, TOP, TOP - 1, M >> 1, (M >> 1) + 1)})
    for a in corners:
        for b in corners:
            out.extend(pair_lines(a, b))
    while len(out) < count:
        a = random_value(rng)
        b = random_value(rng) if rng.randrange(4) else rng.choice(EDGES)
        out.extend(pair_lines(a, b))
        out.extend(one_lines(a, rng))
        out.extend(shift_lines(a, rng.choice(SHIFTS + [rng.randrange(BITS)])))
    return out


def main():
    seed, count = int(sys.argv[1]), int(sys.argv[2])
    if "--decimal-abla" in sys.argv[3:]:
        rng = random.Random(seed)
        values = sorted(set(EDGES) | {wrap(10 ** n + d) for n in range(BITS * 3 // 10 + 1) for d in (-1, 0, 1)}
                        | ({wrap(-(10 ** n + d)) for n in range(BITS * 3 // 10 + 1) for d in (-1, 0, 1)} if SIGNED else set()))
        values += [random_value(rng) for _ in range(count)]
        print('// Generated decimal answers from Python, including powers of ten and their neighbors.')
        print(f'import "abla/{TYPE}"')
        print('val DECIMALS = "' + ''.join(str(n) + '\\n' for n in values) + '"')
        print(f'''
fun decimalText(): string {{
    var out = ""
    var start = 0
    for (at in 0 until DECIMALS.size) {{
        if (int(DECIMALS[at]) == 10) {{
            val value = {TYPE}FromDecimal(DECIMALS.slice(start, at))
            if (value == null) return "parse failed"
            out = "$out$value\\n"
            start = at + 1
        }}
    }}
    out
}}
compile fun compiledDecimalText(): string = decimalText()
val compiledDecimals = #compiledDecimalText()
fun main: int {{
    if (compiledDecimals != DECIMALS) return 1
    if (decimalText() != DECIMALS) return 2
    0
}}
''')
        return
    cases = lines(seed, count)
    if "--abla" in sys.argv[3:]:
        print("// Generated by tools/wide-integers/gen-cases.py.")
        print('val WIDE_CASES = "' + "\\n".join(cases) + '\\n"')
    else:
        print("\n".join(cases))


main()
