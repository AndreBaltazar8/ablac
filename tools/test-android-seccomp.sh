#!/usr/bin/env bash
# Every system call an arm64 Android library can issue is allowed by Android's app seccomp policy (#1194). Android (8.0 and later) starts app
# processes under a seccomp-bpf filter; a call outside it ends the app with SIGSYS, which neither QEMU user mode (no filter) nor the link
# check sees. The library issues its calls through abla_x64_syscall (the x86-64 -> AArch64 translator the backend emits into it): this
# test builds libraries (small, threaded, rich, release and debug runtimes), finds every call of the translator in the machine code and the
# constant x86-64 number it passes (tools/android-seccomp-sites.awk), maps it through the translator's table and handlers (src/backend/llvm)
# to the AArch64 calls the translator makes, and checks each against the policy of five bionic revisions, from the pinned files in
# tests/data/android-seccomp (README.md there: how the policy is made). A call that is not allowed in every revision fails with its name,
# numbers and the function that issues it. A call site whose number the scan cannot see must be in tools/android-seccomp-unresolved.tsv.
# A control library calling setuid (blocked by SECCOMP_BLOCKLIST_APP.TXT) must be rejected.
# Needs llvm-objdump; without it the test says so and skips (exit 0) unless ABLA_REQUIRE_ANDROID_TESTS=1.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $compiler == /* || $compiler != */* ]] || compiler=$root/$compiler
data=tests/data/android-seccomp
objdump=$(command -v llvm-objdump || true)
if [[ -z $objdump ]]; then
    if [[ ${ABLA_REQUIRE_ANDROID_TESTS:-0} == 1 ]]; then
        echo 'android seccomp: required llvm-objdump missing' >&2
        exit 1
    fi
    echo 'android seccomp: llvm-objdump missing; skipped'
    exit 0
fi
out=build/android-seccomp
rm -rf "$out"
mkdir -p "$out"
fail() { echo "android seccomp: $*" >&2; exit 1; }
(cd "$data" && sha256sum -c --quiet SHA256SUMS) || fail "the pinned policy files in $data do not match SHA256SUMS"

# --- the policy: the names Android allows an app on arm64, per bionic revision --------------------------------------------------------------
# A line of SYSCALLS.TXT or SECCOMP_*.TXT is "<type> <function>[|alias][:syscall[:id]](<parameters>) <architectures>"; the system call is
# the name after the first colon, else the function. lp64 and all cover arm64.
names_of() { # file -> system call names available on arm64
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            line = $0
            arches = line; sub(/^.*\)/, "", arches); gsub(/[[:space:]]/, "", arches)
            head = line; sub(/\(.*$/, "", head); n = split(head, words, /[[:space:]]+/); token = words[n]
            if (token == "") token = words[n - 1]
            m = split(token, parts, ":"); name = (m >= 2) ? parts[2] : token; sub(/\|.*$/, "", name)
            k = split(arches, list, ",")
            for (i = 1; i <= k; i++) if (list[i] == "all" || list[i] == "arm64" || list[i] == "lp64") { print name; break }
        }' "$1" | sort -u
}
revisions=
for dir in "$data"/android-*; do
    revision=$(basename -- "$dir")
    revisions="$revisions $revision"
    : > "$out/$revision.base"; : > "$out/$revision.add"; : > "$out/$revision.remove"
    names_of "$dir/SYSCALLS.TXT" > "$out/$revision.base"
    for file in "$dir"/SECCOMP_*.TXT; do
        case $(basename -- "$file") in
            *BLOCKLIST* | *BLACKLIST*) names_of "$file" >> "$out/$revision.remove" ;;
            *) names_of "$file" >> "$out/$revision.add" ;;
        esac
    done
    sort -u -o "$out/$revision.remove" "$out/$revision.remove"
    sort -u -o "$out/$revision.add" "$out/$revision.add"
    comm -23 "$out/$revision.base" "$out/$revision.remove" | cat - "$out/$revision.add" | sort -u > "$out/$revision.allowed"
    [[ -s $out/$revision.allowed && $(wc -l < "$out/$revision.allowed") -gt 100 ]] || fail "$revision: the policy has too few names ($(wc -l < "$out/$revision.allowed"))"
done
# arm64 number -> name
awk 'NR > 2 { name[$2] = $1 } END { for (n in name) print n, name[n] }' "$data/arm64-syscalls.txt" > "$out/arm64-names.txt"

# --- the translator: x86-64 number -> the AArch64 calls it makes ------------------------------------------------------------------------------
# core.ab has the table (".hword" lines of bootstrapLlvmLinuxGenericSyscallNumbers): the AArch64 number, 0xffff for ENOSYS, or 0x8000 + the
# index of a handler of aarch64.ab, whose `mov x8, #n` before `svc #0` are its calls (a handler with no svc falls through to the next).
awk '
    /fun bootstrapLlvmLinuxGenericSyscallNumbers/ { inside = 1; next }
    inside && /^}/ { exit }
    inside && /\.hword/ { line = $0; sub(/^.*\.hword[[:space:]]+/, "", line); sub(/\\n.*$/, "", line); k = split(line, v, ","); for (i = 1; i <= k; i++) print n++, v[i] }
' src/backend/llvm/core.ab > "$out/x86-table.txt"
[[ $(wc -l < "$out/x86-table.txt") -eq 335 ]] || fail "the translator table in src/backend/llvm/core.ab has $(wc -l < "$out/x86-table.txt") entries, not 335"
awk '
    /^fun bootstrapLlvmAarch64SyscallAssembly/ { inside = 1; next }
    inside && /^}/ { exit }
    inside && /"\.word \.Lx64_/ { line = $0; while (match(line, /\.Lx64_[a-z0-9_]+ - 5b/)) { name = substr(line, RSTART + 1, RLENGTH - 6); print "H", count++, name; line = substr(line, RSTART + RLENGTH) } }
    inside && /"\.Lx64_[a-z0-9_]+:/ { match($0, /\.Lx64_[a-z0-9_]+/); label = substr($0, RSTART + 1, RLENGTH - 1); order[++labels] = label; svc[label] = 0 }
    inside && /mov x8, #[0-9]+/ && label != "" { s = $0; while (match(s, /mov x8, #[0-9]+/)) { numbers[label] = numbers[label] " " substr(s, RSTART + 9, RLENGTH - 9); s = substr(s, RSTART + RLENGTH) } }
    inside && /svc #0/ && label != "" { svc[label] = 1 }
    END {
        for (i = labels; i >= 1; i--) { l = order[i]; if (!svc[l] && i < labels) { numbers[l] = numbers[l] numbers[order[i + 1]]; svc[l] = svc[order[i + 1]] } }
        for (i = 1; i <= labels; i++) { l = order[i]; print "L", l, numbers[l] }
    }
' src/backend/llvm/aarch64.ab > "$out/handlers.txt"
[[ $(grep -c '^H ' "$out/handlers.txt") -eq 28 ]] || fail "src/backend/llvm/aarch64.ab names $(grep -c '^H ' "$out/handlers.txt") handlers, not 28"
# x86 number -> "arm64 numbers"
awk '
    FILENAME ~ /handlers/ { if ($1 == "H") handler[$2] = $3; else { numbers[$2] = ""; for (i = 3; i <= NF; i++) numbers[$2] = numbers[$2] " " $i } next }
    {
        value = $2 + 0
        if (value == 65535) { print $1, "enosys"; next }
        if (value >= 32768) { h = handler[value - 32768]; print $1, "handler", h, numbers[h]; next }
        print $1, "direct", value
    }
' "$out/handlers.txt" "$out/x86-table.txt" > "$out/x86-map.txt"

# --- checking a library -------------------------------------------------------------------------------------------------------------------
# check_library <library> <label>: prints a line per violation, returns 1 when there is one
check_library() {
    local library=$1 label=$2 sites violations=0 count
    "$objdump" -d --no-show-raw-insn "$library" > "$out/$label.asm"
    awk -f tools/android-seccomp-sites.awk "$out/$label.asm" "$out/$label.asm" > "$out/$label.sites"
    count=$(wc -l < "$out/$label.sites")
    [[ $count -gt 0 || $label == small ]] || fail "$label: found no system call site in $library"
    # every (x86 number, function) pair
    : > "$out/$label.calls"; : > "$out/$label.used"
    while IFS=$'\t' read -r numbers function address; do
        if [[ $numbers == '?' ]]; then
            if ! awk -F'\t' -v f="$function" '$1 == f { found = 1; print $2 } END { exit !found }' tools/android-seccomp-unresolved.tsv > "$out/$label.unresolved"; then
                printf '%s: the system call number at %s in %s is not a constant the scan can see (add it to tools/android-seccomp-unresolved.tsv with the numbers it can be)\n' \
                    "$label" "$address" "$function"
                violations=1
                continue
            fi
            numbers=$(tr ',' ' ' < "$out/$label.unresolved" | tr '\n' ',' | sed 's/,$//')
        fi
        for n in ${numbers//,/ }; do printf '%s\t%s\t%s\n' "$n" "$function" "$address" >> "$out/$label.calls"; done
    done < "$out/$label.sites"
    # x86 number -> arm64 numbers -> names -> allowed in every revision
    local x86 function address entry kind via arm
    while IFS=$'\t' read -r x86 function address; do
        entry=$(awk -v n="$x86" '$1 == n { $1 = ""; print; exit }' "$out/x86-map.txt")
        [[ -n $entry ]] || { printf '%s: x86-64 system call %s (%s in %s) is beyond the translator table\n' "$label" "$x86" "$address" "$function"; violations=1; continue; }
        set -- $entry
        kind=$1
        case $kind in
            enosys) continue ;;
            direct) arm=$2; via='' ;;
            handler) via=$2; shift 2; arm=$* ;;
        esac
        for number in $arm; do
            name=$(awk -v n="$number" '$1 == n { print $2; exit }' "$out/arm64-names.txt")
            [[ -n $name ]] || { printf '%s: arm64 system call %s has no name in %s/arm64-syscalls.txt\n' "$label" "$number" "$data"; violations=1; continue; }
            local denied=
            for revision in $revisions; do
                grep -qxF -- "$name" "$out/$revision.allowed" || denied="$denied $revision"
            done
            if [[ -n $denied ]]; then
                printf '%s: %s (arm64 %s, from x86-64 %s%s) is not allowed to an app in:%s; issued by %s at %s\n' \
                    "$label" "$name" "$number" "$x86" "${via:+ through $via}" "$denied" "$function" "$address"
                violations=1
            else
                printf '%s\t%s\t%s\t%s\n' "$name" "$number" "$x86" "$function" >> "$out/$label.used"
            fi
        done
    done < <(sort -u "$out/$label.calls")
    return $violations
}

build_library() { # <label> <build program> <ABLA_DEBUG> -> $out/<label>.so
    local label=$1 program=$2 debug=$3 dir
    ABLA_DEBUG=$debug "$compiler" build "tests/cases/android-seccomp/build-$program.ab" -o "$out/build-$label" --fast --no-cache > "$out/build-$label.log" 2>&1 ||
        { cat "$out/build-$label.log" >&2; fail "building the $label library failed"; }
    local status=0
    ABLA_DEBUG=$debug "$out/build-$label" > "$out/run-$label.log" 2>&1 || status=$?
    [[ $status -eq 37 ]] || { cat "$out/run-$label.log" >&2; fail "building the $label library failed ($status)"; }
    dir=$out/$program/src/main/jniLibs/arm64-v8a
    [[ -f $dir/libabla_app.so ]] || fail "no $dir/libabla_app.so"
    cp "$dir/libabla_app.so" "$out/$label.so"
}

status=0
total=0
for variant in small:small:0 threads:threads:0 threads-debug:threads:1 rich-release:rich-release:0 rich-debug:rich:1; do
    IFS=: read -r label program debug <<< "$variant"
    build_library "$label" "$program" "$debug"
    check_library "$out/$label.so" "$label" || status=1
    total=$((total + 1))
done
[[ $status -eq 0 ]] || fail "a system call outside Android's app seccomp policy is reachable (the policy: $data/README.md)"
# the control: a library that calls setuid must be rejected, by name
build_library denied denied 0
if check_library "$out/denied.so" denied > "$out/denied.report" 2>&1; then
    fail 'accepted the control library that calls setuid'
fi
grep -q '^denied: setuid (arm64 146, from x86-64 105) is not allowed to an app in:.* issued by [^ ]* at [0-9a-f]*$' "$out/denied.report" ||
    { cat "$out/denied.report" >&2; fail 'the control was rejected, but not as setuid'; }
distinct=$(cat "$out"/*.used | cut -f1 | sort -u | wc -l)
echo "android seccomp: $distinct distinct system calls in 5 libraries, all allowed to an app in $(wc -w <<< "$revisions") bionic revisions; the setuid control is rejected"
