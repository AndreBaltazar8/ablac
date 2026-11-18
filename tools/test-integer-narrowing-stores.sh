#!/usr/bin/env bash
# An int does not narrow implicitly where a narrower integer is stored, not only where it is passed (#953's neighbour):
# a local, a `var` or field or element assignment, an array literal, a result. A literal that fits needs no
# conversion; one that does not, or any int value, is integer.narrowing. They were accepted and kept out-of-range bits
# (`val a: u8 = 256` printed 256, `val a: u8 = someInt` kept 300) or silently wrapped (a result, an array literal).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/integer-narrowing-stores
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/integer-narrowing-stores/valid.ab -o "$out/valid" --fast --no-cache
got=$("$out/valid")
[[ $got == "255 -128 0 44 32767 255 200 255 A 255 -128 44 255 44 2 44
0 7 8 9 11 12 13" ]] ||{ echo "integer narrowing stores: valid.ab printed '$got'" >&2; exit 1; }
"$compiler" build tests/cases/integer-narrowing-stores/lambda.ab -o "$out/lambda" --fast --no-cache
got=$("$out/lambda")
[[ $got == "0 7 -3 9 5 200 1" ]] || { echo "integer narrowing stores: lambda.ab printed '$got'" >&2; exit 1; }
reject() { # $1 = name, $2 = declarations, $3 = statements of main
    printf 'class Box(var value: u8)\n%s\nfun main: int {\n%s\n    0\n}\n' "$2" "$3" > "$out/$1.ab"
    if "$compiler" build "$out/$1.ab" -o "$out/$1" --fast --no-cache > "$out/$1.log" 2>&1; then
        echo "integer narrowing stores: $1 was accepted" >&2; exit 1
    fi
    grep -Eq "error\[E_SEMANTIC\]: ${4:-integer\.narrowing}:" "$out/$1.log" ||
        { echo "integer narrowing stores: $1 lacks integer.narrowing:" >&2; cat "$out/$1.log" >&2; exit 1; }
}
reject local-u8 '' '    val a: u8 = 256'
reject local-i8 '' '    val a: i8 = -129'
reject local-negative '' '    val a: u8 = -1'
reject local-u32 '' '    val a: u32 = 4294967296'
reject local-u16 '' '    val a: u16 = 65536'
reject local-i32 '' '    val a: i32 = 2147483648'
reject local-char '' '    val a: char = 256'
reject local-int-value '' $'    val i = 300\n    val a: u8 = i'
reject local-if '' '    val a: u8 = if (true) 256 else 0'
reject assign-literal '' $'    var a: u8 = 0\n    a = 256'
reject assign-int-value '' $'    var a: u8 = 0\n    val i = 7\n    a = i'
reject field-literal '' $'    val box = Box(0)\n    box.value = 256'
reject element-literal '' $'    val items: array<u8> = [1]\n    items[0] = 256'
reject array-literal '' '    val items: array<u8> = [1, 256]'
reject result-statement 'fun f(): u8 {
    return 256
}' '    val a = f()'
reject result-expression 'fun f(): u8 = 256' '    val a = f()'
reject result-int-value 'fun f(i: int): u8 = i' '    val a = f(1)'
reject append-literal "" $'    val items: array<i8> = []\n    items.append(300)'
reject append-int-value "" $'    val items: array<u8> = []\n    val i = 5\n    items.append(i)'
reject append-u32 "" $'    val items: array<u32> = []\n    items.append(-1)'
reject map-set-literal "" $'    val table: Map<string, u8> = Map()\n    table.set("k", 300)'
reject map-set-int-value "" $'    val table: Map<string, i16> = Map()\n    val i = 1\n    table.set("k", i)'
reject cell-set-literal "" $'    val cell = Cell(u8(1))\n    cell.set(256)'
reject cell-set-int-value "" $'    val cell = Cell(u8(1))\n    val i = 1\n    cell.set(i)'
# A block's last expression is its result: an int value there, or a literal that doesn't fit, still narrows.
reject block-tail-int-value $'fun f(x: int): u32 {\n    val n: int = x\n    n\n}' '    val a = f(1)'
reject block-tail-literal $'fun f(x: int): u32 {\n    val n = x\n    4294967296\n}' '    val a = f(1)'
reject if-block-int-value $'fun f(x: int): u8 {\n    val n = x\n    if (n > 0) {\n        val m = n\n        m\n    } else 1\n}' '    val a = f(1)'
reject when-int-value $'fun f(x: int): u8 = when (x) {\n    1 -> 3\n    else -> x\n}' '    val a = f(1)'
reject when-literal $'fun f(x: int): u8 = when (x) {\n    1 -> 256\n    else -> 0\n}' '    val a = f(1)'
reject local-if-block $'fun f(x: int): int {\n    val a: u8 = if (x > 0) {\n        val y = x\n        y\n    } else 2\n    0\n}' '    val a = f(1)'
# A lambda's result takes the expected function type only for a literal that fits.
reject lambda-int-value $'fun take(f: (int) -> u32): u32 = f(1)' '    take({ x -> x })' 'function\.(argument|result)|local\.initializer'
reject lambda-block-int-value $'fun take(f: (int) -> u8): u8 = f(1)' $'    take({ x ->\n        val y = x + 1\n        y\n    })' 'function\.(argument|result)|local\.initializer'
reject lambda-literal-range $'fun take(f: (int) -> u8): u8 = f(1)' '    take({ x -> 256 })' 'function\.(argument|result)|local\.initializer'
reject lambda-if-int-value $'fun make(): (int) -> u8 = { x -> if (x > 0) 5 else x }' '    make()' 'function\.(argument|result)|local\.initializer'
reject lambda-declared-int-value '' '    val f: (int) -> u16 = { x -> x }' 'function\.(argument|result)|local\.initializer'
echo "integer narrowing stores: fitting literals and conversions accepted in every store (lambda results too), 35 other forms rejected"
