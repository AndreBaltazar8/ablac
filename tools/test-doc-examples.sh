#!/usr/bin/env bash
# Compiles and runs every Abla example in the documentation.
#
#   tools/test-doc-examples.sh [COMPILER] [DOC.md ...]
#
# With no documents it checks README.md, docs/*.md and docs/*/*.md. Every
# fenced block whose info string starts with `abla` is an example; the words
# after `abla` select what is checked (docs/README.md#examples documents the
# convention):
#
#   ```abla            a complete program: it must compile; when it declares
#                      `fun main` it is run, and its standard output must equal
#                      the `// output:` comment block (when there is one) and its
#                      exit status the `// exit: N` comment (default 0 when the
#                      block has `// output:`, unchecked otherwise, but a crash
#                      always fails)
#   ```abla build      a complete program that is compiled but not run
#                      (servers, programs that read input)
#   ```abla error      a program that must NOT compile; each `// error: TEXT`
#                      comment names text the diagnostics must contain
#   ```abla fragment   not compiled: syntax shown out of context
#   ```abla file=NAME  not compiled itself: written as NAME next to the later
#                      programs of the same document (a module they import);
#                      the same works for any language (```toml file=abla.toml),
#                      and an abla.toml applies only to the next program
#
# Every relative Markdown link must name an existing file, and an anchor in it
# a heading of that file.
#
# Environment: DOC_EXAMPLES_FILTER (a substring of "doc:line" to run a subset,
# which also skips the link check), DOC_EXAMPLES_LINKS_ONLY=1 (check links only),
# DOC_EXAMPLES_KEEP=1 (keep the work directory), DOC_EXAMPLES_JOBS (examples
# built at once, default the number of CPUs), ABLA_MAX_SECONDS (per program).
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
shift || true
if [[ $compiler != /* ]]; then compiler=$PWD/$compiler; fi
if (($# == 0)); then
    set -- "$project_root/README.md"
    for doc in "$project_root"/docs/*.md "$project_root"/docs/*/*.md; do
        [[ -f $doc ]] && set -- "$@" "$doc"
    done
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/abla-doc-examples.XXXXXX")
if [[ ${DOC_EXAMPLES_KEEP:-0} != 1 ]]; then
    trap 'rm -rf "$work"' EXIT
else
    echo "doc examples: work directory $work"
fi
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-60}
export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$ABLA_MAX_SECONDS}

jobs=${DOC_EXAMPLES_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
passed=0
failed=0
skipped=0
links=0
failures=()

fail() { # $1 = location, $2 = reason, $3 = log file (optional)
    failed=$((failed + 1))
    failures+=("$1: $2")
    printf 'FAIL %s: %s\n' "$1" "$2"
    if [[ -n ${3:-} && -s $3 ]]; then sed -n '1,40p' "$3" | sed 's/^/    /'; fi
}

# The expected output: the comment lines after `// output:` up to the first
# line that is not a `//` comment or is the `// exit: N` comment.
expected_output() {
    awk '
        found && /^[[:space:]]*\/\/ exit: *[0-9]/ { exit }
        found && /^[[:space:]]*\/\/ ?/ { sub(/^[[:space:]]*\/\/ ?/, ""); print; next }
        found { exit }
        /^[[:space:]]*\/\/ output:[[:space:]]*$/ { found = 1 }
    ' "$1"
}

# An example's verdict, in <directory>/result: "pass", or "fail", the reason
# and the log to show, a line each.
verdict_fail() { # $1 = directory, $2 = reason, $3 = log file (optional)
    printf 'fail\n%s\n%s\n' "$2" "${3:-}" >"$1/result"
}

# Checks one example; runs in a job of its own, so it only writes its verdict.
check_program() { # $1 = mode, $2 = source, $3 = location, $4 = directory
    local mode=$1 source=$2 location=$3 dir=$4
    local binary=$dir/program log=$dir/build.log status has_main=0
    local emit=()
    if grep -qE '^[[:space:]]*fun main\b' "$source"; then has_main=1; fi
    # A library-shaped example (no main) is built as an object file.
    if ((has_main == 0)); then emit=(--emit object); binary=$dir/program.o; fi
    set +e
    (cd "$dir" && "$compiler" build "$source" -o "$binary" --fast ${emit[@]+"${emit[@]}"}) >"$log" 2>&1
    status=$?
    set -e
    if [[ $mode == error ]]; then
        if ((status == 0)); then
            verdict_fail "$dir" "expected a compile error, but it compiled"
            return
        fi
        local wanted
        while IFS= read -r wanted; do
            if ! grep -qF -- "$wanted" "$log"; then
                verdict_fail "$dir" "diagnostics lack '$wanted'" "$log"
                return
            fi
        done < <(sed -n 's/^[[:space:]]*\/\/ error: *//p' "$source")
        echo pass >"$dir/result"
        return
    fi
    if ((status != 0)); then
        verdict_fail "$dir" "does not compile" "$log"
        return
    fi
    if [[ $mode == build ]] || ((has_main == 0)); then
        echo pass >"$dir/result"
        return
    fi
    set +e
    (cd "$dir" && "$project_root/tools/run-limited.sh" "$binary") \
        >"$dir/stdout" 2>"$dir/stderr" </dev/null
    status=$?
    set -e
    local exit_expected
    exit_expected=$(sed -n 's/^[[:space:]]*\/\/ exit: *\([0-9][0-9]*\).*/\1/p' "$source" | head -1)
    if grep -qE '^[[:space:]]*// output:[[:space:]]*$' "$source"; then
        expected_output "$source" >"$dir/expected"
        if ! cmp -s "$dir/expected" "$dir/stdout"; then
            diff "$dir/expected" "$dir/stdout" >"$dir/diff" 2>&1 || true
            verdict_fail "$dir" "output differs (< expected, > actual)" "$dir/diff"
            return
        fi
        exit_expected=${exit_expected:-0}
    fi
    if [[ -n $exit_expected ]] && ((status != exit_expected)); then
        verdict_fail "$dir" "exit status $status, expected $exit_expected" "$dir/stderr"
        return
    fi
    if ((status >= 124)); then
        verdict_fail "$dir" "crashed or timed out (status $status)" "$dir/stderr"
        return
    fi
    echo pass >"$dir/result"
}

# The anchors GitHub gives the headings of a Markdown file, one per line.
heading_anchors() {
    awk '
        /^```/ { fenced = !fenced; next }
        fenced || !/^#+ / { next }
        {
            text = tolower($0); sub(/^#+ +/, "", text)
            gsub(/[^a-z0-9 _-]/, "", text); gsub(/ /, "-", text)
            anchor = (seen[text]++ ? text "-" (seen[text] - 1) : text)
            print anchor
        }
    ' "$1"
}

# Each relative link of a Markdown file outside code, as "line target".
markdown_links() {
    awk '
        /^```/ { fenced = !fenced; next }
        fenced { next }
        {
            line = $0
            gsub(/`[^`]*`/, "", line)
            while (match(line, /\]\([^) ]+\)/)) {
                target = substr(line, RSTART + 2, RLENGTH - 3)
                line = substr(line, RSTART + RLENGTH)
                if (target !~ /^[a-z]+:/) print NR " " target
            }
        }
    ' "$1"
}

check_links() { # $1 = document, $2 = its name for messages
    local doc=$1 name=$2 line target file anchor resolved
    while read -r line target; do
        file=${target%%#*}
        anchor=
        [[ $target == *"#"* ]] && anchor=${target#*#}
        if [[ -z $file ]]; then resolved=$doc
        else resolved=$(dirname "$doc")/$file; fi
        if [[ ! -e $resolved ]]; then
            fail "$name:$line" "broken link: $target"
        elif [[ -n $anchor && $resolved == *.md ]] &&
            ! grep -qxF -- "$anchor" <<<"$(heading_anchors "$resolved")"; then
            fail "$name:$line" "broken link anchor: $target"
        else
            links=$((links + 1))
        fi
    done < <(markdown_links "$doc")
}

for doc in "$@"; do
    name=${doc#"$project_root"/}
    if [[ -z ${DOC_EXAMPLES_FILTER:-} ]]; then check_links "$doc" "$name"; fi
    [[ ${DOC_EXAMPLES_LINKS_ONLY:-0} == 1 ]] && continue
    doc_dir=$work/$(printf '%s' "$name" | tr '/.' '__')
    mkdir -p "$doc_dir/files" "$doc_dir/blocks"
    # One file per fenced block: blocks/<n>, and a line "<n> <line> <info>" in index.
    awk -v out="$doc_dir/blocks" '
        !inside && /^```/ {
            inside = 1; n++; info = substr($0, 4)
            printf "%d %d %s\n", n, NR, info > (out "/index")
            file = out "/" n; printf "" > file; next
        }
        inside && /^```[[:space:]]*$/ { inside = 0; close(file); next }
        inside { print > file }
    ' "$doc"
    [[ -f $doc_dir/blocks/index ]] || continue
    while read -r n line info; do
        read -r language mode _ <<<"$info" || true
        location="$name:$line"
        file_name=
        for word in $info; do
            case $word in file=*) file_name=${word#file=} ;; esac
        done
        if [[ -n $file_name ]]; then
            mkdir -p "$(dirname "$doc_dir/files/$file_name")"
            cp "$doc_dir/blocks/$n" "$doc_dir/files/$file_name"
            continue
        fi
        [[ $language == abla ]] || continue
        if [[ -n ${DOC_EXAMPLES_FILTER:-} && $location != *"$DOC_EXAMPLES_FILTER"* ]]; then
            continue
        fi
        case ${mode:-run} in
            fragment) skipped=$((skipped + 1)); continue ;;
            run | build | error) ;;
            *) fail "$location" "unknown example mode '$mode'"; continue ;;
        esac
        dir=$doc_dir/run-$n
        mkdir -p "$dir"
        cp -R "$doc_dir/files/." "$dir/"
        rm -f "$doc_dir/files/abla.toml"
        cp "$doc_dir/blocks/$n" "$dir/main.ab"
        printf '%s\0%s\0%s\0%s\0' "${mode:-run}" "$dir/main.ab" "$location" "$dir" >>"$work/examples"
    done <"$doc_dir/blocks/index"
done

# Every example is set up in its own directory above (a document's `file=`
# blocks apply in order); they build and run in parallel, and their verdicts
# are reported in document order.
if [[ -s $work/examples ]]; then
    export compiler project_root
    export -f check_program verdict_fail expected_output
    xargs -0 -n4 -P "$jobs" bash -c 'check_program "$@"' check_program <"$work/examples"
    while IFS= read -r -d '' mode && IFS= read -r -d '' source &&
        IFS= read -r -d '' location && IFS= read -r -d '' dir; do
        if [[ $(sed -n 1p "$dir/result" 2>/dev/null) == pass ]]; then
            passed=$((passed + 1))
        elif [[ -f $dir/result ]]; then
            fail "$location" "$(sed -n 2p "$dir/result")" "$(sed -n 3p "$dir/result")"
        else
            fail "$location" "the check stopped before its verdict"
        fi
    done <"$work/examples"
fi

printf 'doc examples: %d passed, %d failed, %d fragments; %d links checked\n' \
    "$passed" "$failed" "$skipped" "$links"
if ((failed > 0)); then
    printf '  %s\n' "${failures[@]}"
    exit 1
fi
