#!/bin/sh
# Deterministic child modes for compilerCaptureProcess boundary checks.
# Run as `sh child.sh MODE [ARGUMENT]`.
set -eu

case $1 in
bytes)
    # \0 \377 A repeated, cut to exactly ARGUMENT bytes. Built by doubling a file:
    # a printf loop took over a second for 1 MiB and ran into the capture deadline
    # under load and on macOS.
    pattern=${TMPDIR:-/tmp}/abla-capture-bytes.$$
    trap 'rm -f "$pattern" "$pattern.next"' EXIT
    printf '\000\377A' > "$pattern"
    size=3
    while [ "$size" -lt "$2" ]; do
        cat "$pattern" "$pattern" > "$pattern.next"
        mv "$pattern.next" "$pattern"
        size=$((size * 2))
    done
    head -c "$2" "$pattern"
    ;;
exit)
    exit "$2"
    ;;
signal)
    kill -TERM $$
    sleep 30
    ;;
stdin)
    [ "$(cat | wc -c | tr -d ' ')" = 0 ]
    printf closed
    ;;
environment)
    printf '%s' "$ABLA_CAPTURE_MARKER"
    ;;
mark)
    printf spawned > "$2"
    ;;
descendant)
    # Exit while our descendant still holds the stdout pipe open.
    sleep 30 < /dev/null &
    printf '%s' "$!" > "$2"
    ;;
overflow-descendant)
    # The descendant runs before the output cap is triggered.
    sleep 30 < /dev/null &
    printf '%s' "$!" > "$2"
    head -c 65536 /dev/zero | tr '\000' x
    sleep 30
    ;;
esac
