#!/usr/bin/env bash
# A gate's suite holds its slot's two fair-flock locks for half an hour; the next gate on that slot can build its stages
# inside that hold instead of after it (tools/gate.sh). The suite marks the hold, and only a live, matching mark is lent:
#
#   tools/gate-hold.sh mark <file> <pid>        record <pid> (the process inside the locks) and its start time in <file>
#   tools/gate-hold.sh live <file>              exit 0 when <file> names a process that is running and started when it says
#   tools/gate-hold.sh borrow <file> <cmd...>   run <cmd> in a session of its own while that process lives: when it ends
#                                               (or <file> stops naming it) the session's group is killed and this exits 75
#
# A process is its PID and its start time (/proc/<pid>/stat, field 22): a PID reused after the holder ended does not match.
# A mark left by a holder that was killed (no trap ran) names a dead process, or another one, and is not lent. Only a regular
# file this user owns is a mark (not a symlink): tools/gate.sh keeps them in a directory of this user's (mode 700), and a
# mark someone else made could otherwise lend a hold that no suite has.
set -euo pipefail

usage() { echo "usage: tools/gate-hold.sh mark <file> <pid> | live <file> | borrow <file> <command...>" >&2; exit 2; }

# Field <n> (3 or more) of /proc/<pid>/stat; fails when there is no such process, or it has ended.
stat_field() { # pid n
    local stat fields
    [[ $1 =~ ^[1-9][0-9]*$ ]] || return 1
    stat=$(head -c 4096 "/proc/$1/stat" 2> /dev/null) || return 1
    # The command name (field 2) is in parentheses and may hold spaces; the fields after it are plain.
    read -r -a fields <<< "${stat##*) }"
    # fields[0] is field 3 (the state).
    [[ ${#fields[@]} -ge 20 && ${fields[0]} != Z && ${fields[0]} != X ]] || return 1
    printf '%s\n' "${fields[$2 - 3]}"
}

live() { # <file>
    local pid start now
    [[ -f $1 && -O $1 && ! -L $1 ]] || return 1
    read -r pid start <<< "$(head -c 64 -- "$1" 2> /dev/null)" || return 1
    [[ -n ${start:-} ]] || return 1
    now=$(stat_field "$pid" 22) || return 1
    [[ $now == "$start" ]]
}

(($# >= 2)) || usage
case $1 in
    mark)
        (($# == 3)) || usage
        start=$(stat_field "$3" 22) || { echo "gate-hold: no process $3" >&2; exit 1; }
        printf '%s %s\n' "$3" "$start" > "$2.tmp.$$"
        mv -f -- "$2.tmp.$$" "$2"
        ;;
    live)
        (($# == 2)) || usage
        live "$2"
        ;;
    borrow)
        (($# >= 3)) || usage
        file=$2
        shift 2
        live "$file" || exit 75
        # Without job control the background child is no group leader, so setsid makes it a session leader without
        # forking and $! is the command's own session: what a cut kills. Checked, not assumed: had setsid forked, --wait
        # keeps $! alive outside the new session, and the command (its child) is killed and nothing is borrowed.
        set +m
        setsid --wait "$@" &
        child=$!
        # wait-ok: a setsid that has not made its session in 5 s is treated as one that forked: nothing is borrowed.
        for _ in $(seq 50); do
            session=$(stat_field "$child" 6) || break
            [[ $session == "$child" ]] && break
            sleep 0.1
        done
        if session=$(stat_field "$child" 6) && [[ $session != "$child" ]]; then
            echo "gate-hold: the borrowed command is not in a session of its own; not borrowing" >&2
            for forked in $(cat /proc/$child/task/*/children 2> /dev/null); do kill -KILL -- "-$forked" 2> /dev/null || true; done
            kill -KILL "$child" 2> /dev/null || true
            wait "$child" 2> /dev/null || true
            exit 75
        fi
        cut=0
        while kill -0 "$child" 2> /dev/null; do
            if ! live "$file"; then
                cut=1
                kill -TERM -- "-$child" 2> /dev/null || true
                sleep 2
                kill -KILL -- "-$child" 2> /dev/null || true
                break
            fi
            sleep 1
        done
        status=0
        wait "$child" || status=$?
        ((cut)) && exit 75
        exit "$status"
        ;;
    *) usage ;;
esac
