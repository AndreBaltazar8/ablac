#!/bin/sh
# Deterministic child modes for compilerCaptureProcess boundary checks.
# Run as `sh child.sh MODE [ARGUMENT]`.
set -eu

case $1 in
bytes)
    # \0 \377 A repeated, cut to exactly ARGUMENT bytes.
    while :; do printf '\000\377A'; done 2>/dev/null | head -c "$2"
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
