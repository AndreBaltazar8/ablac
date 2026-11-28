#!/usr/bin/env bash
# The trusted contract (docs/language.md, "Trusted native implementations") puts the safety argument inside a `trusted` function, so its callers stay
# safe for any arguments. A public `trusted` function that takes an address as an integer or a pointer cannot make that argument: safe code could import
# and call it (`aesWipe(16, 8)` wrote to address 16; #1139 area 7). The standard library therefore keeps such functions out of its public modules:
# `private` when nothing outside the file calls them, and else in a file of the module that is not its entry (`// public: none`, docs/language.md: a name
# from such a file is internal, no import makes it visible, in strict and flat modules alike).
# This test lists every public `trusted` function (any attributes, any name, signature over several lines too) of an ENTRY file of the library (outside
# abla/unsafe, abla/runtime and abla/sys), or of a file the entry re-exports (`export import "./byte-lanes.ab"`), with an int or a pointer parameter, and
# compares the list with tools/trusted-address-review.tsv, which classes each:
#   a  not an address: a count, a flag, an offset the callee bounds, a descriptor, an index the host validates (the reason is in the table);
#   t  an address (taken or returned) that only trusted code may use: the declaration is marked `@__abla_trusted_only` (decision #130 A) or is a trusted
#      extern, so a call from code that is not trusted is native.trust (tools/test-unsafe-trusted-only.sh); a (t) row whose declaration lost the mark fails;
#   c  an address with no safe alternative, a named exception (none now: the bignum engine moved to bignum/core.ab behind BigModulus and BigNumber).
#   b  (the table keeps them for the record) an address with a safe alternative: must NOT be public.
# A new public function that takes an int or a pointer fails until it is added to the table with its class; an (a), (t) or (c) row whose function is gone
# fails (drop the row); a (b) row that is public again fails.
# Usage: tools/test-trusted-raw-addresses.sh
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
table=tools/trusted-address-review.tsv
out=build/trusted-raw-addresses
mkdir -p "$out"
export LC_ALL=C
git ls-files 'stdlib/*entry.ab' | grep -vE '^stdlib/abla/(unsafe|runtime|sys)/' | sort | while IFS= read -r file; do
    # The entry and the files it re-exports, each listed under the entry's module.
    sources=("$file")
    while IFS= read -r exported; do
        [[ -n $exported ]] && sources+=("$(dirname "$file")/${exported#./}")
    done < <(sed -nE 's|^export import "(\./[^"]+)".*|\1|p' "$file")
    awk -v file="$file" '
        function flush(   params, depth, i, ch, p, n, hit, k) {
            params = ""; depth = 0
            for (i = 1; i <= length(sig); i++) {
                ch = substr(sig, i, 1)
                if (ch == "(") { depth++; if (depth == 1) continue }
                if (ch == ")") { depth--; if (depth == 0) break }
                if (depth >= 1) params = params ch
            }
            hit = (params ~ /:[ ]*int([^A-Za-z0-9_]|$)/) || (params ~ /:[ ]*[A-Za-z0-9_<>]+\*/)
            if (hit) print file "\t" name "\t" marked
        }
        /^(@[A-Za-z]+(\([^)]*\))? )*(inline |noinline )?trusted( noescape)?( extern:"[a-z]+")? fun / {
            line = $0
            sub(/^(@[A-Za-z]+(\([^)]*\))? )*(inline |noinline )?trusted( noescape)?( extern:"[a-z]+")? fun /, "", line)
            name = line; sub(/\(.*/, "", name)
            # A trusted extern is native.trust from code that is not trusted already, as a marked declaration is.
            marked = (previous ~ /^@__abla_trusted_only/ || $0 ~ / extern:"[a-z]+" fun /) ? "marked" : "-"
            sig = line; open = 1
            if (balanced(sig)) { flush(); open = 0 }
            previous = $0
            next
        }
        open { sig = sig " " $0; if (balanced(sig)) { flush(); open = 0 } }
        { previous = $0 }
        function balanced(s,   i, d, ch) { d = 0; for (i = 1; i <= length(s); i++) { ch = substr(s, i, 1); if (ch == "(") d++; if (ch == ")") d-- } return d == 0 && s ~ /\(/ }
    ' "${sources[@]}"
done | sed -E 's|^stdlib/(abla/[^\t]*)/entry\.ab\t|\1\t|' | sort -u > "$out/scanned.tsv"
cut -f1,2 "$out/scanned.tsv" | sort -u > "$out/current.tsv"
awk -F'\t' '$3 == "marked" { print $1 "\t" $2 }' "$out/scanned.tsv" | sort -u > "$out/marked.tsv"
awk -F'\t' 'NR > 1 && ($9 == "a" || $9 == "t" || $9 == "c") { print "abla/" $1 "\t" $2 }' "$table" | sort -u > "$out/allowed.tsv"
awk -F'\t' 'NR > 1 && $9 == "t" { print "abla/" $1 "\t" $2 }' "$table" | sort -u > "$out/trusted-only.tsv"
comm -23 "$out/trusted-only.tsv" "$out/marked.tsv" > "$out/unmarked.tsv"
awk -F'\t' 'NR > 1 && $9 == "b" { print "abla/" $1 "\t" $2 }' "$table" | sort -u > "$out/hidden.tsv"
comm -13 "$out/allowed.tsv" "$out/current.tsv" > "$out/unlisted.tsv"
comm -12 "$out/hidden.tsv" "$out/current.tsv" > "$out/leaked.tsv"
comm -23 "$out/allowed.tsv" "$out/current.tsv" > "$out/gone.tsv"
status=0
if [[ -s $out/leaked.tsv ]]; then
    echo "trusted raw addresses: these take an address, have a safe alternative (class b) and are public again; make them private or move them to the module's raw.ab:" >&2
    cat "$out/leaked.tsv" >&2; status=1
fi
if [[ -s $out/unlisted.tsv ]]; then
    echo "trusted raw addresses: a public trusted function with an int or pointer parameter that $table does not class (add a row: a = not an address, with why; or hide it):" >&2
    cat "$out/unlisted.tsv" >&2; status=1
fi
if [[ -s $out/unmarked.tsv ]]; then
    echo "trusted raw addresses: rows of $table classed t (trusted-only) whose declaration is not marked @__abla_trusted_only (mark it, or hide it):" >&2
    cat "$out/unmarked.tsv" >&2; status=1
fi
if [[ -s $out/gone.tsv ]]; then
    echo "trusted raw addresses: rows of $table whose function is not public any more (drop them, or class them b):" >&2
    cat "$out/gone.tsv" >&2; status=1
fi
((status == 0)) || exit 1
echo "trusted raw addresses: $(wc -l < "$out/allowed.tsv") public functions with an int or pointer parameter, all classed (t: $(wc -l < "$out/trusted-only.tsv") marked trusted-only; c: $(awk -F'\t' 'NR>1 && $9=="c"' "$table" | wc -l) named exceptions); none of the $(wc -l < "$out/hidden.tsv") that take an address with a safe alternative is public"
