# Sourced by the TLS test scripts that need an `openssl s_server` as the peer (. "$(dirname "${BASH_SOURCE[0]}")/lib/openssl-server.sh").
#
#   openssl_server_start LOG BIND [s_server options...]
#
# starts `openssl s_server -accept BIND OPTIONS` in the background (output to LOG), waits up to 30 s for its ACCEPT line and sets
# openssl_server_pid and openssl_server_port. BIND names the address, with port 0: the kernel picks the port and s_server
# reports it, so there is no random number in Linux's ephemeral range (32768 and up) that a parallel suite's outgoing
# connection may hold, and nobody else can be on the port. "0" binds [::] (IPv4 and IPv6 clients both reach it); "[::1]:0"
# binds ::1 only, for a client that resolves "localhost" to ::1 (the pure TLS client does), so no family is left to chance.
# Returns 1, with s_server's first lines on stderr, when it does not start; a bind that fails with "Address already in
# use" (only possible when a caller names a port) is retried on port 0.
#
# Environment: OPENSSL_SERVER_DIR (the directory s_server runs in, for -www/-HTTP files), OPENSSL_SERVER_FIRST_BIND (the
# BIND of the first attempt only: a test hook to exercise the retry), OPENSSL_SERVER_INHERIT_STDIN=1 (s_server reads the
# caller's stdin, `openssl_server_start ... < <(sleep 30)`, instead of /dev/null).
openssl_server_pid=
openssl_server_port=
openssl_server_start() {
    local log=$1 bind=$2 attempt use _
    shift 2
    for attempt in 1 2 3 4 5 6 7 8; do
        use=$bind
        [[ $attempt -eq 1 && -n ${OPENSSL_SERVER_FIRST_BIND:-} ]] && use=$OPENSSL_SERVER_FIRST_BIND
        # Empty the log HERE, before the child starts: a log that is truncated only by the child's own redirection still holds the
        # previous server's ACCEPT line until that process gets to run, and on a loaded machine the grep below can run first
        # and return the previous server's (closed) port.
        : > "$log"
        if [[ -n ${OPENSSL_SERVER_INHERIT_STDIN:-} ]]; then
            (cd "${OPENSSL_SERVER_DIR:-.}" && exec openssl s_server -accept "$use" "$@") 0<&0 > "$log" 2>&1 &
        else
            (cd "${OPENSSL_SERVER_DIR:-.}" && exec openssl s_server -accept "$use" "$@") < /dev/null > "$log" 2>&1 &
        fi
        openssl_server_pid=$!
        for _ in $(seq 300); do
            if grep -q '^ACCEPT' "$log" 2> /dev/null; then
                openssl_server_port=$(sed -n 's/^ACCEPT .*:\([0-9][0-9]*\)$/\1/p' "$log" | head -1)
                [[ -n $openssl_server_port ]] && return 0
                break
            fi
            kill -0 "$openssl_server_pid" 2> /dev/null || break
            sleep 0.1
        done
        kill "$openssl_server_pid" 2> /dev/null || true
        wait "$openssl_server_pid" 2> /dev/null || true
        openssl_server_pid=
        grep -q 'Address already in use' "$log" 2> /dev/null || break
    done
    echo "openssl s_server did not start (bind $use): $(head -3 "$log" 2> /dev/null)" >&2
    return 1
}

# openssl_server_show PORT: for a failure that says tcp_connect, what the kernel knows about the port and the log's head.
openssl_server_show() {
    command -v ss > /dev/null || return 0
    echo "sockets on port $1 (ss -tanp), s_server pid ${openssl_server_pid:-none}:" >&2
    ss -tanp "( sport = :$1 or dport = :$1 )" 2>&1 | head -12 >&2
}
