# Sourced by suite tests that run the release tools (release-check.sh and the scripts it calls): a suite test must never
# depend on the network, because a slow or rate-limited GitHub API can hang a gate (it did on 2026-11-27).
#
#   offline_setup WORKDIR   makes WORKDIR/offline-bin with fakes of gh, curl and wget that log each call to
#                           WORKDIR/network.log and fail, and a recorded comparison.json of a green bootstrap-convergence run
#                           (lineage v9.9.8, source 000...0), and sets:
#                             offline              the directory to put first on PATH
#                             offline_flags        release-check.sh options that make its convergence check read the
#                                                  recorded comparison (release-convergence.sh then needs no gh)
#   offline_check           fails (exit 1, listing the calls) if anything reached for the network.
#
# The fake gh answers one call, `gh run view 1 ...` (check 7b, static-input, reads the run's Linux job log), with nothing: run 1
# has no Release Linux job, so 7b is a SKIP (tools/test-release-check-static-input.sh judges 7b with a job log of its own).
offline_setup() {
    local work=$1 tool
    offline=$work/offline-bin
    offline_log=$work/network.log
    mkdir -p "$offline"
    : > "$offline_log"
    for tool in curl wget; do
        cat > "$offline/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$offline_log"
exit 1
EOF
        chmod +x "$offline/$tool"
    done
    cat > "$offline/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = "run view 1" ]; then exit 0; fi
echo "gh \$*" >> "$offline_log"
exit 1
EOF
    chmod +x "$offline/gh"
    local source=0000000000000000000000000000000000000000
    local a b c one two three four five
    a=$(printf '%064d' 0 | tr 0 a); b=$(printf '%064d' 0 | tr 0 b); c=$(printf '%040d' 0 | tr 0 c)
    one=$(printf '%064d' 0 | tr 0 1); two=$(printf '%064d' 0 | tr 0 2); three=$(printf '%064d' 0 | tr 0 3)
    four=$(printf '%064d' 0 | tr 0 4); five=$(printf '%064d' 0 | tr 0 5)
    cat > "$work/comparison.json" <<JSON
{"passed": true, "candidate": {"revision": "$source", "tree": "t"}, "lineage": "v9.9.8",
 "seeds": {"a": {"version": "v9.9.8", "sha256": "$a"}, "b": {"version": "v9.9.7", "sha256": "$b"}},
 "historical_revision": "$c", "canonical_root": "/build/source", "entry": "src/orc_main.ab",
 "canonical_ir_sha256": "$one", "stage2_binary_sha256": "$two", "stage2_object_sha256": "$three",
 "toolchain": {"environment_sha256": "$four", "closure_sha256": "$five"}}
JSON
    offline_flags=(--lineage v9.9.8 --source-ref "$source" --convergence-comparison "$work/comparison.json")
}

offline_check() {
    [[ ! -s $offline_log ]] && return 0
    echo "a suite test reached for the network (tools/lib/test-offline.sh):" >&2
    head -n 5 "$offline_log" >&2
    exit 1
}
