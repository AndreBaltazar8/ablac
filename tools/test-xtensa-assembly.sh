#!/usr/bin/env bash
# Offline exact differential against the frozen SDK transform's recorded output; no Xtensa LLVM needed.
# tests/cases/xtensa-routing/golden/ holds what Espressif's SDK script (pinned in assembly-provenance.json)
# printed for the complete firmware assembly and for an operand-edge fixture, in the four modes.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
fixtures=$root/tests/cases/xtensa-routing
golden=$fixtures/golden
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-xtensa-assembly-XXXXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL Xtensa assembly: $*" >&2; exit 1; }

sha() { sha256sum | cut -d' ' -f1; }
want=$(sed -n 's/.*"firmwareAssemblySha256": "\([0-9a-f]*\)".*/\1/p' "$fixtures/assembly-provenance.json")
zcat "$fixtures/firmware.s.gz" >"$work/firmware.in.s"
[[ $(sha <"$work/firmware.in.s") == "$want" ]] || fail 'firmware.s.gz is not the pinned assembly'

"$compiler" build "$fixtures/assembly.ab" --fast --no-cache -o "$work/assembly"
run() { "$work/assembly" "$1" "$2" "$3"; }

for name in edges firmware; do
    if [[ $name == edges ]]; then input=$golden/edges.input.s; else input=$work/firmware.in.s; fi
    for mode in narrow keep no-narrow keep-no-narrow; do
        if [[ $name == edges ]]; then cp "$golden/edges.$mode.s" "$work/expected"
        else zcat "$golden/firmware.$mode.s.gz" >"$work/expected"; fi
        run "$input" "$work/actual" "$mode"
        cmp -s "$work/actual" "$work/expected" || fail "$name: exact SDK differential failed (mode $mode)"
        cmp -s "$input" "$work/expected" && fail "$name: fixture exercises no transformation (mode $mode)"
        case $mode in narrow | keep)
            # A broken transform (one narrow encoding lost) must not match.
            sed '0,/movi\.n/s//movi/' "$work/actual" >"$work/broken"
            cmp -s "$work/broken" "$work/expected" && fail "$name: broken transform was not detected"
        esac
    done
done

# The module encoding: the assembly body unchanged, then an alignment of each literal pool.
decode() { # decode <module.ll> <out>: the payload of `module asm "..."` with its \XX escapes undone
    local payload
    payload=$(sed -n 's/^module asm "//p' "$1" | sed 's/"$//')
    printf '%b' "$(printf '%s' "$payload" | sed 's/\\\([0-9A-F][0-9A-F]\)/\\x\1/g')" >"$2"
}
pools() { # pools <decoded> <skip bytes>: the sections whose pool is aligned
    tail -c +$(($2 + 1)) "$1" | awk '/^\.pushsection /{n=$2; sub(/,.*/,"",n); getline a; getline b; if (a == ".p2align 2" && b == ".popsection") print n}' | sort
}
run "$golden/edges.input.s" "$work/module.ll" module
[[ $(sed -n '1p' "$work/module.ll") == 'source_filename = "abla"' ]] || fail 'module: source_filename'
grep -F 'target triple = "xtensa-esp-unknown-elf"' "$work/module.ll" >/dev/null || fail 'module: triple'
run "$work/firmware.in.s" "$work/module.ll" module
grep -F 'module asm "' "$work/module.ll" >/dev/null || fail 'module: no module asm'
grep -F '\0A' "$work/module.ll" >/dev/null || fail 'module: no escaped newline'
grep -F '.p2align 2' "$work/module.ll" >/dev/null || fail 'module: no alignment'
decode "$work/module.ll" "$work/decoded"
tail -n +2 "$work/firmware.in.s" >"$work/body"   # the input without its `.file "abla"` first line
[[ $(head -n 1 "$work/firmware.in.s") == $'\t.file\t"abla"' ]] || fail 'firmware does not begin with .file "abla"'
size=$(stat -c %s "$work/body")
head -c "$size" "$work/decoded" | cmp -s - "$work/body" || fail 'module encoding changed the assembly body'
got=$(pools "$work/decoded" "$size")
for section in .iram1.abla.freertos.yield.literal .iram1.abla.freertos.coproc_exc_hook.literal; do
    grep -Fx -- "$section" <<<"$got" >/dev/null || fail "module: $section pool not aligned"
done

# Section-stack and expression cases must align the pool actually used, without modifying the input
# assembly or inventing a neighbouring pool.
printf '%s\n' '.section .text.root,"ax",@progbits' 'movi a2, 65536' \
    '.pushsection .iram.child,"ax",@progbits' 'movi a3, symbol + 8' '.popsection' 'movi a4, other_symbol' \
    '.previous' 'movi a5, child_symbol' '.text' 'movi a6, last_symbol' \
    '.section ".text.quoted","ax",@progbits' 'movi a7, final_symbol' >"$work/sections.s"
run "$work/sections.s" "$work/module.ll" module
decode "$work/module.ll" "$work/decoded"
size=$(stat -c %s "$work/sections.s")
head -c "$size" "$work/decoded" | cmp -s - "$work/sections.s" || fail 'sections: the input assembly was modified'
got=$(pools "$work/decoded" "$size" | tr '\n' ' ')
[[ $got == '.iram.child.literal .literal .literal.quoted .literal.root ' ]] || fail "sections: pools were $got"

# The empty-module envelope must not encode an input filename or PID. ELF data directives let stock
# host llc prove this offline.
if command -v llc >/dev/null 2>&1; then
    printf '\t.file\t"abla"\n.section .rodata.abla_probe,"a",@progbits\n.long 42\n' >"$work/probe.s"
    run "$work/probe.s" "$work/probe.ll" module
    for stem in first-process-123 other-process-987; do
        cp "$work/probe.ll" "$work/$stem.ll"
        llc -mtriple=x86_64-unknown-linux-gnu -filetype=obj "$work/$stem.ll" -o "$work/$stem.o"
    done
    cmp -s "$work/first-process-123.o" "$work/other-process-987.o" || fail 'temporary module filename leaked into the object'
else
    echo 'SKIP object-envelope reproducibility: host llc is unavailable'
fi
echo 'PASS Xtensa assembly: SDK exact text on operand edges and complete firmware, raw regions, CFI, and negative control'
